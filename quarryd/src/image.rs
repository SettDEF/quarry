//! The image pipeline.
//!
//! Everything the app does to a picture happens here: decode (raster or
//! vector), fit, crop, mask, encode, plus the derived data the catalogue needs
//! — thumbnail ladder, perceptual hash, dominant colour, placeholder.
//!
//! Two rules shape the module:
//!
//! * **Render at the final size, never resample a render.** A vector is
//!   rasterised at each ladder step from its own source, which is why an SVG
//!   avatar is sharp at 32px and at 1024px.
//! * **An export is a printable op chain.** The UI shows it under *Advanced*,
//!   and that is how an export gets debugged — the same reason not to shell out
//!   to ImageMagick, where the chain would live in someone's argv.

//! The export sheet (Phase 7) consumes the rest of this module; the daemon
//! already uses load/apply/encode/thumb_ladder/phash/dominant_color today.
#![allow(dead_code)]
use image::{DynamicImage, GenericImageView, ImageFormat, Rgba, RgbaImage};
use serde::{Deserialize, Serialize};

#[derive(Debug)]
pub enum ImageError {
    Decode(String),
    Encode(String),
    Svg(String),
    Empty,
}

impl std::fmt::Display for ImageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImageError::Decode(e) => write!(f, "decode: {e}"),
            ImageError::Encode(e) => write!(f, "encode: {e}"),
            ImageError::Svg(e) => write!(f, "svg: {e}"),
            ImageError::Empty => write!(f, "empty image"),
        }
    }
}

pub type Result<T> = std::result::Result<T, ImageError>;

/// How a source is made to fill a target box.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Fit {
    /// Fill the box and crop the overflow — what an avatar wants.
    Cover,
    /// Fit inside the box and pad — what an icon wants.
    Contain,
    /// Ignore the aspect ratio. Included because sometimes it is genuinely what
    /// you want, not because it is ever the default.
    Stretch,
    /// Leave the pixels alone.
    None,
}

/// Where a crop is taken from when `Cover` has to discard something.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Gravity {
    Center,
    North,
    South,
    East,
    West,
    /// The busiest region, by entropy — where the subject usually is.
    Smart,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Png,
    Jpeg,
    WebpLossless,
}

/// A rectangle of the source, in source pixels.
///
/// Present when the crop was chosen by hand. The gravity settings decide where
/// an *automatic* crop lands; this overrides them entirely, because a person who
/// has dragged a box has said something more specific than "smart".
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Crop {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// One export, described rather than performed — this is what the UI prints.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recipe {
    pub width: u32,
    pub height: u32,
    pub fit: Fit,
    pub gravity: Gravity,
    pub format: Format,
    /// 1–100, JPEG only.
    pub quality: u8,
    /// Corner radius in pixels; `width/2` is a circle.
    pub radius: u32,
    /// Background for `Contain`, as `#rrggbb` or `#rrggbbaa`.
    pub background: String,
    /// A hand-chosen crop, in source pixels. `None` leaves it to `gravity`.
    #[serde(default)]
    pub crop: Option<Crop>,
}

impl Default for Recipe {
    fn default() -> Self {
        // The Steam avatar, because it is the one people ask for first — but it
        // is a default, not a special case: everything here is per-target data.
        Recipe {
            width: 184,
            height: 184,
            fit: Fit::Cover,
            gravity: Gravity::Center,
            format: Format::Png,
            quality: 92,
            radius: 0,
            background: "#00000000".into(),
            crop: None,
        }
    }
}

// ── loading ─────────────────────────────────────────────────────────────────

/// Is this SVG? Sniffed rather than trusted from the extension, because CDNs
/// serve `.png` URLs that are SVG and vice versa.
pub fn is_svg(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(1024)];
    let text = String::from_utf8_lossy(head);
    text.contains("<svg") || (text.contains("<?xml") && text.contains("svg"))
}

/// Dimensions and format without decoding the pixels — cheap enough to run over
/// a whole crawl.
pub fn probe(bytes: &[u8]) -> Result<(u32, u32, String)> {
    if bytes.is_empty() {
        return Err(ImageError::Empty);
    }
    if is_svg(bytes) {
        let size = svg_size(bytes)?;
        return Ok((size.0, size.1, "svg".into()));
    }
    let format = image::guess_format(bytes).map_err(|e| ImageError::Decode(e.to_string()))?;
    let reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), format);
    let (w, h) = reader.into_dimensions().map_err(|e| ImageError::Decode(e.to_string()))?;
    Ok((w, h, format!("{format:?}").to_lowercase()))
}

/// Animated? Only GIF and WebP can be, and the catalogue needs to know because
/// the grid shows a still and only the hovered tile animates.
pub fn is_animated(bytes: &[u8]) -> bool {
    match image::guess_format(bytes) {
        Ok(ImageFormat::Gif) => {
            // More than one image descriptor (0x2C) means more than one frame.
            bytes.iter().filter(|b| **b == 0x2C).count() > 1
        }
        Ok(ImageFormat::WebP) => bytes.windows(4).any(|w| w == b"ANMF"),
        _ => false,
    }
}

/// What a decode learned about a video it had to open. `None` for a still.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoFacts {
    pub w: u32,
    pub h: u32,
    pub duration: f64,
}

/// Decode a raster, rasterise a vector, or take a frame from a video.
///
/// `hint` matters only for vectors: a raster ignores it, a vector renders to it
/// exactly, which is the whole reason vectors export perfectly at any size.
///
/// Video is handled HERE rather than at each call site on purpose. Everything
/// downstream — the thumbnail ladder, the perceptual hash, the dominant colour,
/// the detail preview — wants a picture and does not care where it came from,
/// and a frame from a video is a picture. One place to teach, and the whole
/// pipeline works on video with nothing else changed.
pub fn load(bytes: &[u8], hint: (u32, u32)) -> Result<DynamicImage> {
    load_any(bytes, hint).map(|(image, _)| image)
}

/// `load`, keeping what a video decode measured along the way.
///
/// Only the thumbnail path wants this: it is the moment the daemon has the
/// actual file in hand, and therefore the only honest source of a duration.
pub fn load_any(bytes: &[u8], hint: (u32, u32)) -> Result<(DynamicImage, Option<VideoFacts>)> {
    if bytes.is_empty() {
        return Err(ImageError::Empty);
    }
    if is_svg(bytes) {
        return render_svg(bytes, hint.0.max(1), hint.1.max(1)).map(|image| (image, None));
    }
    if is_video(bytes) {
        let (frame, w, h, duration) = video_still(bytes)?;
        return Ok((frame, Some(VideoFacts { w, h, duration })));
    }
    image::load_from_memory(bytes)
        .map(|image| (image, None))
        .map_err(|e| ImageError::Decode(e.to_string()))
}

fn parse_svg(bytes: &[u8]) -> Result<usvg::Tree> {
    // usvg's defaults drop scripts and external references, which is the point:
    // an SVG is code, and it never reaches a renderer that could run it.
    let options = usvg::Options::default();
    usvg::Tree::from_data(bytes, &options).map_err(|e| ImageError::Svg(e.to_string()))
}

/// The SVG's own nominal size, from its viewBox.
pub fn svg_size(bytes: &[u8]) -> Result<(u32, u32)> {
    let tree = parse_svg(bytes)?;
    let size = tree.size();
    Ok((size.width().ceil() as u32, size.height().ceil() as u32))
}

/// Rasterise at exactly this size — not "render then scale".
pub fn render_svg(bytes: &[u8], width: u32, height: u32) -> Result<DynamicImage> {
    let tree = parse_svg(bytes)?;
    let size = tree.size();
    let scale = (width as f32 / size.width()).min(height as f32 / size.height());

    let mut pixmap = tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| ImageError::Svg("zero-sized pixmap".into()))?;

    // Centre the drawing in the target box, so a non-square icon in a square
    // tile is centred rather than pinned to a corner.
    let dx = (width as f32 - size.width() * scale) / 2.0;
    let dy = (height as f32 - size.height() * scale) / 2.0;
    let transform = tiny_skia::Transform::from_translate(dx, dy).pre_scale(scale, scale);

    resvg::render(&tree, transform, &mut pixmap.as_mut());

    RgbaImage::from_raw(width, height, pixmap.data().to_vec())
        .map(DynamicImage::ImageRgba8)
        .ok_or_else(|| ImageError::Svg("pixmap did not fit an RgbaImage".into()))
}

/// Is a monochrome vector — one fill colour, so it can be recoloured to any
/// hex or to a live palette role.
pub fn svg_is_tintable(bytes: &[u8]) -> bool {
    let text = String::from_utf8_lossy(bytes);
    let mut colours = std::collections::HashSet::new();
    for token in text.split(['"', '\'', ' ', ';', ':', '(', ')']) {
        if token.starts_with('#') && (token.len() == 4 || token.len() == 7) {
            colours.insert(token.to_ascii_lowercase());
        }
    }
    colours.remove("#none");
    colours.len() <= 1
}

// ── transforms ──────────────────────────────────────────────────────────────

/// The crop rectangle `Cover` would take: the largest region of the source
/// with the target's aspect ratio, placed by gravity.
pub fn cover_rect(
    (sw, sh): (u32, u32),
    (tw, th): (u32, u32),
    gravity: Gravity,
    image: Option<&DynamicImage>,
) -> (u32, u32, u32, u32) {
    if sw == 0 || sh == 0 || tw == 0 || th == 0 {
        return (0, 0, sw, sh);
    }
    let target = tw as f64 / th as f64;
    let source = sw as f64 / sh as f64;

    let (cw, ch) = if source > target {
        ((sh as f64 * target).round() as u32, sh)
    } else {
        (sw, (sw as f64 / target).round() as u32)
    };

    let (max_x, max_y) = (sw.saturating_sub(cw), sh.saturating_sub(ch));
    let (x, y) = match gravity {
        Gravity::Center => (max_x / 2, max_y / 2),
        Gravity::North => (max_x / 2, 0),
        Gravity::South => (max_x / 2, max_y),
        Gravity::West => (0, max_y / 2),
        Gravity::East => (max_x, max_y / 2),
        Gravity::Smart => match image {
            Some(img) => busiest_offset(img, (cw, ch)),
            None => (max_x / 2, max_y / 2),
        },
    };

    (x.min(max_x), y.min(max_y), cw, ch)
}

/// Where the detail is.
///
/// Entropy over a coarse grid: the subject of a picture is almost always the
/// part with the most variation, and cropping a face out of frame is the single
/// most annoying thing an avatar tool can do.
fn busiest_offset(image: &DynamicImage, (cw, ch): (u32, u32)) -> (u32, u32) {
    let (sw, sh) = image.dimensions();
    if cw >= sw && ch >= sh {
        return (0, 0);
    }

    let small = image.thumbnail(64, 64).to_luma8();
    let (gw, gh) = small.dimensions();
    if gw < 2 || gh < 2 {
        return ((sw - cw) / 2, (sh - ch) / 2);
    }

    // Per-pixel gradient magnitude, summed over the candidate window.
    let mut energy = vec![0f64; (gw * gh) as usize];
    for y in 1..gh {
        for x in 1..gw {
            let here = small.get_pixel(x, y)[0] as f64;
            let left = small.get_pixel(x - 1, y)[0] as f64;
            let up = small.get_pixel(x, y - 1)[0] as f64;
            energy[(y * gw + x) as usize] = (here - left).abs() + (here - up).abs();
        }
    }

    let win_w = ((cw as f64 / sw as f64) * gw as f64).round().max(1.0) as u32;
    let win_h = ((ch as f64 / sh as f64) * gh as f64).round().max(1.0) as u32;

    let mut best = (0u32, 0u32, -1f64);
    for y in 0..=gh.saturating_sub(win_h) {
        for x in 0..=gw.saturating_sub(win_w) {
            let mut sum = 0.0;
            for wy in y..(y + win_h).min(gh) {
                for wx in x..(x + win_w).min(gw) {
                    sum += energy[(wy * gw + wx) as usize];
                }
            }
            if sum > best.2 {
                best = (x, y, sum);
            }
        }
    }

    let x = ((best.0 as f64 / gw as f64) * sw as f64).round() as u32;
    let y = ((best.1 as f64 / gh as f64) * sh as f64).round() as u32;
    (x.min(sw - cw), y.min(sh - ch))
}

fn parse_rgba(hex: &str) -> Rgba<u8> {
    let clean = hex.trim_start_matches('#');
    let bytes = |i: usize| u8::from_str_radix(&clean[i..i + 2], 16).unwrap_or(0);
    match clean.len() {
        6 => Rgba([bytes(0), bytes(2), bytes(4), 255]),
        8 => Rgba([bytes(0), bytes(2), bytes(4), bytes(6)]),
        _ => Rgba([0, 0, 0, 0]),
    }
}

/// Apply a recipe. This is the export, and the whole of it.
pub fn apply(source: &DynamicImage, recipe: &Recipe) -> Result<DynamicImage> {
    let (sw, sh) = source.dimensions();
    if sw == 0 || sh == 0 {
        return Err(ImageError::Empty);
    }
    let (tw, th) = (recipe.width.max(1), recipe.height.max(1));

    /*
     * A hand-chosen crop happens first, and then everything else treats the
     * result as the whole picture. That is what makes the box you dragged mean
     * exactly what it looked like: fit, gravity and padding all apply to the
     * region you chose rather than to the original.
     */
    let cropped;
    let source = match recipe.crop {
        Some(crop) if crop.w > 0 && crop.h > 0 => {
            let x = crop.x.min(sw.saturating_sub(1));
            let y = crop.y.min(sh.saturating_sub(1));
            let w = crop.w.min(sw - x);
            let h = crop.h.min(sh - y);
            cropped = source.crop_imm(x, y, w, h);
            &cropped
        }
        _ => source,
    };
    let (sw, sh) = source.dimensions();

    let mut out = match recipe.fit {
        Fit::None => source.clone(),
        Fit::Stretch => source.resize_exact(tw, th, image::imageops::FilterType::Lanczos3),
        Fit::Cover => {
            let (x, y, cw, ch) = cover_rect((sw, sh), (tw, th), recipe.gravity, Some(source));
            source
                .crop_imm(x, y, cw, ch)
                // Lanczos3: this is a downscale to a small square most of the
                // time, and a cheaper filter shows as mush at 184px.
                .resize_exact(tw, th, image::imageops::FilterType::Lanczos3)
        }
        Fit::Contain => {
            let fitted = source.resize(tw, th, image::imageops::FilterType::Lanczos3);
            let mut canvas = RgbaImage::from_pixel(tw, th, parse_rgba(&recipe.background));
            let (fw, fh) = fitted.dimensions();
            image::imageops::overlay(
                &mut canvas,
                &fitted.to_rgba8(),
                ((tw - fw) / 2) as i64,
                ((th - fh) / 2) as i64,
            );
            DynamicImage::ImageRgba8(canvas)
        }
    };

    if recipe.radius > 0 {
        out = round_corners(&out, recipe.radius);
    }
    Ok(out)
}

/// Rounded corners, or a circle when the radius reaches half the short side.
pub fn round_corners(image: &DynamicImage, radius: u32) -> DynamicImage {
    let mut rgba = image.to_rgba8();
    let (w, h) = rgba.dimensions();
    let r = radius.min(w / 2).min(h / 2) as f32;
    if r <= 0.0 {
        return DynamicImage::ImageRgba8(rgba);
    }

    for y in 0..h {
        for x in 0..w {
            let fx = x as f32 + 0.5;
            let fy = y as f32 + 0.5;
            let cx = fx.clamp(r, w as f32 - r);
            let cy = fy.clamp(r, h as f32 - r);
            let distance = ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt();
            if distance > r {
                // Feather the last pixel so the edge is not a staircase.
                let alpha = (1.0 - (distance - r)).clamp(0.0, 1.0);
                let pixel = rgba.get_pixel_mut(x, y);
                pixel[3] = (pixel[3] as f32 * alpha) as u8;
            }
        }
    }
    DynamicImage::ImageRgba8(rgba)
}

// ── encoding ────────────────────────────────────────────────────────────────

/// The default JPEG quality for the automatic thumbnail ladder.
///
/// Chosen on the content this catalogue is ACTUALLY full of, which is not
/// photographs.
///
/// A first pass picked 82 by eye on a photographic wallpaper, where it is
/// genuinely fine — konachan:393054 measures 40.7 dB PSNR against lossless at
/// q82. But most of what is in here is anime and line art: hard edges, flat
/// fills and large single-colour regions, which is the worst case for a
/// DCT-based codec. Measured on five real anilist thumbnails at 640px:
///
///   image              q75      q82      q90     size q82 -> q90
///   anilist-10236    30.3dB   32.2dB   37.2dB      32K -> 48K
///   anilist-10366    31.1dB   32.3dB   43.0dB      28K -> 40K
///   anilist-10369    31.5dB   32.8dB   38.0dB      20K -> 32K
///   anilist-10586    39.4dB   40.4dB   44.3dB       8K -> 16K
///   anilist-10807    29.1dB   30.0dB   53.1dB      24K -> 40K
///
/// 82 sits right at the knee for that content — 30 dB is where ringing on
/// line art stops being theoretical — and q90 buys 5-23 dB back for about
/// 1.5x the bytes, still ~9x smaller than lossless. These sources also serve
/// JPEGs, so a thumbnail is a RE-encode: generation loss compounds, and the
/// cheapest place to not pay it twice is here.
pub const THUMB_QUALITY: u8 = 90;

/// The file extension bytes in this format should be named with. The cache
/// keys a thumbnail's path on this, so a mismatch here is a mismatch on disk.
pub fn extension(format: Format) -> &'static str {
    match format {
        Format::Png => "png",
        Format::Jpeg => "jpg",
        Format::WebpLossless => "webp",
    }
}

/// Which format a thumbnail should be encoded in, decided from the decoded
/// image's OWN colour type — never from the source URL or the catalogue's
/// `kind`/`family`, both of which lie often enough to be useless (a PNG can be
/// opaque, a `.jpg` URL can 404 into an SVG icon). An icon or a rasterised
/// vector with real transparency needs PNG or the alpha flattens to black; a
/// photograph never has alpha and JPEG is 8-11x smaller for it.
pub fn thumb_format(image: &DynamicImage) -> Format {
    if image.color().has_alpha() {
        Format::Png
    } else {
        Format::Jpeg
    }
}

/// Encode. PNG keeps alpha and is the honest default for avatars and icons;
/// JPEG takes a quality knob and is for photographs, where PNG would be five
/// times the size for no visible gain.
pub fn encode(image: &DynamicImage, format: Format, quality: u8) -> Result<Vec<u8>> {
    let mut out = std::io::Cursor::new(Vec::new());
    match format {
        Format::Png => image
            .write_to(&mut out, ImageFormat::Png)
            .map_err(|e| ImageError::Encode(e.to_string()))?,
        Format::WebpLossless => image
            .write_to(&mut out, ImageFormat::WebP)
            .map_err(|e| ImageError::Encode(e.to_string()))?,
        Format::Jpeg => {
            // JPEG has no alpha; flatten onto white rather than letting the
            // encoder decide, which produces black fringes.
            let rgb = DynamicImage::ImageRgb8(image.to_rgb8());
            let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(
                &mut out,
                quality.clamp(1, 100),
            );
            encoder
                .encode_image(&rgb)
                .map_err(|e| ImageError::Encode(e.to_string()))?;
        }
    }
    Ok(out.into_inner())
}

/// The thumbnail ladder: one encode per step, each rendered from the source.
///
/// The gallery then loads the step nearest its draw size, so `sourceSize`
/// always matches and Qt never decodes a 4000px image to draw 330px of it.
///
/// The format is decided ONCE from the source (see `thumb_format`) and held
/// for every rung: `resize` never adds an alpha channel that was not already
/// there, so every step in a ladder always agrees on JPEG vs PNG — a caller
/// never has to ask "which step is which format".
/*
 * GIVE A TRANSPARENT THUMBNAIL SOMETHING TO BE SEEN AGAINST.
 *
 * An icon SVG rasterises to artwork on transparency, and the artwork is very
 * often pure black — measured over this catalogue: tabler renders RGB 0 at 22%
 * coverage, openmoji RGB 19, devicon RGB 25. The wall's tiles are near-black.
 * Black on near-black is not a broken thumbnail; it is a thumbnail nobody can
 * see, which is worse, because every counter in the app reports success:
 * `tilesReady` climbs, `thumbsFailed` stays at zero, and 11,319 vector rows
 * draw as empty cells.
 *
 * So a thumbnail that is mostly transparent gets a plate, and the plate is
 * chosen by the artwork's own luminance: light art gets a dark plate, dark art
 * gets a light one. Either way there is contrast, whatever the source drew.
 *
 * Artwork that already covers the canvas is left alone — it brought its own
 * background and does not need ours.
 *
 * THUMBNAILS ONLY. An export keeps its alpha: an icon written to a file is
 * going somewhere that wants the transparency, and flattening it there would be
 * baking our background into someone's icon.
 */
pub fn plate_for_display(image: &DynamicImage) -> DynamicImage {
    let rgba = image.to_rgba8();
    let (w, h) = rgba.dimensions();
    if w == 0 || h == 0 {
        return image.clone();
    }

    let mut alpha_sum = 0f64;
    let mut lum_sum = 0f64;
    for p in rgba.pixels() {
        let a = p[3] as f64 / 255.0;
        alpha_sum += a;
        // Rec. 601 luma, weighted by how present the pixel actually is.
        lum_sum += a * (0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64);
    }
    let pixels = (w as f64) * (h as f64);
    let coverage = alpha_sum / pixels;

    /*
     * ONLY SPARSE LINE ART, and the threshold is not a round number by accident.
     *
     * A picture with a transparent corner is still a picture, and flattening it
     * would bake our background into someone's cut-out — `transparent_thumbnails
     * _keep_their_alpha` pins exactly that, with a source 84% covered. An icon
     * is a different thing: the measured ones here cover 22-23% of their canvas
     * and are nothing but strokes.
     *
     * Half is comfortably between the two and says the rule plainly: if most of
     * the canvas is drawn on, it is a picture and it keeps its alpha.
     */
    if coverage >= 0.5 {
        return image.clone();
    }
    // Nothing drawn at all: a plate would turn an empty render into a solid
    // block, which reads as a picture that loaded and is simply blank.
    if alpha_sum <= f64::EPSILON {
        return image.clone();
    }

    let luma = lum_sum / alpha_sum;
    // Neutral, and a shade off pure black/white so the tile's own edges stay
    // visible against it.
    let plate = if luma < 128.0 { [244u8, 244, 246, 255] } else { [30u8, 30, 34, 255] };

    let mut out = RgbaImage::from_pixel(w, h, image::Rgba(plate));
    image::imageops::overlay(&mut out, &rgba, 0, 0);
    DynamicImage::ImageRgba8(out)
}

pub fn thumb_ladder(
    source: &DynamicImage,
    steps: &[u32],
    quality: u8,
) -> Result<Vec<(u32, Vec<u8>, Format)>> {
    // NEVER UPSCALE. `resize` fits inside the bounds but happily enlarges past
    // the source, so a 1200px original asked for 2048 produced a 2048px file
    // with 1200px of real detail in it — disk and decode spent on pixels that
    // were invented. The step still names the entry, because the caller asked
    // for that rung and its cache path is keyed on it; only the pixels are
    // capped.
    let limit = source.width().max(source.height());
    // Transparent artwork gets something to be seen against — see
    // `plate_for_display`. Here rather than at each call site because this IS
    // the thumbnail path: an export never comes through this function, so an
    // icon written to a file keeps its alpha.
    let source = &plate_for_display(source);
    let format = thumb_format(source);
    let mut out = Vec::with_capacity(steps.len());
    for &step in steps {
        let render = step.min(limit).max(1);
        let scaled = source.resize(render, render, image::imageops::FilterType::Lanczos3);
        out.push((step, encode(&scaled, format, quality)?, format));
    }
    Ok(out)
}

// ── derived data ────────────────────────────────────────────────────────────

/// Perceptual hash: 8x8 average hash. Cheap, stable under rescaling and
/// re-encoding, which is exactly the duplicate a catalogue collects — the same
/// wallpaper from three sources at three sizes.
pub fn phash(image: &DynamicImage) -> u64 {
    let small = image.resize_exact(8, 8, image::imageops::FilterType::Triangle).to_luma8();
    let mean: f64 = small.pixels().map(|p| p[0] as f64).sum::<f64>() / 64.0;
    let mut hash = 0u64;
    for (i, pixel) in small.pixels().enumerate() {
        if pixel[0] as f64 >= mean {
            hash |= 1 << i;
        }
    }
    hash
}

pub fn hamming(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

/// The dominant colour, ignoring near-transparent and near-grey pixels.
///
/// Greys are excluded on purpose: almost every image has plenty, and a palette
/// match against `#808080` tells you nothing about whether a wallpaper suits an
/// accent colour.
pub fn dominant_color(image: &DynamicImage) -> (u8, u8, u8) {
    let small = image.thumbnail(64, 64).to_rgba8();
    let mut buckets = std::collections::HashMap::<(u8, u8, u8), u32>::new();

    for pixel in small.pixels() {
        if pixel[3] < 128 {
            continue;
        }
        let (r, g, b) = (pixel[0], pixel[1], pixel[2]);
        let max = r.max(g).max(b) as i32;
        let min = r.min(g).min(b) as i32;
        if max - min < 24 {
            continue; // grey
        }
        *buckets.entry((r / 32 * 32, g / 32 * 32, b / 32 * 32)).or_insert(0) += 1;
    }

    buckets
        .into_iter()
        .max_by_key(|(_, count)| *count)
        .map(|((r, g, b), _)| (r.saturating_add(16), g.saturating_add(16), b.saturating_add(16)))
        .unwrap_or_else(|| {
            // An image with no colour at all is legitimately grey.
            let small = image.thumbnail(8, 8).to_rgb8();
            let n = small.pixels().len().max(1) as u32;
            let sum = small.pixels().fold((0u32, 0u32, 0u32), |acc, p| {
                (acc.0 + p[0] as u32, acc.1 + p[1] as u32, acc.2 + p[2] as u32)
            });
            ((sum.0 / n) as u8, (sum.1 / n) as u8, (sum.2 / n) as u8)
        })
}

/// A tiny blurred placeholder, PNG bytes, for the gallery to show while the
/// real thumbnail loads. 16px wide: a few hundred bytes, and it turns a grey
/// hole into something that already has the right colours.
pub fn placeholder(image: &DynamicImage) -> Result<Vec<u8>> {
    let tiny = image.resize(16, 16, image::imageops::FilterType::Triangle).blur(1.2);
    encode(&tiny, Format::Png, 80)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gradient(w: u32, h: u32) -> DynamicImage {
        let mut img = RgbaImage::new(w, h);
        for y in 0..h {
            for x in 0..w {
                img.put_pixel(x, y, Rgba([(x * 255 / w.max(1)) as u8, 40, 180, 255]));
            }
        }
        DynamicImage::ImageRgba8(img)
    }

    /// A picture that is flat except for one busy corner — the smart crop must
    /// find it.
    fn busy_corner(w: u32, h: u32) -> DynamicImage {
        let mut img = RgbaImage::from_pixel(w, h, Rgba([20, 20, 20, 255]));
        for y in 0..h / 4 {
            for x in 0..w / 4 {
                let v = if (x + y) % 2 == 0 { 255 } else { 0 };
                img.put_pixel(x, y, Rgba([v, v, v, 255]));
            }
        }
        DynamicImage::ImageRgba8(img)
    }

    const SVG: &[u8] = br##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#7aa2f7" d="M4 4h16v16H4z"/></svg>"##;

    #[test]
    fn svg_is_sniffed_not_trusted_from_the_extension() {
        assert!(is_svg(SVG));
        assert!(!is_svg(&encode(&gradient(8, 8), Format::Png, 90).unwrap()));
    }

    #[test]
    fn vectors_rasterise_at_the_requested_size() {
        for size in [32u32, 184, 512] {
            let rendered = render_svg(SVG, size, size).unwrap();
            assert_eq!(rendered.dimensions(), (size, size), "at {size}px");
        }
        assert_eq!(svg_size(SVG).unwrap(), (24, 24));
    }

    #[test]
    fn monochrome_vectors_are_tintable() {
        assert!(svg_is_tintable(SVG));
        let two_colours = br##"<svg><path fill="#7aa2f7"/><path fill="#f38ba8"/></svg>"##;
        assert!(!svg_is_tintable(two_colours));
    }

    #[test]
    fn probe_reads_dimensions_without_decoding() {
        let png = encode(&gradient(120, 60), Format::Png, 90).unwrap();
        let (w, h, format) = probe(&png).unwrap();
        assert_eq!((w, h), (120, 60));
        assert_eq!(format, "png");

        let (sw, sh, svg_format) = probe(SVG).unwrap();
        assert_eq!((sw, sh, svg_format.as_str()), (24, 24, "svg"));
        assert!(matches!(probe(&[]), Err(ImageError::Empty)));
    }

    #[test]
    fn cover_crops_to_the_target_aspect() {
        // A 16:9 source cropped to a square keeps the full height.
        let (x, y, w, h) = cover_rect((1920, 1080), (184, 184), Gravity::Center, None);
        assert_eq!((w, h), (1080, 1080));
        assert_eq!(y, 0);
        assert_eq!(x, (1920 - 1080) / 2);

        // A tall source cropped to a wide banner keeps the full width.
        let (_, _, w2, h2) = cover_rect((1000, 2000), (1500, 500), Gravity::Center, None);
        assert_eq!(w2, 1000);
        assert_eq!(h2, 333);
    }

    #[test]
    fn gravity_moves_the_crop() {
        let north = cover_rect((1920, 1080), (100, 100), Gravity::North, None);
        let south = cover_rect((1920, 1080), (100, 100), Gravity::South, None);
        let west = cover_rect((1080, 1920), (100, 100), Gravity::West, None);
        assert_eq!(north.0, south.0, "horizontal position unchanged");
        // A tall source cropped square keeps the full width, so there is no
        // horizontal slack: west pins x at 0 and the crop moves vertically.
        assert_eq!(west.0, 0);
        assert_eq!(west.1, (1920 - 1080) / 2, "no horizontal slack to take");
        assert!(south.1 >= north.1);
    }

    #[test]
    fn smart_crop_finds_the_busy_region() {
        let image = busy_corner(400, 400);
        let (x, y, _, _) = cover_rect((400, 400), (100, 100), Gravity::Smart, Some(&image));
        // The detail is in the top-left quarter; centre gravity would sit at
        // (150, 150).
        assert!(x < 150 && y < 150, "smart crop landed at ({x}, {y})");
    }

    #[test]
    fn a_hand_chosen_crop_wins_over_gravity() {
        // A picture whose left half is red and right half is blue: cropping to
        // one half must produce that half, whatever the gravity says.
        let mut img = RgbaImage::new(200, 100);
        for y in 0..100 {
            for x in 0..200 {
                let colour =
                    if x < 100 { Rgba([220, 20, 20, 255]) } else { Rgba([20, 20, 220, 255]) };
                img.put_pixel(x, y, colour);
            }
        }
        let source = DynamicImage::ImageRgba8(img);

        let recipe = Recipe {
            width: 50,
            height: 50,
            fit: Fit::Cover,
            gravity: Gravity::West,      // would otherwise take the red half
            crop: Some(Crop { x: 100, y: 0, w: 100, h: 100 }),
            ..Recipe::default()
        };

        let out = apply(&source, &recipe).unwrap().to_rgba8();
        let pixel = out.get_pixel(25, 25);
        assert!(pixel[2] > 150 && pixel[0] < 80, "expected the blue half, got {pixel:?}");
    }

    #[test]
    fn a_crop_outside_the_image_is_clamped_not_fatal() {
        let source = gradient(100, 100);
        let recipe = Recipe {
            width: 40,
            height: 40,
            crop: Some(Crop { x: 90, y: 90, w: 999, h: 999 }),
            ..Recipe::default()
        };
        // A UI can round a drag past the edge; that must produce a picture
        // rather than an error.
        assert_eq!(apply(&source, &recipe).unwrap().dimensions(), (40, 40));
    }

    #[test]
    fn recipes_produce_exactly_the_requested_size() {
        let source = gradient(1920, 1080);
        for fit in [Fit::Cover, Fit::Contain, Fit::Stretch] {
            let recipe = Recipe { width: 184, height: 184, fit, ..Recipe::default() };
            let out = apply(&source, &recipe).unwrap();
            assert_eq!(out.dimensions(), (184, 184), "{fit:?}");
        }
    }

    #[test]
    fn contain_pads_with_the_background() {
        let source = gradient(400, 100); // very wide
        let recipe = Recipe {
            width: 200,
            height: 200,
            fit: Fit::Contain,
            background: "#ff0000ff".into(),
            ..Recipe::default()
        };
        let out = apply(&source, &recipe).unwrap().to_rgba8();
        // The top-left corner is padding, not picture.
        assert_eq!(out.get_pixel(2, 2), &Rgba([255, 0, 0, 255]));
    }

    #[test]
    fn radius_cuts_the_corners_transparent() {
        let source = gradient(100, 100);
        let recipe = Recipe { width: 100, height: 100, radius: 50, ..Recipe::default() };
        let out = apply(&source, &recipe).unwrap().to_rgba8();
        assert_eq!(out.get_pixel(0, 0)[3], 0, "corner should be cut away");
        assert_eq!(out.get_pixel(50, 50)[3], 255, "centre should be intact");
    }

    #[test]
    fn encoders_round_trip() {
        let source = gradient(64, 64);
        for format in [Format::Png, Format::WebpLossless] {
            let bytes = encode(&source, format, 90).unwrap();
            let back = image::load_from_memory(&bytes).unwrap();
            assert_eq!(back.dimensions(), (64, 64), "{format:?}");
        }
        // JPEG has no alpha, so it round-trips as RGB — the point is that it
        // decodes at all and honours quality.
        let small = encode(&source, Format::Jpeg, 20).unwrap();
        let large = encode(&source, Format::Jpeg, 95).unwrap();
        assert!(small.len() < large.len(), "quality should change the size");
    }

    #[test]
    fn the_ladder_has_a_step_per_size() {
        let ladder = thumb_ladder(&gradient(1600, 1200), &[160, 320, 640], THUMB_QUALITY).unwrap();
        assert_eq!(ladder.len(), 3);
        for (step, bytes, _format) in ladder {
            let decoded = image::load_from_memory(&bytes).unwrap();
            assert!(decoded.width() <= step, "step {step} produced {}", decoded.width());
            assert!(!bytes.is_empty());
        }
    }

    /// A synthetic stand-in for a photograph: smooth low-frequency structure
    /// (what JPEG's DCT keeps almost for free) plus per-pixel grain (what a
    /// LOSSLESS codec must spend real bits predicting and a lossy one simply
    /// discards, the same trade a camera sensor's noise floor forces on any
    /// codec). Pure uncorrelated noise was tried first and undersold the
    /// case — JPEG has nothing to predict either, so its margin over lossless
    /// shrinks to ~2.6x instead of the 8-11x measured on real catalogue
    /// photos, where large smooth regions (sky, skin, out-of-focus
    /// background) are the norm. No alpha channel, so `thumb_format` must
    /// choose JPEG for it.
    fn noisy_photo(w: u32, h: u32) -> DynamicImage {
        let mut img = image::RgbImage::new(w, h);
        let mut state: u32 = 0x2545_F491;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            (state & 0xff) as f32 - 128.0
        };
        for y in 0..h {
            for x in 0..w {
                let (fx, fy) = (x as f32, y as f32);
                let base_r = 128.0 + 60.0 * (fx * 0.015).sin() + 40.0 * (fy * 0.01).sin();
                let base_g = 128.0 + 50.0 * ((fx + fy) * 0.008).sin();
                let base_b = 128.0 + 55.0 * (fy * 0.013).cos();
                let mut channel = |base: f32| (base + next() * 0.35).clamp(0.0, 255.0) as u8;
                let (r, g, b) = (channel(base_r), channel(base_g), channel(base_b));
                img.put_pixel(x, y, image::Rgb([r, g, b]));
            }
        }
        DynamicImage::ImageRgb8(img)
    }

    #[test]
    fn photographic_thumbnails_are_far_smaller_than_lossless() {
        let source = noisy_photo(256, 256);
        assert!(!source.color().has_alpha(), "fixture must be opaque to exercise the JPEG path");

        let ladder = thumb_ladder(&source, &[160], THUMB_QUALITY).unwrap();
        let (_, jpeg_bytes, format) = &ladder[0];
        assert_eq!(*format, Format::Jpeg, "an opaque source should pick JPEG");

        let scaled = source.resize(160, 160, image::imageops::FilterType::Lanczos3);
        let lossless = encode(&scaled, Format::WebpLossless, 90).unwrap();

        /*
         * Regression check for "still encoding lossless under a different
         * name": if thumb_ladder kept WebpLossless this ratio would be ~1.0.
         *
         * Deliberately NOT tight enough to pin THUMB_QUALITY. This fixture is a
         * small synthetic image, where lossless does unusually well — it lands
         * at 2.9x here while real catalogue images at the same quality run 3.8x
         * and up. Raising the quality constant on measured evidence should not
         * be blocked by a threshold a synthetic fixture happens to sit under;
         * the format assertion above is what actually guards the regression.
         */
        assert!(
            jpeg_bytes.len() * 2 < lossless.len(),
            "JPEG ({} bytes) should be well under half of lossless ({} bytes)",
            jpeg_bytes.len(),
            lossless.len()
        );
    }

    #[test]
    fn transparent_thumbnails_keep_their_alpha() {
        // A real hole, not just a colour type that happens to carry alpha=255
        // everywhere — the corner is actually see-through.
        let mut img = RgbaImage::from_pixel(100, 100, Rgba([200, 40, 40, 255]));
        for y in 0..40 {
            for x in 0..40 {
                img.put_pixel(x, y, Rgba([0, 0, 0, 0]));
            }
        }
        let source = DynamicImage::ImageRgba8(img);
        assert!(source.color().has_alpha());

        let ladder = thumb_ladder(&source, &[64], THUMB_QUALITY).unwrap();
        let (_, bytes, format) = &ladder[0];
        assert_eq!(*format, Format::Png, "an alpha source must not be flattened to JPEG");

        let decoded = image::load_from_memory(bytes).unwrap();
        assert!(decoded.color().has_alpha(), "round trip must keep an alpha channel");
        let rgba = decoded.to_rgba8();
        let corner = rgba.get_pixel(2, 2);
        assert!(corner[3] < 50, "corner should still be transparent, alpha={}", corner[3]);
    }

    #[test]
    fn phash_survives_rescaling_and_reencoding() {
        let source = gradient(400, 300);
        let rescaled = source.resize_exact(200, 150, image::imageops::FilterType::Lanczos3);
        let jpeg = image::load_from_memory(&encode(&source, Format::Jpeg, 60).unwrap()).unwrap();

        assert!(hamming(phash(&source), phash(&rescaled)) <= 4);
        assert!(hamming(phash(&source), phash(&jpeg)) <= 4);

        // A different picture must not collide.
        let other = busy_corner(400, 300);
        assert!(hamming(phash(&source), phash(&other)) > 8);
    }

    #[test]
    fn dominant_colour_ignores_grey() {
        let mut img = RgbaImage::from_pixel(100, 100, Rgba([128, 128, 128, 255]));
        for y in 0..30 {
            for x in 0..30 {
                img.put_pixel(x, y, Rgba([200, 40, 40, 255]));
            }
        }
        let (r, g, b) = dominant_color(&DynamicImage::ImageRgba8(img));
        assert!(r > g && r > b, "expected the red patch, got #{r:02x}{g:02x}{b:02x}");
    }

    #[test]
    fn placeholders_are_tiny() {
        let bytes = placeholder(&gradient(1920, 1080)).unwrap();
        assert!(bytes.len() < 1500, "placeholder was {} bytes", bytes.len());
        assert_eq!(image::load_from_memory(&bytes).unwrap().width(), 16);
    }

    #[test]
    fn animation_is_detected_from_the_bytes() {
        let still = encode(&gradient(8, 8), Format::Png, 90).unwrap();
        assert!(!is_animated(&still));
    }
}


// ── video ───────────────────────────────────────────────────────────────────

/// Whether these bytes look like a container the image decoder cannot open.
///
/// Sniffed rather than trusted from the extension: a URL ending `.mp4` that
/// actually serves a JPEG poster is common enough on CDNs, and the wrong guess
/// here spawns ffmpeg for nothing or hands a video to the PNG decoder.
pub fn is_video(bytes: &[u8]) -> bool {
    if bytes.len() < 12 {
        return false;
    }
    // ISO base media (mp4/mov/m4v): a `ftyp` box at offset 4.
    if &bytes[4..8] == b"ftyp" {
        return true;
    }
    // Matroska and WebM share the EBML magic.
    if bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        return true;
    }
    // Ogg, and AVI's RIFF....AVI␣.
    bytes.starts_with(b"OggS")
        || (bytes.starts_with(b"RIFF") && &bytes[8..11] == b"AVI")
}

/// What a video is, as far as the catalogue cares: size and length.
///
/// `ffprobe` rather than a decode — it reads the container's headers and stops,
/// which is milliseconds against a file we may not want to download in full.
pub fn probe_video(path: &std::path::Path) -> Result<(u32, u32, f64)> {
    let out = std::process::Command::new("ffprobe")
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height:format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .map_err(|e| ImageError::Decode(format!("ffprobe: {e}")))?;

    if !out.status.success() {
        return Err(ImageError::Decode(format!(
            "ffprobe: {}",
            String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("failed")
        )));
    }

    let text = String::from_utf8_lossy(&out.stdout);
    let mut lines = text.lines();
    let w: u32 = lines.next().and_then(|v| v.trim().parse().ok()).unwrap_or(0);
    let h: u32 = lines.next().and_then(|v| v.trim().parse().ok()).unwrap_or(0);
    // "N/A" for a stream with no duration in its header — a live stream, or a
    // fragment. Zero means "not known", which the UI already handles.
    let duration: f64 = lines.next().and_then(|v| v.trim().parse().ok()).unwrap_or(0.0);

    if w == 0 || h == 0 {
        return Err(ImageError::Decode("no video stream".into()));
    }
    Ok((w, h, duration))
}

/// One frame from a video, as an image the rest of the pipeline can use.
///
/// Taken a little way in, not at zero: the first frame of a video is very often
/// black, a fade-in, or a title card, and a wall of black tiles is worse than
/// no thumbnails at all. A tenth of the way in — capped, so a ten-minute file
/// does not seek forever — lands on something representative.
///
/// The seek is BEFORE `-i`, which makes it a container seek to the nearest
/// keyframe rather than a decode of everything up to that point: the difference
/// between milliseconds and seconds on a long file.
pub fn poster_frame(path: &std::path::Path, duration: f64) -> Result<DynamicImage> {
    /*
     * THE MOST PICTURE-LIKE OF A FEW FRAMES, NOT THE FIRST ONE FOUND.
     *
     * A single frame a tenth of the way in was right for most clips and badly
     * wrong for the rest: a fade through white, a flash, a black cut — and the
     * tile showed a blank white rectangle that looked like a broken thumbnail.
     * Three candidates are taken (10%, 35%, 60%, each a keyframe seek, so
     * milliseconds), scored for detail, and the flattest or most washed-out
     * lose. Short clips with a single usable point fall back to the start.
     */
    let mut best: Option<(f64, Vec<u8>)> = None;
    let points: Vec<f64> = if duration > 1.0 {
        [0.1, 0.35, 0.6].iter().map(|f| (duration * f).clamp(0.0, (duration - 0.2).max(0.0)).min(600.0)).collect()
    } else {
        vec![0.0]
    };
    for seek in points {
        let Some(png) = frame_at(path, seek) else { continue };
        let Ok(image) = load(&png, (0, 0)) else { continue };
        let score = frame_score(&image);
        if best.as_ref().is_none_or(|(b, _)| score > *b) {
            best = Some((score, png));
        }
    }
    if let Some((_, png)) = best {
        return load(&png, (0, 0));
    }

    // Retry from the very start before giving up: better a dull frame than a
    // row that can never show anything.
    match frame_at(path, 0.0) {
        Some(png) => load(&png, (0, 0)),
        None => Err(ImageError::Decode("no frame: ffmpeg produced nothing".into())),
    }
}

/// One frame as PNG bytes, from a keyframe seek before `-i`.
fn frame_at(path: &std::path::Path, seek: f64) -> Option<Vec<u8>> {
    let out = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-ss", &format!("{seek:.2}")])
        .arg("-i")
        .arg(path)
        .args(["-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"])
        .output()
        .ok()?;
    (out.status.success() && !out.stdout.is_empty()).then_some(out.stdout)
}

/// How much a frame looks like a picture: luminance spread, minus a heavy
/// penalty for frames that are almost all white or almost all black.
pub fn frame_score(image: &DynamicImage) -> f64 {
    let small = image.thumbnail(64, 64).to_luma8();
    let n = small.pixels().len().max(1) as f64;
    let mean = small.pixels().map(|p| p.0[0] as f64).sum::<f64>() / n;
    let var = small.pixels().map(|p| (p.0[0] as f64 - mean).powi(2)).sum::<f64>() / n;
    let spread = var.sqrt();
    let washed = if mean > 225.0 || mean < 22.0 { 60.0 } else { 0.0 };
    spread - washed
}

/// Poster frame and measurements for a video held in memory.
///
/// ffmpeg needs a seekable file: an mp4 written with its index at the end
/// cannot be decoded from a pipe, and that is most of them. The temporary file
/// is removed on every path out, including the failures.
pub fn video_still(bytes: &[u8]) -> Result<(DynamicImage, u32, u32, f64)> {
    let path = std::env::temp_dir().join(format!(
        "quarry-probe-{}-{}.bin",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::write(&path, bytes).map_err(|e| ImageError::Decode(format!("spool video: {e}")))?;

    let result = probe_video(&path).and_then(|(w, h, duration)| {
        poster_frame(&path, duration).map(|frame| (frame, w, h, duration))
    });

    let _ = std::fs::remove_file(&path);
    result
}

#[cfg(test)]
mod video_tests {
    use super::*;

    /// A tiny real video, made by ffmpeg, so the test exercises the actual
    /// container handling rather than a mock of it.
    fn sample(seconds: u32) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("quarry-test-{seconds}s.mp4"));
        let ok = std::process::Command::new("ffmpeg")
            .args([
                "-v", "error", "-y",
                "-f", "lavfi",
                "-i", &format!("testsrc=size=320x180:rate=10:duration={seconds}"),
                "-pix_fmt", "yuv420p",
            ])
            .arg(&path)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        assert!(ok, "ffmpeg is required for the video tests");
        path
    }

    #[test]
    fn a_video_is_sniffed_from_its_bytes() {
        let path = sample(1);
        let bytes = std::fs::read(&path).unwrap();
        assert!(is_video(&bytes), "an mp4 must be recognised");

        // The formats the pipeline already handles must not be diverted.
        assert!(!is_video(b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0d"));
        assert!(!is_video(b"GIF89a\x01\x00\x01\x00\x00\x00\x00"));
        assert!(!is_video(b"<svg xmlns=\"http://www.w3.org/2000/svg\">"));
        assert!(!is_video(b"short"), "a truncated read must not panic");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_video_yields_a_frame_and_its_length() {
        let path = sample(3);
        let bytes = std::fs::read(&path).unwrap();

        let (frame, w, h, duration) = video_still(&bytes).expect("a still from a real mp4");
        assert_eq!((w, h), (320, 180));
        assert!((duration - 3.0).abs() < 0.3, "measured {duration}s, expected ~3");
        assert_eq!((frame.width(), frame.height()), (320, 180));

        // The frame must be usable by everything downstream, unchanged.
        let ladder = thumb_ladder(&frame, &[160], 82).expect("a thumbnail from a video frame");
        assert_eq!(ladder.len(), 1);

        let _ = std::fs::remove_file(&path);
    }

    /// A one-frame video is the case the 10% seek gets wrong.
    #[test]
    fn a_video_too_short_to_seek_into_still_yields_a_frame() {
        let path = std::env::temp_dir().join("quarry-test-1frame.mp4");
        let ok = std::process::Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=1:duration=0.1", "-pix_fmt", "yuv420p"])
            .arg(&path)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        assert!(ok);

        let bytes = std::fs::read(&path).unwrap();
        let (frame, w, h, _) = video_still(&bytes).expect("even a single frame is a poster");
        assert_eq!((w, h), (64, 64));
        assert_eq!(frame.width(), 64);

        let _ = std::fs::remove_file(&path);
    }

    /// A real file from a real source, when one is lying around: the sample
    /// videos ffmpeg generates are h264/mp4 test patterns, and the boards
    /// serve VP9 in WebM with dimensions that do not match the poster.
    /// Skipped rather than failed when the file is not there — a unit test
    /// must not depend on the network.
    #[test]
    fn a_real_board_video_probes_and_posters() {
        let path = std::path::Path::new("/tmp/probe.webm");
        if !path.exists() {
            return;
        }
        let bytes = std::fs::read(path).unwrap();
        assert!(is_video(&bytes), "a VP9 WebM must be recognised");

        let (frame, w, h, duration) = video_still(&bytes).expect("a still from a real webm");
        assert!(w > 0 && h > 0 && duration > 0.0, "{w}x{h}, {duration}s");
        assert_eq!((frame.width(), frame.height()), (w, h));

        // The poster must not be a black frame — the reason the seek is 10% in.
        let (r, g, b) = dominant_color(&frame);
        assert!(r as u32 + g as u32 + b as u32 > 30, "poster looks black: {r},{g},{b}");
    }

    #[test]
    fn something_that_is_not_a_video_fails_rather_than_hangs() {
        assert!(video_still(b"not a video at all, just some bytes").is_err());
    }

    #[test]
    fn a_detailed_frame_beats_a_washed_out_one() {
        let white = DynamicImage::ImageRgb8(image::RgbImage::from_pixel(64, 64, image::Rgb([250, 250, 250])));
        let mut busy = image::RgbImage::new(64, 64);
        for (x, y, px) in busy.enumerate_pixels_mut() {
            let v = if (x / 8 + y / 8) % 2 == 0 { 40 } else { 200 };
            *px = image::Rgb([v, v, v]);
        }
        let busy = DynamicImage::ImageRgb8(busy);
        assert!(frame_score(&busy) > frame_score(&white));
    }
}

/*
 * A THUMBNAIL NOBODY CAN SEE REPORTS AS A SUCCESS.
 *
 * That is why these exist. Black line art on transparency loads perfectly, so
 * `tilesReady` climbs, `thumbsFailed` stays zero, and the wall is empty — the
 * one failure mode every counter in the app calls healthy.
 */
#[cfg(test)]
mod plate_tests {
    use super::*;

    fn art(w: u32, h: u32, rgb: [u8; 3], coverage: f32) -> DynamicImage {
        let mut img = RgbaImage::from_pixel(w, h, image::Rgba([0, 0, 0, 0]));
        let rows = ((h as f32) * coverage).round() as u32;
        for y in 0..rows {
            for x in 0..w {
                img.put_pixel(x, y, image::Rgba([rgb[0], rgb[1], rgb[2], 255]));
            }
        }
        DynamicImage::ImageRgba8(img)
    }

    fn mean_luma(img: &DynamicImage) -> f64 {
        let rgba = img.to_rgba8();
        let n = rgba.pixels().len() as f64;
        rgba.pixels()
            .map(|p| 0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64)
            .sum::<f64>()
            / n
    }

    /// The measured case: pure black icon strokes over transparency.
    #[test]
    fn black_line_art_gets_a_light_plate() {
        let plated = plate_for_display(&art(32, 32, [0, 0, 0], 0.22));
        assert!(plated.to_rgba8().pixels().all(|p| p[3] == 255), "still transparent");
        assert!(mean_luma(&plated) > 150.0, "too dark to see: {}", mean_luma(&plated));
    }

    /// And the other way, so a white-on-transparent icon is not lost either.
    #[test]
    fn white_line_art_gets_a_dark_plate() {
        let plated = plate_for_display(&art(32, 32, [255, 255, 255], 0.22));
        assert!(mean_luma(&plated) < 110.0, "too light to see: {}", mean_luma(&plated));
    }

    /// A photograph brought its own background; adding ours would be a border.
    #[test]
    fn opaque_artwork_is_left_exactly_as_it_was() {
        let photo = art(16, 16, [120, 60, 30], 1.0);
        let plated = plate_for_display(&photo);
        assert_eq!(plated.to_rgba8().into_raw(), photo.to_rgba8().into_raw());
    }

    /*
     * A CUT-OUT IS A PICTURE, NOT AN ICON.
     *
     * Most of the canvas drawn on means it brought its own subject and its
     * transparency is deliberate — a logo, a sticker, a masked photograph.
     * Flattening that bakes our grey into someone else's artwork, which is what
     * `transparent_thumbnails_keep_their_alpha` has always guarded.
     */
    #[test]
    fn a_mostly_opaque_cutout_keeps_its_transparency() {
        let cutout = art(50, 50, [200, 40, 40], 0.84);
        let plated = plate_for_display(&cutout);
        assert!(
            plated.to_rgba8().pixels().any(|p| p[3] == 0),
            "a mostly-opaque cut-out was flattened"
        );
    }

    /// Nothing drawn stays nothing drawn: plating an empty render would turn a
    /// failure into a convincing solid tile.
    #[test]
    fn a_wholly_empty_render_is_not_turned_into_a_solid_block() {
        let empty = DynamicImage::ImageRgba8(RgbaImage::from_pixel(8, 8, image::Rgba([0, 0, 0, 0])));
        let plated = plate_for_display(&empty);
        assert!(plated.to_rgba8().pixels().all(|p| p[3] == 0), "empty render was plated");
    }
}

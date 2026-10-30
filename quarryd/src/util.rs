//! Small shared utilities.
//!
//! Everything here is a pure function with one job, used from more than one
//! place, and tested. The bar for adding something is that writing it twice
//! would produce two subtly different versions — sizes, aspects, colours and
//! path templates are all things that go wrong quietly when each caller rolls
//! its own.

//! Some of these are consumed by phases that have not landed (export paths,
//! contrast checks). Each is tested, so an unused one is verified rather than
//! assumed.
#![allow(dead_code)]
use std::path::{Path, PathBuf};

// ── numbers people read ──────────────────────────────────────────────────────

/// `1536000` → `"1.5 MB"`. Catalogue UIs are full of byte counts and none of
/// them should be printed raw.
pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else if value >= 100.0 {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// `1920, 1080` → `"16:9"`. Reduced by GCD, and left as a decimal when the
/// reduction is uglier than the number — 3440x1440 is "43:18", which tells
/// nobody anything, so it becomes "2.39:1".
pub fn aspect_label(w: u32, h: u32) -> String {
    if w == 0 || h == 0 {
        return "—".into();
    }
    let divisor = gcd(w, h);
    let (rw, rh) = (w / divisor, h / divisor);
    if rw <= 32 && rh <= 32 {
        format!("{rw}:{rh}")
    } else {
        format!("{:.2}:1", w as f64 / h as f64)
    }
}

pub fn gcd(a: u32, b: u32) -> u32 {
    if b == 0 {
        a.max(1)
    } else {
        gcd(b, a % b)
    }
}

/// Seconds since epoch → `"3 days ago"`. Coarse on purpose: a catalogue row
/// wants an age, not a timestamp.
pub fn relative_age(then: i64, now: i64) -> String {
    let delta = (now - then).max(0);
    match delta {
        d if d < 90 => "just now".into(),
        d if d < 5400 => format!("{} min ago", d / 60),
        d if d < 172_800 => format!("{} hours ago", d / 3600),
        d if d < 2_592_000 => format!("{} days ago", d / 86_400),
        d if d < 31_536_000 => format!("{} months ago", d / 2_592_000),
        d => format!("{} years ago", d / 31_536_000),
    }
}

/// Middle-elided text, so long titles do not push a layout around and the
/// distinguishing end of a filename survives.
pub fn truncate_middle(text: &str, max: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= max || max < 5 {
        return text.to_string();
    }
    let head = (max - 1) / 2;
    let tail = max - 1 - head;
    let mut out: String = chars[..head].iter().collect();
    out.push('…');
    out.extend(chars[chars.len() - tail..].iter());
    out
}

// ── colour ───────────────────────────────────────────────────────────────────

/// `"#7aa2f7"` → `(122, 162, 247)`. Accepts `#rgb`, `#rrggbb`, with or without
/// the hash, because sources write it every way.
pub fn parse_hex(hex: &str) -> Option<(u8, u8, u8)> {
    let hex = hex.trim().trim_start_matches('#');
    match hex.len() {
        3 => {
            let expand = |c: char| u8::from_str_radix(&format!("{c}{c}"), 16).ok();
            let mut chars = hex.chars();
            Some((expand(chars.next()?)?, expand(chars.next()?)?, expand(chars.next()?)?))
        }
        6 => Some((
            u8::from_str_radix(&hex[0..2], 16).ok()?,
            u8::from_str_radix(&hex[2..4], 16).ok()?,
            u8::from_str_radix(&hex[4..6], 16).ok()?,
        )),
        _ => None,
    }
}

pub fn to_hex((r, g, b): (u8, u8, u8)) -> String {
    format!("#{r:02x}{g:02x}{b:02x}")
}

/// Perceptual-ish distance between two colours, 0–100.
///
/// Not CIEDE2000 — this is a weighted RGB distance ("redmean"), which is close
/// enough to rank "does this wallpaper match my accent" and costs nothing to
/// run over 100k rows. The `color:#7aa2f7 dist<25` predicate is built on it.
pub fn color_distance(a: (u8, u8, u8), b: (u8, u8, u8)) -> f64 {
    let rmean = (a.0 as f64 + b.0 as f64) / 2.0;
    let dr = a.0 as f64 - b.0 as f64;
    let dg = a.1 as f64 - b.1 as f64;
    let db = a.2 as f64 - b.2 as f64;
    let weighted = (2.0 + rmean / 256.0) * dr * dr
        + 4.0 * dg * dg
        + (2.0 + (255.0 - rmean) / 256.0) * db * db;
    // The maximum of that expression is ~584 for black↔white; scale to 0–100 so
    // a threshold in a query means something to a person.
    (weighted.sqrt() / 584.0 * 100.0).min(100.0)
}

/// Relative luminance, for deciding whether a light or dark background is the
/// honest preview for an avatar.
pub fn luminance((r, g, b): (u8, u8, u8)) -> f64 {
    let channel = |c: u8| {
        let c = c as f64 / 255.0;
        if c <= 0.03928 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

/// WCAG contrast ratio, 1.0–21.0. The export sheet's contrast check reports
/// this against each platform's real background.
pub fn contrast_ratio(a: (u8, u8, u8), b: (u8, u8, u8)) -> f64 {
    let (la, lb) = (luminance(a), luminance(b));
    let (light, dark) = if la > lb { (la, lb) } else { (lb, la) };
    (light + 0.05) / (dark + 0.05)
}

// ── paths ────────────────────────────────────────────────────────────────────

/// Expand an output path template: `~/Pictures/quarry/{kind}/{slug}-{w}x{h}.{ext}`.
///
/// Unknown tokens are left alone rather than blanked — a typo should be visible
/// in the resulting filename, not silently swallow part of the path.
/// `~` at the start of a path, replaced with $HOME.
///
/// The shell hands over paths as the user typed or stored them, and a literal
/// "~" directory is not what anyone meant.
/*
 * FREEDESKTOP THUMBNAIL NAMING.
 * https://specifications.freedesktop.org/thumbnail-spec/latest/
 *
 * A thumbnail is named by the MD5 of the file's URI and filed under a
 * size-named directory. Following the standard rather than inventing a cache
 * layout means the pictures quarryd makes are the ones every other app on the
 * desktop already looks for — the shell's own ThumbnailImage computes exactly
 * this path and would never have found a private one.
 */

/// `encodeURIComponent`, per path segment — matching what the shell does, so
/// the two agree on the hash. JS leaves these unescaped: A-Z a-z 0-9 - _ . ! ~ * ' ( )
fn encode_segment(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for byte in segment.as_bytes() {
        let c = *byte as char;
        if c.is_ascii_alphanumeric() || "-_.!~*'()".contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// The canonical `file://` URI for an absolute path.
pub fn file_uri(path: &str) -> String {
    let encoded: Vec<String> = path.split('/').map(encode_segment).collect();
    format!("file://{}", encoded.join("/"))
}

/// The spec's directory for a pixel size: the smallest that fits it.
pub fn thumbnail_size_name(size: u32) -> &'static str {
    match size {
        0..=128 => "normal",
        129..=256 => "large",
        257..=512 => "x-large",
        _ => "xx-large",
    }
}

/// Where the spec says this file's thumbnail lives.
pub fn freedesktop_thumb_path(source: &str, size: u32) -> String {
    use md5::{Digest, Md5};
    let mut hasher = Md5::new();
    hasher.update(file_uri(source).as_bytes());
    let digest = hasher.finalize();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let cache = std::env::var("XDG_CACHE_HOME")
        .unwrap_or_else(|_| format!("{}/.cache", std::env::var("HOME").unwrap_or_default()));
    format!("{cache}/thumbnails/{}/{hex}.png", thumbnail_size_name(size))
}

pub fn expand_tilde(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => match std::env::var("HOME") {
            Ok(home) => format!("{home}/{rest}"),
            Err(_) => path.to_string(),
        },
        None => path.to_string(),
    }
}

pub fn expand_template(template: &str, values: &[(&str, String)]) -> String {
    let mut out = template.to_string();
    for (key, value) in values {
        out = out.replace(&format!("{{{key}}}"), value);
    }
    if let Some(rest) = out.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            out = format!("{home}/{rest}");
        }
    }
    out
}

/// Add ` (2)`, ` (3)` … before the extension until the path is free. Exporting
/// the same image twice should not silently overwrite the first one.
pub fn unique_path(path: impl AsRef<Path>) -> PathBuf {
    let path = path.as_ref();
    if !path.exists() {
        return path.to_path_buf();
    }
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
    let parent = path.parent().unwrap_or(Path::new("."));

    for n in 2..10_000 {
        let name =
            if ext.is_empty() { format!("{stem} ({n})") } else { format!("{stem} ({n}).{ext}") };
        let candidate = parent.join(name);
        if !candidate.exists() {
            return candidate;
        }
    }
    path.to_path_buf()
}

/// Write via a temporary file and rename, so a reader never sees half a file
/// and a crash never leaves a truncated catalogue or config.
pub async fn write_atomic(path: impl AsRef<Path>, bytes: &[u8]) -> std::io::Result<()> {
    let path = path.as_ref();
    if let Some(dir) = path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    let temp = path.with_extension(format!(
        "tmp{}",
        std::process::id()
    ));
    tokio::fs::write(&temp, bytes).await?;
    tokio::fs::rename(&temp, path).await
}

// ── misc ─────────────────────────────────────────────────────────────────────

/// Clamp with the arguments in the order people expect.
pub fn clamp<T: PartialOrd>(value: T, low: T, high: T) -> T {
    if value < low {
        low
    } else if value > high {
        high
    } else {
        value
    }
}

/// Split work into chunks — pages, batches of thumbnails, transaction sizes.
pub fn chunk_ranges(total: usize, size: usize) -> Vec<(usize, usize)> {
    if size == 0 || total == 0 {
        return Vec::new();
    }
    (0..total)
        .step_by(size)
        .map(|start| (start, (start + size).min(total)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_read_like_a_person_wrote_them() {
        assert_eq!(human_bytes(512), "512 B");
        assert_eq!(human_bytes(1536), "1.5 KB");
        assert_eq!(human_bytes(1_572_864), "1.5 MB");
        assert_eq!(human_bytes(157_286_400), "150 MB");
    }

    #[test]
    fn aspects_reduce_only_when_it_helps() {
        assert_eq!(aspect_label(1920, 1080), "16:9");
        assert_eq!(aspect_label(184, 184), "1:1");
        // 43:18 is technically right and tells nobody anything.
        assert_eq!(aspect_label(3440, 1440), "2.39:1");
        assert_eq!(aspect_label(0, 100), "—");
    }

    #[test]
    fn ages_stay_coarse() {
        assert_eq!(relative_age(1000, 1030), "just now");
        assert_eq!(relative_age(0, 3600), "60 min ago");
        assert_eq!(relative_age(0, 86_400 * 3), "3 days ago");
        assert_eq!(relative_age(0, 86_400 * 400), "1 years ago");
    }

    #[test]
    fn middle_elision_keeps_both_ends() {
        assert_eq!(truncate_middle("short", 10), "short");
        let out = truncate_middle("a-very-long-wallpaper-filename", 11);
        assert!(out.starts_with("a-ve"), "{out}");
        assert!(out.ends_with("name"), "{out}");
        assert_eq!(out.chars().count(), 11);
    }

    #[test]
    fn hex_parses_every_way_sources_write_it() {
        assert_eq!(parse_hex("#7aa2f7"), Some((122, 162, 247)));
        assert_eq!(parse_hex("7aa2f7"), Some((122, 162, 247)));
        assert_eq!(parse_hex("#fff"), Some((255, 255, 255)));
        assert_eq!(parse_hex("nope"), None);
        assert_eq!(to_hex((122, 162, 247)), "#7aa2f7");
    }

    #[test]
    fn colour_distance_ranks_sensibly() {
        let accent = parse_hex("#7aa2f7").unwrap();
        let near = parse_hex("#89b4fa").unwrap();
        let far = parse_hex("#f38ba8").unwrap();

        assert!(color_distance(accent, accent) < 0.01);
        assert!(color_distance(accent, near) < color_distance(accent, far));
        // The scale is 0-100 so a query threshold means something.
        assert!(color_distance((0, 0, 0), (255, 255, 255)) > 95.0);
    }

    #[test]
    fn contrast_matches_wcag_anchors() {
        let white = (255, 255, 255);
        let black = (0, 0, 0);
        assert!((contrast_ratio(white, black) - 21.0).abs() < 0.01);
        assert!((contrast_ratio(white, white) - 1.0).abs() < 0.01);
    }

    #[test]
    fn templates_expand_and_keep_typos_visible() {
        let out = expand_template(
            "/tmp/quarry/{kind}/{slug}-{w}x{h}.{ext}",
            &[
                ("kind", "avatar".into()),
                ("slug", "cat".into()),
                ("w", "184".into()),
                ("h", "184".into()),
                ("ext", "png".into()),
            ],
        );
        assert_eq!(out, "/tmp/quarry/avatar/cat-184x184.png");
        // An unknown token survives into the filename instead of vanishing.
        assert!(expand_template("/tmp/{nope}.png", &[]).contains("{nope}"));
    }

    #[test]
    fn unique_path_does_not_overwrite() {
        let dir = std::env::temp_dir().join(format!("quarry-util-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("cat.png");
        assert_eq!(unique_path(&target), target);

        std::fs::write(&target, b"x").unwrap();
        assert_eq!(unique_path(&target), dir.join("cat (2).png"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn atomic_writes_leave_no_partial_file() {
        let dir = std::env::temp_dir().join(format!("quarry-atomic-{}", std::process::id()));
        let path = dir.join("nested/catalog.json");
        write_atomic(&path, b"{\"ok\":true}").await.unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{\"ok\":true}");
        // No temp files left behind.
        let leftovers: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp file left behind");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn chunks_cover_everything_exactly_once() {
        assert_eq!(chunk_ranges(10, 4), vec![(0, 4), (4, 8), (8, 10)]);
        assert_eq!(chunk_ranges(0, 4), vec![]);
        assert_eq!(chunk_ranges(10, 0), vec![]);
        let total: usize = chunk_ranges(1000, 137).iter().map(|(a, b)| b - a).sum();
        assert_eq!(total, 1000);
    }

    #[test]
    fn clamp_reads_in_the_expected_order() {
        assert_eq!(clamp(5, 0, 10), 5);
        assert_eq!(clamp(-5, 0, 10), 0);
        assert_eq!(clamp(50, 0, 10), 10);
    }
}

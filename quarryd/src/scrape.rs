/*
 * WHAT A ROW MEANS — the half of the old `scrape.rs` that is quarry's, not the
 * web's.
 *
 * The fetching itself moved to the `fetchkit` crate so quarry and cairn share
 * one rate limiter, one cache and one User-Agent policy instead of two
 * half-right copies. It is re-exported here, so every `scrape::` call site in
 * this codebase still reads exactly as it did.
 *
 * What stayed is the vocabulary: which family an extension belongs to, which
 * kind a shape suggests, and `normalize`, which is the one place an `Item` is
 * built. Those are decisions about a catalogue of pictures — meaningless to a
 * crate whose job ends at bytes.
 */
pub use fetchkit::*;

use std::collections::HashMap;
use std::time::SystemTime;

use serde_json::Value;

use crate::protocol::Item;

/// Which renderer an item needs, from its extension.
///
/// **21**
pub fn infer_family(ext: &str) -> &'static str {
    match ext {
        "svg" => "vector",
        "gltf" | "glb" | "obj" | "stl" | "fbx" | "blend" => "model",
        "hdr" | "exr" => "hdri",
        // A moving picture is not a raster with a flag on it. It cannot be
        // decoded, cropped or re-encoded by the image pipeline, its thumbnail
        // is a frame rather than a resize, and applying one to a wallpaper
        // slot runs a different program. GIF is deliberately NOT here: it is a
        // raster the decoder handles, marked `animated`.
        "mp4" | "webm" | "mkv" | "mov" | "m4v" | "avi" | "ogv" => "video",
        _ => "raster",
    }
}

/// A default `kind` from shape, for sources that do not say.
///
/// Aspect ratio really is the best available signal: square is an avatar or an
/// icon, wide is a wallpaper or a banner. A source that knows better overrides
/// it, and so can the user.
///
/// **22**
pub fn infer_kind(w: u32, h: u32, family: &str) -> &'static str {
    if family == "vector" {
        return "icon";
    }
    if family == "model" || family == "hdri" {
        return "cover";
    }
    /*
     * A VIDEO IS A VIDEO, WHATEVER SHAPE ITS POSTER IS.
     *
     * What a video source hands over is a poster frame, and a poster frame is
     * wide — so this measured 320×180, called it 1.78, and filed every clip on
     * Pornhub, Eporner, Redtube and the rest under "wallpaper". They then
     * turned up in `kind:wallpaper`, which is a query about pictures you would
     * put behind your desktop, and the detail sheet offered "wallpaper" as
     * what the thing IS.
     */
    if family == "video" {
        return "video";
    }
    if w == 0 || h == 0 {
        return "avatar";
    }
    let ratio = w as f64 / h as f64;
    if ratio > 2.6 {
        "banner"
    } else if ratio > 1.25 {
        "wallpaper"
    } else if ratio < 0.8 {
        "cover"
    } else {
        "avatar"
    }
}

/// The catalogue id: stable across re-crawls, and namespaced so two sources
/// cannot collide.
///
/// **23**
pub fn stable_id(source: &str, source_id: &str) -> String {
    format!("{source}:{source_id}")
}

/// Build a validated `Item`, filling in everything derivable.
///
/// Adapters call this rather than constructing `Item` by hand, so `ratio` is
/// never missing — the wall reads it per tile and a zero there is a collapsed
/// row — and `family`, `kind`, `ext` and `slug` are consistent across sources.
///
/// **24**
#[allow(clippy::too_many_arguments)]
pub fn normalize(
    source: &str,
    source_id: &str,
    title: &str,
    url: &str,
    thumb: &str,
    page_url: &str,
    w: u32,
    h: u32,
    tags: Vec<String>,
) -> Item {
    let ext = guess_ext(url, None);
    let family = infer_family(&ext).to_string();
    let family_is_video = family == "video";
    let kind = infer_kind(w, h, &family).to_string();
    let ratio = if h > 0 { w as f64 / h as f64 } else { 1.0 };

    Item {
        id: stable_id(source, source_id),
        source: source.to_string(),
        source_id: source_id.to_string(),
        family,
        kind,
        title: title.to_string(),
        slug: slugify(if title.is_empty() { source_id } else { title }),
        url: url.to_string(),
        thumb: if thumb.is_empty() { url.to_string() } else { thumb.to_string() },
        sample: String::new(),
        page_url: page_url.to_string(),
        ext,
        w,
        h,
        ratio,
        bytes: 0,
        // A video is animated by definition; a GIF is the raster that is.
        animated: url.ends_with(".gif") || family_is_video,
        duration: 0.0,
        tintable: false,
        nsfw: false,
        author: String::new(),
        license: String::new(),
        tags,
        added_at: SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
        phash: String::new(),
        dominant: String::new(),
        thumb_local: String::new(),
    }
}

/// Record what a row was FOUND BY, as tags.
///
/// Some sources describe their rows and some do not. A wallhaven search result
/// carries no title and no tags at all — just an id, a size and a purity
/// rating — so a crawl for "nature" fetched exactly the right pictures and the
/// catalogue could then never find them again: the rows had no text for the
/// query to match, and searching the tab for the word that fetched them
/// returned nothing, forever.
///
/// The terms that fetched a row are the truest thing anybody knows about it —
/// the source itself said this picture answers that word. So they are written
/// down. Only genuine words: an operator like `kind:wallpaper` is a filter
/// rather than a description, and is already a column.
///
/// **26**
pub fn tag_with_terms(items: &mut [Item], terms: &[String]) {
    /*
     * A WORD, not an operator.
     *
     * Blocklisting `:` and a leading `-` was not enough — `w>=3440` has
     * neither, and would have been written onto every row a size filter ever
     * fetched. So this allows rather than forbids: letters and digits, with
     * hyphens and underscores inside, which is what a tag looks like
     * everywhere else in the catalogue.
     */
    let words: Vec<String> = terms
        .iter()
        .flat_map(|t| t.split_whitespace())
        .map(|w| w.trim_matches('"'))
        .filter(|w| {
            w.len() > 1
                && w.chars().next().is_some_and(|c| c.is_alphanumeric())
                && w.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        })
        .map(|w| w.to_lowercase())
        .collect();

    if words.is_empty() {
        return;
    }

    for item in items.iter_mut() {
        // ONLY A ROW THAT DESCRIBES ITSELF WITH NOTHING.
        //
        // Stamping every row a search touched wrote the query into the
        // catalogue: after one search for "bonnie blue", 19,756 rows here
        // carried the tag `bonnie` — anime wallpapers, a photo of cats, a blue
        // flag — because every site returns SOMETHING for every query and all
        // of it got labelled with the words that fetched it. Every later
        // search then matched all of them, and the wall filled with rows that
        // had never been an answer to anything.
        //
        // The case this exists for is narrower than that and still holds: a
        // wallhaven row arrives with no title, no tags and no author, so
        // without this nothing can ever find it again.
        if !describes_itself(item) {
            for word in &words {
                if !item.tags.iter().any(|t| t.eq_ignore_ascii_case(word)) {
                    item.tags.push(word.clone());
                }
            }
        }
    }
}

/// Whether a row carries any text of its own to be found by.
fn describes_itself(item: &Item) -> bool {
    !item.title.trim().is_empty() || !item.tags.is_empty() || !item.author.trim().is_empty()
}

/// Drop rows the catalogue cannot use, and say how many went.
///
/// A source that changes its markup usually does not fail loudly: it starts
/// returning rows with empty URLs. Counting them is what lets `doctor` say
/// "pfps.gg returned 40 rows, 40 unusable" instead of showing an empty wall.
///
/// **25**
pub fn keep_usable(items: Vec<Item>) -> (Vec<Item>, usize) {
    let before = items.len();
    let kept: Vec<Item> = items
        .into_iter()
        .filter(|i| !i.url.is_empty() && !i.id.is_empty() && i.ratio.is_finite() && i.ratio > 0.0)
        .collect();
    let dropped = before - kept.len();
    (kept, dropped)
}


/// Percent-encode one query-string value.
///
/// Not optional decoration: danbooru's tag syntax contains `>` and `=`
/// (`width:>=1920`), and sending those raw makes its HTTP parser reject the
/// request with a 500 that looks nothing like a filter problem.
///
/// **27**
/// The inverse of `urlencode`, for values this process wrote itself (the
/// stream proxy hands segment URLs back to itself in a query string).
pub fn urldecode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                match u8::from_str_radix(&text[i + 1..i + 3], 16) {
                    Ok(byte) => {
                        out.push(byte);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}


/// Remove rows already seen this crawl, by id.
///
/// **26**
pub fn dedupe(items: Vec<Item>) -> Vec<Item> {
    let mut seen = std::collections::HashSet::new();
    items.into_iter().filter(|i| seen.insert(i.id.clone())).collect()
}



/*
 * What stayed: the tests whose subject is an `Item`. The fetching tests went
 * with the fetching, into fetchkit, where they sit beside the code they
 * exercise.
 */
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_fills_in_everything_the_wall_needs() {
        let item = normalize(
            "wallhaven",
            "e82xxr",
            "Mountains at dusk",
            "https://w.wallhaven.cc/full/e8/wallhaven-e82xxr.png",
            "https://th.wallhaven.cc/small/e8/e82xxr.jpg",
            "https://wallhaven.cc/w/e82xxr",
            1920,
            1080,
            vec!["landscape".into()],
        );

        assert_eq!(item.id, "wallhaven:e82xxr");
        assert_eq!(item.family, "raster");
        assert_eq!(item.kind, "wallpaper");
        assert_eq!(item.ext, "png");
        assert_eq!(item.slug, "mountains-at-dusk");
        // The invariant the masonry depends on: ratio is always populated.
        assert!((item.ratio - 1.7777).abs() < 0.001);
        assert!(item.added_at > 0);
    }

    #[test]
    fn unusable_rows_are_counted_not_hidden() {
        let good = normalize("s", "1", "a", "https://x/a.png", "", "", 100, 100, vec![]);
        let mut broken = good.clone();
        broken.url = String::new();
        let mut zero = good.clone();
        zero.id = "s:2".into();
        zero.ratio = 0.0;

        let (kept, dropped) = keep_usable(vec![good, broken, zero]);
        assert_eq!(kept.len(), 1);
        assert_eq!(dropped, 2, "a source that changed its markup must be visible as a count");
    }

    #[test]
    fn dedupe_keeps_first_occurrence() {
        let a = normalize("s", "1", "first", "https://x/a.png", "", "", 10, 10, vec![]);
        let b = normalize("s", "1", "second", "https://x/b.png", "", "", 10, 10, vec![]);
        let c = normalize("s", "2", "third", "https://x/c.png", "", "", 10, 10, vec![]);
        let out = dedupe(vec![a, b, c]);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].title, "first");
    }

    #[test]
    fn family_and_kind_come_from_shape() {
        assert_eq!(infer_family("svg"), "vector");
        assert_eq!(infer_family("glb"), "model");
        assert_eq!(infer_family("png"), "raster");

        assert_eq!(infer_kind(184, 184, "raster"), "avatar");
        assert_eq!(infer_kind(1920, 1080, "raster"), "wallpaper");
        // An ultrawide is still a wallpaper — 3440x1440 is 2.39:1, under the
        // banner threshold on purpose. A banner is a strip: an X header is
        // 1500x500, three to one.
        assert_eq!(infer_kind(3440, 1440, "raster"), "wallpaper");
        assert_eq!(infer_kind(1500, 500, "raster"), "banner");
        assert_eq!(infer_kind(800, 1200, "raster"), "cover");
        // A vector has no meaningful pixel shape; it is an icon until told
        // otherwise.
        assert_eq!(infer_kind(0, 0, "vector"), "icon");
    }

    #[test]
    fn pfps_gg_html_yields_avatars() {
        let html = fixture("pfps-gg.html");
        let rows = regex_captures(
            &html,
            r"https://cdn\.pfps\.gg/pfps/(?P<id>\d+)-\d+-(?P<slug>[a-z0-9-]+)\.(?P<ext>png|jpeg|jpg|gif)",
        )
        .expect("pattern compiles");

        assert!(rows.len() > 10, "expected a page of avatars, got {}", rows.len());
        let first = &rows[0];
        assert!(first["id"].parse::<u64>().is_ok());
        assert!(!first["slug"].is_empty());
        assert!(matches!(first["ext"].as_str(), "png" | "jpeg" | "jpg" | "gif"));
    }

    #[test]
    fn a_row_remembers_what_found_it() {
        let mut rows = vec![row()];
        tag_with_terms(&mut rows, &["nature".to_string()]);
        assert!(rows[0].tags.contains(&"nature".to_string()));
    }

    /// The regression this was written for: every row a search touched was
    /// stamped with the query, so one search for "bonnie blue" left 19,756
    /// rows in a live catalogue tagged `bonnie` — anime wallpapers, a photo of
    /// cats, a flag — and every later search matched all of them.
    #[test]
    fn a_row_that_describes_itself_is_not_labelled_with_the_query() {
        let titled = normalize(
            "wallhaven",
            "t1",
            "Two cats on a windowsill",
            "https://w.cc/t1.jpg",
            "",
            "",
            1920,
            1080,
            vec![],
        );
        let tagged = normalize(
            "booru",
            "t2",
            "",
            "https://b.cc/t2.jpg",
            "",
            "",
            1920,
            1080,
            vec!["1girl".to_string()],
        );

        let mut rows = vec![titled, tagged, row()];
        tag_with_terms(&mut rows, &["bonnie blue".to_string()]);

        assert!(!rows[0].tags.iter().any(|t| t == "bonnie"), "a titled row: {:?}", rows[0].tags);
        assert!(!rows[1].tags.iter().any(|t| t == "bonnie"), "a tagged row: {:?}", rows[1].tags);
        // The row this exists for still learns: it arrived with no text at all.
        assert!(rows[2].tags.contains(&"bonnie".to_string()), "{:?}", rows[2].tags);
    }

    #[test]
    fn operators_are_filters_and_not_descriptions() {
        let mut rows = vec![row()];
        tag_with_terms(&mut rows, &["misty forest kind:wallpaper w>=3440 -nsfw".to_string()]);

        assert!(rows[0].tags.contains(&"misty".to_string()));
        assert!(rows[0].tags.contains(&"forest".to_string()));
        // These are columns, not words about the picture.
        assert!(!rows[0].tags.iter().any(|t| t.contains(':')));
        assert!(!rows[0].tags.iter().any(|t| t.starts_with('-')));
        assert!(!rows[0].tags.iter().any(|t| t.contains(">=")));
    }

    #[test]
    fn nothing_is_added_twice_or_from_nothing() {
        let mut rows = vec![row()];
        tag_with_terms(&mut rows, &["Nature".to_string()]);
        tag_with_terms(&mut rows, &["nature".to_string()]);
        assert_eq!(rows[0].tags.iter().filter(|t| t.eq_ignore_ascii_case("nature")).count(), 1);

        let before = rows[0].tags.len();
        tag_with_terms(&mut rows, &[String::new()]);
        tag_with_terms(&mut rows, &[]);
        assert_eq!(rows[0].tags.len(), before);
    }


    fn row() -> crate::protocol::Item {
        // A wallhaven search result, as it actually arrives: an id, a size, and
        // nothing a person could search for.
        normalize("wallhaven", "abc123", "", "https://w.cc/abc123.jpg", "", "", 3840, 2160, vec![])
    }

    /// Fixtures are real captures from the live sources, checked in beside the
    /// tests. Nothing here touches the network: a source that changes its
    /// markup must fail in `doctor` against the live site, not randomly in CI.
    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("tests/fixtures/{name}"))
            .unwrap_or_else(|e| panic!("missing fixture {name}: {e}"))
    }
}

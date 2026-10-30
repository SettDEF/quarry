//! wallhaven.cc — the anchor wallpaper source.
//!
//! Its API is unusually good for this app: resolution, aspect ratio, purity and
//! a colour palette come back with every row, and nearly every predicate in the
//! quarry query language maps onto a parameter it already understands. That is
//! why it is the adapter to write first — it is the one that proves pushdown is
//! worth the machinery.

use serde::Deserialize;

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::query::Sort;
use crate::scrape;

pub struct Wallhaven;

#[derive(Debug, Deserialize)]
struct Response {
    data: Vec<Row>,
    #[serde(default)]
    meta: Meta,
}

#[derive(Debug, Default, Deserialize)]
struct Meta {
    #[serde(default)]
    current_page: u32,
    #[serde(default)]
    last_page: u32,
}

#[derive(Debug, Deserialize)]
struct Row {
    id: String,
    url: String,
    path: String,
    #[serde(default)]
    purity: String,
    #[serde(default)]
    category: String,
    dimension_x: u32,
    dimension_y: u32,
    #[serde(default)]
    file_size: u64,
    #[serde(default)]
    file_type: String,
    #[serde(default)]
    colors: Vec<String>,
    thumbs: Thumbs,
}

#[derive(Debug, Deserialize)]
struct Thumbs {
    small: String,
    #[serde(default)]
    large: String,
}

/// The only colours Wallhaven's `colors=` accepts. Anything else is ignored
/// by the API without a word, so the crawl comes back unfiltered.
const PALETTE: [&str; 29] = [
    "660000", "990000", "cc0000", "cc3333", "ea4c88", "993399", "663399", "333399",
    "0066cc", "0099cc", "66cccc", "77cc33", "669900", "336600", "666600", "999900",
    "cccc33", "ffff00", "ffcc33", "ff9900", "ff6600", "cc6633", "996633", "663300",
    "000000", "999999", "cccccc", "ffffff", "424153",
];

/// `#cc9933` → `"996633"`: the palette swatch nearest any colour, so a colour
/// picked from a wallpaper (or a slightly-off preset) still filters the crawl.
fn palette_color(hex: &str) -> Option<&'static str> {
    let rgb = |h: &str| -> Option<(i32, i32, i32)> {
        let h = h.trim_start_matches('#');
        if h.len() != 6 {
            return None;
        }
        let c = |i: usize| i32::from_str_radix(&h[i..i + 2], 16).ok();
        Some((c(0)?, c(2)?, c(4)?))
    };
    let (r, g, b) = rgb(hex)?;
    PALETTE.iter().copied().min_by_key(|p| {
        let (pr, pg, pb) = rgb(p).unwrap_or((0, 0, 0));
        // weighted RGB: close enough to perceptual for 29 far-apart swatches
        let (dr, dg, db) = (r - pr, g - pg, b - pb);
        2 * dr * dr + 4 * dg * dg + 3 * db * db
    })
}

/// `1.777` → `"16x9"`. Wallhaven takes named ratios, and the ones people ask
/// for are the ones worth mapping; anything else is left to the local residue.
fn ratio_param(ratio: f64) -> Option<&'static str> {
    const KNOWN: [(f64, &str); 8] = [
        (16.0 / 9.0, "16x9"),
        (16.0 / 10.0, "16x10"),
        (21.0 / 9.0, "21x9"),
        (32.0 / 9.0, "32x9"),
        (4.0 / 3.0, "4x3"),
        (1.0, "1x1"),
        (9.0 / 16.0, "9x16"),
        (10.0 / 16.0, "10x16"),
    ];
    KNOWN
        .iter()
        .find(|(value, _)| (value - ratio).abs() < 0.03)
        .map(|(_, name)| *name)
}

impl Wallhaven {
    /// Real wallhaven search terms, run through the same `q` box user text
    /// goes through and checked against the live API for a nonzero count —
    /// wallhaven has no published category list, only tags people search by.
    pub fn popular_groups() -> &'static [(&'static str, &'static [&'static str])] {
        &[
            ("Nature", &["nature", "mountains", "forest", "ocean", "space", "galaxy"]),
            ("Style", &["abstract", "minimal", "gradient", "cyberpunk", "digital art"]),
            ("Anime & gaming", &["anime", "gaming", "scifi", "fantasy"]),
            ("Urban", &["city", "architecture", "cars", "technology"]),
        ]
    }
}

impl Source for Wallhaven {
    fn id(&self) -> &'static str {
        "wallhaven"
    }

    fn category(&self) -> &'static str {
        "wallpapers"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            min_size: true,
            ratio: true,
            nsfw: true,
            sort: true,
            video: false,
            colors: true,
            // Wallhaven has tags, but they go through the same `q` box as text.
            tags: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        let mut params: Vec<String> = Vec::new();

        let text = query
            .text
            .iter()
            .chain(query.tags.iter())
            .cloned()
            .collect::<Vec<_>>()
            .join(" ");
        if !text.is_empty() {
            params.push(format!("q={}", scrape::urlencode(&text)));
        }

        // Purity is a three-bit mask: sfw / sketchy / nsfw. Without an API key
        // only the first bit is allowed, so asking for more without one returns
        // nothing at all — better to ask for what we can have.
        let purity = match query.allow_nsfw {
            Some(true) => "110",
            _ => "100",
        };
        params.push(format!("purity={purity}"));

        if query.min_w > 0 || query.min_h > 0 {
            params.push(format!(
                "atleast={}x{}",
                query.min_w.max(1),
                query.min_h.max(1)
            ));
        }

        if let Some(ratio) = query.ratio.and_then(ratio_param) {
            params.push(format!("ratios={ratio}"));
        }

        if let Some(color) = query.color.as_deref().and_then(palette_color) {
            params.push(format!("colors={color}"));
        }

        /*
         * Relevance needs something to be relevant to.
         *
         * `sorting=relevance` with an empty `q` returns nothing at all — not an
         * error, just zero rows — so a browse with no search term silently
         * comes back empty. Fall back to newest, which is what "show me
         * something" means. This fooled `doctor` into reporting a working
         * source as broken before it fooled the app.
         */
        let sorting = match query.sort {
            Sort::Newest => "date_added",
            Sort::Random => "random",
            Sort::Largest => "toplist",
            Sort::Title | Sort::Widest | Sort::Relevance => {
                if text.is_empty() {
                    "date_added"
                } else {
                    "relevance"
                }
            }
        };
        params.push(format!("sorting={sorting}"));

        params.push(format!("page={}", query.page.max(1)));
        format!("https://wallhaven.cc/api/v1/search?{}", params.join("&"))
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let response: Response =
            serde_json::from_str(body).map_err(|e| format!("wallhaven json: {e}"))?;

        Ok(response
            .data
            .into_iter()
            .map(|row| {
                let mut item = scrape::normalize(
                    "wallhaven",
                    &row.id,
                    "",
                    &row.path,
                    if row.thumbs.large.is_empty() { &row.thumbs.small } else { &row.thumbs.large },
                    &row.url,
                    row.dimension_x,
                    row.dimension_y,
                    if row.category.is_empty() { vec![] } else { vec![row.category.clone()] },
                );
                item.bytes = row.file_size;
                item.nsfw = row.purity != "sfw";
                item.license = String::new();
                // The palette comes free with the row, so colour matching works
                // on this source without ever decoding an image.
                item.dominant = row.colors.first().cloned().unwrap_or_default();
                if !row.file_type.is_empty() {
                    item.ext = row.file_type.trim_start_matches("image/").to_string();
                }
                // Every wallhaven row is a wallpaper, whatever its aspect says.
                item.kind = "wallpaper".into();
                item
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<Response>(body)
            .map(|r| r.meta.current_page < r.meta.last_page)
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod palette_tests {
    use super::palette_color;

    #[test]
    fn palette_colours_pass_through() {
        assert_eq!(palette_color("#0066cc"), Some("0066cc"));
        assert_eq!(palette_color("ff9900"), Some("ff9900"));
    }

    #[test]
    fn off_palette_colours_snap_to_the_nearest() {
        // the old "orange" preset, not a Wallhaven colour
        assert_eq!(palette_color("#cc9933"), Some("cccc33"));
        assert_eq!(palette_color("#e58a3d"), Some("cc6633"));
        assert_eq!(palette_color("#fefefe"), Some("ffffff"));
    }

    #[test]
    fn junk_is_no_filter() {
        assert_eq!(palette_color("blue"), None);
        assert_eq!(palette_color("#12"), None);
    }
}

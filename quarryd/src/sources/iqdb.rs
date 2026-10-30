//! IQDB — reverse image search over HTML, and the shape it does not fit.
//!
//! Same gap as `saucenao.rs`, so read that file's header first; the short
//! version is that `Source::build_url(&SourceQuery)` takes a parsed *text*
//! query, and "where else does this picture exist" has no picture to put in
//! one. This is a pair of plain functions, not a `Source` impl, for the same
//! reason and pending the same trait decision.
//!
//! ## The request
//!
//! iqdb.org's own form POSTs `multipart/form-data` to `https://iqdb.org/`
//! (`https://3d.iqdb.org/` for the non-anime instance) with a `file` field for
//! an upload and a `url` field as its keyless alternative — a link to an
//! already-hosted image, which is exactly what a quarry `Item.url` already is.
//! `build_request` describes that body; since quarry only ever sends `url`
//! and never `file`, `scrape::Http::post_form` sends it as a plain
//! `application/x-www-form-urlencoded` POST instead of true multipart — a
//! server reads a lone text field the same way regardless of which encoding
//! carried it, multipart only earning its keep once a `file` part exists, and
//! this way needs no extra dependency. See `build_request`'s doc comment.
//!
//! ## The response, and why this parses defensively
//!
//! There is no JSON API and no version number on the HTML — a markup change
//! on iqdb's end is silent until something here breaks. So `parse` does not
//! trust element order or a fixed table shape: it looks for the two facts a
//! result row cannot exist without (a link to the matched page, a `N%
//! similarity` figure) and builds a `Match` only when both are present, and it
//! derives the source label from the link's own host rather than a text cell
//! at a guessed position, which is one fewer thing that can drift.
//!
//! That principle used to stop short of *categorising* a row: an earlier
//! version located "Additional matches" and "Possible matches" by slicing the
//! page on `id="more1"`/`id="more2"`, positions guessed from the fields these
//! reconstructed fixtures never had reason to omit. A real capture (see the
//! fixture-provenance note on the tests below) has neither id, so every row
//! landed in "best" and 16 unrelated matches all came back `Best`. The count
//! was right; the categorisation was invented. See `MatchCategory` and
//! `parse_matches` for what the real page actually delimits.
//!
//! ## Rate limit
//!
//! iqdb.org is a small, free, individually-run service with no published
//! numeric limit and no API key to attach one to — the only documented rule is
//! "don't hammer it". Treat that as license to be more conservative than a
//! documented limit would require, not less: a caller wiring this up should
//! run it through something like `scrape::RateLimiter` with a multi-second
//! per-host delay, not the per-request pacing a keyed API can afford.

use crate::scrape;

/// Which iqdb instance to ask. `All` is the anime/booru index at
/// `iqdb.org`; `ThreeD` is the separate photo/3D-art index — different
/// corpora entirely, so this is a choice of *database*, not a filter on one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Service {
    All,
    ThreeD,
}

impl Service {
    fn endpoint(self) -> &'static str {
        match self {
            Service::All => "https://iqdb.org/",
            Service::ThreeD => "https://3d.iqdb.org/",
        }
    }
}

/// One field of the multipart body iqdb.org's own form submits.
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub name: &'static str,
    pub value: String,
}

/// The request iqdb's own form makes, translated to data instead of a browser:
/// POST these fields to the returned endpoint.
///
/// iqdb's form sends `multipart/form-data`, but quarry only ever fills the
/// `url` field, never `file`, and a lone text field parses identically off a
/// `multipart` or an `application/x-www-form-urlencoded` body — multipart
/// only earns its keep once a binary `file` part is in the request. So the
/// caller (`main.rs`'s `"iqdb"` reverse-search arm) sends these fields with
/// `scrape::Http::post_form`, which speaks urlencoded, and `reqwest`'s
/// `multipart` feature stays unneeded.
pub fn build_request(image_url: &str, service: Service) -> (&'static str, Vec<Field>) {
    (service.endpoint(), vec![Field { name: "url", value: image_url.to_string() }])
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchCategory {
    /// iqdb's own top pick — the only tier the page itself labels, marked
    /// with a literal `<th>Best match</th>` on that one result's table.
    Best,
    /// Every other genuine result row. A real capture showed no second,
    /// separately-labelled "Additional matches"/"Possible matches" split —
    /// that three-tier read was this parser's own earlier invention, built
    /// from a reconstructed fixture rather than the page iqdb actually
    /// serves. Whatever iqdb sends beyond the one row it calls "Best match"
    /// lands here undivided, ordered by similarity.
    Additional,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Match {
    pub category: MatchCategory,
    /// The page a human would open — the fact a row cannot exist without.
    pub source_url: String,
    pub thumbnail: String,
    /// The matched site's host, e.g. `"danbooru.donmai.us"` — read from
    /// `source_url` itself rather than a text cell, which is what keeps this
    /// working if iqdb reorders or relabels its columns.
    pub host: String,
    pub width: u32,
    pub height: u32,
    /// The booru rating iqdb prints next to the size, e.g. `"Safe"`,
    /// `"Ero"`, `"Explicit"` — verbatim, since this is iqdb's own vocabulary
    /// and not one quarry's `nsfw` bool can losslessly become on its own.
    pub rating: String,
    pub similarity: f64,
}

/// A parsed page: real matches, or the site's own explanation for finding
/// none. Kept apart from `Err` deliberately — "iqdb looked and found nothing"
/// and "this page's markup is not one this parser understands" are different
/// failures, and only the second one is this parser's fault.
#[derive(Debug, Clone, PartialEq)]
pub enum SearchResult {
    Matches(Vec<Match>),
    NoMatches(String),
}

/// Parse an iqdb.org results page.
pub fn parse(html: &str) -> Result<SearchResult, String> {
    if html.trim().is_empty() {
        return Err("iqdb: empty response body".to_string());
    }

    let matches = parse_matches(html);
    if !matches.is_empty() {
        return Ok(SearchResult::Matches(matches));
    }

    // Nothing parsed as a match row. Trust iqdb's own wording when it is
    // there rather than manufacture a reason; when it is not, this is a page
    // shape the parser does not recognise, and that must fail loudly rather
    // than read as "no matches" — an honest search coming back empty and a
    // parser that has silently stopped working must never look the same.
    match no_match_reason(html) {
        Some(reason) => Ok(SearchResult::NoMatches(reason)),
        None => Err(
            "iqdb: no result table found and no \"no matches\" notice either — \
             the page's markup likely changed"
                .to_string(),
        ),
    }
}

/// The page's own explanation for an empty result, when it gives one — iqdb
/// marks it with an `.err` element.
fn no_match_reason(html: &str) -> Option<String> {
    scrape::select_texts(html, ".err").ok()?.into_iter().find(|t| !t.trim().is_empty())
}

/// Every genuine match row on the page, tagged `Best` or `Additional`.
///
/// Walks every `<table>` in the whole document rather than slicing the page
/// into sections by id first (a real capture has no `more1`/`more2` markers
/// to slice on — see the module doc). A `<table>` is a match row only if it
/// has both a link to the matched page and an "N% similarity" cell; the
/// "Your image" preview table has neither (no link at all), and the upload
/// form's own `<table>`s have links but no similarity figure, so both are
/// excluded without needing to be sliced out by position. Of what is left,
/// the one row iqdb itself headers `<th>Best match</th>` is `Best`; every
/// other row that gets this far is `Additional` — see `MatchCategory`.
fn parse_matches(html: &str) -> Vec<Match> {
    let document = scraper::Html::parse_document(html);
    let Ok(table_sel) = scraper::Selector::parse("table") else { return Vec::new() };
    let Ok(td_sel) = scraper::Selector::parse("td") else { return Vec::new() };
    let Ok(th_sel) = scraper::Selector::parse("th") else { return Vec::new() };
    let Ok(a_sel) = scraper::Selector::parse("a[href]") else { return Vec::new() };
    let Ok(img_sel) = scraper::Selector::parse("img[src]") else { return Vec::new() };

    document
        .select(&table_sel)
        .filter_map(|table| {
            let source_url = table.select(&a_sel).next().and_then(|a| a.value().attr("href"))?;
            // The one cell every genuine match row has and the preview table
            // for the query image itself does not — this is what tells the
            // two apart.
            let cells: Vec<String> = table
                .select(&td_sel)
                .map(|td| td.text().collect::<String>().split_whitespace().collect::<Vec<_>>().join(" "))
                .collect();
            let joined = cells.join(" | ");
            let similarity = extract_similarity(&joined)?;

            let category = if table.select(&th_sel).any(|th| {
                th.text().collect::<String>().trim().eq_ignore_ascii_case("best match")
            }) {
                MatchCategory::Best
            } else {
                MatchCategory::Additional
            };

            let thumbnail =
                table.select(&img_sel).next().and_then(|img| img.value().attr("src"));
            let (width, height, rating) = extract_size_and_rating(&joined);
            let source_url = absolute(source_url);

            Some(Match {
                category,
                host: scrape::host_of(&source_url).unwrap_or_default(),
                source_url,
                thumbnail: thumbnail.map(absolute).unwrap_or_default(),
                width,
                height,
                rating,
                similarity,
            })
        })
        .collect()
}

fn extract_similarity(text: &str) -> Option<f64> {
    let rows = scrape::regex_captures(text, r"(?P<pct>\d+)%\s*similarity").ok()?;
    rows.first()?.get("pct")?.parse().ok()
}

fn extract_size_and_rating(text: &str) -> (u32, u32, String) {
    let Ok(rows) = scrape::regex_captures(text, r"(?P<w>\d+)\s*[×x]\s*(?P<h>\d+)\s*\[(?P<rating>[^\]]*)\]")
    else {
        return (0, 0, String::new());
    };
    let Some(row) = rows.first() else { return (0, 0, String::new()) };
    let get = |k: &str| row.get(k).cloned().unwrap_or_default();
    (get("w").parse().unwrap_or(0), get("h").parse().unwrap_or(0), get("rating"))
}

/// iqdb serves two different kinds of relative link, and a browser resolves
/// both against the page it is looking at — nothing here has one, so both
/// need their own rule. A matched *page* link is protocol-relative
/// (`//host/path`): the matched site could be anywhere. A *thumbnail* is
/// root-relative (`/danbooru/...`, `/thu/...`): iqdb's own image proxy,
/// confirmed against a real capture, resolved against `iqdb.org` — the only
/// host a capture exists for; whether `3d.iqdb.org` proxies thumbnails under
/// its own host instead is untested.
fn absolute(raw: &str) -> String {
    if let Some(rest) = raw.strip_prefix("//") {
        format!("https://{rest}")
    } else if let Some(rest) = raw.strip_prefix('/') {
        format!("https://iqdb.org/{rest}")
    } else {
        raw.to_string()
    }
}

#[cfg(test)]
mod tests {
    /*
     * FIXTURE PROVENANCE.
     *
     * `iqdb-results.html` is a REAL capture, not reconstructed: an actual
     * `post_form` POST of `url=` (a hosted image) to https://iqdb.org/,
     * saved verbatim (the untouched original also sits alongside it as
     * `iqdb-real-capture.html`). It is what caught this parser modelling
     * three match tiers (`more1`/`more2` markers) that do not exist on the
     * live page — the previous version of this comment's warning, made good
     * on. Trust assertions built from it.
     *
     * `iqdb-no-match.html` is still RECONSTRUCTED, not captured — built from
     * the documented `.err` notice shape, because getting a genuine empty
     * result means finding an image iqdb has never indexed anywhere. Treat
     * it as weaker evidence than `iqdb-results.html` until it, too, is
     * replaced with a real capture.
     */

    use super::*;

    #[test]
    fn build_request_carries_the_image_url() {
        let (endpoint, fields) = build_request("https://example.com/pic.jpg", Service::All);
        assert_eq!(endpoint, "https://iqdb.org/");
        assert_eq!(fields, vec![Field { name: "url", value: "https://example.com/pic.jpg".into() }]);
    }

    #[test]
    fn three_d_is_a_different_endpoint() {
        let (endpoint, _) = build_request("https://example.com/pic.jpg", Service::ThreeD);
        assert_eq!(endpoint, "https://3d.iqdb.org/");
    }

    #[test]
    fn absolute_fixes_protocol_relative_links() {
        assert_eq!(absolute("//danbooru.donmai.us/post/show/1"), "https://danbooru.donmai.us/post/show/1");
        assert_eq!(absolute("https://already-absolute.example/x"), "https://already-absolute.example/x");
    }

    #[test]
    fn absolute_resolves_iqdbs_own_root_relative_thumbnails() {
        // The fixture's thumbnails are root-relative (`/danbooru/...`),
        // a different shape from the matched-page links above — the
        // reconstructed fixtures never had a reason to use this shape, so
        // nothing exercised it before.
        assert_eq!(
            absolute("/danbooru/6/f/4/6f4a9ea0ae71ac917031d187693cab45.jpg"),
            "https://iqdb.org/danbooru/6/f/4/6f4a9ea0ae71ac917031d187693cab45.jpg"
        );
    }

    #[test]
    fn parses_a_results_page() {
        let html = include_str!("../../tests/fixtures/iqdb-results.html");
        let result = parse(html).expect("parses");
        let SearchResult::Matches(matches) = result else { panic!("expected matches") };
        // The fixture: one best match plus 15 other results.
        assert_eq!(matches.len(), 16, "{matches:#?}");

        let best = matches.iter().find(|m| m.category == MatchCategory::Best).expect("a best match");
        assert_eq!(best.source_url, "https://danbooru.donmai.us/posts/11900000");
        assert_eq!(best.host, "danbooru.donmai.us");
        assert!((best.similarity - 87.0).abs() < 0.01, "{}", best.similarity);
        assert_eq!(best.rating, "Unrated");
        assert_eq!((best.width, best.height), (1500, 915));
        assert_eq!(
            best.thumbnail,
            "https://iqdb.org/danbooru/6/f/4/6f4a9ea0ae71ac917031d187693cab45.jpg"
        );
        assert!(!best.thumbnail.contains("//iqdb.org//"), "double-slash bug in {}", best.thumbnail);

        let additional = matches
            .iter()
            .find(|m| m.category == MatchCategory::Additional)
            .expect("an additional match");
        assert!(additional.similarity <= best.similarity);
        assert!(additional.thumbnail.starts_with("https://iqdb.org/"), "{}", additional.thumbnail);
    }

    #[test]
    fn categories_reflect_only_the_tier_iqdb_actually_labels() {
        // The regression this exists to catch: `split_sections` used to hunt
        // for `id="more1"`/`id="more2"`, which the real page does not have,
        // so `find_marker(...).unwrap_or(html.len())` put every row in
        // "best" and all 16 matches came back tagged `Best` — the count was
        // right, the categorisation silently wrong. Categorising by each
        // table's own `<th>` instead means exactly the one row iqdb calls
        // "Best match" gets that tag, and nothing invents a third tier.
        let html = include_str!("../../tests/fixtures/iqdb-results.html");
        let SearchResult::Matches(matches) = parse(html).expect("parses") else {
            panic!("expected matches")
        };

        let best = matches.iter().filter(|m| m.category == MatchCategory::Best).count();
        let additional = matches.iter().filter(|m| m.category == MatchCategory::Additional).count();
        assert_eq!(best, 1, "iqdb only ever labels one row \"Best match\"");
        assert_eq!(additional, matches.len() - 1, "every other row is the single unlabelled tier");
        assert_ne!(additional, 0, "must not silently collapse everything into Best either");
    }

    #[test]
    fn parses_a_no_match_page_without_treating_it_as_an_error() {
        let html = include_str!("../../tests/fixtures/iqdb-no-match.html");
        let result = parse(html).expect("a clean no-match page must not be an Err");
        let SearchResult::NoMatches(reason) = result else { panic!("expected NoMatches") };
        assert!(!reason.is_empty());
        assert!(reason.to_lowercase().contains("no"), "{reason}");
    }

    #[test]
    fn unrecognisable_markup_is_a_parse_error_not_a_silent_empty() {
        // No result table and no `.err` notice: this must not be reported the
        // same way as a genuine zero-match search.
        let err = parse("<html><body><p>Something else entirely</p></body></html>")
            .expect_err("must not silently succeed with nothing");
        assert!(err.contains("markup likely changed"), "{err}");
    }

    #[test]
    fn empty_body_is_a_parse_error() {
        assert!(parse("").is_err());
        assert!(parse("   ").is_err());
    }
}

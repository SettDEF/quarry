//! SauceNAO — reverse image search, and the shape it does not fit.
//!
//! Every other adapter in this module answers `Source::build_url(&SourceQuery)`:
//! a *text* query, pushed down from `q:`, `tag:`, `w>=`, and so on. SauceNAO
//! answers a different question entirely — "where else does *this picture*
//! exist" — and the picture is not a field `SourceQuery` has anywhere to put.
//! `pushdown()` only ever produces a `SourceQuery` from a parsed `Query`, and a
//! parsed `Query` has no notion of "an image" as a term.
//!
//! Bending the existing shape to fit — a magic `image:` field key holding a
//! URL, say — would make `pushdown` lie: every other clause in that key space
//! is text semantics (equality, any-of, &negation), and an image reference has
//! none of those. So this is deliberately **not** a `Source` impl. It is a
//! pair of plain functions — build the request, parse the response — the same
//! functions a `Source` impl would eventually call, minus the trait plumbing
//! that does not describe what they take.
//!
//! What the trait would need, if this is ever wired into `query`/`search`:
//! a second, parallel entry point — `fn reverse(&self, image: &ImageRef) ->
//! (String, Option<Value>)` or a sibling trait `ReverseSource` — plus a wire
//! method beside `search` (`PROTOCOL.md` has no such method; `search` is
//! defined as "crawl a source with the query pushed down", which an image is
//! not). That is a protocol decision, not an adapter one, so it is named here
//! rather than made here.
//!
//! ## The API
//!
//! `output_type=2` (JSON) needs an `api_key` — an unkeyed request to that
//! endpoint answers with an HTML page instead of JSON, which is not a smaller
//! result, it is a different, undocumented one. The key is read from
//! `$SAUCENAO_API_KEY`; see `api_key()`.
//!
//! `url=` takes a link to an already-hosted image rather than a file upload —
//! which is exactly what a quarry `Item.url` already is, so no multipart
//! encoding is needed and no new dependency either.
//!
//! ## Rate limit
//!
//! SauceNAO's limit is per-account and changes over time (short-window and
//! daily, roughly single digits per 30s and low hundreds per day on a free
//! key, better on a paid one) — a number worth linking to, not hardcoding: see
//! <https://saucenao.com/user.php?page=search-api>. The response is the source
//! of truth regardless: every reply echoes `short_remaining`/`long_remaining`
//! in its header, so a caller reads the budget it actually has left instead of
//! a guess baked in here. `parse()` below surfaces both.

use serde::Deserialize;

use crate::scrape;

/// One candidate match SauceNAO found for the submitted image.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Match {
    /// 0–100. SauceNAO ships this as a numeric string; unparsable is 0.0
    /// rather than a dropped row — a bad number is still evidence a match
    /// came back.
    pub similarity: f64,
    pub thumbnail: String,
    /// e.g. `"Index #9: Danbooru - Safe"` — which catalogue answered, kept
    /// verbatim rather than split, since the format is not documented as
    /// stable.
    pub index_name: String,
    pub title: String,
    /// Pages a human could open for this match — usually one, sometimes a
    /// few when more than one site hosts the same upload.
    pub urls: Vec<String>,
}

/// A parsed response: the matches, and the quota headroom they came with —
/// the two travel together because "zero matches" and "zero matches, and no
/// searches left today" are different answers the daemon must not conflate.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SauceResponse {
    pub matches: Vec<Match>,
    pub short_remaining: i64,
    pub long_remaining: i64,
}

#[derive(Debug, Deserialize)]
struct RawResponse {
    header: RawHeader,
    #[serde(default)]
    results: Vec<RawResult>,
}

#[derive(Debug, Deserialize)]
struct RawHeader {
    status: i64,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    short_remaining: i64,
    #[serde(default)]
    long_remaining: i64,
}

#[derive(Debug, Deserialize)]
struct RawResult {
    header: RawResultHeader,
    #[serde(default)]
    data: RawResultData,
}

#[derive(Debug, Deserialize)]
struct RawResultHeader {
    // A numeric string ("87.34"), not a number — SauceNAO's own JSON quirk.
    #[serde(default)]
    similarity: String,
    #[serde(default)]
    thumbnail: String,
    #[serde(default)]
    index_name: String,
}

#[derive(Debug, Default, Deserialize)]
struct RawResultData {
    #[serde(default)]
    ext_urls: Vec<String>,
    #[serde(default)]
    title: String,
}

/// Read and validate the key from the environment.
///
/// Split from the environment lookup (`validate_key`) so the validation logic
/// — what counts as "not really set" — is testable without a test racing every
/// other test in the binary over the same process-global env var.
pub fn api_key() -> Result<String, String> {
    validate_key(std::env::var("SAUCENAO_API_KEY").ok().as_deref())
}

fn validate_key(raw: Option<&str>) -> Result<String, String> {
    match raw.map(str::trim) {
        Some(key) if !key.is_empty() => Ok(key.to_string()),
        _ => Err(
            "saucenao: SAUCENAO_API_KEY is not set — get a free key at \
             https://saucenao.com/user.php?page=search-api and export it; \
             without one the JSON endpoint (output_type=2) does not answer"
                .to_string(),
        ),
    }
}

/// Build the request URL for a reverse search against an already-hosted image.
///
/// `db=999` asks every index at once — SauceNAO does not charge extra for
/// breadth, only for request count, so there is no reason to narrow it here.
/// `numres=16` mirrors what the other adapters treat as a page.
pub fn build_url(image_url: &str, api_key: &str) -> String {
    format!(
        "https://saucenao.com/search.php?db=999&output_type=2&numres=16&api_key={}&url={}",
        scrape::urlencode(api_key),
        scrape::urlencode(image_url),
    )
}

/// Parse a `output_type=2` response body.
///
/// A non-zero `header.status` is always an error — SauceNAO does not use the
/// field for warnings-with-results — so it short-circuits before any row is
/// read. The message SauceNAO sends is trusted over guessing what a given
/// status code has meant historically, since that has drifted between their
/// docs and their actual replies before.
pub fn parse(body: &str) -> Result<SauceResponse, String> {
    let raw: RawResponse =
        serde_json::from_str(body).map_err(|e| format!("saucenao json: {e}"))?;

    if raw.header.status != 0 {
        let reason =
            raw.header.message.unwrap_or_else(|| "no message from the server".to_string());
        return Err(format!("saucenao: status {} — {reason}", raw.header.status));
    }

    let matches = raw
        .results
        .into_iter()
        .map(|r| Match {
            similarity: r.header.similarity.parse().unwrap_or(0.0),
            thumbnail: r.header.thumbnail,
            index_name: r.header.index_name,
            title: r.data.title,
            urls: r.data.ext_urls,
        })
        .collect();

    Ok(SauceResponse {
        matches,
        short_remaining: raw.header.short_remaining,
        long_remaining: raw.header.long_remaining,
    })
}

#[cfg(test)]
mod tests {
    /*
     * THESE FIXTURES WERE RECONSTRUCTED, NOT CAPTURED.
     *
     * Built from the documented response shape rather than from a real reply,
     * because capturing one means POSTing an actual image to a live service and
     * the tests do not touch the network. So they prove the parser handles the
     * shape we BELIEVE these services return — which is weaker evidence than a
     * saved response, and worth knowing before trusting a green run here.
     *
     * Replace them with real captures the first time either source is wired up
     * for real; that is when a genuine reply is in hand anyway.
     */

    use super::*;

    #[test]
    fn build_url_carries_the_key_and_the_image() {
        let url = build_url("https://example.com/pic.jpg", "abc123");
        assert!(url.contains("api_key=abc123"), "{url}");
        assert!(url.contains("output_type=2"), "{url}");
        assert!(url.contains("db=999"), "{url}");
        assert!(url.contains(&scrape::urlencode("https://example.com/pic.jpg")), "{url}");
    }

    #[test]
    fn missing_key_explains_why() {
        let err = validate_key(None).unwrap_err();
        assert!(err.contains("SAUCENAO_API_KEY"), "{err}");
    }

    #[test]
    fn blank_key_is_treated_as_missing() {
        assert!(validate_key(Some("   ")).is_err());
    }

    #[test]
    fn a_real_key_passes() {
        assert_eq!(validate_key(Some(" abc123 ")).unwrap(), "abc123");
    }

    #[test]
    fn parses_a_successful_response() {
        let body = include_str!("../../tests/fixtures/saucenao-success.json");
        let resp = parse(body).expect("parses");
        assert_eq!(resp.matches.len(), 2);
        assert!(
            resp.matches[0].similarity > resp.matches[1].similarity,
            "SauceNAO already ranks by similarity; the parse must not reorder it"
        );
        assert!(!resp.matches[0].urls.is_empty());
        assert!(resp.matches[0].index_name.contains("Danbooru"));
        assert_eq!(resp.long_remaining, 98);
    }

    #[test]
    fn error_status_explains_why_instead_of_returning_empty() {
        let body = include_str!("../../tests/fixtures/saucenao-error.json");
        let err = parse(body).expect_err("a non-zero status must not be silently empty");
        assert!(err.contains("Invalid API key"), "{err}");
    }

    #[test]
    fn zero_results_is_not_an_error() {
        // A real, honest zero — SauceNAO answers status 0 with an empty
        // `results` array when nothing is close enough. That is a fact about
        // the picture, not a failure of the request.
        let body = r#"{"header":{"status":0,"short_remaining":3,"long_remaining":50},"results":[]}"#;
        let resp = parse(body).expect("status 0 must parse even with nothing in it");
        assert!(resp.matches.is_empty());
        assert_eq!(resp.short_remaining, 3);
    }

    #[test]
    fn garbage_body_is_a_parse_error_not_a_panic() {
        assert!(parse("not json").is_err());
        assert!(parse("").is_err());
    }
}

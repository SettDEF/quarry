//! AniList — "I want a Gojo avatar", answered directly.
//!
//! Every other source here is searched by keyword and hope; AniList is searched
//! by character, and returns that character's portrait. It is the only adapter
//! whose request has no URL to speak of: it is a GraphQL endpoint, a GET is a
//! 404, and both the search term and the page live in the POST body. That is
//! what `Source::body` exists for.

use serde::Deserialize;
use serde_json::{json, Value};

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct AniList;

/// AniList caps `perPage` at 50 and answers a larger request with an error
/// rather than a truncation.
const PER_PAGE: u32 = 50;

/// Written out once, with the page as a variable, so paging never rebuilds the
/// document — AniList rate-limits by request, not by cost.
const DOCUMENT: &str = r#"query ($q: String, $page: Int, $perPage: Int, $sort: [CharacterSort]) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage }
    characters(search: $q, sort: $sort) {
      id
      name { full }
      image { large }
      siteUrl
    }
  }
}"#;

#[derive(Debug, Deserialize)]
struct Response {
    #[serde(default)]
    data: Data,
}

#[derive(Debug, Default, Deserialize)]
struct Data {
    #[serde(default, rename = "Page")]
    page: PageBlock,
}

#[derive(Debug, Default, Deserialize)]
struct PageBlock {
    #[serde(default, rename = "pageInfo")]
    page_info: PageInfo,
    #[serde(default)]
    characters: Vec<Character>,
}

#[derive(Debug, Default, Deserialize)]
struct PageInfo {
    #[serde(default, rename = "hasNextPage")]
    has_next_page: bool,
}

#[derive(Debug, Deserialize)]
struct Character {
    id: u64,
    #[serde(default)]
    name: Name,
    #[serde(default)]
    image: Image,
    #[serde(default, rename = "siteUrl")]
    site_url: String,
}

#[derive(Debug, Default, Deserialize)]
struct Name {
    #[serde(default)]
    full: String,
}

#[derive(Debug, Default, Deserialize)]
struct Image {
    #[serde(default)]
    large: String,
}

impl AniList {
    /// AniList has no genre or category browse — the API this adapter calls
    /// only searches `characters(search:)` — so these are character names,
    /// each checked live and confirmed to come back as the top hit, the same
    /// way "I want a Gojo avatar" does in the module comment above.
    pub fn popular_groups() -> &'static [(&'static str, &'static [&'static str])] {
        &[
            ("Shonen", &["naruto", "luffy", "goku", "tanjiro", "gojo"]),
            ("Fan favorites", &["levi", "itachi", "killua", "zenitsu", "mikasa"]),
            ("Icons", &["eren", "light yagami", "edward elric", "ichigo", "vegeta"]),
        ]
    }
}

impl Source for AniList {
    fn id(&self) -> &'static str {
        "anilist"
    }

    fn category(&self) -> &'static str {
        "art"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            // A character portrait has no size, aspect or rating to filter on;
            // the schema simply has no such argument.
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: false,
            video: false,
            colors: false,
            tags: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, _query: &SourceQuery) -> String {
        // One endpoint, forever. Everything that varies is in `body`.
        "https://graphql.anilist.co".to_string()
    }

    fn body(&self, query: &SourceQuery) -> Option<Value> {
        let text =
            query.text.iter().chain(query.tags.iter()).cloned().collect::<Vec<_>>().join(" ");

        /*
         * Relevance needs something to be relevant to — the same trap wallhaven
         * set, in a different shape.
         *
         * `SEARCH_MATCH` with a null search is not an error here; it is a page
         * of characters in no useful order, which reads as a broken source
         * rather than an empty one. Browsing without a term means "show me
         * someone", and the most-favourited characters are the best answer to
         * that this API can give.
         */
        let (search, sort) = if text.is_empty() {
            (Value::Null, "FAVOURITES_DESC")
        } else {
            (Value::String(text), "SEARCH_MATCH")
        };

        Some(json!({
            "query": DOCUMENT,
            "variables": {
                "q": search,
                "page": query.page.max(1),
                "perPage": PER_PAGE,
                "sort": sort,
            },
        }))
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let response: Response =
            serde_json::from_str(body).map_err(|e| format!("anilist json: {e}"))?;

        Ok(response
            .data
            .page
            .characters
            .into_iter()
            .filter(|character| !character.image.large.is_empty())
            .map(|character| {
                let mut item = scrape::normalize(
                    "anilist",
                    &character.id.to_string(),
                    &character.name.full,
                    &character.image.large,
                    &character.image.large,
                    &character.site_url,
                    0,
                    0,
                    Vec::new(),
                );
                // No dimensions come back, so the shape inference in
                // `normalize` had nothing to work from and guessed. Say it
                // outright instead: these are portraits, cropped to a face, and
                // that is the whole reason to reach for this source.
                item.kind = "avatar".into();
                item.family = "raster".into();
                item
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<Response>(body)
            .map(|r| r.data.page.page_info.has_next_page)
            .unwrap_or(false)
    }
}

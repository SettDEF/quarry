//! Free text, turned into the tags a booru actually has.
//!
//! A booru's search box is not a text search. It matches TAGS, exactly, and
//! every term is one more tag that must be present. So a typed `red car` sent
//! as it was asked for either `red` AND `car` (danbooru has no tag `red`: zero
//! rows) or, glued together by the manifest, `red_car` — which happens to
//! exist, while `mountain_lake` and `cyberpunk_city` do not. Philomena boards
//! read `mountain lake` as ONE tag with a space in it. All of these parse to
//! zero rows and look exactly like "that site has nothing".
//!
//! What the site's own search box does instead is autocomplete: it offers the
//! real tags as you type. So this asks the same endpoint the site's box asks:
//!
//! 1. the whole phrase as one tag (`red car` → `red_car`), exactly or as an
//!    alias — the most specific answer when the site has it;
//! 2. otherwise each word on its own — exact tag, alias, or the most-used tag
//!    that contains the word as a whole word (`lake` → `lake`,
//!    `mountains` → `mountain` via the site's alias).
//!
//! Resolutions are cached per site and phrase. A lookup that FAILS (network,
//! refusal) is not cached and falls back to the words as given, so a site
//! whose autocomplete is down still gets asked the old way rather than not at
//! all.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::scrape;

/// How a site's tag lookup is asked and answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolver {
    /// Danbooru and its forks (aibooru): `/autocomplete.json`.
    Danbooru,
    /// Gelbooru 0.2.x (gelbooru.com, safebooru.org, xbooru, hypnohub,
    /// rule34): `index.php?page=autocomplete2` where the site has it, the older
    /// `autocomplete.php` where it does not.
    Gelbooru,
    /// Moebooru (yande.re, konachan, sakugabooru): `/tag.json`.
    Moebooru,
    /// e621 / e926: `/tags/autocomplete.json`.
    E621,
    /// Philomena (derpibooru, furbooru, manebooru, twibooru): the tag search
    /// API. Tags carry spaces there and a comma means AND.
    Philomena,
    /// e-shuushuu: tags are numeric ids in the image search.
    Eshuushuu,
}

impl Resolver {
    pub fn from_name(name: &str) -> Option<Resolver> {
        Some(match name.trim().to_ascii_lowercase().as_str() {
            "danbooru" => Resolver::Danbooru,
            "gelbooru" => Resolver::Gelbooru,
            "moebooru" => Resolver::Moebooru,
            "e621" => Resolver::E621,
            "philomena" => Resolver::Philomena,
            "eshuushuu" | "e-shuushuu" => Resolver::Eshuushuu,
            _ => return None,
        })
    }

    fn name(self) -> &'static str {
        match self {
            Resolver::Danbooru => "danbooru",
            Resolver::Gelbooru => "gelbooru",
            Resolver::Moebooru => "moebooru",
            Resolver::E621 => "e621",
            Resolver::Philomena => "philomena",
            Resolver::Eshuushuu => "eshuushuu",
        }
    }

    /// How a tag is spelled when looked up and sent: underscores on the
    /// boorus, spaces on Philomena and e-shuushuu.
    fn spell(self, words: &[String]) -> String {
        match self {
            Resolver::Philomena | Resolver::Eshuushuu => words.join(" "),
            _ => words.join("_"),
        }
    }

    /// How several tags are sent in one search.
    pub fn separator(self) -> &'static str {
        match self {
            Resolver::Philomena => ", ",
            Resolver::Eshuushuu => ",",
            _ => " ",
        }
    }

    /// Whether the search takes tag ids rather than names — an unresolved word
    /// cannot be sent as it is typed.
    fn by_id(self) -> bool {
        self == Resolver::Eshuushuu
    }

    /// The fewest characters the lookup accepts; e621 400s below three.
    fn min_len(self) -> usize {
        match self {
            Resolver::E621 => 3,
            _ => 1,
        }
    }

    /// Where to ask about `term`, given the site's search URL (its origin, and
    /// for Philomena its API path). `legacy` picks Gelbooru's older endpoint.
    fn lookup_url(self, search_url: &str, term: &str, legacy: bool) -> String {
        let origin = origin_of(search_url);
        let enc = scrape::urlencode(term);
        match self {
            Resolver::Danbooru => format!(
                "{origin}/autocomplete.json?search%5Bquery%5D={enc}&search%5Btype%5D=tag_query&limit=20"
            ),
            Resolver::Gelbooru if legacy => format!("{origin}/autocomplete.php?q={enc}"),
            Resolver::Gelbooru => format!(
                "{origin}/index.php?page=autocomplete2&term={enc}&type=tag_query&limit=20"
            ),
            // `name=x` matches anywhere in a tag; `x*` from the start, which
            // keeps series titles that merely contain the word out of it.
            Resolver::Moebooru => {
                format!("{origin}/tag.json?name={enc}%2A&order=count&limit=50")
            }
            Resolver::E621 => format!(
                "{origin}/tags/autocomplete.json?search%5Bname_matches%5D={enc}&expiry=7"
            ),
            Resolver::Philomena => {
                // `/api/v1/json/search/images` → `/api/v1/json/search/tags`,
                // `/api/v3/search/posts` → `/api/v3/search/tags`.
                let path = search_url
                    .split('?')
                    .next()
                    .unwrap_or_default()
                    .rsplit_once("/search/")
                    .map(|(base, _)| format!("{base}/search/tags"))
                    .unwrap_or_else(|| format!("{origin}/api/v1/json/search/tags"));
                format!(
                    "{path}?q={}&per_page=50&sf=images&sd=desc",
                    scrape::urlencode(&format!("name:{term}*"))
                )
            }
            Resolver::Eshuushuu => format!(
                "{origin}/api/v1/tags?search={enc}&per_page=50&sort_by=usage_count&sort_order=DESC"
            ),
        }
    }
}

fn origin_of(url: &str) -> String {
    match url.split_once("://") {
        Some((scheme, rest)) => {
            format!("{scheme}://{}", rest.split(['/', '?', '#']).next().unwrap_or_default())
        }
        None => String::new(),
    }
}

/// One tag the site offered.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    /// What it is called — or, for an alias, the name that was typed.
    pub name: String,
    /// What to send: the real tag's name, or its id.
    pub value: String,
    /// Posts carrying it, where the site says.
    pub count: u64,
    /// An alias names a real tag even when its own count reads zero.
    pub alias: bool,
    /// A general (subject) tag rather than a series, character or artist.
    /// Only these are close enough to stand in for a word the site has no
    /// exact tag for: `mountain` is not `some_series_mountain`.
    pub general: bool,
}

fn number(value: Option<&serde_json::Value>) -> u64 {
    match value {
        Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0),
        Some(serde_json::Value::String(s)) => s.trim().parse().unwrap_or(0),
        _ => 0,
    }
}

fn text(value: Option<&serde_json::Value>) -> String {
    match value {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

/// Whether a category field names the general kind. Absent means the site
/// does not say, which is taken as general.
fn general_category(value: Option<&serde_json::Value>, general: &[&str]) -> bool {
    match value {
        None | Some(serde_json::Value::Null) => true,
        Some(v) => {
            let v = text(Some(v));
            v.is_empty() || general.contains(&v.as_str())
        }
    }
}

/// Read a lookup answer. `None` means "not the shape this site answers in" —
/// a Cloudflare page, a redirect to HTML — which is different from an empty
/// list and must not be cached as "no such tag".
pub fn parse_candidates(resolver: Resolver, body: &str) -> Option<Vec<Candidate>> {
    let document: serde_json::Value = serde_json::from_str(body).ok()?;
    let rows: &Vec<serde_json::Value> = match resolver {
        Resolver::Philomena => document.get("tags")?.as_array()?,
        Resolver::Eshuushuu => document.get("tags")?.as_array()?,
        _ => document.as_array()?,
    };

    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let candidate = match resolver {
            Resolver::Danbooru => {
                let value = text(row.get("value"));
                let antecedent = text(row.get("antecedent"));
                Candidate {
                    alias: !antecedent.is_empty(),
                    name: if antecedent.is_empty() { value.clone() } else { antecedent },
                    value,
                    count: number(row.get("post_count")),
                    general: general_category(row.get("category"), &["0"]),
                }
            }
            Resolver::Gelbooru => {
                let value = text(row.get("value"));
                // autocomplete2 has `post_count`; autocomplete.php only says it
                // inside the label: `name (1234)`.
                let count = match row.get("post_count") {
                    Some(v) => number(Some(v)),
                    None => text(row.get("label"))
                        .rsplit_once('(')
                        .and_then(|(_, n)| n.trim_end_matches(')').trim().parse().ok())
                        .unwrap_or(0),
                };
                Candidate {
                    name: value.clone(),
                    value,
                    count,
                    alias: false,
                    general: general_category(row.get("category"), &["tag", "general"]),
                }
            }
            Resolver::Moebooru => {
                let name = text(row.get("name"));
                Candidate {
                    value: name.clone(),
                    name,
                    count: number(row.get("count")),
                    alias: false,
                    general: general_category(row.get("type"), &["0"]),
                }
            }
            Resolver::E621 => {
                let value = text(row.get("name"));
                let antecedent = text(row.get("antecedent_name"));
                Candidate {
                    alias: !antecedent.is_empty(),
                    name: if antecedent.is_empty() { value.clone() } else { antecedent },
                    value,
                    count: number(row.get("post_count")),
                    // 5 is species, which is what most animal words mean there.
                    general: general_category(row.get("category"), &["0", "5"]),
                }
            }
            Resolver::Philomena => {
                let name = text(row.get("name"));
                let target = text(row.get("aliased_tag"));
                // derpibooru says `images`; twibooru says `posts`.
                let count = number(row.get("images")).max(number(row.get("posts")));
                Candidate {
                    alias: !target.is_empty(),
                    value: if target.is_empty() { name.clone() } else { target },
                    name,
                    count,
                    general: general_category(row.get("category"), &["species"]),
                }
            }
            Resolver::Eshuushuu => {
                let is_alias = row.get("is_alias").and_then(|v| v.as_bool()).unwrap_or(false);
                let target = text(row.get("alias_of"));
                let alias = is_alias && !target.is_empty();
                Candidate {
                    name: text(row.get("title")),
                    value: if alias { target } else { text(row.get("tag_id")) },
                    count: if alias {
                        number(row.get("alias_of_usage_count"))
                    } else {
                        number(row.get("usage_count"))
                    },
                    alias,
                    // Type 1 is Theme; the rest are source, artist, character.
                    general: general_category(row.get("type"), &["1"]),
                }
            }
        };
        if !candidate.name.is_empty() && !candidate.value.is_empty() {
            out.push(candidate);
        }
    }
    Some(out)
}

fn norm(name: &str) -> String {
    name.to_lowercase().replace('_', " ").split_whitespace().collect::<Vec<_>>().join(" ")
}

fn words_of(name: &str) -> Vec<String> {
    name.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

/// Pick the tag that means `term`.
///
/// `fuzzy` allows the most-used tag containing every word of the term as a
/// whole word — right for one word (`lake`), wrong for a phrase, where it
/// would turn `red car` into whatever popular tag has both words in it.
pub fn choose(term: &str, candidates: &[Candidate], fuzzy: bool) -> Option<String> {
    let wanted = norm(term);
    if wanted.is_empty() {
        return None;
    }
    let live = |c: &&Candidate| c.count > 0 || c.alias;

    let exact = |target: &str| {
        candidates
            .iter()
            .filter(live)
            .filter(|c| norm(&c.name) == target || norm(&c.value) == target)
            // A real tag with posts beats an alias of the same spelling.
            .max_by_key(|c| (c.count, !c.alias))
            .map(|c| c.value.clone())
    };
    if let Some(found) = exact(&wanted) {
        return Some(found);
    }
    // `mountains` → `mountain`, for sites without the alias.
    if let Some(singular) = wanted.strip_suffix('s').filter(|s| s.len() >= 3) {
        if let Some(found) = exact(singular) {
            return Some(found);
        }
    }
    if !fuzzy {
        return None;
    }

    let want_words = words_of(&wanted);
    candidates
        .iter()
        .filter(|c| c.count > 0 && c.general)
        // `mountain_(some_series)` is a disambiguated name for something
        // particular, not the subject the word names.
        .filter(|c| !c.name.contains('('))
        .filter(|c| {
            let have = words_of(&c.name);
            // The word must be the tag's HEAD — its last word. `lily_pond` is
            // a pond; `red_eyes` is not red anything, and taking it turned a
            // search for "red car" into eyes and cars (measured on aibooru).
            want_words.iter().all(|w| have.contains(w)) && have.last() == want_words.last()
        })
        // Most used first; the shorter name on a tie, which is the less
        // specific tag.
        .max_by(|a, b| a.count.cmp(&b.count).then(b.name.len().cmp(&a.name.len())))
        .map(|c| c.value.clone())
}

/// What a set of words became.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Resolution {
    /// Tags to send, in the site's own spelling, most specific first.
    pub tags: Vec<String>,
    /// Words the site has no tag for.
    pub unmatched: Vec<String>,
    /// Whether the site answered. `false` means the tags are the words as
    /// typed, a fallback — not something to remember.
    pub answered: bool,
}

/// Resolve with a caller-supplied fetcher; the pure half of `resolve`, and
/// what the tests drive.
pub fn resolve_with(
    resolver: Resolver,
    search_url: &str,
    text: &[String],
    fetch: &dyn Fn(&[String]) -> Vec<Result<String, String>>,
) -> Resolution {
    let words: Vec<String> = text
        .iter()
        .flat_map(|t| t.split_whitespace())
        .map(|w| w.trim_matches('"').to_lowercase())
        .filter(|w| !w.is_empty())
        .collect();
    if words.is_empty() {
        return Resolution { answered: true, ..Default::default() };
    }

    // What to ask: the phrase, then every word long enough to be asked about.
    let phrase = resolver.spell(&words);
    let mut terms: Vec<String> = Vec::new();
    if words.len() > 1 && phrase.chars().count() >= resolver.min_len() {
        terms.push(phrase.clone());
    }
    for word in &words {
        if word.chars().count() >= resolver.min_len() && !terms.contains(word) {
            terms.push(word.clone());
        }
    }

    if terms.is_empty() {
        // Every word is shorter than the site will look up; send them as they
        // are, which is all the site's own box could do with them either.
        return Resolution { tags: vec![phrase], unmatched: Vec::new(), answered: true };
    }

    let answer_for = |bodies: &[Result<String, String>]| -> Vec<Option<Vec<Candidate>>> {
        bodies
            .iter()
            .map(|b| b.as_ref().ok().and_then(|body| parse_candidates(resolver, body)))
            .collect()
    };

    let urls: Vec<String> =
        terms.iter().map(|t| resolver.lookup_url(search_url, t, legacy(resolver, search_url))).collect();
    let bodies = fetch(&urls);
    let mut answers = answer_for(&bodies);

    // Gelbooru forks without `autocomplete2` redirect it to HTML; ask the
    // older endpoint instead, and remember that for this site. Only when the
    // site DID answer — a network failure says nothing about which endpoint
    // it has.
    let site_answered = bodies.iter().any(Result::is_ok);
    if resolver == Resolver::Gelbooru && site_answered && answers.iter().all(Option::is_none) {
        if !legacy(resolver, search_url) {
            set_legacy(search_url);
            let urls: Vec<String> =
                terms.iter().map(|t| resolver.lookup_url(search_url, t, true)).collect();
            answers = answer_for(&fetch(&urls));
        }
    }

    let answered = answers.iter().any(Option::is_some);
    let by_term: HashMap<&str, &Vec<Candidate>> = terms
        .iter()
        .zip(answers.iter())
        .filter_map(|(t, a)| a.as_ref().map(|a| (t.as_str(), a)))
        .collect();

    if !answered {
        // Nobody to ask: the words as typed, which is what was sent before.
        let tags = if resolver.by_id() { Vec::new() } else { vec![phrase] };
        return Resolution { tags, unmatched: Vec::new(), answered: false };
    }

    if words.len() > 1 {
        if let Some(candidates) = by_term.get(phrase.as_str()) {
            if let Some(tag) = choose(&phrase, candidates, false) {
                return Resolution { tags: vec![tag], unmatched: Vec::new(), answered: true };
            }
        }
    }

    let mut tags: Vec<String> = Vec::new();
    let mut unmatched = Vec::new();
    for word in &words {
        let found = by_term.get(word.as_str()).and_then(|c| choose(word, c, true));
        match found {
            Some(tag) if !tags.contains(&tag) => tags.push(tag),
            Some(_) => {}
            None => unmatched.push(word.clone()),
        }
    }

    if tags.is_empty() {
        // The site has no tag for any of it. Say so the way the site would —
        // the words as typed, which match nothing — rather than sending an
        // empty tag list, which is the site's front page.
        tags = if resolver.by_id() {
            // No id is 0; `tags=0` is an honest empty answer.
            vec!["0".to_string()]
        } else {
            vec![phrase]
        };
    }
    Resolution { tags, unmatched, answered: true }
}

static LEGACY: Mutex<Option<HashMap<String, bool>>> = Mutex::new(None);

fn legacy(resolver: Resolver, search_url: &str) -> bool {
    resolver == Resolver::Gelbooru
        && LEGACY
            .lock()
            .ok()
            .and_then(|g| g.as_ref().and_then(|m| m.get(&origin_of(search_url)).copied()))
            .unwrap_or(false)
}

fn set_legacy(search_url: &str) {
    if let Ok(mut guard) = LEGACY.lock() {
        guard.get_or_insert_with(HashMap::new).insert(origin_of(search_url), true);
    }
}

type CacheMap = HashMap<String, (Instant, Resolution)>;
static CACHE: Mutex<Option<CacheMap>> = Mutex::new(None);
const CACHE_FOR: Duration = Duration::from_secs(6 * 3600);

/// Resolve free text to this site's tags, asking the site (cached).
///
/// `search_url` is the site's own search URL — only its origin (and for
/// Philomena its API path) is used.
pub fn resolve(resolver: Resolver, search_url: &str, text: &[String]) -> Resolution {
    let key = format!("{}|{}|{}", resolver.name(), origin_of(search_url), text.join(" ").to_lowercase());
    if let Ok(guard) = CACHE.lock() {
        if let Some((at, hit)) = guard.as_ref().and_then(|m| m.get(&key)) {
            if at.elapsed() < CACHE_FOR {
                return hit.clone();
            }
        }
    }

    let resolution = resolve_with(resolver, search_url, text, &super::prefetch::get_many);

    if resolution.answered {
        eprintln!(
            "[quarryd] {} tags for {:?} at {}: {} tag(s){}",
            resolver.name(),
            text.join(" "),
            origin_of(search_url),
            resolution.tags.len(),
            if resolution.unmatched.is_empty() {
                String::new()
            } else {
                format!(", no tag for {:?}", resolution.unmatched)
            }
        );
        if let Ok(mut guard) = CACHE.lock() {
            let map = guard.get_or_insert_with(HashMap::new);
            if map.len() > 2000 {
                map.clear();
            }
            map.insert(key, (Instant::now(), resolution.clone()));
        }
    } else if !cfg!(test) {
        eprintln!(
            "[quarryd] {} tag lookup failed at {} — sending {:?} as typed",
            resolver.name(),
            origin_of(search_url),
            text.join(" ")
        );
    }
    resolution
}

/// The `{query}` and `{tags}` values for a manifest that opted into tag
/// resolution with `[request] tag_resolver = "…"`.
///
/// `None` when the manifest names no resolver (or one this build does not
/// know), or when there is nothing to search for — both keep the manifest's
/// ordinary substitution, including its `browse_term`.
pub fn for_manifest(
    resolver: &str,
    search_url: &str,
    query: &super::SourceQuery,
    video_tag: &str,
) -> Option<(String, String)> {
    if resolver.trim().is_empty() {
        return None;
    }
    let Some(kind) = Resolver::from_name(resolver) else {
        eprintln!("[quarryd] unknown tag_resolver {resolver:?} — sending words as typed");
        return None;
    };
    let wants_video = query.wants_video == Some(true) && !video_tag.is_empty();
    if query.text.is_empty() && query.tags.is_empty() && !wants_video {
        return None;
    }

    let mut terms: Vec<String> = Vec::new();
    if !query.text.is_empty() {
        terms = resolve(kind, search_url, &query.text).tags;
    }
    for tag in &query.tags {
        // An explicit `tag:` is already the site's word — except where the
        // site searches by id, which needs it looked up like any other.
        let tags = if kind.by_id() {
            resolve(kind, search_url, std::slice::from_ref(tag)).tags
        } else {
            vec![tag.clone()]
        };
        for tag in tags {
            if !terms.contains(&tag) {
                terms.push(tag);
            }
        }
    }
    // Danbooru forks refuse more than two tags from an anonymous client.
    if kind == Resolver::Danbooru {
        terms.truncate(if wants_video { 1 } else { 2 });
    }
    if wants_video {
        terms.push(video_tag.to_string());
    }

    let query_value = terms.join(kind.separator());
    let tags_value = terms.iter().map(|t| t.replace(' ', "_")).collect::<Vec<_>>().join(" ");
    Some((query_value, tags_value))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_string).collect()
    }

    /// A fake site: each lookup URL containing a key answers that body.
    fn site(answers: Vec<(&'static str, &'static str)>) -> impl Fn(&[String]) -> Vec<Result<String, String>> {
        move |urls: &[String]| {
            urls.iter()
                .map(|u| {
                    answers
                        .iter()
                        .find(|(needle, _)| u.contains(needle))
                        .map(|(_, body)| Ok(body.to_string()))
                        .unwrap_or_else(|| Ok("[]".to_string()))
                })
                .collect()
        }
    }

    #[test]
    fn danbooru_prefers_the_exact_tag_over_bigger_prefix_matches() {
        let body = r#"[
            {"type":"tag-word","label":"widget","value":"widget","category":0,"post_count":900},
            {"type":"tag-word","label":"widget ears","value":"widget_ears","category":0,"post_count":40000},
            {"type":"tag-word","label":"widget tail","value":"widget_tail","category":0,"post_count":20000}
        ]"#;
        let found = resolve_with(Resolver::Danbooru, "https://booru.example/posts.json?tags=", &words("widget"), &site(vec![("widget", body)]));
        assert_eq!(found.tags, vec!["widget"]);
        assert!(found.answered);
    }

    #[test]
    fn a_phrase_the_site_has_becomes_one_tag() {
        let phrase = r#"[{"value":"blue_boat","post_count":50},{"value":"blue_boathouse","post_count":90}]"#;
        let found = resolve_with(
            Resolver::Danbooru,
            "https://booru.example/posts.json",
            &words("blue boat"),
            &site(vec![("blue_boat", phrase), ("=blue&", r#"[{"value":"blue","post_count":9}]"#)]),
        );
        assert_eq!(found.tags, vec!["blue_boat"]);
    }

    #[test]
    fn a_phrase_the_site_lacks_becomes_one_tag_per_word() {
        let hill = r#"[{"value":"hill","post_count":300},{"value":"hill_fort","post_count":800}]"#;
        let pond = r#"[{"value":"pond_(series)","post_count":900},{"value":"pond_water","post_count":70},{"value":"lily_pond","post_count":20}]"#;
        let found = resolve_with(
            Resolver::Danbooru,
            "https://booru.example/posts.json",
            &words("hill pond"),
            // The phrase lookup answers an empty list.
            &site(vec![("hill_pond", "[]"), ("=hill&", hill), ("=pond&", pond)]),
        );
        // `hill` exactly; `pond` has no exact tag, so the most used general
        // tag that ENDS in the word — a kind of pond — not `pond_water`, and
        // not the disambiguated series name.
        assert_eq!(found.tags, vec!["hill", "lily_pond"]);
        assert!(found.unmatched.is_empty());
    }

    #[test]
    fn an_adjective_is_not_stretched_into_another_subject() {
        let red = r#"[{"value":"red_eyes","post_count":90000},{"value":"red_hair","post_count":80000}]"#;
        let c = parse_candidates(Resolver::Danbooru, red).unwrap();
        assert_eq!(choose("red", &c, true), None, "red_eyes is eyes, not red");
    }

    #[test]
    fn an_alias_resolves_to_what_it_points_at() {
        let body = r#"[{"type":"tag-word","antecedent":"hills","value":"hill","post_count":300}]"#;
        let found = resolve_with(Resolver::Danbooru, "https://b.example/", &words("hills"), &site(vec![("hills", body)]));
        assert_eq!(found.tags, vec!["hill"]);

        let e621 = r#"[{"id":1,"name":"domestic_widget","post_count":10,"category":0,"antecedent_name":"widget"}]"#;
        let found = resolve_with(Resolver::E621, "https://e.example/posts.json", &words("widget"), &site(vec![("widget", e621)]));
        assert_eq!(found.tags, vec!["domestic_widget"]);
    }

    #[test]
    fn gelbooru_reads_counts_from_either_endpoint() {
        let modern = r#"[{"label":"widget_ears (5)","value":"widget_ears","post_count":"5000","category":"tag"},{"label":"widget (1)","value":"widget","post_count":"12","category":"tag"}]"#;
        let c = parse_candidates(Resolver::Gelbooru, modern).unwrap();
        assert_eq!(c[0].count, 5000);
        let legacy = r#"[{"label":"widget_ears (5000)","value":"widget_ears"},{"label":"widget (12)","value":"widget"}]"#;
        let c = parse_candidates(Resolver::Gelbooru, legacy).unwrap();
        assert_eq!((c[1].value.as_str(), c[1].count), ("widget", 12));
        assert_eq!(choose("widget", &c, true).as_deref(), Some("widget"));
    }

    #[test]
    fn gelbooru_falls_back_to_the_legacy_endpoint_when_autocomplete2_is_html() {
        let fetch = |urls: &[String]| -> Vec<Result<String, String>> {
            urls.iter()
                .map(|u| {
                    if u.contains("autocomplete2") {
                        Ok("<html>moved</html>".to_string())
                    } else {
                        Ok(r#"[{"label":"widget (12)","value":"widget"}]"#.to_string())
                    }
                })
                .collect()
        };
        let found = resolve_with(Resolver::Gelbooru, "https://legacy-gel.example/index.php?page=dapi", &words("widget"), &fetch);
        assert_eq!(found.tags, vec!["widget"]);
        assert!(legacy(Resolver::Gelbooru, "https://legacy-gel.example/x"));
    }

    #[test]
    fn moebooru_picks_the_most_used_whole_word_match() {
        let body = r#"[
            {"id":1,"name":"widgetry","count":9000,"type":0,"ambiguous":false},
            {"id":2,"name":"widget_ears","count":400,"type":0,"ambiguous":false},
            {"id":3,"name":"red_widget","count":90,"type":0,"ambiguous":false},
            {"id":4,"name":"widget_the_series","count":80000,"type":3,"ambiguous":false}
        ]"#;
        let found = resolve_with(Resolver::Moebooru, "https://moe.example/post.json", &words("widget"), &site(vec![("widget", body)]));
        // `widgetry` merely starts with the letters; it is not the word. A
        // series named after the word is not a stand-in for it, and
        // `widget_ears` are ears — `red_widget` is the widget.
        assert_eq!(found.tags, vec!["red_widget"]);
    }

    #[test]
    fn philomena_joins_with_commas_and_follows_aliases() {
        let hill = r#"{"tags":[{"name":"hill","images":120,"aliased_tag":null},{"name":"hills","images":0,"aliased_tag":"hill"}],"total":2}"#;
        let pond = r#"{"tags":[{"name":"pond","images":40,"aliased_tag":null}],"total":1}"#;
        let found = resolve_with(
            Resolver::Philomena,
            "https://pony.example/api/v1/json/search/images?q=x",
            &words("hills pond"),
            &site(vec![("hills+pond", r#"{"tags":[],"total":0}"#), ("hills%2A", hill), ("pond%2A", pond)]),
        );
        assert_eq!(found.tags, vec!["hill", "pond"]);
        assert_eq!(Resolver::Philomena.separator(), ", ");
        let url = Resolver::Philomena.lookup_url("https://pony.example/api/v3/search/posts?q=", "pond", false);
        assert!(url.starts_with("https://pony.example/api/v3/search/tags?q=name%3Apond%2A"), "{url}");
    }

    #[test]
    fn eshuushuu_sends_ids_and_follows_aliases_to_their_ids() {
        let body = r#"{"tags":[
            {"tag_id":10,"title":"widget","usage_count":0,"is_alias":true,"alias_of":77,"alias_of_name":"widget (thing)","alias_of_usage_count":500},
            {"tag_id":11,"title":"widget ears","usage_count":900,"is_alias":false,"alias_of":null}
        ],"total":2}"#;
        let found = resolve_with(Resolver::Eshuushuu, "https://es.example/api/v1/images?tags=", &words("widget"), &site(vec![("widget", body)]));
        assert_eq!(found.tags, vec!["77"]);
    }

    #[test]
    fn a_site_with_no_tag_for_any_word_gets_an_honest_empty_search() {
        let empty = site(vec![]);
        let found = resolve_with(Resolver::Danbooru, "https://b.example/", &words("qqq zzz"), &empty);
        assert_eq!(found.tags, vec!["qqq_zzz"], "never an empty tag list — that is the front page");
        assert_eq!(found.unmatched.len(), 2);
        let found = resolve_with(Resolver::Eshuushuu, "https://es.example/api/v1/images", &words("qqq"), &site(vec![("qqq", r#"{"tags":[],"total":0}"#)]));
        assert_eq!(found.tags, vec!["0"]);
    }

    #[test]
    fn a_failed_lookup_falls_back_to_the_words_and_is_not_trusted() {
        let down = |urls: &[String]| -> Vec<Result<String, String>> {
            urls.iter().map(|_| Err("http 503".to_string())).collect()
        };
        let found = resolve_with(Resolver::Danbooru, "https://b.example/", &words("blue boat"), &down);
        assert!(!found.answered);
        assert_eq!(found.tags, vec!["blue_boat"]);
        // And `resolve` itself makes no request under test.
        assert!(!resolve(Resolver::Moebooru, "https://moe.example/", &words("widget")).answered);
    }

    #[test]
    fn e621_does_not_ask_about_words_shorter_than_it_accepts() {
        let asked = std::cell::RefCell::new(Vec::new());
        let fetch = |urls: &[String]| -> Vec<Result<String, String>> {
            asked.borrow_mut().extend(urls.iter().cloned());
            urls.iter().map(|_| Ok("[]".to_string())).collect()
        };
        resolve_with(Resolver::E621, "https://e.example/posts.json", &words("ox"), &fetch);
        assert!(asked.borrow().is_empty());
    }

    #[test]
    fn resolver_names_round_trip() {
        for name in ["danbooru", "gelbooru", "moebooru", "e621", "philomena", "eshuushuu"] {
            assert_eq!(Resolver::from_name(name).map(|r| r.name()), Some(name));
        }
        assert!(Resolver::from_name("nope").is_none());
    }

    #[test]
    fn manifests_keep_tags_apart_instead_of_gluing_them_into_one() {
        use crate::sources::SourceQuery;
        let q = SourceQuery {
            tags: vec!["blue_sky".into(), "cloud".into()],
            wants_video: Some(true),
            ..Default::default()
        };
        let (query, tags) = for_manifest("moebooru", "https://moe.example/post.json", &q, "video").unwrap();
        assert_eq!(tags, "blue_sky cloud video", "used to be blue_sky_cloud_video");
        assert_eq!(query, "blue_sky cloud video");

        let (query, _) = for_manifest("philomena", "https://p.example/api/v1/json/search/images", &q, "mime_type:video/webm").unwrap();
        assert_eq!(query, "blue_sky, cloud, mime_type:video/webm");

        // Nothing to search for, or no resolver: the manifest's own path.
        assert!(for_manifest("moebooru", "https://moe.example/", &SourceQuery::default(), "video").is_none());
        assert!(for_manifest("", "https://moe.example/", &q, "video").is_none());
    }
}

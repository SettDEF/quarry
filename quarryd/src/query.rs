//! The query language.
//!
//! One bar answers "a wallpaper for my ultrawide" and "a square avatar of a
//! cat", which is only possible if the bar is a language rather than a search
//! box:
//!
//!     anime kind:wallpaper ratio>=2.3 w>=3440 -nsfw sort:new
//!     cat kind:avatar source:pfps.gg,danbooru animated:true
//!     "cherry blossom" -source:danbooru sort:random
//!
//! Grammar (PROTOCOL.md carries the same table):
//!
//!   term            free text; matches title, slug, tags, author, source
//!   "two words"     a quoted phrase, matched whole
//!   key:value       equality; `a,b` means any-of
//!   key>=n key<n    numeric comparison — w, h, ratio, bytes, added
//!   ratio:16:9      an aspect written as a ratio, equivalent to ratio≈1.777
//!   -anything       negates the term or predicate that follows
//!   sort:new|random|large|wide|title
//!   seed:N            — fixes sort:random's order; without it each query draws a new one
//!
//! An unknown key is reported, never silently ignored: a query that quietly
//! matches everything is worse than one that says it did not understand.

#![allow(dead_code)]
use crate::protocol::Item;

#[derive(Debug, Clone, PartialEq)]
pub enum Cmp {
    Eq,
    Ge,
    Gt,
    Le,
    Lt,
}

#[derive(Debug, Clone)]
pub enum Term {
    /// Free text, matched against several fields.
    Text(String),
    /// `key:a,b` — any-of.
    Field { key: String, values: Vec<String> },
    /// `w>=2560`
    Number { key: String, cmp: Cmp, value: f64 },
    /// `animated:true`
    Flag { key: String, value: bool },
}

#[derive(Debug, Clone)]
pub struct Clause {
    pub term: Term,
    pub negated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum Sort {
    /// Catalogue order, which for a fresh crawl is newest-first per source.
    #[default]
    Relevance,
    Newest,
    Random,
    Largest,
    Widest,
    Title,
}

#[derive(Debug, Clone)]
pub struct Query {
    pub clauses: Vec<Clause>,
    /// `color:#7aa2f7 dist<25` — the two halves of one predicate, kept together
    /// because a colour without a tolerance means nothing and a tolerance
    /// without a colour means less.
    pub color: Option<(u8, u8, u8)>,
    pub color_distance: f64,
    /// `collection:wallpapers` — a saved set, resolved by the catalogue rather
    /// than by the matcher, since membership is not a property of the row.
    pub collection: Option<String>,
    /// `used` — only what is currently in a slot. Resolved by the catalogue,
    /// like membership, because it is not a property of the row either.
    pub used: bool,
    pub sort: Sort,
    /// The shuffle for `sort:random`: `seed:N` when given (same seed, same order —
    /// for walls that should stay put), else fresh per query. Unused by other sorts.
    pub seed: u64,
    /// Keys the parser did not recognise, surfaced to the UI rather than
    /// dropped.
    pub unknown: Vec<String>,
}

const FIELD_KEYS: &[&str] = &[
    "kind", "source", "family", "ext", "author", "tag", "tags", "license", "id", "color",
    "colour", "collection", "in", "category", "seed",
];
const NUMBER_KEYS: &[&str] =
    &["w", "width", "h", "height", "ratio", "bytes", "added", "dist", "duration", "secs", "length"];
const FLAG_KEYS: &[&str] =
    &["animated", "nsfw", "tintable", "vector", "used", "video", "moving"];

/// Split on whitespace, but keep quoted phrases whole.
fn tokenize(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quoted = false;

    for ch in input.chars() {
        match ch {
            '"' => {
                quoted = !quoted;
                if !quoted && !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            c if c.is_whitespace() && !quoted => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn parse_ratio(value: &str) -> Option<f64> {
    // `16:9` reads better than `1.777` and is how people actually think about
    // screens.
    if let Some((w, h)) = value.split_once(':') {
        let w: f64 = w.parse().ok()?;
        let h: f64 = h.parse().ok()?;
        if h != 0.0 {
            return Some(w / h);
        }
        return None;
    }
    value.parse().ok()
}

fn parse_size(value: &str) -> Option<f64> {
    // 2mb / 500k, since bytes are unreadable at catalogue scale.
    let lower = value.to_ascii_lowercase();
    let (number, scale) = if let Some(rest) = lower.strip_suffix("mb") {
        (rest, 1024.0 * 1024.0)
    } else if let Some(rest) = lower.strip_suffix("kb") {
        (rest, 1024.0)
    } else if let Some(rest) = lower.strip_suffix('m') {
        (rest, 1024.0 * 1024.0)
    } else if let Some(rest) = lower.strip_suffix('k') {
        (rest, 1024.0)
    } else {
        (lower.as_str(), 1.0)
    };
    number.parse::<f64>().ok().map(|n| n * scale)
}

fn parse_clause(token: &str, unknown: &mut Vec<String>) -> Option<Clause> {
    let (negated, body) = match token.strip_prefix('-') {
        Some(rest) if !rest.is_empty() => (true, rest),
        _ => (false, token),
    };

    // Numeric comparison first: `w>=2560` also contains no colon.
    for (marker, cmp) in [(">=", Cmp::Ge), ("<=", Cmp::Le), (">", Cmp::Gt), ("<", Cmp::Lt)] {
        if let Some((key, value)) = body.split_once(marker) {
            let key = key.to_ascii_lowercase();
            if !NUMBER_KEYS.contains(&key.as_str()) {
                unknown.push(key);
                return None;
            }
            let parsed = if key == "ratio" { parse_ratio(value) } else { parse_size(value) };
            // A known key with a value that will not parse (`w>=huge`) is the
            // same case as an unrecognised key: the clause vanishes either
            // way, so it has to say so or the query just looks broader than
            // it was asked to be.
            return match parsed {
                Some(value) => {
                    Some(Clause { term: Term::Number { key, cmp: cmp.clone(), value }, negated })
                }
                None => {
                    unknown.push(format!("{key}{marker}{value}"));
                    None
                }
            };
        }
    }

    if let Some((key, value)) = body.split_once(':') {
        let key = key.to_ascii_lowercase();

        if key == "sort" {
            // Handled by the caller; not a filter.
            return Some(Clause {
                term: Term::Field { key, values: vec![value.to_string()] },
                negated: false,
            });
        }

        if key == "ratio" {
            return match parse_ratio(value) {
                Some(value) => {
                    Some(Clause { term: Term::Number { key, cmp: Cmp::Eq, value }, negated })
                }
                None => {
                    unknown.push(format!("{key}:{value}"));
                    None
                }
            };
        }

        if NUMBER_KEYS.contains(&key.as_str()) {
            return match parse_size(value) {
                Some(value) => {
                    Some(Clause { term: Term::Number { key, cmp: Cmp::Eq, value }, negated })
                }
                None => {
                    unknown.push(format!("{key}:{value}"));
                    None
                }
            };
        }

        if FLAG_KEYS.contains(&key.as_str()) {
            let value = matches!(value.to_ascii_lowercase().as_str(), "true" | "yes" | "1");
            return Some(Clause { term: Term::Flag { key, value }, negated });
        }

        if FIELD_KEYS.contains(&key.as_str()) {
            let values = value
                .split(',')
                .filter(|v| !v.is_empty())
                .map(|v| v.to_ascii_lowercase())
                .collect::<Vec<_>>();
            if values.is_empty() {
                return None;
            }
            return Some(Clause { term: Term::Field { key, values }, negated });
        }

        unknown.push(key);
        return None;
    }

    // A bare flag word: `-nsfw` and `animated` read naturally.
    let lower = body.to_ascii_lowercase();
    if FLAG_KEYS.contains(&lower.as_str()) {
        return Some(Clause { term: Term::Flag { key: lower, value: true }, negated });
    }

    Some(Clause { term: Term::Text(lower), negated })
}

pub fn parse(input: &str) -> Query {
    let mut clauses = Vec::new();
    let mut unknown = Vec::new();
    let mut sort = Sort::Relevance;
    let mut seed: Option<u64> = None;

    for token in tokenize(input) {
        let Some(clause) = parse_clause(&token, &mut unknown) else {
            continue;
        };

        if let Term::Field { key, values } = &clause.term {
            if key == "sort" {
                sort = match values[0].to_ascii_lowercase().as_str() {
                    "new" | "newest" => Sort::Newest,
                    "random" => Sort::Random,
                    "large" | "largest" | "size" => Sort::Largest,
                    "wide" | "widest" => Sort::Widest,
                    "title" | "name" => Sort::Title,
                    other => {
                        unknown.push(format!("sort:{other}"));
                        Sort::Relevance
                    }
                };
                continue;
            }
            if key == "seed" {
                match values[0].parse::<u64>() {
                    Ok(n) => seed = Some(n),
                    Err(_) => unknown.push(format!("seed:{}", values[0])),
                }
                continue;
            }
        }
        clauses.push(clause);
    }

    // Pull the colour predicate out of the clause list: it is a comparison
    // against a stored colour rather than a field match, so the generic matcher
    // cannot express it.
    let mut color = None;
    let mut color_distance = 25.0;
    let mut collection = None;
    let mut used = false;
    clauses.retain(|clause| match &clause.term {
        Term::Flag { key, value } if key == "used" => {
            used = *value && !clause.negated;
            false
        }
        Term::Field { key, values } if key == "collection" || key == "in" => {
            collection = values.first().cloned();
            false
        }
        Term::Field { key, values } if key == "color" || key == "colour" => {
            match crate::util::parse_hex(&values[0]) {
                Some(rgb) => color = Some(rgb),
                // A known key with a value we cannot read is still a query the
                // user did not get: `color:blue` has to say so rather than
                // quietly matching everything.
                None => unknown.push(format!("{key}:{}", values[0])),
            }
            false
        }
        Term::Number { key, value, .. } if key == "dist" => {
            color_distance = *value;
            false
        }
        _ => true,
    });

    // sort:random was the same order every time (a constant seed): the shell's
    // "random wallpaper" got konachan:402164 four times running. Fresh per query
    // now; paging is unaffected because the result is stored once.
    let seed = seed.unwrap_or_else(fresh_seed);
    Query { clauses, sort, seed, unknown, color, color_distance, collection, used }
}

fn fresh_seed() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    // splitmix64 over time + a counter: two queries in one nanosecond still differ.
    let mut z = nanos ^ COUNTER.fetch_add(0x9E3779B97F4A7C15, Ordering::Relaxed);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

/// The xorshift state for a seed; never zero, which would stay zero.
fn shuffle_state(seed: u64) -> u64 {
    if seed == 0 { 0x9E3779B97F4A7C15 } else { seed }
}

fn field_of<'a>(item: &'a Item, key: &str) -> Vec<&'a str> {
    match key {
        "kind" => vec![item.kind.as_str()],
        "source" => vec![item.source.as_str()],
        "family" => vec![item.family.as_str()],
        "ext" => vec![item.ext.as_str()],
        "author" => vec![item.author.as_str()],
        "license" => vec![item.license.as_str()],
        "id" => vec![item.id.as_str()],
        /*
         * A site's own categories arrive on the row as tags — pornhub's mapper
         * reads `tags[].tag_name`, which is where its categories live — so
         * locally `category:` and `tag:` are the same question. They differ
         * only in PUSHDOWN: a category is a real parameter on some sites and a
         * tag is not. See `pushdown`.
         */
        "tag" | "tags" | "category" => item.tags.iter().map(|t| t.as_str()).collect(),
        _ => Vec::new(),
    }
}

fn number_of(item: &Item, key: &str) -> f64 {
    match key {
        "w" | "width" => item.w as f64,
        "h" | "height" => item.h as f64,
        "ratio" => {
            if item.ratio > 0.0 {
                item.ratio
            } else if item.h > 0 {
                item.w as f64 / item.h as f64
            } else {
                1.0
            }
        }
        "bytes" => item.bytes as f64,
        "duration" | "secs" | "length" => item.duration,
        "added" => item.added_at as f64,
        _ => 0.0,
    }
}

fn flag_of(item: &Item, key: &str) -> bool {
    match key {
        "animated" => item.animated,
        "nsfw" => item.nsfw,
        "tintable" => item.tintable,
        "vector" => item.family == "vector",
        "video" => item.family == "video",
        // A GIF and a webm are both "moving" to a person looking for one.
        "moving" => item.family == "video" || item.animated,
        _ => false,
    }
}

fn text_matches(item: &Item, needle: &str) -> bool {
    item.title.to_lowercase().contains(needle)
        || item.slug.to_lowercase().contains(needle)
        || item.source.to_lowercase().contains(needle)
        || item.author.to_lowercase().contains(needle)
        || item.tags.iter().any(|t| t.to_lowercase().contains(needle))
}

fn clause_matches(item: &Item, clause: &Clause) -> bool {
    let hit = match &clause.term {
        Term::Text(needle) => text_matches(item, needle),
        Term::Field { key, values } => {
            let have = field_of(item, key);
            values.iter().any(|v| have.iter().any(|h| h.to_lowercase() == *v))
        }
        Term::Number { key, cmp, value } => {
            let have = number_of(item, key);
            match cmp {
                // A ratio is a float that never lands exactly, so equality is a
                // tolerance — `ratio:16:9` should match a 1920x1080 and a
                // 2560x1440 alike.
                Cmp::Eq if key == "ratio" => (have - value).abs() < 0.05,
                Cmp::Eq => (have - value).abs() < f64::EPSILON,
                Cmp::Ge => have >= *value,
                Cmp::Gt => have > *value,
                Cmp::Le => have <= *value,
                Cmp::Lt => have < *value,
            }
        }
        Term::Flag { key, value } => flag_of(item, key) == *value,
    };

    hit != clause.negated
}

/// Every clause must hold: terms are ANDed, and any-of lives inside a clause as
/// `a,b`. That is what people mean when they type two words.
pub fn matches(item: &Item, query: &Query) -> bool {
    if let Some(target) = query.color {
        /*
         * Colour match.
         *
         * An item with no dominant colour recorded cannot match: it has not
         * been through the pipeline yet, and guessing would put grey noise in
         * an answer to "wallpapers that fit my accent".
         */
        let Some(dominant) = crate::util::parse_hex(&item.dominant) else {
            return false;
        };
        if crate::util::color_distance(dominant, target) > query.color_distance {
            return false;
        }
    }
    query.clauses.iter().all(|c| clause_matches(item, c))
}

/// The DSL's own word for a sort — what `sort:` accepts, and the key a source
/// manifest's `[request.sort]` table is written in.
pub fn sort_name(sort: Sort) -> &'static str {
    match sort {
        Sort::Relevance => "relevance",
        Sort::Newest => "new",
        Sort::Random => "random",
        Sort::Largest => "large",
        Sort::Widest => "wide",
        Sort::Title => "title",
    }
}

/// Sort borrowed rows the same way `sort_index` sorts an index into them.
///
/// The fixture path has no index to sort — it holds the rows themselves — and
/// two orderings that can drift apart is one more than this needs, so both go
/// through the same match.
pub fn sort_items(rows: &mut [&Item], sort: Sort, seed: u64) {
    match sort {
        Sort::Relevance => {}
        Sort::Newest => rows.sort_by(|a, b| b.added_at.cmp(&a.added_at)),
        Sort::Largest => {
            rows.sort_by_key(|i| std::cmp::Reverse(i.w as u64 * i.h as u64));
        }
        Sort::Widest => rows.sort_by(|a, b| {
            number_of(b, "ratio")
                .partial_cmp(&number_of(a, "ratio"))
                .unwrap_or(std::cmp::Ordering::Equal)
        }),
        Sort::Title => rows.sort_by_key(|i| i.title.to_lowercase()),
        Sort::Random => {
            let mut state = shuffle_state(seed);
            for i in (1..rows.len()).rev() {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                rows.swap(i, (state % (i as u64 + 1)) as usize);
            }
        }
    }
}

/// Sort an index of items. `Relevance` keeps catalogue order, which for a fresh
/// crawl is already newest-first per source.
pub fn sort_index(index: &mut [u32], items: &[Item], sort: Sort, seed: u64) {
    match sort {
        Sort::Relevance => {}
        Sort::Newest => index.sort_by(|a, b| {
            items[*b as usize].added_at.cmp(&items[*a as usize].added_at)
        }),
        Sort::Largest => index.sort_by(|a, b| {
            let area = |i: &u32| items[*i as usize].w as u64 * items[*i as usize].h as u64;
            area(b).cmp(&area(a))
        }),
        Sort::Widest => index.sort_by(|a, b| {
            let ratio = |i: &u32| number_of(&items[*i as usize], "ratio");
            ratio(b).partial_cmp(&ratio(a)).unwrap_or(std::cmp::Ordering::Equal)
        }),
        Sort::Title => index.sort_by(|a, b| {
            items[*a as usize].title.to_lowercase().cmp(&items[*b as usize].title.to_lowercase())
        }),
        Sort::Random => {
            // xorshift over the index: a shuffle needs to be reproducible
            // within a session so paging does not reshuffle under the user.
            let mut state = shuffle_state(seed);
            for i in (1..index.len()).rev() {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                index.swap(i, (state % (i as u64 + 1)) as usize);
            }
        }
    }
}

/// Completion for a half-typed token: keys while there is no colon, values from
/// the catalogue once there is one.
pub fn complete(prefix: &str, values: &dyn Fn(&str) -> Vec<String>) -> Vec<String> {
    match prefix.split_once(':') {
        None => {
            let mut keys: Vec<String> = FIELD_KEYS
                .iter()
                .chain(NUMBER_KEYS.iter())
                .chain(FLAG_KEYS.iter())
                .chain(["sort"].iter())
                .filter(|k| k.starts_with(prefix))
                .map(|k| format!("{k}:"))
                .collect();
            keys.sort();
            keys.dedup();
            keys
        }
        Some((key, typed)) => {
            if key == "sort" {
                return ["new", "random", "large", "wide", "title"]
                    .iter()
                    .filter(|v| v.starts_with(typed))
                    .map(|v| format!("sort:{v}"))
                    .collect();
            }
            if FLAG_KEYS.contains(&key) {
                return ["true", "false"]
                    .iter()
                    .filter(|v| v.starts_with(typed))
                    .map(|v| format!("{key}:{v}"))
                    .collect();
            }
            values(key)
                .into_iter()
                .filter(|v| v.starts_with(typed))
                .map(|v| format!("{key}:{v}"))
                .collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scrape::normalize;

    fn item(source: &str, title: &str, w: u32, h: u32, tags: &[&str]) -> Item {
        let mut it = normalize(
            source,
            title,
            title,
            &format!("https://x/{title}.png"),
            "",
            "",
            w,
            h,
            tags.iter().map(|t| t.to_string()).collect(),
        );
        it.added_at = w as i64; // deterministic ordering handle for tests
        it
    }

    fn matching<'a>(items: &'a [Item], q: &str) -> Vec<&'a str> {
        let parsed = parse(q);
        items
            .iter()
            .filter(|i| matches(i, &parsed))
            .map(|i| i.title.as_str())
            .collect()
    }

    fn corpus() -> Vec<Item> {
        let mut wide = item("wallhaven", "ultrawide", 3440, 1440, &["landscape"]);
        wide.nsfw = false;
        let mut anime = item("danbooru", "anime girl", 1920, 1080, &["anime", "sky"]);
        anime.nsfw = true;
        let mut avatar = item("pfps.gg", "cat", 400, 400, &["pfp", "cat"]);
        avatar.animated = true;
        let mut icon = item("iconify", "home", 24, 24, &["icon"]);
        // normalize() infers from the URL, and the helper builds a .png; a real
        // Iconify adapter yields .svg, so set both fields the way that adapter
        // would rather than leaving a square vector labelled "avatar".
        icon.family = "vector".into();
        icon.kind = "icon".into();
        icon.ext = "svg".into();
        icon.tintable = true;
        vec![wide, anime, avatar, icon]
    }

    #[test]
    fn bare_words_search_several_fields() {
        let items = corpus();
        assert_eq!(matching(&items, "cat"), vec!["cat"]);
        assert_eq!(matching(&items, "landscape"), vec!["ultrawide"]);
        assert_eq!(matching(&items, "danbooru"), vec!["anime girl"]);
    }

    #[test]
    fn quoted_phrases_stay_whole() {
        let items = corpus();
        assert_eq!(matching(&items, "\"anime girl\""), vec!["anime girl"]);
        // Unquoted, the two words are separate clauses and both must hold.
        assert_eq!(matching(&items, "anime girl"), vec!["anime girl"]);
    }

    #[test]
    fn field_predicates_and_any_of() {
        let items = corpus();
        assert_eq!(matching(&items, "kind:avatar"), vec!["cat"]);
        assert_eq!(matching(&items, "source:wallhaven,pfps.gg").len(), 2);
        assert_eq!(matching(&items, "family:vector"), vec!["home"]);
        assert_eq!(matching(&items, "tag:sky"), vec!["anime girl"]);
    }

    #[test]
    fn numeric_comparisons() {
        let items = corpus();
        assert_eq!(matching(&items, "w>=1920").len(), 2);
        assert_eq!(matching(&items, "w<500").len(), 2);
        assert_eq!(matching(&items, "h>1000").len(), 2);
    }

    #[test]
    fn ratios_can_be_written_as_ratios() {
        let items = corpus();
        // 1920x1080 is 16:9; 3440x1440 is not, and a tolerance must not blur
        // them together.
        assert_eq!(matching(&items, "ratio:16:9"), vec!["anime girl"]);
        assert_eq!(matching(&items, "ratio>=2.3"), vec!["ultrawide"]);
        assert_eq!(matching(&items, "ratio:1:1").len(), 2);
    }

    #[test]
    fn sizes_accept_units() {
        let mut items = corpus();
        items[0].bytes = 5 * 1024 * 1024;
        assert_eq!(matching(&items, "bytes>2mb"), vec!["ultrawide"]);
        assert_eq!(matching(&items, "bytes>500k"), vec!["ultrawide"]);
    }

    #[test]
    fn flags_work_bare_and_negated() {
        let items = corpus();
        assert_eq!(matching(&items, "animated"), vec!["cat"]);
        assert_eq!(matching(&items, "animated:true"), vec!["cat"]);
        assert_eq!(matching(&items, "-nsfw").len(), 3);
        assert_eq!(matching(&items, "tintable"), vec!["home"]);
        assert_eq!(matching(&items, "vector"), vec!["home"]);
    }

    #[test]
    fn negation_applies_to_predicates_too() {
        let items = corpus();
        assert_eq!(matching(&items, "-source:danbooru").len(), 3);
        assert_eq!(matching(&items, "-kind:icon").len(), 3);
        assert_eq!(matching(&items, "-cat").len(), 3);
    }

    #[test]
    fn clauses_combine_with_and() {
        let items = corpus();
        assert_eq!(matching(&items, "kind:wallpaper -nsfw w>=3000"), vec!["ultrawide"]);
        assert!(matching(&items, "kind:avatar w>=3000").is_empty());
    }

    #[test]
    fn the_readme_queries_parse_and_run() {
        let items = corpus();
        // The three queries the plan advertises must actually work.
        assert_eq!(matching(&items, "kind:wallpaper ratio>=2.3 w>=3440 -nsfw"), vec!["ultrawide"]);
        assert_eq!(matching(&items, "cat kind:avatar source:pfps.gg animated:true"), vec!["cat"]);
        let parsed = parse("kind:wallpaper sort:random");
        assert_eq!(parsed.sort, Sort::Random);
        assert_eq!(parsed.clauses.len(), 1, "sort is not a filter");
    }

    #[test]
    fn unknown_keys_are_reported_not_swallowed() {
        let parsed = parse("mood:blue kind:avatar");
        assert_eq!(parsed.unknown, vec!["mood"]);
        // The rest of the query still runs — one bad token does not void it.
        assert_eq!(parsed.clauses.len(), 1);

        let bad_sort = parse("sort:sideways");
        assert_eq!(bad_sort.unknown, vec!["sort:sideways"]);
        assert_eq!(bad_sort.sort, Sort::Relevance);
    }

    #[test]
    fn sorting_orders_the_index() {
        let items = corpus();
        let mut index: Vec<u32> = (0..items.len() as u32).collect();

        sort_index(&mut index, &items, Sort::Largest, 0);
        assert_eq!(items[index[0] as usize].title, "ultrawide");

        sort_index(&mut index, &items, Sort::Widest, 0);
        assert_eq!(items[index[0] as usize].title, "ultrawide");

        sort_index(&mut index, &items, Sort::Title, 0);
        assert_eq!(items[index[0] as usize].title, "anime girl");

        sort_index(&mut index, &items, Sort::Newest, 0);
        assert_eq!(items[index[0] as usize].title, "ultrawide"); // added_at = w
    }

    #[test]
    fn random_sort_is_stable_for_one_seed() {
        let items = corpus();
        let mut a: Vec<u32> = (0..items.len() as u32).collect();
        let mut b = a.clone();
        sort_index(&mut a, &items, Sort::Random, 42);
        sort_index(&mut b, &items, Sort::Random, 42);
        // Same seed, same order: paging and `seed:N` walls depend on it.
        assert_eq!(a, b);
    }

    #[test]
    fn seed_term_is_read_and_random_without_one_differs() {
        let fixed = parse("sort:random seed:42");
        assert_eq!((fixed.sort, fixed.seed), (Sort::Random, 42));
        assert!(fixed.unknown.is_empty(), "{:?}", fixed.unknown);
        assert!(parse("seed:abc").unknown.contains(&"seed:abc".to_string()));
        // Fresh per query: the shell's "random" kept getting the same first row.
        let seeds: std::collections::HashSet<u64> = (0..8).map(|_| parse("sort:random").seed).collect();
        assert!(seeds.len() > 1, "eight parses drew one seed");
    }

    #[test]
    fn completion_suggests_keys_then_values() {
        let values = |key: &str| match key {
            "source" => vec!["danbooru".to_string(), "pfps.gg".to_string()],
            _ => vec![],
        };

        let keys = complete("ki", &values);
        assert_eq!(keys, vec!["kind:"]);

        let sources = complete("source:d", &values);
        assert_eq!(sources, vec!["source:danbooru"]);

        let sorts = complete("sort:r", &values);
        assert_eq!(sorts, vec!["sort:random"]);

        let flags = complete("animated:t", &values);
        assert_eq!(flags, vec!["animated:true"]);
    }
}

#[cfg(test)]
mod color_tests {
    use super::*;
    use crate::scrape::normalize;

    fn with_colour(hex: &str) -> Item {
        let mut item = normalize("s", hex, "t", "https://x/a.png", "", "", 100, 100, vec![]);
        item.dominant = hex.to_string();
        item
    }

    #[test]
    fn colour_predicate_filters_by_distance() {
        let accent = with_colour("#7aa2f7");   // the query colour itself
        let near = with_colour("#89b4fa");     // a near neighbour
        let far = with_colour("#f38ba8");      // a pink

        let q = parse("color:#7aa2f7 dist<20");
        assert!(matches(&accent, &q));
        assert!(matches(&near, &q));
        assert!(!matches(&far, &q));
    }

    #[test]
    fn colour_and_tolerance_leave_the_clause_list() {
        // They are one predicate against stored data, not field matches, so the
        // generic matcher must not see them.
        let q = parse("kind:wallpaper color:#7aa2f7 dist<30");
        assert_eq!(q.clauses.len(), 1);
        assert_eq!(q.color, Some((122, 162, 247)));
        assert!((q.color_distance - 30.0).abs() < f64::EPSILON);
    }

    #[test]
    fn items_without_a_colour_do_not_match() {
        let mut unindexed = with_colour("#7aa2f7");
        unindexed.dominant = String::new();
        assert!(!matches(&unindexed, &parse("color:#7aa2f7")));
    }

    #[test]
    fn an_unreadable_colour_is_reported() {
        // A known key with a value that is not a colour still failed to do what
        // was asked, so it is named rather than dropped.
        let parsed = parse("color:blue");
        assert_eq!(parsed.unknown, vec!["color:blue"]);
        assert_eq!(parsed.color, None);
    }

    #[test]
    fn colour_is_spelled_either_way() {
        assert_eq!(parse("colour:#7aa2f7").color, Some((122, 162, 247)));
        assert_eq!(parse("color:7aa2f7").color, Some((122, 162, 247)));
        // …and neither is reported as unknown any more.
        assert!(parse("colour:#7aa2f7").unknown.is_empty());
    }
}

#[cfg(test)]
mod collection_tests {
    use super::*;

    #[test]
    fn collection_leaves_the_clause_list() {
        // It is not a property of a row, so the matcher must never see it.
        let q = parse("collection:wallpapers kind:wallpaper");
        assert_eq!(q.collection.as_deref(), Some("wallpapers"));
        assert_eq!(q.clauses.len(), 1);
    }

    #[test]
    fn in_is_a_synonym() {
        assert_eq!(parse("in:keepers").collection.as_deref(), Some("keepers"));
        assert!(parse("in:keepers").unknown.is_empty());
    }
}

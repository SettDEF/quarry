//! Which rows are adult.
//!
//! Sites disagree: some publish a rating, some tag it, some say nothing at all
//! — so a row from an adult board arrived unmarked and the blur and the
//! "hide them" setting had nothing to act on. Terms come from a public list
//! that is refreshed weekly, with a built-in core so a cold start still works.

use std::collections::HashSet;
use std::sync::RwLock;

/// Curated and public: one term per line, updated by its maintainers.
const LIST_URL: &str =
    "https://raw.githubusercontent.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/master/en";
const REFRESH_AFTER: std::time::Duration = std::time::Duration::from_secs(7 * 24 * 3600);

/// Enough to be useful before the list has ever been fetched. Deliberately
/// unambiguous words only: "sexy" and "bikini" describe plenty of rows nobody
/// would call adult, and a false positive hides a picture from its owner.
const BUILTIN: &[&str] = &[
    "nsfw", "porn", "porno", "pornographic", "hentai", "rule34", "explicit", "xxx", "nude", "nudes",
    "nudity", "naked", "topless", "erotic", "erotica", "lewd", "ecchi", "futanari", "yaoi", "yuri",
    "bdsm", "fetish", "milf", "camgirl", "onlyfans", "blowjob", "handjob", "creampie", "gangbang",
    "cumshot", "deepthroat", "masturbation", "orgasm", "anal", "hardcore", "softcore", "fapping",
    "boobs", "titties", "cleavage_focus", "ahegao", "bukkake", "doujin", "doujinshi", "r18",
];

fn store() -> &'static RwLock<HashSet<String>> {
    static TERMS: std::sync::OnceLock<RwLock<HashSet<String>>> = std::sync::OnceLock::new();
    TERMS.get_or_init(|| RwLock::new(BUILTIN.iter().map(|t| t.to_string()).collect()))
}

fn adopt(text: &str) -> usize {
    let mut terms: HashSet<String> = BUILTIN.iter().map(|t| t.to_string()).collect();
    for line in text.lines() {
        let term = line.trim().to_lowercase();
        // One-character entries match everything; the list has a few.
        if term.len() > 2 && term.chars().all(|c| c.is_ascii_alphanumeric() || c == ' ' || c == '_') {
            terms.insert(term.replace('_', " "));
        }
    }
    let count = terms.len();
    if let Ok(mut held) = store().write() {
        *held = terms;
    }
    count
}

/// Read the cached list at startup, if it is there at all.
pub fn load(cache_dir: &str) -> usize {
    match std::fs::read_to_string(cached_path(cache_dir)) {
        Ok(text) => adopt(&text),
        Err(_) => store().read().map(|t| t.len()).unwrap_or(0),
    }
}

fn cached_path(cache_dir: &str) -> String {
    format!("{cache_dir}/nsfw-terms.txt")
}

/// Fetch the list again if the cached copy is older than a week. Failing is
/// fine and silent-ish: the built-in core and the last copy still stand.
pub async fn refresh(http: &crate::scrape::Http, cache_dir: &str) -> Option<usize> {
    let path = cached_path(cache_dir);
    let fresh = std::fs::metadata(&path)
        .and_then(|m| m.modified())
        .map(|when| when.elapsed().unwrap_or(REFRESH_AFTER) < REFRESH_AFTER)
        .unwrap_or(false);
    if fresh {
        return None;
    }
    let text = http.fetch_text(LIST_URL).await.ok()?;
    if text.lines().count() < 50 {
        return None;      // a captive portal or an error page, not the list
    }
    std::fs::create_dir_all(cache_dir).ok();
    std::fs::write(&path, &text).ok();
    Some(adopt(&text))
}

/// Whether this text names something adult. Words, not substrings: "scunthorpe"
/// is a place and "analysis" is not anal.
pub fn is_adult(text: &str) -> bool {
    let Ok(terms) = store().read() else { return false };
    let flattened: String = text
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { ' ' })
        .collect();
    let words: Vec<&str> = flattened.split_whitespace().collect();
    if words.iter().any(|w| terms.contains(*w)) {
        return true;
    }
    // Phrases from the list ("big ass" and the like) are matched against the
    // same flattened text, padded so they cannot match inside a longer word.
    let padded = format!(" {} ", words.join(" "));
    terms.iter().any(|t| t.contains(' ') && padded.contains(&format!(" {t} ")))
}

/// How many terms are loaded — for `stats`, so "is the list there" is answerable.
pub fn count() -> usize {
    store().read().map(|t| t.len()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_words_are_matched_whole() {
        assert!(is_adult("Explicit artwork"));
        assert!(is_adult("tags: hentai, doujin"));
        assert!(!is_adult("an analysis of scunthorpe united"), "no substring matches");
        assert!(!is_adult("mountain lake at sunset"));
    }

    #[test]
    fn the_fetched_list_replaces_nothing_it_should_keep() {
        let before = count();
        let added = adopt("widgetlewdness\nbig widget\nxx\n");
        assert!(added >= before, "the built-in core survives a refresh");
        assert!(is_adult("a WIDGETLEWDNESS picture"));
        assert!(is_adult("one big widget here"), "phrases match as phrases");
        assert!(!is_adult("a big red widget"), "…not as loose words");
        assert!(is_adult("nsfw"), "and the built-ins are still there");
        assert!(!is_adult("xx"), "one- and two-character entries are dropped");
    }
}

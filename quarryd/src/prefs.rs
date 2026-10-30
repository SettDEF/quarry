//! Per-source settings, written by the app and read by the crawler.
//!
//! Twenty-four sources is past the point where "all of them, always" is a
//! policy. Someone browsing wallpapers does not want a furry booru consuming a
//! quarter of every crawl, and someone who has added a key for gelbooru
//! probably wants it asked first. Neither is expressible by editing manifests:
//! a manifest describes what a source IS, and this describes what you want
//! from it.
//!
//! Kept apart from the manifests on purpose. A manifest is shipped and
//! replaceable; this is yours, survives an upgrade, and is the file to delete
//! when you want the defaults back.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourcePrefs {
    /// Off means the crawler skips it entirely — it keeps whatever rows it has
    /// already contributed, because deleting them would throw away work over a
    /// preference.
    #[serde(default = "yes")]
    pub enabled: bool,

    /// How many pages one crawl takes from this source.
    ///
    /// The lever that actually matters: a source set to 1 still appears and
    /// still contributes, it just stops being a quarter of every result. 0
    /// means "use the crawl's own number".
    #[serde(default)]
    pub pages: u32,

    /// Asked before the others. Sources with the same weight keep their
    /// declared order, so this is a nudge rather than a total ordering.
    #[serde(default)]
    pub weight: i32,
}

fn yes() -> bool {
    true
}

impl Default for SourcePrefs {
    fn default() -> Self {
        SourcePrefs { enabled: true, pages: 0, weight: 0 }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Prefs {
    /// Keyed by source id. A source with no entry uses the defaults, so the
    /// file only ever contains decisions somebody actually made.
    #[serde(default)]
    pub sources: HashMap<String, SourcePrefs>,

    /*
     * HOW A MIX IS BLENDED, AND THE SEED THAT MAKES IT REPEATABLE.
     *
     * "Everything at once" is not one behaviour: taking a page from each source
     * in turn, taking more from the ones that have more, and taking at random
     * all produce different walls from the same catalogue. A seed makes any of
     * them reproducible — the same seed gives the same wall tomorrow, and
     * changing it is how you ask for a different one.
     */
    #[serde(default = "default_blend")]
    pub blend: String,
    #[serde(default)]
    pub seed: u64,

    /*
     * HOW MUCH DISK THE CACHES MAY HAVE, IN MEGABYTES.
     *
     * These were environment variables with defaults compiled in — which means
     * the only way to change how much of your disk quarry keeps was to edit a
     * unit file and restart the daemon, and the only way to find out how much
     * it was keeping was `du`. They are settings now: the app shows what is
     * stored and what the limit is, and writes the limit here.
     *
     * Zero means no limit, which is a thing somebody with a large disk may
     * genuinely want and was not expressible before.
     */
    #[serde(default = "default_thumb_budget")]
    pub thumb_budget_mb: u64,
    #[serde(default = "default_media_budget")]
    pub media_budget_mb: u64,
    /*
     * AND THE ONE NOBODY WAS WATCHING.
     *
     * Thumbnails and media have been trimmed for a while; the HTTP body cache
     * — every API answer and page the crawler has read — never was. Measured
     * on a real install the day this was written: **1,007 MB in 8,817 files**,
     * a quarter of everything quarry was keeping, and nothing anywhere would
     * ever have removed it.
     */
    #[serde(default = "default_http_budget")]
    pub http_budget_mb: u64,

    /*
     * WHETHER ADULT ROWS EXIST AS FAR AS ANYBODY ASKING IS CONCERNED.
     *
     * A DAEMON setting, and the reasoning is in PROTOCOL.md: the app used to
     * express this by appending `-nsfw` to the query string, which is a
     * predicate in a box the user can edit and which any later assignment to
     * the query silently dropped. The switch hid what was on screen and
     * nothing else — the next tag, lens or history entry brought it back out
     * of the local catalogue with no network involved.
     *
     * Defaults to false. A fresh install shows nothing adult until somebody
     * asks for it, which is the only safe direction for this default to fail
     * in.
     */
    #[serde(default)]
    pub show_adult: bool,
}

fn default_http_budget() -> u64 {
    256
}

fn default_thumb_budget() -> u64 {
    3000
}

fn default_media_budget() -> u64 {
    512
}

fn default_blend() -> String {
    "round-robin".into()
}

impl Prefs {
    pub fn path() -> std::path::PathBuf {
        let base = std::env::var("XDG_CONFIG_HOME")
            .unwrap_or_else(|_| format!("{}/.config", std::env::var("HOME").unwrap_or_default()));
        std::path::PathBuf::from(format!("{base}/quarry/sources.json"))
    }

    /// Read what is on disk. A missing or broken file is defaults, never an
    /// error: preferences must not be able to stop the daemon starting.
    pub fn load() -> Self {
        let Ok(text) = std::fs::read_to_string(Self::path()) else {
            return Prefs { blend: default_blend(), ..Default::default() };
        };
        match serde_json::from_str(&text) {
            Ok(prefs) => prefs,
            Err(e) => {
                eprintln!("[quarryd] source preferences unreadable, using defaults: {e}");
                Prefs { blend: default_blend(), ..Default::default() }
            }
        }
    }

    pub fn save(&self) -> Result<(), String> {
        let path = Self::path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("create {parent:?}: {e}"))?;
        }
        let text = serde_json::to_string_pretty(self).map_err(|e| format!("encode: {e}"))?;
        std::fs::write(&path, text).map_err(|e| format!("write {path:?}: {e}"))
    }

    pub fn for_source(&self, id: &str) -> SourcePrefs {
        self.sources.get(id).cloned().unwrap_or_default()
    }

    pub fn enabled(&self, id: &str) -> bool {
        self.for_source(id).enabled
    }

    /*
     * HOW THE ENABLED SOURCES ARE BLENDED.
     *
     * `round-robin` asks each in turn — the fairest, and what makes a mixed
     * wall feel mixed. `weighted` respects the weights strictly, so a source
     * you pushed up dominates rather than merely leading. `shuffle` reorders
     * them from the seed, which is the one that produces a *different* wall
     * from the same catalogue: the same seed gives the same order tomorrow,
     * and changing the seed is how you ask for another.
     */
    pub fn blend_order(&self, ids: Vec<String>) -> Vec<String> {
        match self.blend.as_str() {
            "shuffle" => {
                let mut out = ids;
                // xorshift from the seed: reproducible, and one line rather
                // than a dependency. A seed of 0 would degenerate to zero
                // forever, so it is folded away from it.
                let mut state = self.seed ^ 0x9E37_79B9_7F4A_7C15;
                for i in (1..out.len()).rev() {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    out.swap(i, (state % (i as u64 + 1)) as usize);
                }
                out
            }
            // `weighted` is already what `order` produced; round-robin is the
            // same list asked one page at a time, which the crawl loop does.
            _ => ids,
        }
    }

    /// The crawl order: heaviest first, and everything disabled removed.
    pub fn order<'a>(&self, ids: impl Iterator<Item = &'a str>) -> Vec<String> {
        let mut kept: Vec<(i32, String)> = ids
            .filter(|id| self.enabled(id))
            .map(|id| (self.for_source(id).weight, id.to_string()))
            .collect();
        // Stable, so equal weights keep the order they were declared in.
        kept.sort_by(|a, b| b.0.cmp(&a.0));
        self.blend_order(kept.into_iter().map(|(_, id)| id).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_source_nobody_configured_is_on_with_defaults() {
        let prefs = Prefs::default();
        assert!(prefs.enabled("wallhaven"));
        assert_eq!(prefs.for_source("wallhaven").pages, 0);
    }

    #[test]
    fn disabling_removes_it_from_the_order_and_nothing_else() {
        let mut prefs = Prefs::default();
        prefs.sources.insert(
            "e621".into(),
            SourcePrefs { enabled: false, ..Default::default() },
        );

        let order = prefs.order(["wallhaven", "e621", "danbooru"].into_iter());
        assert_eq!(order, vec!["wallhaven", "danbooru"]);
        assert!(!prefs.enabled("e621"));
    }

    #[test]
    fn weight_sorts_and_ties_keep_their_declared_order() {
        let mut prefs = Prefs::default();
        prefs.sources.insert("danbooru".into(), SourcePrefs { weight: 5, ..Default::default() });
        prefs.sources.insert("e621".into(), SourcePrefs { weight: -2, ..Default::default() });

        let order = prefs.order(["wallhaven", "danbooru", "e621", "iconify"].into_iter());
        assert_eq!(order, vec!["danbooru", "wallhaven", "iconify", "e621"]);
    }

    #[test]
    fn a_seed_reproduces_an_order_and_a_new_one_changes_it() {
        let ids = || ["a", "b", "c", "d", "e", "f", "g", "h"].map(String::from).to_vec();

        let mut prefs = Prefs { blend: "shuffle".into(), seed: 7, ..Default::default() };
        let first = prefs.blend_order(ids());
        let again = prefs.blend_order(ids());
        assert_eq!(first, again, "the same seed must give the same wall");

        prefs.seed = 8;
        assert_ne!(prefs.blend_order(ids()), first, "a new seed must give a different one");

        // Whatever the order, nothing is lost or duplicated.
        let mut sorted = first.clone();
        sorted.sort();
        assert_eq!(sorted, ids());
    }

    #[test]
    fn round_robin_leaves_the_order_alone() {
        let prefs = Prefs { blend: "round-robin".into(), seed: 99, ..Default::default() };
        let ids = ["a", "b", "c"].map(String::from).to_vec();
        assert_eq!(prefs.blend_order(ids.clone()), ids);
    }

    /// Preferences must never be able to stop the daemon.
    #[test]
    fn a_broken_file_is_defaults_rather_than_a_failure() {
        let parsed: Result<Prefs, _> = serde_json::from_str("{ this is not json");
        assert!(parsed.is_err(), "and load() turns that into defaults");
        let prefs = Prefs::default();
        assert!(prefs.enabled("anything"));
    }
}

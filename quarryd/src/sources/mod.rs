//! Source adapters, and the filter pushdown that makes their results good.
//!
//! A query typed into quarry is answered twice: once by the source, which knows
//! how to filter its own catalogue far better than we can after the fact, and
//! once locally for whatever the source could not express. Asking wallhaven for
//! `atleast=3440x1440&ratios=21x9` returns a page of usable ultrawides; asking
//! it for everything and filtering 24 rows locally returns two.
//!
//! So each adapter declares what it can push down, `pushdown()` splits the
//! parsed query accordingly, and the residue is applied to whatever comes back.

#![allow(dead_code)]
use crate::protocol::Item;
use crate::query::{Cmp, Query, Sort, Term};

pub mod anilist;
pub mod danbooru;
pub mod declarative;
pub mod deviantart;
pub mod iconify;
pub mod local;
pub mod iqdb;
pub mod pfps_gg;
pub mod reddit;
pub mod redgifs;
pub mod saucenao;
pub mod wallhaven;
pub mod yandex;
pub mod bing;
pub mod duckduckgo;
pub mod searxng;
pub mod google;
pub mod prefetch;
pub mod tag_resolve;
pub mod text_search;
pub mod seventv;
pub mod erome;
pub mod baidu;

/// What a source can filter on its own side.
#[derive(Debug, Clone, Default)]
pub struct Capabilities {
    pub text: bool,
    pub min_size: bool,
    pub ratio: bool,
    pub nsfw: bool,
    pub sort: bool,
    pub colors: bool,
    pub tags: bool,
    /// Whether the source can be asked for one creator's work. Without it,
    /// `author:` is a local filter over a front page that answers it by
    /// accident or not at all.
    pub author: bool,
    /// Whether the source can be asked for video specifically. Paired with the
    /// tag that means it — `video` on Danbooru, `type:webm` on e621 — which
    /// the adapter or the manifest supplies.
    pub video: bool,
    /*
     * THE CATEGORY NAMES THIS SOURCE WILL ACCEPT, AND NOTHING ELSE.
     *
     * A list rather than a bool, because a category parameter is usually a
     * CLOSED SET and answers an unknown value with an error. Pornhub returns
     * HTTP 200 and `{"message": "Category does not exist!"}` for a name it does
     * not have, and for two names at once — so a typed `category:whatever`, or
     * `category:a,b`, would turn a whole page into an error that parses as
     * "no results" rather than as a failure. Probed live 2026-09-28.
     *
     * So the value is checked against this list before it is pushed down, and
     * anything else stays a text term, which every source can answer.
     */
    pub categories: Vec<String>,
}

/// The half of a query a source can answer.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SourceQuery {
    pub text: Vec<String>,
    pub tags: Vec<String>,
    pub min_w: u32,
    pub min_h: u32,
    /// Target aspect, as a ratio, when the query names one.
    pub ratio: Option<f64>,
    /// `Some(false)` means "definitely no NSFW"; `None` means the query did not
    /// say, which is not the same thing and must not silently become a filter.
    pub allow_nsfw: Option<bool>,
    pub sort: Sort,
    pub color: Option<String>,
    /// The kind asked for, when the query names one — some sources keep
    /// different kinds in different sections rather than as a filter.
    pub kind: String,
    /// The creator asked for. Only ever set when the source said it can search
    /// by one; otherwise it stays in the residue.
    pub author: String,
    /// The site's own category, when the query named one the site actually has.
    /// `{category}` in a manifest's URL. See `Capabilities::categories`.
    pub category: String,
    /*
     * Whether the query is asking for moving pictures.
     *
     * This has to be pushed down or it does not work at all. Video is a small
     * fraction of any board — a few thousand posts against millions — so
     * fetching a page of everything and keeping the videos locally returns an
     * empty screen, page after page, and looks exactly like a source that is
     * broken. The sources that carry video all have a tag for it; they just
     * spell it differently.
     */
    pub wants_video: Option<bool>,
    pub page: u32,
}

/// Split a parsed query into "what the source can do" and "what is left".
///
/// The residue is returned as a `Query` so it can be applied with the same
/// matcher the local catalogue uses — one implementation of the semantics, not
/// two that drift.
pub fn pushdown(query: &Query, caps: &Capabilities) -> (SourceQuery, Query) {
    let mut pushed = SourceQuery { sort: query.sort, page: 1, ..Default::default() };
    let mut residue = Vec::new();

    for clause in &query.clauses {
        // Negation is never pushed down: these APIs express "must have", not
        // "must not", and a half-applied negation is worse than none.
        if clause.negated {
            // `-nsfw` is the one exception, and it is the common one.
            if let Term::Flag { key, value: true } = &clause.term {
                if key == "nsfw" && caps.nsfw {
                    pushed.allow_nsfw = Some(false);
                    continue;
                }
            }
            residue.push(clause.clone());
            continue;
        }

        match &clause.term {
            /*
             * `family:video` MEANS THE SAME THING AS `video`.
             *
             * Only the flag was pushed down, so a query written the other way
             * — which is what the media switch in the dock produces, and what
             * anyone would type after seeing `family` in the filter panel —
             * asked every source for its usual mixture, got stills, filtered
             * them all out locally and reported nothing new. It looked like
             * video "stopping early"; it was video never being asked for.
             */
            Term::Field { key, values } if key == "family" && caps.video
                && values.iter().any(|v| v == "video") =>
            {
                pushed.wants_video = Some(true);
                residue.push(clause.clone());
            }
            Term::Flag { key, value } if (key == "video" || key == "moving") && caps.video => {
                pushed.wants_video = Some(*value);
                // Still applied locally: a board's video tag is a claim about
                // the post, and `moving` also means an animated GIF, which no
                // source has a tag for.
                residue.push(clause.clone());
            }
            Term::Text(text) if caps.text => pushed.text.push(text.clone()),
            /*
             * NOT re-checked locally, for the same reason text is not.
             *
             * Half these sites answer "by this person" from a profile listing
             * and never fill an author field on the row itself — so keeping the
             * predicate in the residue would throw away the very rows the
             * source just selected correctly. `text_search` is what guarantees
             * only a source that can answer this is asked at all.
             */
            Term::Field { key, values } if key == "author" && caps.author => {
                pushed.author = values.first().cloned().unwrap_or_default();
            }
            Term::Field { key, values } if key == "kind" => {
                pushed.kind = values.first().cloned().unwrap_or_default();
                // Still checked locally: a section is not a guarantee.
                residue.push(clause.clone());
            }
            /*
             * A category is pushed down ONLY when the source has one by that
             * exact name; otherwise it falls through to being a tag, which is
             * what it is locally anyway.
             */
            Term::Field { key, values } if key == "category" => {
                let named = values.first().cloned().unwrap_or_default();
                let known = values.len() == 1
                    && caps.categories.iter().any(|c| c.eq_ignore_ascii_case(&named));
                if known {
                    pushed.category = named;
                    // Checked locally too: a category page is the site's
                    // opinion, and the rows still have to match what was asked.
                    residue.push(clause.clone());
                } else if caps.text {
                    pushed.text.extend(values.clone());
                } else {
                    residue.push(clause.clone());
                }
            }
            Term::Field { key, values } if key == "tag" || key == "tags" => {
                if caps.tags {
                    pushed.tags.extend(values.clone());
                } else if caps.text {
                    pushed.text.extend(values.clone());
                } else {
                    residue.push(clause.clone());
                }
            }
            Term::Number { key, cmp, value } => {
                let is_min = matches!(cmp, Cmp::Ge | Cmp::Gt);
                match key.as_str() {
                    "w" | "width" if is_min && caps.min_size => pushed.min_w = *value as u32,
                    "h" | "height" if is_min && caps.min_size => pushed.min_h = *value as u32,
                    "ratio" if matches!(cmp, Cmp::Eq) && caps.ratio => pushed.ratio = Some(*value),
                    // A `w<=` or a `ratio>=` still has to be honoured; it just
                    // cannot be honoured by the source.
                    _ => residue.push(clause.clone()),
                }
                // A pushed minimum is still re-checked locally: sources round,
                // and `atleast` is not always exact.
                if is_min {
                    residue.push(clause.clone());
                }
            }
            Term::Flag { key, value } if key == "nsfw" && caps.nsfw => {
                pushed.allow_nsfw = Some(*value);
            }
            _ => residue.push(clause.clone()),
        }
    }

    // The colour predicate travels with the residue: only wallhaven can express
    // it server-side, and even there it is a palette bucket rather than a
    // distance, so it is re-checked locally either way.
    pushed.color = query.color.map(crate::util::to_hex);

    (
        pushed,
        Query {
            clauses: residue,
            sort: query.sort,
            seed: query.seed,
            unknown: Vec::new(),
            color: query.color,
            color_distance: query.color_distance,
            // Membership and use are resolved by the catalogue; a source never
            // sees either.
            collection: None,
            used: false,
        },
    )
}

/// A source adapter. Everything an adapter must do, and nothing more: describe
/// a request, and turn a response into items.
pub trait Source {
    fn id(&self) -> &'static str;

    /*
     * WHICH SHELF THIS SOURCE BELONGS ON.
     *
     * Twenty-two sources in one flat list is not a filter, it is a phone book:
     * wallhaven and the Met and a furry booru sat between each other in
     * alphabetical order, and choosing between them meant knowing what every
     * name was before you could use the panel at all.
     *
     * Six shelves, chosen by what you would be looking for rather than by what
     * the site is: `wallpapers`, `art`, `photography`, `icons`, `video`,
     * `adult`. A source belongs to exactly one — the one it is best at — so
     * the list stays short enough to read.
     */
    fn category(&self) -> &'static str {
        "art"
    }
    fn capabilities(&self) -> Capabilities;
    fn build_url(&self, query: &SourceQuery) -> String;
    fn parse(&self, body: &str) -> Result<Vec<Item>, String>;

    /// The request body, for a source that answers only to POST.
    ///
    /// A GraphQL endpoint has one URL and no parameters — the search term and
    /// the page are in the document it is sent — so a URL alone cannot describe
    /// its request. Returning `Some` here is what makes the daemon POST.
    fn body(&self, query: &SourceQuery) -> Option<serde_json::Value> {
        let _ = query;
        None
    }

    /// Whether a page of results means there are more.
    fn has_more(&self, body: &str) -> bool {
        let _ = body;
        true
    }

    /// `has_more` for a page already parsed into `rows` rows, so a source
    /// whose answer is "it had rows" need not parse the page a second time.
    fn has_more_after(&self, body: &str, rows: usize) -> bool {
        let _ = rows;
        self.has_more(body)
    }

    /*
     * THE SITE'S OWN TABLE OF CONTENTS: (group, label, query).
     *
     * Categories, channels and orderings a site publishes, as things the
     * filter panel can offer rather than words you have to know to type.
     */
    /// (group, label, query, adult). `adult` hides the section while the adult
    /// switch is off — a source that is mostly safe can still have categories
    /// that are not, and a source-level flag cannot say that.
    fn sections(&self) -> Vec<(String, String, String, bool)> {
        Vec::new()
    }

    /*
     * WHY THIS SOURCE CANNOT ANSWER AT ALL, TODAY.
     *
     * Not a capability — a capability is about the query. This is about the
     * source: a credential that is not set, a host that has closed its API.
     * Reported and skipped like an unanswerable query rather than fetched and
     * failed, because a source that fails every round burns a request, inflates
     * the failure count the app reads to decide the scroll is over, and makes
     * the honest reporting less trustworthy.
     */
    fn unavailable(&self) -> Option<String> {
        None
    }

    /*
     * A VIDEO'S TAGS, FROM ITS OWN PAGE.
     *
     * Most tube listings carry a title and a poster and nothing else; the tags
     * are on the video's page, which the daemon reads anyway to find the file
     * when somebody plays it. A source that knows where on that page the tags
     * are says so here, and the row gets them then.
     */
    fn page_tags(&self, html: &str) -> Vec<String> {
        let _ = html;
        Vec::new()
    }

    /// A hard page count, for sources that have one.
    ///
    /// Most do not: you page until a response comes back empty. A source paged
    /// by a fixed list of sections knows exactly where it ends, and crawling
    /// past that point returns the first section again — duplicate rows that
    /// look like a working crawl.
    fn page_limit(&self) -> Option<u32> {
        None
    }
}

pub fn all() -> Vec<Box<dyn Source + Send + Sync>> {
    let mut sources = natives();

    // Manifests last, so a `sources/*.toml` with the same id as a built-in
    // replaces it — the same rule extensions follow.
    for declared in declarative::Declarative::load_all() {
        let id = declared.id();
        sources.retain(|s| s.id() != id);
        sources.push(Box::new(declared));
    }

    sources
}

fn natives() -> Vec<Box<dyn Source + Send + Sync>> {
    let mut sources: Vec<Box<dyn Source + Send + Sync>> = vec![
        Box::new(wallhaven::Wallhaven),
        Box::new(danbooru::Danbooru),
        Box::new(pfps_gg::PfpsGg::default()),
        Box::new(deviantart::DeviantArt),
        Box::new(anilist::AniList),
        Box::new(iconify::Iconify),
        Box::new(yandex::Yandex),
        Box::new(local::Local),
        Box::new(reddit::Reddit),
        Box::new(redgifs::RedGifs),
        Box::new(bing::Bing),
        Box::new(duckduckgo::DuckDuckGo),
        Box::new(searxng::SearxNG),
        Box::new(seventv::SevenTv),
        Box::new(erome::Erome),
        Box::new(baidu::Baidu),
    ];

    // Registered only with its keys, the rule `[auth]` follows in a manifest: a
    // source that 403s on every query is not one that returns nothing. Unset,
    // `from_env` logs once where to get them. See `google.rs` for the setup.
    if let Some(google) = google::Google::from_env() {
        sources.push(Box::new(google));
    }
    sources
}

/// Suggested starting points per source — the categories a site publishes
/// itself, which are a better first query than anything guessed.
pub fn suggestions(id: &str) -> Vec<String> {
    match id {
        "pfps.gg" => pfps_gg::PfpsGg::popular().iter().map(|s| s.to_string()).collect(),
        _ => Vec::new(),
    }
}

/*
 * THE CATALOGUE'S OWN CATEGORIES.
 *
 * These belonged to whichever source happened to publish a footer, so "anime"
 * arrived labelled `pfps.gg · Anime` — as though it were that site's idea
 * rather than a subject the whole catalogue has. With more than one source
 * publishing, that becomes several sections of overlapping vocabulary and no
 * coherent set anywhere.
 *
 * So the app owns the taxonomy and a source CONTRIBUTES to it. A plain text
 * term is pushed down to every source that can take text (see `pushdown`), so
 * one word genuinely searches all of them — there is nothing to translate, only
 * something to agree on.
 */
pub fn categories() -> &'static [(&'static str, &'static [&'static str])] {
    &[
        ("Subject", &[
            "anime", "gaming", "characters", "nature", "space", "cars", "city",
        ]),
        ("Look", &[
            "aesthetic", "minimal", "dark", "pastel", "retro", "y2k", "grunge",
            "kawaii", "abstract",
        ]),
        ("Moving", &["animated", "gif"]),
    ]
}

/// The app's categories with each source's own terms folded in.
///
/// A term the taxonomy already carries is DROPPED, wherever the source filed
/// it: "anime" is a subject this catalogue has, and listing it again under a
/// site's own heading is the duplication this was meant to remove. What is left
/// is the specific vocabulary the app would never have guessed — `naruto`,
/// `valorant`, `egirl` — and that keeps the source's own grouping, because a
/// site that sorts its characters from its games has said something true.
pub fn category_groups() -> Vec<(String, Vec<String>)> {
    let mut out: Vec<(String, Vec<String>)> = categories()
        .iter()
        .map(|(g, terms)| (g.to_string(), terms.iter().map(|t| t.to_string()).collect()))
        .collect();

    // Every term already spoken for, across the whole taxonomy — not just the
    // bucket a term happens to land in.
    let mut seen: std::collections::HashSet<String> = out
        .iter()
        .flat_map(|(_, terms)| terms.iter().map(|t| t.to_lowercase()))
        .collect();

    for source in all() {
        for (group, terms) in suggestion_groups(source.id()) {
            let fresh: Vec<String> = terms
                .into_iter()
                .filter(|t| seen.insert(t.to_lowercase()))
                .collect();
            if fresh.is_empty() {
                continue;
            }
            let name = if group.is_empty() { "More".to_string() } else { group };
            match out.iter_mut().find(|(g, _)| g.eq_ignore_ascii_case(&name)) {
                Some((_, bucket)) => bucket.extend(fresh),
                None => out.push((name, fresh)),
            }
        }
    }
    out.retain(|(_, terms)| !terms.is_empty());
    out
}

/// Suggested starting points, in the groups the source publishes them in.
pub fn suggestion_groups(id: &str) -> Vec<(String, Vec<String>)> {
    match id {
        "pfps.gg" => pfps_gg::PfpsGg::popular_groups()
            .iter()
            .map(|(g, terms)| {
                (g.to_string(), terms.iter().map(|t| t.to_string()).collect())
            })
            .collect(),
        "wallhaven" => wallhaven::Wallhaven::popular_groups()
            .iter()
            .map(|(g, terms)| {
                (g.to_string(), terms.iter().map(|t| t.to_string()).collect())
            })
            .collect(),
        "danbooru" => danbooru::Danbooru::popular_groups()
            .iter()
            .map(|(g, terms)| {
                (g.to_string(), terms.iter().map(|t| t.to_string()).collect())
            })
            .collect(),
        "anilist" => anilist::AniList::popular_groups()
            .iter()
            .map(|(g, terms)| {
                (g.to_string(), terms.iter().map(|t| t.to_string()).collect())
            })
            .collect(),
        "iconify" => iconify::Iconify::popular_groups()
            .iter()
            .map(|(g, terms)| {
                (g.to_string(), terms.iter().map(|t| t.to_string()).collect())
            })
            .collect(),
        // A source with no groups of its own still answers with one unnamed
        // bucket, so the caller has a single shape to render.
        other => {
            let flat = suggestions(other);
            if flat.is_empty() {
                Vec::new()
            } else {
                vec![(String::new(), flat)]
            }
        }
    }
}

pub fn by_id(id: &str) -> Option<Box<dyn Source + Send + Sync>> {
    // A manifest replaces a built-in of the same id, as in `all`.
    if let Some(declared) = declarative::Declarative::by_id(id) {
        return Some(Box::new(declared));
    }
    natives().into_iter().find(|s| s.id() == id)
}

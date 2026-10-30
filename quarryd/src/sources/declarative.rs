//! Sources described in a file rather than written in Rust.
//!
//! Most adapters differ only in a URL, a page parameter and which JSON field
//! holds the image — wallhaven, the boorus, Openverse and every icon set are
//! the same twenty lines with different names. Writing each as Rust means a
//! rebuild to add a booru, and it means someone who wants their own source has
//! to be a Rust programmer.
//!
//! So a source can instead be a manifest: where to ask, and which field is
//! which. Loaded from
//!
//!   <install>/sources/*.toml          shipped
//!   ~/.config/quarry/sources/*.toml   yours, overriding a shipped id
//!
//! The awkward ones stay native — reddit's OAuth, pfps.gg's HTML, AniList's
//! GraphQL — and both kinds implement the same trait, so nothing downstream
//! knows the difference.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

#[derive(Debug, Clone, Deserialize)]
pub struct Manifest {
    /// The site's own sections, surfaced in the filter panel.
    #[serde(default)]
    pub sections: Vec<Section>,
    /// Where the site publishes its full lists — see `SectionsFrom`.
    #[serde(default)]
    pub sections_from: Vec<SectionsFrom>,
    /// Where a video's page keeps its tags — see `PageTags`.
    #[serde(default)]
    pub page_tags: Option<PageTags>,
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub family: String,

    pub request: Request,
    #[serde(default)]
    pub capabilities: Caps,
    pub map: Mapping,
    /// Required by `format = "html"`, ignored otherwise.
    #[serde(default)]
    pub html: Option<HtmlSpec>,
    /// Present only for a source that cannot answer without credentials —
    /// most manifests have none of this.
    #[serde(default)]
    pub auth: Option<Auth>,
    /// Everything this source returns is adult.
    ///
    /// A fact about the source, not a capability: `capabilities.nsfw` says
    /// "this site can filter by rating", which is a different question from
    /// "what comes back should be marked". Without this the rows arrive
    /// unmarked and `-nsfw` — the filter that exists precisely so the rest of
    /// the catalogue stays browsable — silently keeps every one of them.
    #[serde(default)]
    pub adult: bool,
    /// Which shelf this source belongs on — see `Source::category`.
    #[serde(default)]
    pub category: String,
    /*
     * A SITE THAT WILL NOT SERVE ITS OWN PICTURES TO A STRANGER.
     *
     * The Art Institute's IIIF server answers the API happily and then returns
     * 403 for every image unless the request carries a `Referer` naming the
     * museum's own site. That is a fact about the HOST, not about one request,
     * so it is declared once here and applied to any fetch that goes to the
     * same host — the API call, the thumbnail and the original alike.
     *
     * Hotlink protection like this is the norm across the IIIF museums, and
     * without it every one of them looks like a source that returns rows whose
     * pictures are all broken — which is the worst failure this app has,
     * because the catalogue fills up and nothing can be seen.
     */
    #[serde(default)]
    pub referer: String,
    /// Extra hosts the same referer applies to — a site's pictures are rarely
    /// on the site's own host. A bare domain covers everything under it, so
    /// `phncdn.com` is every edge Pornhub serves posters from.
    #[serde(default)]
    pub referer_hosts: Vec<String>,
}

/// Environment variables a source needs before it can work at all, and how
/// they turn into part of the request.
///
/// This is deliberately generic — a list of variable names and a template to
/// fill in with them — rather than "an api_key field", because different
/// boorus name their pair differently (Gelbooru's dapi wants both a user id
/// and a key; another source might want only one, under a different name).
#[derive(Debug, Clone, Deserialize)]
pub struct Auth {
    /// Every name in here must be set, or the source does not load at all —
    /// see `Declarative::load`. An empty env var counts as unset: a leftover
    /// `export FOO=` from a half-finished setup should read as "not done",
    /// not as a real value.
    pub vars: Vec<String>,
    /// Appended to `request.url` once every var is present. `{VAR}` tokens
    /// are replaced with that variable's value, urlencoded the same way
    /// `{tags}` is.
    #[serde(default)]
    pub query: String,
    /// Where to get the credential, folded into the startup log line when a
    /// var is missing so the fix is one click, not a search.
    #[serde(default)]
    pub hint: String,
}

/// Check every required var and, if all are set, build the resolved query
/// string — otherwise the names still missing, in manifest order.
///
/// Takes a lookup function rather than reading `std::env` directly so a test
/// can exercise "some set, some not" without racing every other test in the
/// binary over the same process-global environment.
fn resolve_auth(auth: &Auth, get: impl Fn(&str) -> Option<String>) -> Result<String, Vec<String>> {
    let missing: Vec<String> = auth
        .vars
        .iter()
        .filter(|v| get(v).map(|value| value.trim().is_empty()).unwrap_or(true))
        .cloned()
        .collect();
    if !missing.is_empty() {
        return Err(missing);
    }

    let mut query = auth.query.clone();
    for var in &auth.vars {
        // `unwrap_or_default` never fires here — the missing-check above
        // already proved every var resolves to a non-blank value.
        let value = get(var).unwrap_or_default();
        query = query.replace(&format!("{{{var}}}"), &scrape::urlencode(&value));
    }
    Ok(query)
}

/*
 * WHAT A SITE OFFERS, AS THINGS YOU CAN PICK.
 *
 * A site's categories, channels and orderings are its table of contents, and
 * flattening them into "type the right word" loses them. A section carries a
 * label and the query it runs, because those differ: "Newest" runs `sort:new`,
 * a category runs its own name through the site's search.
 */
/*
 * THE SITE'S WHOLE LIST, NOT THIRTY-SIX OF IT.
 *
 * A tube site has a hundred categories and a thousand tags, and the manifests
 * carried a hand-picked three dozen — the panel offered what somebody typed
 * once, not what the site has. Most of these sites publish the lists
 * (redtube: 111 categories and 909 tags, 2026-10-23), so a manifest names
 * where, and the daemon fetches them in the background and keeps them a day.
 * The hand-written sections stay first and are what shows until it arrives.
 */
#[derive(Debug, Clone, Deserialize)]
pub struct SectionsFrom {
    /// The heading they go under: "Categories", "Tags".
    #[serde(default)]
    pub group: String,
    pub url: String,
    /// `json` (the default) or `html`.
    #[serde(default)]
    pub format: String,
    /// json: the array, as a dotted path (`categories`).
    #[serde(default)]
    pub root: String,
    /// json: the name inside each entry (`tag.tag_name`).
    #[serde(default)]
    pub label: String,
    /// html: a CSS selector whose text is each name.
    #[serde(default)]
    pub select: String,
    /// Every one of them is adult (see `Section::adult`).
    #[serde(default)]
    pub adult: bool,
}

impl SectionsFrom {
    /// The names in a fetched list, trimmed, deduplicated, in the site's order.
    pub fn names(&self, body: &str) -> Vec<String> {
        let raw: Vec<String> = if self.format.eq_ignore_ascii_case("html") {
            scrape::select_texts(body, &self.select).unwrap_or_default()
        } else {
            let Ok(json) = serde_json::from_str::<serde_json::Value>(body) else { return Vec::new() };
            let list = if self.root.is_empty() { Some(&json) } else { scrape::json_pluck(&json, &self.root) };
            list.and_then(|l| l.as_array())
                .map(|rows| rows.iter().filter_map(|row| scrape::json_pluck(row, &self.label).and_then(|v| v.as_str()).map(String::from)).collect())
                .unwrap_or_default()
        };
        let mut seen = std::collections::HashSet::new();
        raw.into_iter()
            .map(|n| n.split_whitespace().collect::<Vec<_>>().join(" "))
            .filter(|n| !n.is_empty() && n.len() <= 60 && seen.insert(n.to_lowercase()))
            .collect()
    }
}

/*
 * WHERE A VIDEO'S PAGE KEEPS ITS TAGS.
 *
 * Every site hides them somewhere different, and the obvious place is wrong
 * on half of them: the `keywords` meta is the video's tags on hqporner and
 * the site's slogan on xnxx, and links to tag pages are mostly the menu. So a
 * manifest names the exact place (measured per site, 2026-10-23):
 *
 *   attrs       comma lists in an attribute — youporn's `data-context-tag`
 *   select      CSS whose text is each tag — xnxx's `.video-tags a.is-keyword`
 *   meta        a `<meta name=…>` comma list — hqporner's `keywords`
 *   json_array  a JSON array in the page, and the field in each entry —
 *               xhamster's `"tags":[{"name":…}]`
 *
 * `skip` drops the boilerplate a site mixes in ("hd porn video").
 */
#[derive(Debug, Clone, Default, Deserialize)]
pub struct PageTags {
    #[serde(default)]
    pub attrs: Vec<String>,
    #[serde(default)]
    pub select: String,
    #[serde(default)]
    pub meta: String,
    #[serde(default)]
    pub json_array: String,
    #[serde(default)]
    pub field: String,
    /// Entries in the JSON array to keep only when this field is true —
    /// xhamster marks its creators and channels as well as its tags.
    #[serde(default)]
    pub keep_if: Vec<String>,
    #[serde(default)]
    pub skip: Vec<String>,
    /// Cut from the end of each tag: hqporner writes "anal porn".
    #[serde(default)]
    pub trim_suffix: String,
    /// `group-sex` → `group sex` (attributes always get this).
    #[serde(default)]
    pub dashes: bool,
}

impl PageTags {
    pub fn read(&self, html: &str) -> Vec<String> {
        let mut raw: Vec<String> = Vec::new();
        for attr in &self.attrs {
            let pattern = format!(r#"{}=['"]([^'"]*)['"]"#, regex::escape(attr));
            if let Ok(found) = scrape::regex_all(html, &pattern, 1) {
                if let Some(first) = found.into_iter().next() {
                    raw.extend(first.split(',').map(|t| t.replace('-', " ")));
                }
            }
        }
        if !self.select.is_empty() {
            raw.extend(scrape::select_texts(html, &self.select).unwrap_or_default());
        }
        if !self.meta.is_empty() {
            let pattern = format!(r#"<meta[^>]+name=['"]{}['"][^>]+content=['"]([^'"]*)"#, regex::escape(&self.meta));
            if let Ok(found) = scrape::regex_all(html, &pattern, 1) {
                if let Some(first) = found.into_iter().next() {
                    raw.extend(scrape::html_unescape(&first).split(',').map(String::from));
                }
            }
        }
        if !self.json_array.is_empty() {
            raw.extend(json_array_in(html, &self.json_array, &self.field, &self.keep_if));
        }
        let skip: std::collections::HashSet<String> = self.skip.iter().map(|s| s.to_lowercase()).collect();
        let mut seen = std::collections::HashSet::new();
        raw.into_iter()
            .map(|t| if self.dashes { t.replace('-', " ") } else { t })
            .map(|t| t.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase())
            .map(|t| match t.strip_suffix(&self.trim_suffix.to_lowercase()) {
                Some(cut) if !self.trim_suffix.is_empty() => cut.trim().to_string(),
                _ => t,
            })
            .filter(|t| !t.is_empty() && t.len() <= 40 && !skip.contains(t) && seen.insert(t.clone()))
            .take(40)
            .collect()
    }
}

/// The first `"key":[ … ]` in a page, parsed, and `field` of each entry —
/// only entries where every `keep_if` field is true, when any are named.
fn json_array_in(html: &str, key: &str, field: &str, keep_if: &[String]) -> Vec<String> {
    let needle = format!("\"{key}\":[");
    let Some(at) = html.find(&needle) else { return Vec::new() };
    let start = at + needle.len() - 1;
    // The matching `]`, counting brackets outside strings.
    let bytes = html.as_bytes();
    let (mut depth, mut in_str, mut escaped, mut end) = (0i32, false, false, None);
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        if in_str {
            match (escaped, b) {
                (true, _) => escaped = false,
                (false, b'\\') => escaped = true,
                (false, b'"') => in_str = false,
                _ => {}
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            b'[' => depth += 1,
            b']' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(i + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    let Some(end) = end else { return Vec::new() };
    let Ok(serde_json::Value::Array(rows)) = serde_json::from_str::<serde_json::Value>(&html[start..end]) else {
        return Vec::new();
    };
    rows.iter()
        .filter(|row| keep_if.iter().all(|k| row.get(k).and_then(|v| v.as_bool()) == Some(true)))
        .filter_map(|row| row.get(field).and_then(|v| v.as_str()).map(String::from))
        .collect()
}

/// Fetched lists, per source id: when, and (group, label, adult) rows.
type Fetched = (std::time::Instant, Vec<(String, String, bool)>);
static FETCHED_SECTIONS: std::sync::Mutex<Option<std::collections::HashMap<String, Fetched>>> = std::sync::Mutex::new(None);
static FETCHING_SECTIONS: std::sync::Mutex<Option<std::collections::HashSet<String>>> = std::sync::Mutex::new(None);

#[derive(Debug, Clone, Deserialize)]
pub struct Section {
    /// Which heading it sits under — "Categories", "Sort", whatever the site
    /// calls it. Empty groups together under the source's own name.
    #[serde(default)]
    pub group: String,
    pub label: String,
    /// The query DSL this section runs. Defaults to the label, which is right
    /// for a category: its name IS the search.
    #[serde(default)]
    pub q: String,
    /*
     * THIS CATEGORY IS ADULT, EVEN IF THE SOURCE IS NOT.
     *
     * `adult` on the source marks every row it returns and is the right answer
     * for a site that is wholly adult. Most sites are not: a general booru, a
     * video site or an art gallery is mostly safe with a handful of adult
     * categories, and a source-level flag can only hide all of it or none.
     *
     * Marking the section instead means the safe categories stay browsable with
     * the switch off and the adult ones are not offered at all.
     */
    #[serde(default)]
    pub adult: bool,
}

impl Section {
    pub fn query(&self) -> String {
        if self.q.is_empty() { self.label.clone() } else { self.q.clone() }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    /// A template. `{query}`, `{tags}`, `{page}`, `{page0}`, `{offset}`,
    /// `{limit}` and `{minw}`/`{minh}` are substituted; anything else is left
    /// alone so a typo shows up in the URL rather than vanishing.
    pub url: String,
    /*
     * WHO QUARRY SAYS IT IS TO THIS HOST.
     *
     * Empty is the rule: the honest agent, as everywhere else. `"browser"`
     * spells out `scrape::BROWSER_USER_AGENT`, and any other value is sent
     * literally.
     *
     * Only for hosts that answer 403 to the honest one — measured, not
     * assumed, and written in the manifest so `grep -l user_agent sources/`
     * lists every exception in one command. Nothing else changes: the same
     * rate limiter, the same cache, the same robots-shaped manners.
     */
    #[serde(default)]
    pub user_agent: String,
    /// Extra headers for the request's host, e.g. `{ Accept = "text/css" }`.
    /// Only where a host refuses without them — measured, like `user_agent`.
    #[serde(default)]
    pub headers: std::collections::BTreeMap<String, String>,
    /// How this board spells "by this person" as a search term, e.g.
    /// `user:{author}`. Folded in with the other terms; sources with a real
    /// parameter use `{author}` in `url` instead.
    #[serde(default)]
    pub author_tag: String,
    /// `{sort}` in the URL, in the site's own words: a table keyed by the
    /// query DSL's sort names (`new`, `large`, …) plus `default` for when
    /// nothing was asked. `[capabilities] sort` was declared and never used to
    /// build anything; this is what makes it true.
    ///
    /// A value may carry extra parameters after an `&` — `mostviewed&period=weekly`
    /// — for the sites where an ordering is really two parameters. Each part is
    /// encoded on its own so the `&` and `=` survive; see `encode_sort`.
    #[serde(default)]
    pub sort: std::collections::HashMap<String, String>,
    #[serde(default = "default_limit")]
    pub limit: u32,
    /// What the response is: `json`, `rss` or `html`.
    #[serde(default = "default_format")]
    pub format: String,
    /// What a space becomes in the substituted value. `+` by default; a site
    /// whose search is a path segment needs `%20`, where `+` is a literal plus
    /// (Shimmie answers 404 to one).
    #[serde(default)]
    pub space: String,
    /// For JSON: the array to walk. Empty means the document itself is one.
    #[serde(default)]
    pub root: String,
    /// A term to use when the query is empty, for sources that answer nothing
    /// (or 400) without one — a trap three hand-written adapters hit.
    #[serde(default)]
    pub browse_term: String,
    /*
     * Sources that are not paged by number.
     *
     * Peapix publishes the Bing wallpaper of the day per market: seven rows a
     * feed, `page` ignored, a date range ignored too. It is not one list with
     * pages, it is fourteen small lists — and a source that answers the same
     * seven rows to every request stalls endless scroll on its second turn.
     *
     * Where this is set, `{page_value}` cycles through it as the page number
     * grows, and the list length is how many pages the source has. Any source
     * paged by section rather than by offset fits the same shape.
     */
    #[serde(default)]
    pub page_values: Vec<String>,
    /// The tag that means "only moving pictures", in this source's own
    /// spelling: `video` on Danbooru, `type:webm` on e621. Its presence is
    /// what makes `capabilities.video` true — a capability nobody can act on
    /// is a lie the pushdown would believe.
    #[serde(default)]
    pub video_tag: String,
    /// Look typed words up as this site's real tags before searching —
    /// `danbooru`, `gelbooru`, `moebooru`, `e621`, `philomena` or `eshuushuu`.
    /// See `tag_resolve`.
    #[serde(default)]
    pub tag_resolver: String,
    /*
     * HOW TERMS ARE GLUED TOGETHER when no tag resolver has already done it.
     *
     * A space on nearly every booru, where a space separates tags. Philomena
     * is the exception that makes this a key: a tag there may CONTAIN a space,
     * so `wallpaper safe` is one tag nobody has and answers 0 results, while
     * `wallpaper,safe` answers 10,552 (manebooru, measured 2026-09-15). It
     * matters most for the browse term plus a pushed-down rating tag, which
     * never goes through a resolver. Empty means a space.
     */
    #[serde(default)]
    pub joiner: String,
    /*
     * The tag that means "only safe" and the one that means "only not safe",
     * in this source's own spelling: `rating:s` / `-rating:s` on Moebooru,
     * `rating:g` / `-rating:g` on Danbooru, `safe` / `-safe` on Philomena.
     *
     * Both present is what makes `capabilities.nsfw` true, exactly as
     * `video_tag` does for video: the pushdown drops `-nsfw` from the local
     * residue once a source claims it, so a source that could only say one
     * half would answer `nsfw` with its usual mixture and nothing would
     * filter it afterwards.
     */
    #[serde(default)]
    pub sfw_tag: String,
    #[serde(default)]
    pub nsfw_tag: String,
}

/*
 * An ordering that is really two parameters.
 *
 * Pornhub's "most viewed this week" is `ordering=mostviewed&period=weekly`, and
 * plenty of sites are like it. Encoding the whole thing as one value turns the
 * `&` into `%26` and the site quietly ignores the half it cannot read — a feed
 * that looks fine and is sorted wrong, which is worse than an error. So the
 * pieces are encoded separately and the separators kept.
 */
/// "15:10" → 910, "1:02:33" → 3753. Anything else → 0, because a length that
/// cannot be read is better absent than wrong.
fn parse_clock(text: &str) -> f64 {
    let parts: Vec<&str> = text.trim().split(':').collect();
    if parts.is_empty() || parts.len() > 3 {
        return 0.0;
    }
    let mut seconds = 0.0;
    for part in &parts {
        match part.trim().parse::<f64>() {
            Ok(value) if value >= 0.0 => seconds = seconds * 60.0 + value,
            _ => return 0.0,
        }
    }
    seconds
}

fn encode_sort(value: &str, encode: impl Fn(&str) -> String) -> String {
    let mut out = String::new();
    for (index, part) in value.split('&').enumerate() {
        if index > 0 {
            out.push('&');
        }
        match part.split_once('=') {
            Some((key, val)) => {
                out.push_str(&encode(key));
                out.push('=');
                out.push_str(&encode(val));
            }
            None => out.push_str(&encode(part)),
        }
    }
    out
}

fn default_limit() -> u32 {
    50
}

fn default_format() -> String {
    "json".into()
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Caps {
    #[serde(default)]
    pub text: bool,
    #[serde(default)]
    pub tags: bool,
    /// Set only when the request can name a creator — `{author}` in the URL,
    /// or `author_tag` for a board where the creator is a tag.
    #[serde(default)]
    pub author: bool,
    #[serde(default)]
    pub min_size: bool,
    #[serde(default)]
    pub ratio: bool,
    #[serde(default)]
    pub nsfw: bool,
    #[serde(default)]
    pub sort: bool,
}

/// Reading a listing page: `row` picks one element per result, `fields` says
/// where each value sits in it. Extraction yields a flat object per row, which
/// `[map]` then reads exactly as it reads JSON — templates, `a || b` and the
/// rating mapping all work unchanged.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct HtmlSpec {
    pub row: String,
    /// A "next page" link. Present means there is one; without this key
    /// `has_more` falls back to "this page had rows", as JSON does.
    #[serde(default)]
    pub next: String,
    /// What relative URLs resolve against. Defaults to `request.url` up to its
    /// first template token.
    #[serde(default)]
    pub base: String,
    #[serde(default)]
    pub fields: std::collections::BTreeMap<String, HtmlField>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct HtmlField {
    /// A CSS selector inside the row; empty means the row element itself.
    #[serde(default)]
    pub sel: String,
    /// Which attribute to read; empty means the element's text.
    #[serde(default)]
    pub attr: String,
    /// Keep only what this matches — capture group 1 if there is one. Pulling a
    /// fragment out of a URL is not itself a link, so it is not absolutised.
    #[serde(default, rename = "re")]
    pub pattern: String,
    /// Every match, as a list, rather than the first — tags as one element each.
    #[serde(default)]
    pub all: bool,
    /// Resolve against the base. Defaults to true for link-ish attributes.
    #[serde(default)]
    pub abs: Option<bool>,
}

/// Attributes that hold a URL, and so are absolutised by default.
const LINK_ATTRS: [&str; 7] =
    ["src", "href", "content", "poster", "data-src", "data-original", "data-file"];

/// Which field is which. Values are dotted paths (`data.items[0].url`) resolved
/// with the same plucker the native adapters use — or, under `format = "html"`,
/// the names declared in `[html.fields]`.
#[derive(Debug, Clone, Deserialize)]
pub struct Mapping {
    pub id: String,
    pub url: String,
    #[serde(default)]
    pub thumb: String,
    /// Mid-size image (Moebooru `sample_url`, Danbooru `large_file_url`).
    /// Missing key stays empty like `thumb` does.
    #[serde(default)]
    pub sample: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub page_url: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub width: String,
    #[serde(default)]
    pub height: String,
    #[serde(default)]
    pub tags: String,
    /// Seconds of video, where a source publishes it (e621 does). Measured
    /// from the file when it does not.
    #[serde(default)]
    pub duration: String,
    /// The same thing in MILLISECONDS, for the APIs that publish it that way
    /// (Openverse's audio half does). One of the two, never both: a length in
    /// the wrong unit is a three-minute song filed as fifty hours.
    #[serde(default)]
    pub duration_ms: String,
    /// …and as a CLOCK — "15:10", "1:02:33" — which is what the tube sites
    /// publish. Parsed rather than fed to `parse::<f64>()`, which reads "15:10"
    /// as fifteen seconds.
    #[serde(default)]
    pub duration_clock: String,
    /// File size in bytes, where a source publishes it.
    #[serde(default)]
    pub bytes: String,
    /// The file type, for a URL that does not carry one — Shimmie serves its
    /// images from an extensionless path, and without this every video there
    /// read as a still. A MIME type is accepted as well as a bare extension.
    #[serde(default)]
    pub ext: String,
    /// How to split a tag string, when tags arrive as one.
    #[serde(default)]
    pub tags_separator: String,
    /*
     * WHICH ROWS ARE ADULT, on a source that mixes both.
     *
     * `adult = true` answers this for a whole source. A board like yande.re
     * or AIBooru is neither: most of a page can be safe and the rest not, and
     * without a per-row answer every one of those rows arrived unmarked — so
     * `-nsfw` kept all of them, which is the filter failing silently.
     *
     * `rating` is a path to the field (or, on Philomena, the tag LIST, since
     * the rating is one of the tags), and a row is nsfw when any value there
     * is one of `nsfw_ratings`, compared case-insensitively — mspabooru
     * answers both `safe` and `Safe`. An absent rating marks nothing: a
     * guess in either direction would be quarry deciding, not the site.
     */
    #[serde(default)]
    pub rating: String,
    #[serde(default)]
    pub nsfw_ratings: Vec<String>,
}

#[derive(Clone)]
pub struct Declarative {
    manifest: Manifest,
    /// Leaked so the trait's `&'static str` id can be satisfied without every
    /// caller carrying a lifetime. There are a handful of sources, loaded once.
    id: &'static str,
    /// `manifest.auth.query` with its `{VAR}` tokens already filled in from
    /// the environment. Resolved once at load time, not per-request: by the
    /// time a `Declarative` exists, `load` has already confirmed every var is
    /// there, so there is nothing left to re-check on the hot path.
    auth_query: String,
}

impl Declarative {
    /*
     * The category names this source will accept: its own "Categories"
     * sections, which are the list the manifest already carries and the list
     * the UI already offers. Deriving it rather than repeating it means the
     * menu and the accepted values cannot disagree.
     */
    fn declared_categories(&self) -> Vec<String> {
        if !self.manifest.request.url.contains("{category}") {
            return Vec::new();
        }
        self.manifest
            .sections
            .iter()
            .filter(|s| s.group.eq_ignore_ascii_case("categories"))
            .map(|s| s.label.clone())
            .collect()
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let manifest: Manifest = toml::from_str(&text)
            .map_err(|e| format!("{}: {e}", path.display()))?;

        // A source that 401s without a key is not a source that returns zero
        // results — it is a source that is not configured yet, and those are
        // different things a caller must be able to tell apart. So this
        // fails the SAME way a broken manifest does: `load_all` skips it and
        // logs why, rather than registering an id that always errors.
        let auth_query = match &manifest.auth {
            Some(auth) => match resolve_auth(auth, |v| std::env::var(v).ok()) {
                Ok(query) => query,
                Err(missing) => {
                    let hint =
                        if auth.hint.is_empty() { String::new() } else { format!(" — {}", auth.hint) };
                    return Err(format!(
                        "{}: ${} not set{hint}",
                        manifest.id,
                        missing.join(", $")
                    ));
                }
            },
            None => String::new(),
        };

        // Declared per host, not per request, so the picture fetch honours it
        // too — a 403 on the image is the same empty tile as a 403 on the list.
        if !manifest.request.user_agent.is_empty() {
            let agent = match manifest.request.user_agent.as_str() {
                "browser" => crate::scrape::BROWSER_USER_AGENT.to_string(),
                other => other.to_string(),
            };
            if let Ok(parsed) = url::Url::parse(&manifest.request.url) {
                if let Some(host) = parsed.host_str() {
                    crate::scrape::set_host_agent(host, &agent);
                }
            }
        }
        if !manifest.request.headers.is_empty() {
            if let Some(host) = url::Url::parse(&manifest.request.url).ok().and_then(|u| u.host_str().map(String::from)) {
                for (name, value) in &manifest.request.headers {
                    crate::scrape::set_host_header(&host, name, value);
                }
            }
        }

        let id: &'static str = Box::leak(manifest.id.clone().into_boxed_str());
        Ok(Declarative { manifest, id, auth_query })
    }

    /// Every manifest on disk, user ones overriding shipped ones of the same id.
    /*
     * READ ONCE, RE-READ WHEN A FILE CHANGES.
     *
     * `by_id` came through here, so every lookup parsed all ~160 manifests
     * (and leaked each id): a search looks sources up per page, and the first
     * rows of every search waited ~5 s for it. A changed, added or removed
     * file still takes effect without a restart — the directories are looked
     * at again at most once a second.
     */
    pub fn load_all() -> Vec<Declarative> {
        Self::cached(|sources| sources.to_vec())
    }

    /// The cached one, by id, without copying the rest.
    pub fn by_id(id: &str) -> Option<Declarative> {
        Self::cached(|sources| sources.iter().find(|s| s.id == id).cloned())
    }

    fn cached<R>(read: impl FnOnce(&[Declarative]) -> R) -> R {
        type Seen = Vec<(PathBuf, Option<std::time::SystemTime>, u64)>;
        static CACHE: std::sync::Mutex<Option<(std::time::Instant, Seen, Vec<Declarative>)>> =
            std::sync::Mutex::new(None);
        let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((checked, _, sources)) = cache.as_ref() {
            if checked.elapsed() < std::time::Duration::from_secs(1) {
                return read(sources);
            }
        }
        let seen: Seen = Self::directories()
            .iter()
            .filter_map(|dir| std::fs::read_dir(dir).ok())
            .flat_map(|entries| entries.flatten())
            .map(|entry| {
                let meta = entry.metadata().ok();
                (entry.path(), meta.as_ref().and_then(|m| m.modified().ok()), meta.map_or(0, |m| m.len()))
            })
            .collect();
        if let Some((checked, before, sources)) = cache.as_mut() {
            if *before == seen {
                *checked = std::time::Instant::now();
                return read(sources);
            }
        }
        let fresh = (std::time::Instant::now(), seen, Self::read_all());
        read(&cache.insert(fresh).2)
    }

    fn read_all() -> Vec<Declarative> {
        let mut found: std::collections::HashMap<String, Declarative> =
            std::collections::HashMap::new();

        for dir in Self::directories() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                    continue;
                }
                match Self::load(&path) {
                    // A later directory wins: user manifests are read last.
                    Ok(source) => {
                        source.register_referer();
                        found.insert(source.manifest.id.clone(), source);
                    }
                    // A broken manifest is named and skipped. Failing to start
                    // because one file has a typo would be worse.
                    Err(e) => eprintln!("[quarryd] ignoring source manifest — {e}"),
                }
            }
        }

        found.into_values().collect()
    }

    fn directories() -> Vec<PathBuf> {
        let mut dirs = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            if let Some(base) = exe.parent() {
                dirs.push(base.join("../share/quarry/sources"));
            }
        }
        dirs.push(PathBuf::from("sources"));
        if let Ok(home) = std::env::var("HOME") {
            dirs.push(PathBuf::from(format!("{home}/.config/quarry/sources")));
        }
        dirs
    }

    /*
     * Tell the fetcher this source's site wants a Referer.
     *
     * The host is taken from the referer itself rather than from the request
     * URL: a museum's API and its image server are usually different hosts,
     * and the one that refuses hotlinks is the one the referer names.
     */
    fn register_referer(&self) {
        let referer = self.manifest.referer.trim();
        if referer.is_empty() {
            return;
        }
        let Some(rest) = referer.split_once("://").map(|(_, r)| r) else {
            eprintln!(
                "[quarryd] {}: referer must be a full URL, got {referer:?}",
                self.manifest.id
            );
            return;
        };
        let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
        crate::scrape::set_referer(host, referer);
        for extra in &self.manifest.referer_hosts {
            crate::scrape::set_referer(extra.trim().trim_start_matches('.'), referer);
        }
    }

    /// Resolve one mapping entry against a row.
    ///
    /// Three forms, in order of how often they are needed:
    ///
    /// - a **path** (`file.url`, `imageinfo[0].url`) — the usual case;
    /// - a **literal**, written `=1920`. Some sources return no dimensions at
    ///   all — Peapix serves the Bing wallpaper of the day and every one of
    ///   them is 1920x1080 — and a row with no size is dropped by
    ///   `keep_usable` as a collapsed tile. Writing the constant in the
    ///   manifest is honest about where the number came from; inventing one in
    ///   code would not be;
    /// - a **template**, any value containing `{field}`. A whole family of
    ///   museum APIs (IIIF: the Art Institute, Harvard, the Bodleian, dozens
    ///   more) publish an image *id* and expect the client to build the URL
    ///   from it, with the size in the path. Without this, every one of them
    ///   needs a hand-written adapter to do string concatenation.
    ///
    /// Two refinements, each earned by a source that needed it:
    ///
    /// - **alternatives**, `route || route.dark`: svgl publishes a logo's
    ///   file either as a string or, for logos with a light and a dark
    ///   variant, as an object of both. The first alternative that resolves
    ///   wins.
    /// - **a replace filter** inside a template token,
    ///   `{photos[0].url|replace:square:original}`: iNaturalist publishes the
    ///   75px square and the original sits at the same path with one word
    ///   changed — including its real extension, which a template built from
    ///   the photo id would have to guess.
    ///
    /// And paths may count from the end, `links[-1].href` — NASA lists every
    /// rendition of a picture with the original always last, at an index that
    /// depends on how many renditions exist.
    fn field(&self, value: &serde_json::Value, path: &str) -> String {
        if path.contains("||") {
            return path
                .split("||")
                .map(|alternative| self.field(value, alternative.trim()))
                .find(|resolved| !resolved.is_empty())
                .unwrap_or_default();
        }
        if let Some(literal) = path.strip_prefix('=') {
            return literal.to_string();
        }
        if path.is_empty() {
            return String::new();
        }
        if !path.contains('{') {
            return pluck(value, path).map(scalar).unwrap_or_default();
        }

        let mut out = String::with_capacity(path.len() + 32);
        let mut rest = path;
        while let Some(open) = rest.find('{') {
            out.push_str(&rest[..open]);
            let Some(close) = rest[open..].find('}').map(|i| open + i) else {
                // An unclosed brace is a typo; leaving it visible in the URL is
                // how it gets noticed, rather than silently swallowing the
                // rest of the template.
                break;
            };
            let mut parts = rest[open + 1..close].split('|');
            let token_path = parts.next().unwrap_or_default();
            let mut resolved = pluck(value, token_path).map(scalar).unwrap_or_default();
            // A template whose field is missing must not produce a URL with a
            // hole in it — that would be a row pointing at a 404.
            if resolved.is_empty() {
                return String::new();
            }
            for filter in parts {
                let mut args = filter.splitn(3, ':');
                match (args.next(), args.next(), args.next()) {
                    (Some("replace"), Some(from), Some(to)) if !from.is_empty() => {
                        resolved = resolved.replace(from, to);
                    }
                    // An unknown filter is a typo, and a URL that silently
                    // ignored it would point somewhere the author did not
                    // mean. No URL is the honest answer.
                    _ => return String::new(),
                }
            }
            out.push_str(&resolved);
            rest = &rest[close + 1..];
        }
        out.push_str(rest);
        out
    }

    /// Every value a mapping entry resolves to, for fields that may be a list:
    /// Philomena publishes tags as an array, gelbooru as one string.
    fn values(&self, value: &serde_json::Value, path: &str, separator: &str) -> Vec<String> {
        if path.is_empty() {
            return Vec::new();
        }
        /*
         * SEVERAL PATHS AT ONCE: `a + b + c`.
         *
         * A site's words for a row are not always in one place. Pornhub
         * publishes free-text tags, the performers, and its own categories as
         * three separate lists, and all three are what somebody would search
         * for. `||` picks the first that resolves; this takes all of them.
         */
        if path.contains(" + ") {
            let mut out = Vec::new();
            for part in path.split(" + ") {
                out.extend(self.values(value, part.trim(), separator));
            }
            out.dedup();
            return out;
        }
        /*
         * ONE FIELD OUT OF EVERY ELEMENT: `tags[].tag_name`.
         *
         * A list of OBJECTS, which the plain path form cannot read: it plucks
         * the array and asks each element for its scalar, and an object has
         * none. This is why pornhub.toml carried the line "tags is a list of
         * objects the mapper cannot flatten, so it is left unmapped" — every
         * video in the catalogue arrived with no words on it at all.
         */
        if let Some((head, tail)) = path.split_once("[]") {
            let tail = tail.trim_start_matches('.');
            if let Some(serde_json::Value::Array(list)) = pluck(value, head.trim()) {
                return list
                    .iter()
                    .map(|element| {
                        if tail.is_empty() {
                            scalar(element)
                        } else {
                            pluck(element, tail).map(|found| scalar(&found)).unwrap_or_default()
                        }
                    })
                    .filter(|t| !t.is_empty())
                    .collect();
            }
            return Vec::new();
        }
        if let Some(serde_json::Value::Array(list)) =
            (!path.contains('{') && !path.starts_with('=')).then(|| pluck(value, path)).flatten()
        {
            return list.iter().map(scalar).filter(|t| !t.is_empty()).collect();
        }
        let separator = if separator.is_empty() { " " } else { separator };
        self.field(value, path)
            .split(separator)
            .filter(|t| !t.is_empty())
            .map(|t| t.to_string())
            .collect()
    }

    /// Whether this row is adult by the source's own rating.
    fn rated_nsfw(&self, row: &serde_json::Value) -> bool {
        let map = &self.manifest.map;
        if map.rating.is_empty() || map.nsfw_ratings.is_empty() {
            return false;
        }
        self.values(row, &map.rating, &map.tags_separator)
            .iter()
            .any(|value| map.nsfw_ratings.iter().any(|r| r.eq_ignore_ascii_case(value.trim())))
    }
}

/// One field out of one element: an attribute or the text, optionally cut down
/// by a pattern, and made absolute unless it is a fragment rather than a link.
fn read_html(
    element: scraper::ElementRef,
    field: &HtmlField,
    pattern: Option<&regex::Regex>,
    base: &str,
) -> String {
    let mut value = match field.attr.is_empty() {
        true => element.text().collect::<String>().split_whitespace().collect::<Vec<_>>().join(" "),
        false => element.value().attr(&field.attr).unwrap_or_default().to_string(),
    };

    if let Some(re) = pattern {
        value = re
            .captures(&value)
            .and_then(|caught| caught.get(1).or_else(|| caught.get(0)))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
    }

    /*
     * A PATTERN USUALLY MEANS "A FRAGMENT", BUT `//host/path` IS NEVER ONE.
     *
     * `pattern.is_none()` is the right default: a regex on an attribute is
     * normally pulling an id or a count out of some prose, and resolving that
     * against the base would invent a URL out of a number.
     *
     * A PROTOCOL-RELATIVE value is the exception, and it is unambiguous — no
     * id, tag or count ever begins with two slashes. hqporner's thumbnail is
     * read by regex out of an `onmouseleave` handler and arrives as
     * `//fastporndelivery.hqporner.com/imgs/...`; with no scheme the HTTP
     * client cannot even build a request ("http: builder error"), so all 6,259
     * of its rows drew as empty frames with nothing in any log to say why.
     */
    let protocol_relative = value.starts_with("//");
    let linkish = (pattern.is_none() || protocol_relative) && (LINK_ATTRS.contains(&field.attr.as_str()) || protocol_relative);
    if !value.is_empty() && field.abs.unwrap_or(linkish) {
        value = scrape::abs_url(base, &value).unwrap_or(value);
    }
    value
}

/// `scrape::json_pluck`, plus indices counted from the end (`links[-1]`).
fn pluck<'a>(value: &'a serde_json::Value, path: &str) -> Option<&'a serde_json::Value> {
    let Some(at) = path.find("[-") else {
        return scrape::json_pluck(value, path);
    };
    let close = at + path[at..].find(']')?;
    let back: usize = path[at + 2..close].parse().ok()?;
    let list = scrape::json_pluck(value, &path[..at])?.as_array()?;
    let item = list.get(list.len().checked_sub(back)?)?;
    let rest = &path[close + 1..];
    let rest = rest.strip_prefix('.').unwrap_or(rest);
    if rest.is_empty() { Some(item) } else { pluck(item, rest) }
}

/// A JSON scalar as text, the way `scrape::json_str` reads one.
fn scalar(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

impl Source for Declarative {
    fn id(&self) -> &'static str {
        self.id
    }

    fn category(&self) -> &'static str {
        // Leaked deliberately and exactly once per source: the trait returns a
        // &'static str because every other implementation is a literal, and a
        // manifest's category is read once at startup and lives as long as the
        // process either way.
        match self.manifest.category.as_str() {
            "" if self.manifest.adult => "adult",
            "" => "art",
            other => Box::leak(other.to_string().into_boxed_str()),
        }
    }

    fn page_tags(&self, html: &str) -> Vec<String> {
        self.manifest.page_tags.as_ref().map(|spec| spec.read(html)).unwrap_or_default()
    }

    fn sections(&self) -> Vec<(String, String, String, bool)> {
        let mut out: Vec<(String, String, String, bool)> = self
            .manifest
            .sections
            .iter()
            .map(|s| (s.group.clone(), s.label.clone(), s.query(), s.adult))
            .collect();
        if self.manifest.sections_from.is_empty() {
            return out;
        }
        let id = self.manifest.id.clone();
        let fresh = {
            let held = FETCHED_SECTIONS.lock().unwrap_or_else(|e| e.into_inner());
            held.as_ref().and_then(|m| m.get(&id)).map(|(at, rows)| (at.elapsed() < std::time::Duration::from_secs(24 * 3600), rows.clone()))
        };
        if let Some((_, rows)) = &fresh {
            let mut seen: std::collections::HashSet<(String, String)> =
                out.iter().map(|(g, l, _, _)| (g.to_lowercase(), l.to_lowercase())).collect();
            for (group, label, adult) in rows {
                if seen.insert((group.to_lowercase(), label.to_lowercase())) {
                    out.push((group.clone(), label.clone(), label.clone(), *adult));
                }
            }
        }
        // Missing or a day old: fetch in the background, never on this call.
        if !fresh.is_some_and(|(ok, _)| ok) && !cfg!(test) {
            let mut busy = FETCHING_SECTIONS.lock().unwrap_or_else(|e| e.into_inner());
            if busy.get_or_insert_with(Default::default).insert(id.clone()) {
                let specs = self.manifest.sections_from.clone();
                std::thread::spawn(move || {
                    let mut rows = Vec::new();
                    for spec in &specs {
                        let Ok(body) = super::prefetch::get(&spec.url) else { continue };
                        let group = if spec.group.is_empty() { "Categories".to_string() } else { spec.group.clone() };
                        rows.extend(spec.names(&body).into_iter().map(|n| (group.clone(), n, spec.adult)));
                    }
                    // A failure is tried again in an hour, not on every call:
                    // it is stamped 23 hours old.
                    let now = std::time::Instant::now();
                    let at = if rows.is_empty() { now.checked_sub(std::time::Duration::from_secs(23 * 3600)).unwrap_or(now) } else { now };
                    let mut held = FETCHED_SECTIONS.lock().unwrap_or_else(|e| e.into_inner());
                    let map = held.get_or_insert_with(Default::default);
                    // An empty answer never replaces a list that worked.
                    if !rows.is_empty() || !map.contains_key(&id) {
                        map.insert(id.clone(), (at, rows));
                    }
                    drop(held);
                    if let Some(set) = FETCHING_SECTIONS.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
                        set.remove(&id);
                    }
                });
            }
        }
        out
    }

    fn capabilities(&self) -> Capabilities {
        let caps = &self.manifest.capabilities;
        Capabilities {
            text: caps.text,
            tags: caps.tags,
            min_size: caps.min_size,
            ratio: caps.ratio,
            // A manifest that names both rating tags can be asked either way.
            nsfw: caps.nsfw
                || (!self.manifest.request.sfw_tag.is_empty()
                    && !self.manifest.request.nsfw_tag.is_empty()),
            // Declared, or evident: a manifest with a sort table can be asked.
            sort: caps.sort || !self.manifest.request.sort.is_empty(),
            // A manifest that names a video tag can be asked for video.
            video: !self.manifest.request.video_tag.is_empty(),
            colors: false,
            // Declared, or evident: a manifest that names a creator in its URL
            // or its tag vocabulary can be asked for one.
            author: caps.author
                || !self.manifest.request.author_tag.is_empty()
                || self.manifest.request.url.contains("{author}"),
            // Evident, like the others: a URL with a `{category}` slot and a
            // Categories section list is a source that can be asked for one.
            categories: self.declared_categories(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        let request = &self.manifest.request;

        let mut terms: Vec<String> = query.text.clone();
        terms.extend(query.tags.clone());
        if query.wants_video == Some(true) && !request.video_tag.is_empty() {
            terms.push(request.video_tag.clone());
        }
        let joiner = if request.joiner.is_empty() { " " } else { request.joiner.as_str() };
        let joined = if terms.is_empty() {
            request.browse_term.clone()
        } else {
            terms.join(joiner)
        };

        // A tag board resolves typed words to its own tags first.
        let (mut query_value, mut tags_value) =
            super::tag_resolve::for_manifest(&request.tag_resolver, &request.url, query, &request.video_tag)
                .unwrap_or_else(|| (joined.clone(), joined.replace(' ', "_")));

        // The rating, pushed down in the site's own words — appended after
        // resolution, because it is already a real tag and has nothing to
        // look up. With no other term it rides on the browse term, which is
        // what keeps `-nsfw` on the home feed from being a page of rows
        // filtered away locally.
        let rating_tag = match query.allow_nsfw {
            Some(false) => request.sfw_tag.as_str(),
            Some(true) => request.nsfw_tag.as_str(),
            None => "",
        };
        // The creator, for a board that spells it as a tag. Appended here for
        // the same reason the rating is: a tag resolver rebuilds the term list
        // from the query's own words and would drop anything added before it.
        let author_tag = if query.author.is_empty() || request.author_tag.is_empty() {
            String::new()
        } else {
            request.author_tag.replace("{author}", &query.author)
        };
        for extra in [rating_tag, author_tag.as_str()] {
            if extra.is_empty() {
                continue;
            }
            for (value, glue) in [(&mut query_value, joiner), (&mut tags_value, " ")] {
                *value = if value.is_empty() {
                    extra.to_string()
                } else {
                    format!("{value}{glue}{extra}")
                };
            }
        }

        let page = query.page.max(1);
        let limit = request.limit.max(1);

        // The site's own word for this ordering; `default` when the query did
        // not ask, and nothing at all when the manifest has no table.
        let sort_value = if request.sort.is_empty() {
            String::new()
        } else {
            let asked = crate::query::sort_name(query.sort);
            request
                .sort
                .get(asked)
                .or_else(|| request.sort.get("default"))
                .cloned()
                .unwrap_or_default()
        };

        // Past the end of the list the source has nothing more to say, and
        // saying it again would be duplicate rows rather than a next page.
        let page_value = if request.page_values.is_empty() {
            String::new()
        } else {
            request.page_values[(page as usize - 1) % request.page_values.len()].clone()
        };

        let mut url = request.url.clone();
        // `+` for a space, unless the manifest asks for another spelling.
        let encode = |text: &str| match request.space.as_str() {
            "" => scrape::urlencode(text),
            space => scrape::urlencode(text).replace('+', space),
        };

        for (token, value) in [
            ("{query}", encode(&query_value)),
            ("{tags}", encode(&tags_value)),
            // Empty is a plain browse on every site that has this parameter —
            // probed on pornhub 2026-09-28: `category=` alone returns 30 rows.
            ("{category}", encode(&query.category)),
            ("{page}", page.to_string()),
            ("{page0}", (page - 1).to_string()),
            ("{offset}", ((page - 1) * limit).to_string()),
            ("{limit}", limit.to_string()),
            ("{sort}", encode_sort(&sort_value, &encode)),
            ("{author}", encode(&query.author)),
            ("{minw}", query.min_w.to_string()),
            ("{minh}", query.min_h.to_string()),
            ("{page_value}", page_value),
        ] {
            url = url.replace(token, &value);
        }
        // The credential pair, resolved once at load time — not a token in
        // `request.url` itself, since `[auth]` is about whether the source
        // exists at all, not one more substitution among the rest.
        url.push_str(&self.auth_query);
        url
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        // Several boards answer "no posts" with an empty body rather than `[]`
        // (hypnohub, safebooru past the last page) — that is zero rows, not a
        // parse failure that marks the source as failing.
        if body.trim().is_empty() {
            return Ok(Vec::new());
        }

        if self.manifest.request.format == "html" {
            return Ok(self.items(&self.html_rows(body)?));
        }

        // RSS is common enough among these to be worth handling directly rather
        // than making every feed source native.
        if self.manifest.request.format == "rss" {
            let feed = scrape::parse_rss(body).map_err(|e| e.to_string())?;
            return Ok(feed
                .into_iter()
                .filter(|row| !row.media_url.is_empty())
                .map(|row| {
                    let mut item = scrape::normalize(
                        self.id,
                        &row.link,
                        &row.title,
                        &row.media_url,
                        &row.thumb_url,
                        &row.link,
                        row.width,
                        row.height,
                        Vec::new(),
                    );
                    item.author = row.author;
                    self.stamp(&mut item);
                    item
                })
                .collect());
        }

        let document: serde_json::Value =
            serde_json::from_str(body).map_err(|e| format!("{}: {e}", self.id))?;

        let found = if self.manifest.request.root.is_empty() {
            Some(&document)
        } else {
            scrape::json_pluck(&document, &self.manifest.request.root)
        };

        /*
         * An array, or an object whose values are the rows.
         *
         * MediaWiki answers with `query.pages` keyed by page id rather than as
         * a list, and it is not alone — an id-keyed map is a common shape for
         * an API that expects to be merged into a client-side store. Refusing
         * it would mean a hand-written adapter for a source whose mapping is
         * otherwise three lines.
         */
        let rows: Vec<serde_json::Value> = match found {
            Some(serde_json::Value::Array(rows)) => rows.clone(),
            /*
             * THE KEY IS USUALLY THE ID.
             *
             * An id-keyed map puts the row's identity in the KEY, and the
             * mapper could only see values — so a source whose rows are
             * `{"730": {"name": "…"}}` had a name and no id, and was
             * unmappable however simple it looked. Each row gets its key back
             * as `_key`, which a manifest asks for like any other field:
             *
             *   id = "_key"
             *   url = "https://…/{_key}/header.jpg"
             */
            Some(serde_json::Value::Object(map)) => map
                .iter()
                .map(|(key, value)| match value {
                    serde_json::Value::Object(fields) => {
                        let mut row = fields.clone();
                        row.entry("_key".to_string())
                            .or_insert_with(|| serde_json::Value::String(key.clone()));
                        serde_json::Value::Object(row)
                    }
                    other => other.clone(),
                })
                .collect(),
            _ => Vec::new(),
        };

        Ok(self.items(&rows))
    }

    fn has_more(&self, body: &str) -> bool {
        // A "next page" link is what the site itself says; everything else
        // pages until a response comes back with no rows.
        if let Some(spec) = self.manifest.html.as_ref().filter(|s| !s.next.is_empty()) {
            return scraper::Selector::parse(&spec.next)
                .map(|sel| scraper::Html::parse_document(body).select(&sel).next().is_some())
                .unwrap_or(false);
        }
        self.parse(body).map(|rows| !rows.is_empty()).unwrap_or(false)
    }

    fn has_more_after(&self, body: &str, rows: usize) -> bool {
        if self.manifest.html.as_ref().is_some_and(|s| !s.next.is_empty()) {
            return self.has_more(body);
        }
        rows > 0
    }

    /// How many pages this source has, where that is a fixed number.
    ///
    /// Only sources paged by a list know this; everything else pages until a
    /// response comes back empty.
    fn page_limit(&self) -> Option<u32> {
        let values = &self.manifest.request.page_values;
        (!values.is_empty()).then(|| values.len() as u32)
    }
}

impl Declarative {
    /// Rows — from JSON or from HTML, which by here look the same — as items.
    fn items(&self, rows: &[serde_json::Value]) -> Vec<Item> {
        let map = &self.manifest.map;
        rows.iter()
            .filter_map(|row| {
                let url = self.field(row, &map.url);
                let id = self.field(row, &map.id);
                if url.is_empty() || id.is_empty() {
                    return None;
                }

                let width = self.field(row, &map.width).parse().unwrap_or(0);
                let height = self.field(row, &map.height).parse().unwrap_or(0);

                // A list or a delimited string — Philomena's tags are an
                // array, and read as a string they were silently nothing.
                let mut tags = self.values(row, &map.tags, &map.tags_separator);
                tags.truncate(8);

                let mut item = scrape::normalize(
                    self.id,
                    &id,
                    &self.field(row, &map.title),
                    &url,
                    &self.field(row, &map.thumb),
                    &self.field(row, &map.page_url),
                    width,
                    height,
                    tags,
                );
                // Before `stamp`, which reads the family back off the extension.
                self.restate_ext(row, &mut item);
                item.author = self.field(row, &map.author);
                item.license = self.field(row, &map.license);
                item.sample = self.field(row, &map.sample);
                item.duration = if !map.duration_clock.is_empty() {
                    parse_clock(&self.field(row, &map.duration_clock))
                } else if !map.duration_ms.is_empty() {
                    self.field(row, &map.duration_ms).parse().unwrap_or(0.0) / 1000.0
                } else {
                    self.field(row, &map.duration).parse().unwrap_or(0.0)
                };
                item.bytes = self.field(row, &map.bytes).parse().unwrap_or(0);
                self.stamp(&mut item);
                if self.rated_nsfw(row) {
                    item.nsfw = true;
                }
                Some(item)
            })
            .collect()
    }

    /// Take the file type from the row rather than from the URL, where the
    /// manifest names a field for it. `image/jpeg`, `.jpg` and `jpg` all mean
    /// the same thing here.
    fn restate_ext(&self, row: &serde_json::Value, item: &mut Item) {
        let stated = self.field(row, &self.manifest.map.ext);
        let stated = stated.rsplit('/').next().unwrap_or_default().trim_start_matches('.');
        if stated.is_empty() {
            return;
        }
        item.ext = match stated.to_ascii_lowercase().as_str() {
            "jpeg" => "jpg".to_string(),
            other => other.to_string(),
        };
        item.family = scrape::infer_family(&item.ext).to_string();
        item.kind = scrape::infer_kind(item.w, item.h, &item.family).to_string();
        item.animated = item.ext == "gif" || item.family == "video";
    }

    /// One flat object per listing row, ready for `[map]` to read.
    fn html_rows(&self, body: &str) -> Result<Vec<serde_json::Value>, String> {
        let spec = self
            .manifest
            .html
            .as_ref()
            .ok_or_else(|| format!("{}: format = \"html\" needs an [html] section", self.id))?;
        let blame = |what: &str, e: String| format!("{}: {what}: {e}", self.id);

        let document = scraper::Html::parse_document(body);
        let row_selector = scraper::Selector::parse(&spec.row)
            .map_err(|e| blame("[html].row", format!("{e:?}")))?;

        // Selectors and patterns are compiled once for the page, not per row.
        let mut fields = Vec::with_capacity(spec.fields.len());
        for (name, field) in &spec.fields {
            let selector = match field.sel.is_empty() {
                true => None,
                false => Some(
                    scraper::Selector::parse(&field.sel)
                        .map_err(|e| blame(&format!("[html.fields].{name}"), format!("{e:?}")))?,
                ),
            };
            let pattern = match field.pattern.is_empty() {
                true => None,
                false => Some(
                    regex::Regex::new(&field.pattern)
                        .map_err(|e| blame(&format!("[html.fields].{name}"), e.to_string()))?,
                ),
            };
            fields.push((name, field, selector, pattern));
        }

        let base = match spec.base.is_empty() {
            true => self.manifest.request.url.split('{').next().unwrap_or_default(),
            false => spec.base.as_str(),
        };

        Ok(document
            .select(&row_selector)
            .map(|row| {
                let mut object = serde_json::Map::new();
                for (name, field, selector, pattern) in &fields {
                    let mut values: Vec<String> = match selector {
                        Some(sel) => row
                            .select(sel)
                            .map(|el| read_html(el, field, pattern.as_ref(), base))
                            .collect(),
                        None => vec![read_html(row, field, pattern.as_ref(), base)],
                    };
                    values.retain(|value| !value.is_empty());
                    if field.all {
                        object.insert(
                            (*name).clone(),
                            values.into_iter().map(serde_json::Value::String).collect(),
                        );
                    } else if let Some(value) = values.into_iter().next() {
                        object.insert((*name).clone(), serde_json::Value::String(value));
                    }
                }
                serde_json::Value::Object(object)
            })
            .collect())
    }

    /// Apply the manifest's own opinions, which beat anything inferred from
    /// shape: a source that only publishes icons knows that better than a
    /// ratio does.
    fn stamp(&self, item: &mut Item) {
        if !self.manifest.kind.is_empty() {
            item.kind = self.manifest.kind.clone();
        }
        if !self.manifest.family.is_empty() {
            // A manifest naming a family means "these are all X" — but a board
            // that serves both pictures and video has rows of two families,
            // and the file extension is the one that knows which. So a
            // declared family is a default for rows the extension could not
            // place, never an override of one it could.
            let inferred = crate::scrape::infer_family(&item.ext);
            if inferred == "raster" {
                item.family = self.manifest.family.clone();
            }
            item.tintable = item.family == "vector";
        }
        if self.manifest.adult {
            item.nsfw = true;
        }
    }
}

#[cfg(test)]
mod tests {
    /*
     * `gelbooru-page.json` WAS RECONSTRUCTED, NOT CAPTURED.
     *
     * The live dapi endpoint 401s with an empty body without a key (checked
     * with a manual curl — see TASKS.md item 8), so there is no real response
     * to save. The fixture below is built from Gelbooru's documented
     * `post` row shape instead. It proves the parser reads that shape
     * correctly; it does not prove the shape itself is still current.
     * Replace it with a real capture the first time someone runs this with
     * an actual key.
     */

    use super::*;

    const GELBOORU_TOML: &str = include_str!("../../../sources/gelbooru.toml");

    pub(super) fn manifest(text: &str) -> Manifest {
        toml::from_str(text).expect("valid manifest")
    }

    pub(super) fn declarative(manifest: Manifest, auth_query: &str) -> Declarative {
        let id: &'static str = Box::leak(manifest.id.clone().into_boxed_str());
        Declarative { manifest, id, auth_query: auth_query.to_string() }
    }

    #[test]
    fn resolve_auth_reports_every_missing_var_by_name() {
        let auth = Auth {
            vars: vec!["GELBOORU_USER_ID".into(), "GELBOORU_API_KEY".into()],
            query: "&user_id={GELBOORU_USER_ID}&api_key={GELBOORU_API_KEY}".into(),
            hint: "https://example.com".into(),
        };
        let missing = resolve_auth(&auth, |_| None).unwrap_err();
        assert_eq!(missing, vec!["GELBOORU_USER_ID", "GELBOORU_API_KEY"]);
    }

    #[test]
    fn resolve_auth_treats_a_blank_value_as_missing() {
        // A leftover `export FOO=` from a half-finished setup must not read
        // as "configured".
        let auth = Auth {
            vars: vec!["GELBOORU_API_KEY".into()],
            query: String::new(),
            hint: String::new(),
        };
        assert!(resolve_auth(&auth, |_| Some("   ".to_string())).is_err());
    }

    #[test]
    fn resolve_auth_fills_the_template_and_urlencodes_the_values() {
        let auth = Auth {
            vars: vec!["GELBOORU_USER_ID".into(), "GELBOORU_API_KEY".into()],
            query: "&user_id={GELBOORU_USER_ID}&api_key={GELBOORU_API_KEY}".into(),
            hint: String::new(),
        };
        let get = |name: &str| match name {
            "GELBOORU_USER_ID" => Some("123".to_string()),
            "GELBOORU_API_KEY" => Some("has spaces".to_string()),
            _ => None,
        };
        let query = resolve_auth(&auth, get).expect("both vars are set");
        assert_eq!(query, "&user_id=123&api_key=has+spaces");
    }

    #[test]
    fn gelbooru_manifest_declares_auth_and_a_zero_based_page() {
        let m = manifest(GELBOORU_TOML);
        let auth = m.auth.as_ref().expect("gelbooru needs [auth] to load at all");
        assert_eq!(auth.vars, vec!["GELBOORU_USER_ID", "GELBOORU_API_KEY"]);
        assert!(!auth.hint.is_empty(), "a missing var must say where to get one");
        // pid is zero-based here, unlike Moebooru's one-based page — `{page0}`
        // already exists in `build_url` for exactly this.
        assert!(m.request.url.contains("pid={page0}"), "{}", m.request.url);
        assert_eq!(m.request.root, "post");
    }

    #[test]
    fn gelbooru_build_url_appends_the_resolved_credentials() {
        let source = declarative(manifest(GELBOORU_TOML), "&user_id=1&api_key=xyz");
        let query = SourceQuery { text: vec!["cat".into()], page: 2, ..Default::default() };
        let url = source.build_url(&query);
        assert!(url.contains("pid=1"), "page 2 should be pid 1 (zero-based): {url}");
        assert!(url.ends_with("&user_id=1&api_key=xyz"), "{url}");
    }

    #[test]
    fn gelbooru_parses_a_reconstructed_response() {
        let source = declarative(manifest(GELBOORU_TOML), "");
        let body = include_str!("../../tests/fixtures/gelbooru-page.json");
        let items = source.parse(body).expect("parses");
        assert_eq!(items.len(), 2);

        let first = &items[0];
        assert_eq!(first.source, "gelbooru");
        assert!(first.url.starts_with("https://"));
        assert!(!first.thumb.is_empty());
        assert_eq!((first.w, first.h), (1920, 1080));
        assert!(first.tags.contains(&"1girl".to_string()), "{:?}", first.tags);
        // The manifest now maps `sample`, so the fixture's sample_url must
        // survive the parse rather than being left on the floor.
        assert_eq!(first.sample, "https://img3.gelbooru.com/images/aa/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg");
    }

    // ── ratings, rating pushdown, templates, and the shipped set ────────────
    //
    // Every body below is synthetic: neutral tags (`tag_a`), example.com
    // hosts, no captured rows. They pin the SHAPE each manifest reads, which
    // is what these tests are for; `doctor` is what checks the live site.

    const KONACHAN_TOML: &str = include_str!("../../../sources/konachan.toml");
    const TANTABUS_TOML: &str = include_str!("../../../sources/tantabus.toml");
    const NASA_TOML: &str = include_str!("../../../sources/nasa.toml");
    const INATURALIST_TOML: &str = include_str!("../../../sources/inaturalist.toml");
    const EMOJIGG_TOML: &str = include_str!("../../../sources/emojigg.toml");
    const SVGL_TOML: &str = include_str!("../../../sources/svgl.toml");

    // ── listings read as HTML ───────────────────────────────────────────────
    //
    // Both fixtures are written by hand: neutral tags (`tag_a`), example.test
    // hosts, nothing captured from a live board.

    const PAHEAL_TOML: &str = include_str!("../../../sources/paheal.toml");
    const LEFTY_TOML: &str = include_str!("../../../sources/lefty.toml");
    const DIV_ROW: &str = include_str!("../../tests/fixtures/shimmie-div-row.html");
    const ANCHOR_ROW: &str = include_str!("../../tests/fixtures/shimmie-anchor-row.html");

    /// A manifest exercising the parts of `[html]` no shipped board needs all
    /// of at once: text, a list field, a pattern, and `abs` both ways.
    const HTML_TOML: &str = r#"
id = "example"
[request]
url = "https://example.test/list/{query}/{page}"
format = "html"
space = "%20"
[html]
row = "li.row"
next = "a.next"
[html.fields]
id = { attr = "data-id" }
thumb = { sel = "img", attr = "src" }
hash = { sel = "img", attr = "src", re = "/thumbs/([^/]+)/" }
title = { sel = "h3" }
tags = { sel = "a.tag", all = true }
here = { sel = "a.post", attr = "href", abs = false }
[map]
id = "id"
url = "https://example.test/files/{hash}.jpg"
thumb = "thumb"
title = "title"
tags = "tags"
page_url = "https://example.test{here}"
"#;

    const HTML_BODY: &str = r#"<!doctype html><html><body>
<ul>
  <li class="row" data-id="7">
    <a class="post" href="/post/7"><img src="/thumbs/abc123/t.jpg"></a>
    <h3>  A   title  </h3>
    <a class="tag" href="/t/tag_a">tag_a</a> <a class="tag" href="/t/tag_b">tag_b</a>
  </li>
  <li class="row" data-id="8">
    <a class="post" href="/post/8"><img src="//cdn.example.test/thumbs/def456/t.jpg"></a>
    <h3>Another</h3>
  </li>
  <li class="row"><span>no id, no link</span></li>
</ul>
<a class="next" href="/list//2">Next</a>
</body></html>"#;

    #[test]
    fn html_fields_read_attributes_text_lists_and_patterns() {
        let source = declarative(manifest(HTML_TOML), "");
        let items = source.parse(HTML_BODY).expect("parses");

        // The third row has neither id nor a resolvable url, so it is dropped
        // rather than becoming a row that points nowhere.
        assert_eq!(items.len(), 2);

        let first = &items[0];
        assert_eq!(first.source_id, "7");
        assert_eq!(first.url, "https://example.test/files/abc123.jpg", "pattern, not the whole src");
        assert_eq!(first.thumb, "https://example.test/thumbs/abc123/t.jpg", "made absolute");
        assert_eq!(first.title, "A title", "text, with the whitespace collapsed");
        assert_eq!(first.tags, vec!["tag_a", "tag_b"], "`all` keeps every match");
        // `abs = false` is what lets a manifest build its own link from a path.
        assert_eq!(first.page_url, "https://example.test/post/7");

        // A protocol-relative src takes the page's scheme.
        assert_eq!(items[1].thumb, "https://cdn.example.test/thumbs/def456/t.jpg");
        assert!(items[1].tags.is_empty(), "a field with no match is simply absent");
    }

    #[test]
    fn html_has_more_follows_the_next_link() {
        let source = declarative(manifest(HTML_TOML), "");
        assert!(source.has_more(HTML_BODY));
        // Rows but no next link is the last page — which "the page had rows"
        // could never tell you.
        let last = HTML_BODY.replace(r#"<a class="next" href="/list//2">Next</a>"#, "");
        assert!(!source.has_more(&last));
        assert_eq!(source.parse(&last).expect("parses").len(), 2, "still a full page of rows");
    }

    #[test]
    fn html_search_terms_are_joined_the_way_the_path_needs() {
        let source = declarative(manifest(HTML_TOML), "");
        let query = SourceQuery { text: vec!["tag_a".into(), "tag_b".into()], page: 2, ..Default::default() };
        // "+" in a path segment is a literal plus, and these boards 404 on it.
        assert_eq!(source.build_url(&query), "https://example.test/list/tag_a%20tag_b/2");
        let browse = SourceQuery { page: 3, ..Default::default() };
        assert_eq!(source.build_url(&browse), "https://example.test/list//3");
    }

    #[test]
    fn a_bad_selector_is_named_rather_than_silently_returning_nothing() {
        let mut broken = manifest(HTML_TOML);
        broken.html.as_mut().expect("[html]").row = "li..row".into();
        let error = declarative(broken, "").parse(HTML_BODY).unwrap_err();
        assert!(error.contains("[html].row"), "{error}");

        let mut missing = manifest(HTML_TOML);
        missing.html = None;
        let error = declarative(missing, "").parse(HTML_BODY).unwrap_err();
        assert!(error.contains("[html] section"), "{error}");
    }

    #[test]
    fn paheal_takes_the_file_link_and_the_type_the_row_states() {
        let source = declarative(manifest(PAHEAL_TOML), "");
        let items = source.parse(DIV_ROW).expect("parses");
        assert_eq!(items.len(), 3);

        let first = &items[0];
        assert_eq!(first.source_id, "101");
        assert_eq!(first.url, "https://files.example.test/aa/b1/1111111111111111");
        assert_eq!(first.thumb, "https://thumbs.example.test/aa/b1/1111111111111111");
        assert_eq!(first.page_url, "https://rule34.paheal.net/post/view/101");
        assert_eq!(first.tags, vec!["tag_a", "tag_b"]);
        // The file URL carries no extension at all, so `map.ext` is the only
        // thing that knows a still from a video.
        assert_eq!((first.ext.as_str(), first.family.as_str()), ("jpg", "raster"));
        assert_eq!((items[1].ext.as_str(), items[1].family.as_str()), ("mp4", "video"));
        assert!(items[1].animated);
        assert!(items.iter().all(|i| i.nsfw), "the board has no rating of its own");
    }

    #[test]
    fn an_anchor_row_board_builds_its_file_url_and_marks_by_rating() {
        let source = declarative(manifest(LEFTY_TOML), "");
        let items = source.parse(ANCHOR_ROW).expect("parses");
        assert_eq!(items.len(), 3);

        let first = &items[0];
        assert_eq!(first.url, "https://lefty.pictures/_images/1111111111111111/201.jpeg");
        assert_eq!(first.thumb, "https://lefty.pictures/_thumbs/1111111111111111/thumb.jpg");
        assert_eq!((first.w, first.h), (800, 600), "the row states its own size");
        assert_eq!(first.ext, "jpg", "a MIME type reads as an extension");
        assert_eq!(first.page_url, "https://lefty.pictures/post/view/201");

        assert_eq!(items[1].family, "video");
        assert!(items[1].url.ends_with(".mp4"));
        /*
         * EVERY ROW OF AN ADULT SOURCE IS ADULT, WHATEVER THE ROW SAYS.
         *
         * This board rates its posts s / e / q and once carried that through, so a
         * safe-rated post from an adult board arrived flagged safe — and stayed on
         * screen with adult content switched off.
         *
         * The switch has to mean "none of this", and a mixed board in the adult
         * category is still an adult board: its safe pictures sit one click from
         * the rest of it, and the per-row rating is the site's opinion of its own
         * content rather than a promise to anybody. `lefty` declares
         * `category = "adult"`, so `stamp` marks the lot.
         *
         * The rating still decides on its own for sources that are NOT adult —
         * that is what `rated_nsfw` is for, and what the danbooru fixtures cover.
         */
        assert_eq!(
            items.iter().map(|i| i.nsfw).collect::<Vec<_>>(),
            vec![true, true, true],
            "an adult board's rows are adult, including the one it rates safe"
        );
        assert_eq!(items[2].thumb, "https://cdn.example.test/_thumbs/3333333333333333/thumb.jpg");
    }

    #[test]
    fn a_mixed_board_marks_each_row_by_its_own_rating() {
        let source = declarative(manifest(KONACHAN_TOML), "");
        let body = r#"[
            {"id": 1, "file_url": "https://img.example/a.jpg", "width": 100, "height": 50, "rating": "s", "tags": "tag_a tag_b"},
            {"id": 2, "file_url": "https://img.example/b.jpg", "width": 100, "height": 50, "rating": "q", "tags": "tag_a"},
            {"id": 3, "file_url": "https://img.example/c.jpg", "width": 100, "height": 50, "rating": "E", "tags": "tag_c"},
            {"id": 4, "file_url": "https://img.example/d.jpg", "width": 100, "height": 50, "tags": "tag_d"}
        ]"#;
        let items = source.parse(body).expect("parses");
        let marked: Vec<bool> = items.iter().map(|i| i.nsfw).collect();
        // Compared case-insensitively; an absent rating marks nothing.
        assert_eq!(marked, vec![false, true, true, false]);
        // Each row links to its own post, not to the listing.
        assert_eq!(items[0].page_url, "https://konachan.com/post/show/1");
        assert_eq!(items[2].page_url, "https://konachan.com/post/show/3");
    }

    #[test]
    fn rating_tags_turn_the_capability_on_and_ride_on_the_browse_term() {
        let moebooru = declarative(manifest(KONACHAN_TOML), "");
        assert!(moebooru.capabilities().nsfw, "both rating tags present");

        let safe = SourceQuery { allow_nsfw: Some(false), page: 1, ..Default::default() };
        assert!(moebooru.build_url(&safe).ends_with("tags=rating%3As"), "{}", moebooru.build_url(&safe));
        let adult = SourceQuery { allow_nsfw: Some(true), page: 1, ..Default::default() };
        assert!(moebooru.build_url(&adult).ends_with("tags=-rating%3As"), "{}", moebooru.build_url(&adult));
        let unsaid = SourceQuery { page: 1, ..Default::default() };
        assert!(moebooru.build_url(&unsaid).ends_with("tags="), "{}", moebooru.build_url(&unsaid));

        // Philomena: the browse term stays, and the comma joins — a space
        // there would make `* safe` one tag nobody has.
        let philomena = declarative(manifest(TANTABUS_TOML), "");
        assert!(philomena.build_url(&safe).contains("q=%2A%2Csafe&"), "{}", philomena.build_url(&safe));
        assert!(philomena.build_url(&unsaid).contains("q=%2A&"), "{}", philomena.build_url(&unsaid));

        // One tag without the other is not a capability.
        let mut half = manifest(KONACHAN_TOML);
        half.request.nsfw_tag.clear();
        assert!(!declarative(half, "").capabilities().nsfw);
    }

    #[test]
    fn philomena_reads_tags_and_rating_from_the_tag_array() {
        let source = declarative(manifest(TANTABUS_TOML), "");
        let body = r#"{"images": [
            {"id": 10, "width": 800, "height": 600, "tags": ["safe", "tag_a", "tag_b"],
             "representations": {"full": "https://img.example/10.png", "thumb": "https://img.example/10t.png"}},
            {"id": 11, "width": 800, "height": 600, "tags": ["tag_a", "explicit"],
             "representations": {"full": "https://img.example/11.png", "thumb": "https://img.example/11t.png"}}
        ], "total": 2}"#;
        let items = source.parse(body).expect("parses");
        assert_eq!(items.len(), 2);
        // Read as a string, an array was silently no tags at all.
        assert_eq!(items[0].tags, vec!["safe", "tag_a", "tag_b"]);
        assert_eq!((items[0].nsfw, items[1].nsfw), (false, true));
        assert_eq!(items[1].page_url, "https://tantabus.ai/images/11");
    }

    #[test]
    fn templates_take_alternatives_filters_and_indices_from_the_end() {
        let source = declarative(manifest(KONACHAN_TOML), "");
        let row: serde_json::Value = serde_json::from_str(
            r#"{"links": [{"href": "https://img.example/x~small.jpg", "width": 64},
                          {"href": "https://img.example/x~orig.tif", "width": 4096}],
                "route": {"light": "https://img.example/l.svg", "dark": "https://img.example/d.svg"},
                "photo": "https://img.example/photos/9/square.jpeg",
                "n": 7}"#,
        )
        .unwrap();

        assert_eq!(source.field(&row, "links[-1].href"), "https://img.example/x~orig.tif");
        assert_eq!(source.field(&row, "links[-1].width"), "4096");
        assert_eq!(source.field(&row, "links[-2].width"), "64");
        assert_eq!(source.field(&row, "links[-3].width"), "", "past the front is nothing");
        assert_eq!(source.field(&row, "route || route.dark"), "https://img.example/d.svg");
        assert_eq!(source.field(&row, "missing || =fallback"), "fallback");
        assert_eq!(
            source.field(&row, "{photo|replace:/square.:/original.}"),
            "https://img.example/photos/9/original.jpeg"
        );
        assert_eq!(source.field(&row, "https://x.example/{n}/{links[-1].width}"), "https://x.example/7/4096");
        // A filter nobody knows must not quietly produce a different URL.
        assert_eq!(source.field(&row, "{photo|upper}"), "");
    }

    #[test]
    fn nasa_takes_the_original_from_the_last_rendition() {
        let source = declarative(manifest(NASA_TOML), "");
        let body = r#"{"collection": {"items": [
            {"data": [{"nasa_id": "ID1", "title": "Title A", "center": "C1", "keywords": ["tag_a", "tag_b"]}],
             "links": [
                {"href": "https://images-assets.example/ID1~medium.jpg", "rel": "alternate", "width": 1280, "height": 640},
                {"href": "https://images-assets.example/ID1~thumb.jpg", "rel": "preview", "width": 640, "height": 320},
                {"href": "https://images-assets.example/ID1~orig.png", "rel": "canonical", "width": 2800, "height": 1400}
             ]}
        ]}}"#;
        let items = source.parse(body).expect("parses");
        assert_eq!(items.len(), 1);
        let item = &items[0];
        assert_eq!(item.url, "https://images-assets.example/ID1~orig.png");
        assert_eq!((item.w, item.h), (2800, 1400));
        assert_eq!(item.author, "C1", "photographer, then secondary creator, then centre");
        assert_eq!(item.tags, vec!["tag_a", "tag_b"]);
        assert_eq!(item.page_url, "https://images.nasa.gov/details/ID1");
    }

    #[test]
    fn inaturalist_swaps_one_word_for_the_original() {
        let source = declarative(manifest(INATURALIST_TOML), "");
        let body = r#"{"results": [
            {"id": 5, "uri": "https://www.inaturalist.example/observations/5",
             "photos": [{"id": 9, "url": "https://static.example/photos/9/square.png",
                         "license_code": "cc0", "original_dimensions": {"width": 2048, "height": 1536}}],
             "taxon": {"name": "Genus species"}, "user": {"login": "someone"}}
        ]}"#;
        let item = &source.parse(body).expect("parses")[0];
        assert_eq!(item.url, "https://static.example/photos/9/original.png");
        assert_eq!(item.thumb, "https://static.example/photos/9/medium.png");
        assert_eq!(item.title, "Genus species", "no common name, so the scientific one");
        assert_eq!((item.w, item.h), (2048, 1536));
    }

    #[test]
    fn emojigg_marks_its_own_nsfw_category_and_svgl_takes_either_route() {
        let emoji = declarative(manifest(EMOJIGG_TOML), "");
        let body = r#"[
            {"id": 1, "slug": "1_a", "image": "https://cdn.example/1_a.png", "category": 4, "width": 0, "height": 0},
            {"id": 2, "slug": "2_b", "image": "https://cdn.example/2_b.gif", "category": 9, "width": 64, "height": 64}
        ]"#;
        let items = emoji.parse(body).expect("parses");
        assert_eq!((items[0].nsfw, items[1].nsfw), (false, true));
        assert_eq!(items[1].page_url, "https://emoji.gg/emoji/2_b");
        assert_eq!(emoji.page_limit(), Some(1), "one document, fetched once");

        let svgl = declarative(manifest(SVGL_TOML), "");
        let body = r#"[
            {"id": 1, "title": "A", "category": "Software", "route": "https://svg.example/a.svg", "url": "https://a.example"},
            {"id": 2, "title": "B", "category": ["AI", "Software"], "route": {"light": "https://svg.example/b-l.svg", "dark": "https://svg.example/b-d.svg"}, "url": "https://b.example"}
        ]"#;
        let items = svgl.parse(body).expect("parses");
        assert_eq!(items.len(), 2, "an object route must not drop the logo");
        assert_eq!(items[1].url, "https://svg.example/b-l.svg");
        assert_eq!(items[1].tags, vec!["AI", "Software"]);
        assert_eq!(items[1].family, "vector");
    }

    /// The claims every shipped manifest must keep, checked on the files the
    /// daemon actually reads.
    #[test]
    fn every_shipped_manifest_links_its_posts_marks_its_adult_rows_and_pages() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../sources");
        let mut checked = 0;
        for entry in std::fs::read_dir(&dir).expect("sources/") {
            let path = entry.expect("entry").path();
            if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            let text = std::fs::read_to_string(&path).expect("read");
            let m: Manifest = toml::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"));

            // "Open source page" must go to the post, never to the listing.
            assert!(!m.map.page_url.is_empty(), "{name}: map.page_url is missing");

            // Adult rows must be marked, one way or the other.
            if m.category == "adult" {
                assert!(
                    m.adult || !m.map.rating.is_empty(),
                    "{name}: an adult source needs `adult = true` or a rating mapping"
                );
            }
            assert_eq!(
                m.map.rating.is_empty(),
                m.map.nsfw_ratings.is_empty(),
                "{name}: `rating` and `nsfw_ratings` go together"
            );
            assert_eq!(
                m.request.sfw_tag.is_empty(),
                m.request.nsfw_tag.is_empty(),
                "{name}: one rating tag without the other cannot answer both questions"
            );

            /*
             * A THUMBNAIL MUST BE FETCHABLE FROM ITS MAPPING ALONE.
             *
             * For a JSON source nothing absolutises what the mapping plucks —
             * the value goes to the HTTP client exactly as the API wrote it.
             * shikimori's `image.preview` is `/system/animes/preview/37446.jpg`
             * and its `url` template carries the host while `thumb` did not, so
             * 2,080 rows held a path with no host: unfetchable, drawn as empty
             * frames, and silent in every log. A literal mapping (a template
             * with `{}` in it, or a bare `http…`) has to start with a scheme;
             * a bare dotted path is a pluck and can only be judged at runtime.
             */
            for (field, value) in [("thumb", &m.map.thumb), ("url", &m.map.url)] {
                // A template that OPENS with a placeholder cannot be judged
                // here: smk's `{image_iiif_id}/full/!400,400/0/default.jpg`
                // plucks a whole IIIF base URL, scheme and all. Only a mapping
                // whose own first characters are literal can be checked.
                let literal = !value.starts_with('{') && (value.contains('{') || value.starts_with("http"));
                if literal && !value.is_empty() {
                    assert!(
                        value.starts_with("http://") || value.starts_with("https://"),
                        "{name}: map.{field} = {value:?} has no scheme — it cannot be fetched"
                    );
                }
            }

            /*
             * A CATEGORY THE APP HAS NO HEADING FOR IS A SOURCE NOBODY FINDS.
             *
             * Settings groups the sources list by `category`, and anything it
             * does not recognise collapses into "Everything else" at the
             * bottom. Six 3D sources and an audio one sat there for months,
             * each declaring a category the settings page had simply never
             * been told about. The two lists have to agree, and this is the
             * cheaper half to check.
             *
             * Keep in step with `categoryOrder` in SettingsPanel.qml.
             */
            const CATEGORIES: [&str; 10] = [
                "wallpapers",
                "photography",
                "art",
                "3d",
                "games",
                "icons",
                "video",
                "audio",
                "adult",
                "local",
            ];
            assert!(
                CATEGORIES.contains(&m.category.as_str()),
                "{name}: category {:?} has no heading in Settings — add it to categoryOrder, or use one of {CATEGORIES:?}",
                m.category
            );

            // Every credential in the template must be a `{VAR}` that
            // resolve_auth fills — a `$VAR` is sent as literal text.
            if let Some(auth) = &m.auth {
                assert!(!auth.query.contains('$'), "{name}: [auth].query uses $VAR, write {{VAR}}");
                for var in &auth.vars {
                    assert!(auth.query.contains(&format!("{{{var}}}")), "{name}: {var} is never sent");
                }
            }

            // Browsing with no query must advance: page 2 is a different
            // request from page 1, or the home feed repeats itself forever.
            let source = declarative(m, "");
            let page = |n| source.build_url(&SourceQuery { page: n, ..Default::default() });
            if source.page_limit() != Some(1) {
                assert_ne!(page(1), page(2), "{name}: page 2 asks for the same thing as page 1");
            }
            assert!(!page(1).contains("{query}") && !page(1).contains("{tags}"), "{name}: {}", page(1));
            checked += 1;
        }
        assert!(checked >= 30, "expected the shipped manifests, found {checked}");
    }
}

#[cfg(test)]
mod author_tests {
    use super::*;
    use crate::sources::{Source, SourceQuery};

    fn source(extra: &str, url: &str) -> Declarative {
        let text = format!(
            "id = \"t\"\nlabel = \"T\"\n\n[request]\nurl = \"{url}\"\n{extra}\n\n[capabilities]\ntext = true\n\n[map]\nid = \"id\"\nurl = \"u\"\n"
        );
        let parsed: Manifest = toml::from_str(&text).expect("valid manifest");
        let id: &'static str = Box::leak(parsed.id.clone().into_boxed_str());
        Declarative { manifest: parsed, id, auth_query: String::new() }
    }

    /// A site with a real parameter gets the name in the URL, encoded.
    #[test]
    fn a_creator_parameter_is_substituted() {
        let source = source("", "https://x.test/?q={query}&creator={author}&page={page}");
        assert!(source.capabilities().author, "{{author}} in the url means it can");
        let url = source.build_url(&SourceQuery {
            author: "Bernard Spragg".into(),
            page: 1,
            ..Default::default()
        });
        assert!(url.contains("creator=Bernard+Spragg"), "{url}");
    }

    /// A board spells the creator as a tag, and it rides with the other terms.
    #[test]
    fn an_author_tag_joins_the_query_terms() {
        let source = source(
            "author_tag = \"artist:{author}\"\njoiner = \",\"",
            "https://x.test/?q={query}&page={page}",
        );
        assert!(source.capabilities().author, "an author_tag means it can");

        let url = source.build_url(&SourceQuery {
            text: vec!["pony".into()],
            author: "assasinmonkey".into(),
            page: 1,
            ..Default::default()
        });
        assert!(url.contains("artist%3Aassasinmonkey"), "{url}");
        assert!(url.contains("pony"), "the words survive too: {url}");
    }

    /*
     * PROTOCOL-RELATIVE THUMBNAILS, READ BY REGEX.
     *
     * hqporner hides its thumbnail in an `onmouseleave` handler, so the
     * manifest reads it with a pattern — and a patterned field used to skip
     * absolutisation entirely, storing `//host/path`. A URL with no scheme
     * cannot be turned into a request at all, so every one of those rows drew
     * as an empty frame. The two leading slashes are the tell: no id, tag or
     * count ever starts with them.
     */
    #[test]
    fn a_regex_captured_protocol_relative_url_still_gets_a_scheme() {
        let html = r#"<div class="w403px" onmouseleave="defaultImage(&quot;//cdn.example.com/a/b_main.jpg&quot;)"></div>"#;
        let doc = scraper::Html::parse_fragment(html);
        let row = doc.select(&scraper::Selector::parse("div.w403px").unwrap()).next().unwrap();
        let field = HtmlField {
            sel: "div.w403px".into(),
            attr: "onmouseleave".into(),
            abs: None,
            ..Default::default()
        };
        let pattern = regex::Regex::new(r#"defaultImage\("([^"]+)""#).unwrap();
        let got = read_html(row, &field, Some(&pattern), "https://hqporner.com");
        assert_eq!(got, "https://cdn.example.com/a/b_main.jpg");
    }

    /// A pattern that pulls a bare id out of prose must NOT become a URL —
    /// which is what `pattern.is_none()` was defending, and still does.
    #[test]
    fn a_regex_captured_fragment_is_left_alone() {
        let html = r#"<a href="/post/1" data-info="views: 4821">x</a>"#;
        let doc = scraper::Html::parse_fragment(html);
        let row = doc.select(&scraper::Selector::parse("a").unwrap()).next().unwrap();
        let field = HtmlField {
            sel: "a".into(),
            attr: "data-info".into(),
            abs: None,
            ..Default::default()
        };
        let pattern = regex::Regex::new(r"views: (\d+)").unwrap();
        let got = read_html(row, &field, Some(&pattern), "https://example.com");
        assert_eq!(got, "4821");
    }

    /// No author asked for, no author in the URL — a `{author}` template must
    /// not leave an empty parameter that means something else to the site.
    #[test]
    fn an_absent_author_substitutes_to_nothing() {
        let source = source("", "https://x.test/?q={query}&creator={author}&page={page}");
        let url = source.build_url(&SourceQuery { page: 1, ..Default::default() });
        assert!(url.contains("creator=&"), "{url}");
        assert!(!url.contains("{author}"), "{url}");
    }

    /// A manifest that says nothing about creators must not claim it can.
    #[test]
    fn a_plain_manifest_does_not_claim_author_search() {
        let source = source("", "https://x.test/?q={query}&page={page}");
        assert!(!source.capabilities().author);
    }
}

#[cfg(test)]
mod section_tests {
    use super::*;
    use crate::sources::Source;

    fn from(text: &str) -> Declarative {
        let parsed: Manifest = toml::from_str(text).expect("valid manifest");
        let id: &'static str = Box::leak(parsed.id.clone().into_boxed_str());
        Declarative { manifest: parsed, id, auth_query: String::new() }
    }

    const WITH_SECTIONS: &str = r#"
id = "t"
label = "T"
[request]
url = "https://x.test/?q={query}&p={page}"
[capabilities]
text = true
[map]
id = "id"
url = "u"
[[sections]]
group = "Sort"
label = "Newest"
q = "sort:new"
[[sections]]
group = "Categories"
label = "cosplay"
"#;

    /// A category's name IS its search, so `q` defaults to the label; an
    /// ordering's is not, so it says so.
    #[test]
    fn a_section_query_defaults_to_its_label() {
        let source = from(WITH_SECTIONS);
        let sections = source.sections();
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0], ("Sort".into(), "Newest".into(), "sort:new".into(), false));
        // A section can be adult while its source is not — the whole point of
        // the per-section flag. Unset means safe, so the two above are false.
        assert_eq!(sections[1], ("Categories".into(), "cosplay".into(), "cosplay".into(), false));
    }

    /// A manifest that declares none must not invent any.
    #[test]
    fn a_manifest_without_sections_offers_none() {
        let plain = from(
            "id = \"t\"\nlabel = \"T\"\n\n[request]\nurl = \"https://x.test/?q={query}\"\n\n[capabilities]\ntext = true\n\n[map]\nid = \"id\"\nurl = \"u\"\n",
        );
        assert!(plain.sections().is_empty());
    }

    /// The ten tube manifests added today all carry their site's own sections,
    /// and every section resolves to a query rather than an empty string.
    #[test]
    fn the_shipped_tube_manifests_publish_sections() {
        for name in [
            "xvideos", "xnxx", "youporn", "tube8", "spankwire", "porntrex", "tnaflix",
            "youjizz", "hqporner", "rule34video", "pornhub", "eporner", "redtube",
        ] {
            let path = format!("{}/../sources/{name}.toml", env!("CARGO_MANIFEST_DIR"));
            let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
            let source = from(&text);
            let sections = source.sections();
            assert!(!sections.is_empty(), "{name} publishes no sections");
            for (_, label, query, _) in &sections {
                assert!(!label.is_empty(), "{name} has a section with no label");
                assert!(!query.is_empty(), "{name}/{label} resolves to an empty query");
            }
        }
    }
}

/*
 * A BOOLEAN IS A RATING TOO.
 *
 * `rating`/`nsfw_ratings` was written for a booru's `rating: explicit`. The
 * fediverse states the same fact as a bool — Mastodon's `sensitive`, Lemmy's
 * `post.nsfw` — and those went unmapped, so every row from eleven instances
 * arrived marked safe whatever the poster ticked. With the adult switch off,
 * explicit photographs were on the wall and the daemon was filtering
 * faithfully: it had simply never been told.
 */
#[cfg(test)]
mod boolean_rating_tests {
    use super::tests::{declarative, manifest};

    const MASTODON_TOML: &str = include_str!("../../../sources/mastodonworld.toml");
    const LEMMY_TOML: &str = include_str!("../../../sources/lemmy_hexbear.toml");

    /// Mastodon: one boolean at the top of the status.
    #[test]
    fn a_sensitive_flag_marks_the_row_adult() {
        let source = declarative(manifest(MASTODON_TOML), "");
        let adult = serde_json::json!({ "id": "1", "sensitive": true });
        let safe = serde_json::json!({ "id": "2", "sensitive": false });
        let missing = serde_json::json!({ "id": "3" });

        assert!(source.rated_nsfw(&adult), "sensitive:true was not read as adult");
        assert!(!source.rated_nsfw(&safe));
        // An absent rating marks nothing — quarry does not guess either way.
        assert!(!source.rated_nsfw(&missing));
    }

    /*
     * Lemmy: EITHER the post or its community.
     *
     * A safe-looking post inside an adult community is still in an adult
     * community, so the two paths are read together and either one is enough.
     */
    #[test]
    fn either_the_post_or_its_community_is_enough_for_lemmy() {
        let source = declarative(manifest(LEMMY_TOML), "");
        let by_post = serde_json::json!({
            "post": { "nsfw": true }, "community": { "nsfw": false }
        });
        let by_community = serde_json::json!({
            "post": { "nsfw": false }, "community": { "nsfw": true }
        });
        let neither = serde_json::json!({
            "post": { "nsfw": false }, "community": { "nsfw": false }
        });

        assert!(source.rated_nsfw(&by_post), "an adult post was not marked");
        assert!(source.rated_nsfw(&by_community), "an adult community was not marked");
        assert!(!source.rated_nsfw(&neither));
    }

    /*
     * The check that stops the next instance being added without one.
     *
     * A source that republishes other people's posts and has no way to mark any
     * of them adult is a hole in the switch, and it is invisible: the rows just
     * arrive safe.
     */
    #[test]
    fn every_fediverse_manifest_maps_its_adult_flag() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../sources");
        let mut checked = 0;
        for entry in std::fs::read_dir(&dir).expect("sources/") {
            let path = entry.expect("entry").path();
            if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                continue;
            }
            let name = path.file_stem().unwrap().to_string_lossy().to_string();
            if !(name.starts_with("lemmy_") || name.starts_with("mastodon") || name.starts_with("toot")) {
                continue;
            }
            let m = manifest(&std::fs::read_to_string(&path).expect("read"));
            assert!(
                !m.map.rating.is_empty() && !m.map.nsfw_ratings.is_empty(),
                "{name} publishes other people's posts and cannot mark any of them adult"
            );
            checked += 1;
        }
        assert!(checked >= 11, "expected the fediverse manifests, found {checked}");
    }
}

/*
 * The two manifests added on 2026-10-08, each pinned against a synthetic body
 * of the shape its endpoint really returns (probed live that day: V&A 200 /
 * 22,927 bytes, Coub 200 / 25,352 bytes).
 *
 * Both exist to pin something the mapping has to get right and which a reader
 * of the TOML cannot check by eye: V&A builds its picture URL out of a
 * template because the payload has no full-size link at all, and Coub reads
 * its dimensions out of a two-element array.
 */
#[cfg(test)]
mod new_manifest_tests {
    use super::tests::{declarative, manifest};
    use super::*;

    const VAM_TOML: &str = include_str!("../../../sources/vam.toml");
    const COUB_TOML: &str = include_str!("../../../sources/coub.toml");

    /// The V&A payload contains NO full-size URL — only a 100px thumbnail and
    /// an image id. If the template ever stops being applied, every row becomes
    /// a hundred-pixel square, which on a wall looks like a decode fault.
    #[test]
    fn vam_builds_a_full_size_url_from_the_image_id() {
        let source = declarative(manifest(VAM_TOML), "");
        let items = source
            .parse(include_str!("../../tests/fixtures/vam-search.json"))
            .expect("parses");
        assert_eq!(items.len(), 2);

        let first = &items[0];
        assert_eq!(first.source, "vam");
        assert!(
            first.url.contains("/2015AA0001/full/!1600,1600/"),
            "not the IIIF full-size url: {}",
            first.url
        );
        assert!(first.thumb.contains("!400,400"), "{}", first.thumb);
        assert_eq!(first.page_url, "https://collections.vam.ac.uk/item/O1000001/");
        assert_eq!(first.author, "Aveline Marsk");
    }

    /// Most V&A objects have no title — they are catalogued by what they are.
    /// A row with neither is one you can never search for again.
    #[test]
    fn vam_falls_back_to_the_object_type_when_there_is_no_title() {
        let source = declarative(manifest(VAM_TOML), "");
        let items = source
            .parse(include_str!("../../tests/fixtures/vam-search.json"))
            .expect("parses");
        assert_eq!(items[0].title, "Portrait", "empty title was not filled in");
        assert_eq!(items[1].title, "A Quiet Harbour", "a real title was overwritten");
    }

    /// The reason Coub is here and dailymotion is not: a real file, not a page.
    #[test]
    fn coub_rows_carry_a_playable_file() {
        let source = declarative(manifest(COUB_TOML), "");
        let items = source
            .parse(include_str!("../../tests/fixtures/coub-timeline.json"))
            .expect("parses");
        assert_eq!(items.len(), 2);

        let first = &items[0];
        assert_eq!(first.family, "video");
        assert!(first.url.ends_with(".mp4"), "not a file: {}", first.url);
        assert_eq!(first.page_url, "https://coub.com/view/aaaaaaaaaa");
        assert_eq!(first.duration, 10.0);
        assert_eq!(first.author, "Nysorl");
        assert!(first.tags.contains(&"cats".to_string()), "{:?}", first.tags);
    }

    /// `dimensions.big` is `[w, h]`, not `{w, h}` — read by position or the
    /// wall gets a zero ratio, which collapses the row it is in.
    #[test]
    fn coub_reads_its_size_out_of_a_two_element_array() {
        let source = declarative(manifest(COUB_TOML), "");
        let items = source
            .parse(include_str!("../../tests/fixtures/coub-timeline.json"))
            .expect("parses");
        assert_eq!((items[0].w, items[0].h), (640, 360));
        assert_eq!((items[1].w, items[1].h), (1280, 720));
    }

    /// Coub marks adult rows with a bare `true`/`null`, and `null` is the
    /// common case — so a careless read makes the whole timeline adult.
    #[test]
    fn coub_rates_only_the_rows_the_source_rated() {
        let source = declarative(manifest(COUB_TOML), "");
        let items = source
            .parse(include_str!("../../tests/fixtures/coub-timeline.json"))
            .expect("parses");
        assert!(!items[0].nsfw, "null was read as adult");
        assert!(items[1].nsfw, "true was not read as adult");
    }

    /// osu!'s seasonal list: one row per background, credited, a wallpaper.
    #[test]
    fn osu_seasonal_reads_its_backgrounds() {
        let source = declarative(manifest(include_str!("../../../sources/osu_seasonal.toml")), "");
        let items = source.parse(include_str!("../../tests/fixtures/osu-seasonal.json")).expect("parses");
        assert_eq!(items.len(), 2);
        assert!(items[0].url.ends_with("Example-One.jpg"), "{}", items[0].url);
        assert_eq!(items[0].author, "example_artist");
        assert_eq!(items[0].kind, "wallpaper");
        assert_ne!(items[0].id, items[1].id);
    }

    /// `-nsfw` must reach Konachan as `rating:s`, so konachan.com sends only the
    /// safe side (the shell's old script used the SFW mirror konachan.net).
    #[test]
    fn konachan_minus_nsfw_asks_the_site_for_safe_only() {
        use crate::sources::{Source, SourceQuery};
        let source = declarative(manifest(include_str!("../../../sources/konachan.toml")), "");
        let (pushed, _) = crate::sources::pushdown(&crate::query::parse("kind:wallpaper -nsfw"), &source.capabilities());
        let url = source.build_url(&SourceQuery { page: 1, ..pushed });
        assert!(url.contains("rating%3As") || url.contains("rating:s"), "{url}");
        assert!(!url.contains("-rating"), "{url}");
    }

    const KEMONO_TOML: &str = include_str!("../../../sources/kemono.toml");

    /// Image post, video post with a poster attachment, text-only post.
    #[test]
    fn kemono_builds_urls_from_paths_and_drops_text_posts() {
        let source = declarative(manifest(KEMONO_TOML), "");
        let items = source
            .parse(include_str!("../../tests/fixtures/kemono-posts.json"))
            .expect("parses");
        // Three posts in; the text-only one has no URL and parse drops it.
        assert_eq!(items.len(), 2, "the text-only post must be dropped");
        assert!(items.iter().all(|i| !i.page_url.ends_with("/post/138619219")));

        let image = &items[0];
        assert!(image.url.starts_with("https://kemono.cr/data/1a/86/") && image.url.ends_with(".gif"), "{}", image.url);
        assert!(image.thumb.starts_with("https://img.kemono.cr/thumbnail/data/"), "{}", image.thumb);
        assert_eq!(image.page_url, "https://kemono.cr/patreon/user/44096704/post/152271177");
        assert!(image.nsfw);

        // The mp4 is the file; the thumbnail must be the png poster, not the
        // mp4 (img.kemono.cr 404s video thumbnails).
        let video = &items[1];
        assert_eq!(video.family, "video");
        assert!(video.thumb.ends_with(".png"), "{}", video.thumb);
        assert_ne!(image.id, video.id);
    }

    #[test]
    fn kemono_pages_by_offset_and_declares_its_accept_header() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../sources/kemono.toml");
        let source = Declarative::load(std::path::Path::new(path)).expect("loads");
        assert_eq!(source.manifest.request.limit, 50, "`o` steps by 50");
        assert_eq!(
            crate::scrape::headers_for("https://kemono.cr/api/v1/posts?q=&o=50"),
            vec![("Accept".to_string(), "text/css".to_string())]
        );
    }
}

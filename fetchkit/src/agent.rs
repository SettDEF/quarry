/*
 * Who fetchkit says it is, and to whom.
 *
 * The honest agent is the rule and the exceptions are listed: a host that
 * answers 403 to it and 200 to a browser is named here rather than everywhere.
 * Referers live here too — same question, different header.
 */

#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::Mutex;



/// Identify honestly. A crawler that pretends to be a browser is a crawler that
/// cannot be blocked politely, and being blockable is part of being welcome.
pub const USER_AGENT: &str =
    concat!("quarry/", env!("CARGO_PKG_VERSION"), " (personal image catalogue; +local)");

/*
 * THE ONE QUARRY SENDS WHEN A HOST WILL NOT ANSWER ANYTHING ELSE.
 *
 * Measured 2026-09-24 with quarry's own agent: the whole `*.booru.org` network,
 * tbib, rule34hentai, spankbang and motherless answer 403 to it and 200 to a
 * browser's. Nothing about those pages is private — no login, no paywall, no
 * robots rule against them; the filter is on the string alone.
 *
 * So this is opt-in PER SOURCE and written in that source's manifest
 * (`user_agent = "browser"`), never a global default. The honest agent stays
 * the rule, the exception is visible in the file that needs it, and `grep -l
 * user_agent sources/` lists every place quarry is not introducing itself.
 * The rate limiter and the cache apply exactly as before: what changes is the
 * name on the request, not the manners behind it.
 */
pub const BROWSER_USER_AGENT: &str =
    "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";

/// host → the agent that host is sent, for the few that need one.
static HOST_AGENTS: std::sync::OnceLock<Mutex<std::collections::HashMap<String, String>>> =
    std::sync::OnceLock::new();

pub(crate) fn host_agents() -> &'static Mutex<std::collections::HashMap<String, String>> {
    HOST_AGENTS.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

/// Declared by a manifest as it loads. `agent` is the literal string to send;
/// "browser" is spelled out into `BROWSER_USER_AGENT` by the caller.
pub fn set_host_agent(host: &str, agent: &str) {
    if host.is_empty() {
        return;
    }
    if let Ok(mut map) = host_agents().lock() {
        map.insert(host.trim_start_matches("www.").to_lowercase(), agent.to_string());
    }
}

/// What to introduce ourselves as for this URL — `None` means the honest one.
pub fn agent_for(url: &str) -> Option<String> {
    let host = url::Url::parse(url).ok()?.host_str()?.trim_start_matches("www.").to_lowercase();
    host_agents().lock().ok()?.get(&host).cloned()
}

/*
 * OTHER HEADERS A HOST INSISTS ON.
 *
 * Kemono's API answers 429 to any request without `Accept: text/css` — the
 * DDoS guard's filter, measured 2026-10-16, not a rate limit. Declared per
 * host by the manifest (`[request] headers`), like the agent above.
 */
static HOST_HEADERS: std::sync::OnceLock<std::sync::RwLock<HashMap<String, Vec<(String, String)>>>> =
    std::sync::OnceLock::new();

fn host_headers() -> &'static std::sync::RwLock<HashMap<String, Vec<(String, String)>>> {
    HOST_HEADERS.get_or_init(|| std::sync::RwLock::new(HashMap::new()))
}

/// Send `name: value` to `host`. A repeated name replaces the earlier value.
pub fn set_host_header(host: &str, name: &str, value: &str) {
    if host.is_empty() || name.is_empty() {
        return;
    }
    if let Ok(mut map) = host_headers().write() {
        let list = map.entry(host.trim_start_matches("www.").to_ascii_lowercase()).or_default();
        list.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
        list.push((name.to_string(), value.to_string()));
    }
}

/// The extra headers for this URL's exact host — empty for almost every host.
pub fn headers_for(url: &str) -> Vec<(String, String)> {
    let Some(host) = url::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_ascii_lowercase)) else {
        return Vec::new();
    };
    let host = host.trim_start_matches("www.");
    host_headers().read().ok().and_then(|m| m.get(host).cloned()).unwrap_or_default()
}

/// The HTTP client every adapter shares.
/*
 * HOSTS THAT WANT A REFERER, AND WHAT TO SEND THEM.
 *
 * Filled once from the source manifests at startup (see `Declarative::load_all`
 * and `sources::all`) and read from the one place bytes are fetched, so a
 * manifest declaring `referer` gets it applied to its API call, its thumbnails
 * and its originals without a single call site knowing about it.
 *
 * Keyed by host rather than by source because that is what is actually true: a
 * museum's IIIF server refuses hotlinks from anyone, no matter which of our
 * sources happens to be asking.
 */
static REFERERS: std::sync::OnceLock<std::sync::RwLock<HashMap<String, String>>> =
    std::sync::OnceLock::new();

pub(crate) fn referers() -> &'static std::sync::RwLock<HashMap<String, String>> {
    REFERERS.get_or_init(|| std::sync::RwLock::new(HashMap::new()))
}

/// Declare that `host` must be sent `referer`. Later calls overwrite earlier
/// ones, so a user manifest can correct a shipped one.
pub fn set_referer(host: &str, referer: &str) {
    if host.is_empty() || referer.is_empty() {
        return;
    }
    if let Ok(mut map) = referers().write() {
        map.insert(host.to_ascii_lowercase(), referer.to_string());
    }
}

/*
 * The referer for a URL, if its host asked for one — or if its PARENT did.
 *
 * A site's pictures rarely live on the site's own host. Pornhub serves its
 * posters from `pix-cdn77.phncdn.com` and `pix-fl.phncdn.com`, and only some of
 * those edges enforce the hotlink rule: verified live, `pix-cdn77` answers 403
 * without a Referer and 200 with one, while `pix-fl` does not care — which is
 * why twelve of thirty tiles were blank and the rest were fine, a pattern that
 * looks random until you read the hostname.
 *
 * So a manifest declaring `phncdn.com` covers every edge under it. Matching is
 * on a dot boundary, so `evilphncdn.com` is not a match for `phncdn.com`.
 */
pub(crate) fn referer_for(url: &str) -> Option<String> {
    // Deliberately not a URL parse: this runs on every fetch, and the host is
    // the span between "//" and the next "/" in every URL that has one.
    let rest = url.split_once("://")?.1;
    let host = rest.split(['/', '?', '#']).next()?.to_ascii_lowercase();
    let host = host.rsplit_once('@').map_or(host.as_str(), |(_, h)| h);
    let host = host.split_once(':').map_or(host, |(h, _)| h);
    let map = referers().read().ok()?;
    if let Some(exact) = map.get(host) {
        return Some(exact.clone());
    }
    let mut rest = host;
    while let Some((_, parent)) = rest.split_once('.') {
        if let Some(hit) = map.get(parent) {
            return Some(hit.clone());
        }
        rest = parent;
    }
    None
}


#[cfg(test)]
mod tests {
    #[test]
    fn referer_is_matched_by_host_and_only_that_host() {
        super::set_referer("www.artic.edu", "https://www.artic.edu/");

        // The plain case, and the two shapes a URL host can hide behind.
        assert_eq!(
            super::referer_for("https://www.artic.edu/iiif/2/abc/full/400,/0/default.jpg"),
            Some("https://www.artic.edu/".into())
        );
        assert_eq!(
            super::referer_for("https://www.artic.edu:443/iiif/2/abc"),
            Some("https://www.artic.edu/".into())
        );
        assert_eq!(
            super::referer_for("https://WWW.ARTIC.EDU/iiif/2/abc"),
            Some("https://www.artic.edu/".into())
        );

        // The API host is a DIFFERENT host and must not be sent one: a referer
        // where none was asked for is a header that can only lose.
        assert_eq!(super::referer_for("https://api.artic.edu/api/v1/artworks"), None);
        // Nor may a suffix match — a host that merely ends with the registered
        // one is somebody else entirely.
        assert_eq!(super::referer_for("https://evil-www.artic.edu.example/x"), None);
        assert_eq!(super::referer_for("file:///home/x/a.png"), None);
    }

    #[test]
    fn host_headers_apply_to_that_host_only() {
        super::set_host_header("kemono.test", "Accept", "text/plain");
        super::set_host_header("kemono.test", "accept", "text/css");
        assert_eq!(
            super::headers_for("https://www.kemono.test/api/v1/posts?o=50"),
            vec![("accept".to_string(), "text/css".to_string())]
        );
        // Its image host is a different host and is sent nothing extra.
        assert!(super::headers_for("https://img.kemono.test/thumbnail/x.png").is_empty());
        assert!(super::headers_for("not a url").is_empty());
    }
}

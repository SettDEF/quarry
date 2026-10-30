//! Reddit, through OAuth — the only way in since 2024.
//!
//! Every unauthenticated path is a 403 now: `www.reddit.com/r/x/hot.json`,
//! `api.reddit.com`, and `old.reddit.com` which redirects to HTML. Checked
//! again from this machine on 2026-08-31, with a browser User-Agent, and all
//! three refuse. So this is the OAuth API or nothing.
//!
//! CREDENTIALS ARE NEVER PRINTED, LOGGED OR STORED HERE. They are read from an
//! environment file the user already keeps for their own scripts, used to mint
//! a token, and dropped. The only thing that reaches the log is when a token
//! was refreshed and how long it lasts.
//!
//! The token cache is deliberately the SAME FILE the user's shell scripts use:
//! one token serves both, so quarry crawling does not race a shell script into
//! Reddit's rate limit with two separate sessions.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct Reddit;

/// Where the credentials and the shared token live. Both overridable, both
/// defaulting to where the user's existing setup already put them.
fn env_file() -> String {
    std::env::var("REDDIT_ENV_FILE").unwrap_or_else(|_| {
        format!("{}/.secure/reddit-app.env", std::env::var("HOME").unwrap_or_default())
    })
}

fn token_cache() -> String {
    std::env::var("REDDIT_TOKEN_CACHE").unwrap_or_else(|_| {
        format!(
            "{}/.cache/quickshell/reddit-oauth-token.json",
            std::env::var("HOME").unwrap_or_default()
        )
    })
}

/// The credential set, held only for as long as a token exchange takes.
struct Credentials {
    client_id: String,
    client_secret: String,
    username: String,
    password: String,
    user_agent: String,
}

/// Read `KEY=value` pairs, the way a shell would source them.
///
/// The environment wins: a daemon started with the variables set does not need
/// the file at all, which is the right shape for a service.
fn credentials() -> Option<Credentials> {
    let mut vars: HashMap<String, String> = HashMap::new();

    if let Ok(text) = std::fs::read_to_string(env_file()) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let line = line.strip_prefix("export ").unwrap_or(line);
            if let Some((key, value)) = line.split_once('=') {
                let value = value.trim().trim_matches('"').trim_matches('\'');
                vars.insert(key.trim().to_string(), value.to_string());
            }
        }
    }

    let get = |key: &str| -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty()).or_else(|| vars.get(key).cloned())
    };

    Some(Credentials {
        client_id: get("REDDIT_CLIENT_ID")?,
        client_secret: get("REDDIT_CLIENT_SECRET")?,
        username: get("REDDIT_USER")?,
        password: get("REDDIT_PASS")?,
        user_agent: get("REDDIT_UA").unwrap_or_else(|| DEFAULT_UA.to_string()),
    })
}

/// Whether this source can work at all, for `doctor` and for the skip message.
pub fn configured() -> bool {
    credentials().is_some()
}

/// The User-Agent the app is registered with.
///
/// Reddit 403s its OAuth API for a request whose UA it does not recognise, even
/// with a valid token — so this is not decoration, it is part of the
/// credential.
///
/// The fallback is reddit's own `platform:app-id:version` shape, not quarry's
/// browser-style agent: an env file written before `REDDIT_UA` existed has no
/// such key, and falling back to a UA reddit refuses turned a working
/// credential into a 403 with nothing saying why.
pub const DEFAULT_UA: &str = concat!("linux:dev.quarry:v", env!("CARGO_PKG_VERSION"));

pub fn user_agent() -> String {
    credentials()
        .map(|c| c.user_agent)
        .filter(|ua| !ua.is_empty())
        .unwrap_or_else(|| DEFAULT_UA.to_string())
}

/// A token and when it dies, as the shell scripts write it.
fn cached_token() -> Option<String> {
    let text = std::fs::read_to_string(token_cache()).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    let expires_at = json.get("expires_at").and_then(|v| v.as_i64()).unwrap_or(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    // A minute of headroom: a token that expires mid-crawl is a 401 halfway
    // through a page.
    if expires_at - 60 <= now {
        return None;
    }
    json.get("access_token").and_then(|v| v.as_str()).map(String::from)
}

fn store_token(token: &str, expires_in: i64) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let body = serde_json::json!({ "access_token": token, "expires_at": now + expires_in });
    let path = token_cache();
    if let Some(parent) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Readable only by its owner: it is a bearer token for an account.
    if std::fs::write(&path, body.to_string()).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
    }
}

/// One token at a time, whatever else is happening.
///
/// A crawl asks several sources at once and Reddit's own pages in parallel;
/// without this every one of them would mint its own token on a cold start,
/// which is both wasteful and a good way to be rate-limited by the endpoint
/// that hands them out.
/// A tokio mutex, not a std one: the lock is held ACROSS the token exchange,
/// which is an await, and a std guard cannot cross one — the whole server
/// future stops being `Send` and nothing compiles. Holding it across the await
/// is the entire point, so the lock has to be the async kind.
static MINTING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/*
 * REDDIT GETS ITS OWN HTTP CLIENT.
 *
 * The shared one is built with quarry's User-Agent as a default header, and a
 * per-request `.header(USER_AGENT, …)` on top of that is ambiguous — reqwest
 * appends rather than replaces, so the request can carry two User-Agent values
 * and Reddit answers 403 with no indication that the header is the problem.
 * The same request from curl with the same token and the same UA returns 200,
 * which is a long way to travel to find a duplicated header.
 *
 * A client whose ONLY User-Agent is the registered one cannot be ambiguous.
 */
static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();

fn client() -> &'static reqwest::Client {
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(user_agent())
            .timeout(std::time::Duration::from_secs(30))
            .gzip(true)
            // See Cargo.toml: rustls is refused by Reddit's edge before the
            // request is even read.
            .use_native_tls()
            .build()
            .unwrap_or_default()
    })
}

/// A GET against the OAuth API, with the credential's own User-Agent.
pub async fn fetch(url: &str, token: &str) -> Result<String, scrape::ScrapeError> {
    let response = client()
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| scrape::ScrapeError::Http(e.to_string()))?;

    let status = response.status().as_u16();
    if !response.status().is_success() {
        // Reddit's refusals explain themselves in the body far more often than
        // in the status — "Blocked", a Cloudflare interstitial, or a JSON
        // `message` naming the missing scope.
        let body = response.text().await.unwrap_or_default();
        eprintln!(
            "[quarryd] reddit: {status} — {}",
            body.chars().take(180).collect::<String>().replace('\n', " ")
        );
        return Err(scrape::ScrapeError::Status(status, url.to_string()));
    }
    response.text().await.map_err(|e| scrape::ScrapeError::Http(e.to_string()))
}

/// The token exchange, on the same client for the same reason.
async fn exchange(creds: &Credentials) -> Option<String> {
    let response = client()
        .post("https://www.reddit.com/api/v1/access_token")
        .basic_auth(&creds.client_id, Some(&creds.client_secret))
        .form(&[
            ("grant_type", "password"),
            ("username", creds.username.as_str()),
            ("password", creds.password.as_str()),
            ("scope", "read"),
        ])
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        // Without the body: an auth failure can echo back what was sent.
        eprintln!("[quarryd] reddit: token exchange refused ({})", response.status().as_u16());
        return None;
    }
    response.text().await.ok()
}

/// Throw away the cached token, so the next call mints a fresh one.
pub fn forget_token() {
    let _ = std::fs::remove_file(token_cache());
}

/// A usable bearer token: the shared cache if it is still alive, otherwise a
/// fresh exchange.
pub async fn token() -> Option<String> {
    if let Some(cached) = cached_token() {
        return Some(cached);
    }

    let creds = credentials()?;
    let _one_at_a_time = MINTING.lock().await;
    // Someone else may have minted one while this was waiting for the lock.
    if let Some(cached) = cached_token() {
        return Some(cached);
    }

    /*
     * The `password` grant, not `client_credentials`.
     *
     * A script-type app on Reddit authenticates as its owner, and the
     * client-credentials grant it also accepts gives a token that cannot read
     * a subreddit listing — it answers 403 to exactly the request this source
     * exists to make. This is the grant the user's own setup uses.
     */
    let body = exchange(&creds).await?;
    let json: serde_json::Value = serde_json::from_str(&body).ok()?;
    let access = json.get("access_token").and_then(|v| v.as_str())?;
    let expires_in = json.get("expires_in").and_then(|v| v.as_i64()).unwrap_or(3600);

    store_token(access, expires_in);
    eprintln!("[quarryd] reddit: token refreshed, good for {} minutes", expires_in / 60);
    Some(access.to_string())
}

/*
 * REDDIT PAGES BY CURSOR, NOT BY NUMBER.
 *
 * Every other source here takes `?page=3`. Reddit takes `after=t3_abc123` — the
 * fullname of the last post you saw — and there is no way to ask for the third
 * page without having walked the first two. The crawl loop only knows about
 * page numbers, so the cursor is remembered here, keyed by the listing it
 * belongs to, and `parse` updates it from each response.
 *
 * In memory only: it is a position in a feed that reorders constantly, so
 * persisting it would restore a cursor into a listing that no longer exists.
 */
static CURSORS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

fn cursor_for(key: &str) -> Option<String> {
    CURSORS.lock().ok()?.as_ref()?.get(key).cloned()
}

fn remember_cursor(key: &str, after: &str) {
    if let Ok(mut guard) = CURSORS.lock() {
        let map = guard.get_or_insert_with(HashMap::new);
        if after.is_empty() {
            map.remove(key);
        } else {
            map.insert(key.to_string(), after.to_string());
        }
    }
}

/// Which search a cursor belongs to, when the last request built was a
/// search rather than a subreddit listing. A search answer does not echo its
/// query, so `parse` cannot key the cursor from the response the way it does
/// for a listing.
static SEARCHING: Mutex<Option<String>> = Mutex::new(None);

/// What a query asks Reddit for.
#[derive(Debug, Clone, PartialEq)]
enum Ask {
    /// A subreddit's feed: `r/wallpapers`, or nothing typed at all.
    Listing { sub: String, sort: &'static str },
    /// Reddit's own search, across the site or inside one subreddit
    /// (`r/earthporn lake`).
    Search { sub: Option<String>, words: String, sort: &'static str },
    /// One person's submissions. `author:` through site search is unreliable —
    /// reddit dropped the operator — but /user/<name>/submitted is exact.
    User { name: String, sort: &'static str },
}

fn clean_sub(raw: &str) -> String {
    raw.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_').collect()
}

/*
 * WORDS ARE A SEARCH. `r/name` IS A SUBREDDIT.
 *
 * This used to read the first word as a subreddit name, so `mountain lake`
 * fetched r/mountain — a real place, with its own front page, which is not
 * what anyone typing two words asked for. Reddit has a search; typed words go
 * to it. Naming a subreddit the way Reddit writes it still opens that
 * subreddit, and words after it search inside it.
 */
fn ask(query: &SourceQuery) -> Ask {
    let raw = query
        .text
        .iter()
        .chain(query.tags.iter())
        .map(|s| s.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let raw = raw.trim();

    let (sub, words) = match raw.trim_start_matches('/').strip_prefix("r/") {
        Some(rest) => {
            let (name, words) = rest.split_once([' ', '/']).unwrap_or((rest, ""));
            let name = clean_sub(name);
            (if name.is_empty() { None } else { Some(name) }, words.trim().to_string())
        }
        None => (None, raw.to_string()),
    };

    // A named creator is a place on reddit, not a word to search for.
    if !query.author.is_empty() && words.is_empty() && sub.is_none() {
        let sort = match query.sort {
            crate::query::Sort::Newest => "new",
            crate::query::Sort::Largest | crate::query::Sort::Widest => "top",
            _ => "new",
        };
        return Ask::User { name: clean_sub(&query.author), sort };
    }

    if words.is_empty() {
        let sort = match query.sort {
            crate::query::Sort::Newest => "new",
            crate::query::Sort::Largest | crate::query::Sort::Widest => "top",
            _ => "hot",
        };
        return Ask::Listing { sub: sub.unwrap_or_else(|| "wallpapers".to_string()), sort };
    }

    let sort = match query.sort {
        crate::query::Sort::Newest => "new",
        crate::query::Sort::Largest | crate::query::Sort::Widest => "top",
        crate::query::Sort::Random => "hot",
        _ => "relevance",
    };
    Ask::Search { sub, words, sort }
}

/*
 * A GALLERY'S PICTURES, IN THE ORDER SOMEBODY CHOSE.
 *
 * `gallery_data.items` is the sequence; `media_metadata` is the map it points
 * into. Returns (url, thumb, width, height) per picture, or None when the post
 * is not a gallery.
 *
 * Every URL here arrives HTML-escaped (`&amp;`), which is why they are
 * unescaped rather than 404ing later with a URL that looks right in a log.
 */
fn gallery_items(post: &serde_json::Value) -> Option<Vec<(String, String, u32, u32)>> {
    let order = scrape::json_pluck(post, "gallery_data.items")?.as_array()?;
    let meta = post.get("media_metadata")?.as_object()?;
    let mut out = Vec::with_capacity(order.len());
    for entry in order {
        let Some(id) = entry.get("media_id").and_then(|v| v.as_str()) else { continue };
        let Some(m) = meta.get(id) else { continue };
        // A deleted picture stays in the list with status "failed"; keeping it
        // would be a broken tile with no way to tell why.
        if m.get("status").and_then(|v| v.as_str()).unwrap_or("valid") != "valid" {
            continue;
        }
        // An animated entry keeps its file under `s.gif`/`s.mp4`; a still one
        // under `s.u`.
        let source = m.get("s")?;
        let url = ["u", "gif", "mp4"]
            .iter()
            .filter_map(|k| source.get(*k).and_then(|v| v.as_str()))
            .next()
            .map(scrape::html_unescape)
            .unwrap_or_default();
        if url.is_empty() {
            continue;
        }
        let w = source.get("x").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let h = source.get("y").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        // The largest preview under 1080 wide, same rule as a single post.
        let thumb = m
            .get("p")
            .and_then(|p| p.as_array())
            .and_then(|list| {
                list.iter().rev().find(|r| r.get("x").and_then(|v| v.as_u64()).unwrap_or(0) <= 1080)
            })
            .and_then(|r| r.get("u").and_then(|v| v.as_str()))
            .map(scrape::html_unescape)
            .unwrap_or_default();
        out.push((url, thumb, w, h));
    }
    (!out.is_empty()).then_some(out)
}

/// The playable file of a Reddit-hosted video: (url, width, height, seconds).
fn reddit_video(post: &serde_json::Value) -> Option<(String, u32, u32, f64)> {
    let video = scrape::json_pluck(post, "secure_media.reddit_video")
        .or_else(|| scrape::json_pluck(post, "media.reddit_video"))
        .or_else(|| scrape::json_pluck(post, "preview.reddit_video_preview"))?;
    let url = scrape::html_unescape(&scrape::json_str(video, "fallback_url"));
    if url.is_empty() {
        return None;
    }
    Some((
        url,
        video.get("width").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        video.get("height").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        video.get("duration").and_then(|v| v.as_f64()).unwrap_or(0.0),
    ))
}

/// The biggest preview a wall can use without fetching the whole video.
fn preview_thumb(post: &serde_json::Value) -> String {
    scrape::json_pluck(post, "preview.images[0].resolutions")
        .and_then(|r| r.as_array())
        .and_then(|list| {
            list.iter().rev().find(|r| r.get("width").and_then(|v| v.as_u64()).unwrap_or(0) <= 1080)
        })
        .map(|r| scrape::html_unescape(&scrape::json_str(r, "url")))
        .unwrap_or_default()
}

impl Source for Reddit {
    fn id(&self) -> &'static str {
        "reddit"
    }

    fn category(&self) -> &'static str {
        "wallpapers"
    }

    /// Reddit refuses anonymous API traffic outright, so with no credential
    /// there is nothing to ask. See `configured` for what has to be set.
    fn unavailable(&self) -> Option<String> {
        if configured() {
            return None;
        }
        Some(
            "reddit needs an app credential — set REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, \
             REDDIT_USER and REDDIT_PASS (in the environment or ~/.secure/reddit-app.env)"
                .to_string(),
        )
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            // The "search" here is which subreddit to read, which is a section
            // rather than a filter — so the text is consumed by the listing and
            // everything else is applied locally.
            text: true,
            // /user/<name>/submitted is a real listing of one person's posts.
            author: true,
            tags: true,
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: true,
            colors: false,
            video: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        match ask(query) {
            Ask::Listing { sub, sort } => {
                let key = format!("{sub}/{sort}");
                if let Ok(mut searching) = SEARCHING.lock() {
                    *searching = None;
                }

                // Page one starts the listing over; anything else continues
                // from where the last response said it had got to.
                let after = if query.page <= 1 { None } else { cursor_for(&key) };

                let mut url =
                    format!("https://oauth.reddit.com/r/{sub}/{sort}?limit=100&raw_json=1");
                if sort == "top" {
                    url.push_str("&t=all");
                }
                if let Some(after) = after {
                    url.push_str(&format!("&after={after}"));
                }
                url
            }
            Ask::Search { sub, words, sort } => {
                let key = format!(
                    "search:{}:{}:{sort}",
                    sub.as_deref().unwrap_or(""),
                    words.to_lowercase()
                );
                if let Ok(mut searching) = SEARCHING.lock() {
                    *searching = Some(key.clone());
                }
                let after = if query.page <= 1 { None } else { cursor_for(&key) };

                let mut url = match &sub {
                    Some(sub) => format!(
                        "https://oauth.reddit.com/r/{sub}/search?q={}&restrict_sr=1",
                        scrape::urlencode(&words)
                    ),
                    None => format!(
                        "https://oauth.reddit.com/search?q={}",
                        scrape::urlencode(&words)
                    ),
                };
                url.push_str(&format!("&type=link&sort={sort}&t=all&limit=100&raw_json=1"));
                if let Some(after) = after {
                    url.push_str(&format!("&after={after}"));
                }
                url
            }
            Ask::User { name, sort } => {
                let key = format!("user:{name}:{sort}");
                if let Ok(mut searching) = SEARCHING.lock() {
                    *searching = Some(key.clone());
                }
                let after = if query.page <= 1 { None } else { cursor_for(&key) };
                let mut url = format!(
                    "https://oauth.reddit.com/user/{name}/submitted?sort={sort}&t=all&limit=100&raw_json=1"
                );
                if let Some(after) = after {
                    url.push_str(&format!("&after={after}"));
                }
                url
            }
        }
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let document: serde_json::Value =
            serde_json::from_str(body).map_err(|e| format!("reddit: {e}"))?;

        let data = document.get("data").ok_or_else(|| {
            // A 403 page, or a token that expired mid-crawl: say which rather
            // than returning zero rows and looking like an empty subreddit.
            let message = scrape::json_str(&document, "message");
            if message.is_empty() {
                "reddit: no listing in the response".to_string()
            } else {
                format!("reddit: {message}")
            }
        })?;

        // The cursor for the next page, straight from the response. A search
        // answer does not say what was searched, so its cursor goes under the
        // search the last URL was built for.
        let searching = SEARCHING.lock().ok().and_then(|s| s.clone());
        if let Some(key) = searching {
            let after = data.get("after").and_then(|v| v.as_str()).unwrap_or("");
            remember_cursor(&key, after);
        } else if let Some(children) = data.get("children").and_then(|v| v.as_array()) {
            if let Some(first) = children.first() {
                let sub = scrape::json_str(first, "data.subreddit");
                if !sub.is_empty() {
                    let after = data.get("after").and_then(|v| v.as_str()).unwrap_or("");
                    // The sort is not in the response, so every listing of this
                    // subreddit shares a cursor. Crawls do one sort at a time.
                    for sort in ["hot", "new", "top"] {
                        remember_cursor(&format!("{}/{}", sub.to_lowercase(), sort), after);
                    }
                }
            }
        }

        let children = data
            .get("children")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "reddit: listing has no children".to_string())?;

        let mut items = Vec::with_capacity(children.len());
        for child in children {
            let outer = child.get("data").unwrap_or(child);

            /*
             * A CROSSPOST CARRIES ITS PICTURE IN THE POST IT CAME FROM.
             *
             * The crosspost itself has a reddit.com URL and no media, so the
             * old "is the URL an image?" test dropped it. The original is
             * right there in `crosspost_parent_list`, and taking the media
             * from it while keeping THIS post's id, title and permalink is
             * what every Reddit client does.
             */
            let parent = scrape::json_pluck(outer, "crosspost_parent_list[0]");
            let media = parent.unwrap_or(outer);
            let post = outer;

            /*
             * GALLERIES — A QUARTER OF A PICTURE SUBREDDIT, PREVIOUSLY ZERO.
             *
             * A gallery post's URL is `reddit.com/gallery/…`, which is not an
             * image, so every one of them was skipped: measured on one page of
             * r/wallpapers+EarthPorn+pics, 24 of 100 posts were galleries
             * holding 156 pictures, and quarry kept none of them.
             *
             * The pictures are in `media_metadata`, keyed by an id, and the
             * ORDER is in `gallery_data.items` — which is why both are read
             * rather than just iterating the map: a map has no order, and a
             * gallery is a sequence somebody chose.
             */
            if let Some(entries) = gallery_items(media) {
                let sub = scrape::json_str(post, "subreddit");
                let author = scrape::json_str(post, "author");
                let title = scrape::json_str(post, "title");
                let permalink = format!("https://reddit.com{}", scrape::json_str(post, "permalink"));
                let nsfw = scrape::json_pluck(post, "over_18").and_then(|v| v.as_bool()).unwrap_or(false);
                let base = scrape::json_str(post, "id");
                for (n, (url, thumb, w, h)) in entries.into_iter().enumerate() {
                    // One row per picture, with the post's number in its id so
                    // a re-crawl recognises the same picture rather than
                    // adding it again.
                    let mut item = scrape::normalize(
                        self.id(),
                        &format!("{base}-{n}"),
                        &title,
                        &url,
                        &thumb,
                        &permalink,
                        w,
                        h,
                        if sub.is_empty() { Vec::new() } else { vec![sub.to_lowercase()] },
                    );
                    item.author = author.clone();
                    item.nsfw = nsfw;
                    items.push(item);
                }
                continue;
            }

            /*
             * A REDDIT VIDEO IS A FILE, NOT A PAGE.
             *
             * `v.redd.it/xyz` has no extension, so these were dropped too.
             * The playable file, its size and its length are all in
             * `reddit_video` — including for a crosspost, which is why this
             * reads from `media` rather than the post.
             */
            if let Some(video) = reddit_video(media) {
                let (url, w, h, seconds) = video;
                let thumb = preview_thumb(media);
                let sub = scrape::json_str(post, "subreddit");
                let mut item = scrape::normalize(
                    self.id(),
                    &scrape::json_str(post, "id"),
                    &scrape::json_str(post, "title"),
                    &url,
                    &thumb,
                    &format!("https://reddit.com{}", scrape::json_str(post, "permalink")),
                    w,
                    h,
                    if sub.is_empty() { Vec::new() } else { vec![sub.to_lowercase()] },
                );
                item.author = scrape::json_str(post, "author");
                item.nsfw = scrape::json_pluck(post, "over_18").and_then(|v| v.as_bool()).unwrap_or(false);
                item.duration = seconds;
                items.push(item);
                continue;
            }

            // Self posts and links to articles: anything whose URL is not an
            // image is not a row.
            let url = scrape::json_str(media, "url_overridden_by_dest");
            let url = if url.is_empty() { scrape::json_str(media, "url") } else { url };
            let ext = scrape::guess_ext(&url, None);
            if !matches!(ext.as_str(), "jpg" | "jpeg" | "png" | "webp" | "gif" | "mp4") {
                continue;
            }

            let id = scrape::json_str(post, "id");
            if id.is_empty() {
                continue;
            }

            /*
             * The dimensions Reddit already measured.
             *
             * They live under the preview, which is also where a usable
             * thumbnail lives — and the preview URLs come HTML-escaped
             * (`&amp;`), which is why they are unescaped here rather than
             * 404ing later with a URL that looks correct in a log.
             */
            let preview = scrape::json_pluck(media, "preview.images[0]");
            let (w, h) = preview
                .and_then(|p| p.get("source"))
                .map(|s| {
                    (
                        s.get("width").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                        s.get("height").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                    )
                })
                .unwrap_or((0, 0));

            let thumb = preview
                .and_then(|p| p.get("resolutions"))
                .and_then(|r| r.as_array())
                .and_then(|list| list.iter().rev().find(|r| {
                    r.get("width").and_then(|v| v.as_u64()).unwrap_or(0) <= 1080
                }))
                .map(|r| scrape::html_unescape(&scrape::json_str(r, "url")))
                .unwrap_or_default();

            let sub = scrape::json_str(post, "subreddit");
            let mut item = scrape::normalize(
                self.id(),
                &id,
                &scrape::json_str(post, "title"),
                &url,
                &thumb,
                &format!("https://reddit.com{}", scrape::json_str(post, "permalink")),
                w,
                h,
                // The subreddit is the one tag every post has, and it is the
                // one people search by.
                if sub.is_empty() { Vec::new() } else { vec![sub.to_lowercase()] },
            );
            item.author = scrape::json_str(post, "author");
            item.nsfw = scrape::json_pluck(post, "over_18")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            items.push(item);
        }

        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<serde_json::Value>(body)
            .ok()
            .and_then(|v| v.get("data")?.get("after").cloned())
            .map(|after| !after.is_null())
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod search_tests {
    use super::*;

    fn q(text: &str) -> SourceQuery {
        SourceQuery {
            text: text.split_whitespace().map(str::to_string).collect(),
            page: 1,
            ..Default::default()
        }
    }

    #[test]
    fn typed_words_use_reddits_search_not_a_subreddit_named_after_the_first_word() {
        let url = Reddit.build_url(&q("blue boat"));
        assert!(url.starts_with("https://oauth.reddit.com/search?q=blue+boat&"), "{url}");
        assert!(url.contains("type=link") && url.contains("sort=relevance"), "{url}");
    }

    #[test]
    fn a_named_subreddit_is_its_feed_and_words_after_it_search_inside_it() {
        assert!(Reddit.build_url(&q("r/wallpapers")).starts_with("https://oauth.reddit.com/r/wallpapers/hot?"));
        let url = Reddit.build_url(&q("r/pics blue boat"));
        assert!(url.starts_with("https://oauth.reddit.com/r/pics/search?q=blue+boat&restrict_sr=1"), "{url}");
        // Nothing typed is still a browse of the default feed.
        assert!(Reddit.build_url(&q("")).starts_with("https://oauth.reddit.com/r/wallpapers/hot?"));
    }
}

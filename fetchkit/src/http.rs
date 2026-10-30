/*
 * The client itself: retries, the limiter, the cache and the headers above,
 * wired together so a caller writes `fetch_text` and gets all of it.
 */

#![allow(dead_code)]

use std::path::PathBuf;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::*;

pub struct Http {
    client: reqwest::Client,
    pub(crate) limiter: RateLimiter,
    /// A second, stricter limiter for form POSTs (currently: iqdb).
    ///
    /// The GET limiter's 700ms is sized for keyed APIs that can afford
    /// per-request pacing. A form-POST source reached through `post_form` is,
    /// so far, always a small free service with no key and no published
    /// limit — iqdb.org's own rule is just "don't hammer it" — so it gets a
    /// separate, multi-second-per-host limiter rather than sharing the
    /// keyed-API one and inheriting a pace those services never agreed to.
    pub(crate) form_limiter: RateLimiter,
    /// Pictures the user is looking at, paced apart from the crawl: a wall of
    /// empty tiles waiting behind forty crawl pages on the same host is the
    /// difference between "loading" and "broken".
    thumb_limiter: RateLimiter,
    cache: Option<Cache>,
    attempts: u32,
}

impl Http {
    pub fn new() -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .timeout(Duration::from_secs(20))
            .connect_timeout(Duration::from_secs(8))
            .build()
            .map_err(|e| ScrapeError::Http(e.to_string()))?;

        Ok(Http {
            client,
            limiter: RateLimiter::new(Duration::from_millis(700)),
            form_limiter: RateLimiter::new(Duration::from_secs(5)),
            thumb_limiter: RateLimiter::new(Duration::from_millis(250)),
            cache: None,
            attempts: 3,
        })
    }

    /// The client itself, for a caller that has to drive the request rather
    /// than take an answer — the stream proxy forwards Range and streams back.
    pub fn raw(&self) -> &reqwest::Client {
        &self.client
    }

    pub fn with_cache(mut self, dir: impl Into<PathBuf>, ttl: Duration) -> Self {
        self.cache = Some(Cache::new(dir, ttl));
        self
    }

    pub fn with_delay(mut self, delay: Duration) -> Self {
        self.limiter = RateLimiter::new(delay);
        self
    }

    /// GET a page as text: rate limited, cached, and retried on transient
    /// failures only.
    ///
    /// **7**
    pub async fn fetch_text(&self, url: &str) -> Result<String> {
        self.fetch_text_inner(url, true).await
    }

    /*
     * THE SAME PAGE, BUT NOT FROM THE CACHE.
     *
     * For a page whose VALUE EXPIRES. A video page carries signed media URLs
     * that die within minutes, so replaying a copy taken up to the cache's TTL
     * ago hands the player links that are already gone — measured on pornhub:
     * HTTP 410 on every one, and a black player with no error anywhere.
     *
     * Everything else about the request is unchanged: same limiter, same
     * referer and agent rules, same retries. Only the shortcut at the top is
     * skipped, and the answer is still written to the cache for whoever asks
     * next without caring about freshness.
     */
    pub async fn fetch_text_fresh(&self, url: &str) -> Result<String> {
        self.fetch_text_inner(url, false).await
    }

    async fn fetch_text_inner(&self, url: &str, may_reuse: bool) -> Result<String> {
        if may_reuse {
            if let Some(cache) = &self.cache {
                if let Some(hit) = cache.get(url).await {
                    return Ok(hit);
                }
            }
        }

        let mut last = ScrapeError::Http("no attempt made".into());
        for attempt in 1..=self.attempts {
            self.limiter.wait(url).await;

            let mut request = self.client.get(url);
            // The same hotlink rule the image fetch honours: some IIIF hosts
            // serve their API from the protected host too.
            if let Some(referer) = referer_for(url) {
                request = request.header(reqwest::header::REFERER, referer);
            }
            // A host that answers only a browser — see `set_host_agent`. The
            // client's own agent stays the default for everything else.
            if let Some(agent) = agent_for(url) {
                request = request.header(reqwest::header::USER_AGENT, agent);
            }
            for (name, value) in headers_for(url) {
                request = request.header(name, value);
            }
            match request.send().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if response.status().is_success() {
                        self.limiter.speed_up(url);
                        let body = response
                            .text()
                            .await
                            .map_err(|e| ScrapeError::Http(e.to_string()))?;
                        if let Some(cache) = &self.cache {
                            let _ = cache.put(url, &body).await;
                        }
                        return Ok(body);
                    }
                    if status == 429 {
                        // The host's own number when it gives one, so the pace
                        // is what it asked for rather than what we guessed.
                        self.limiter.slow_down(url, retry_after(response.headers()));
                        last = ScrapeError::RateLimited(url.to_string());
                        if attempt < self.attempts {
                            tokio::time::sleep(backoff_delay(attempt)).await;
                        }
                        continue;
                    }
                    last = ScrapeError::Status(status, url.to_string());
                    if !is_transient(status) {
                        // A 403 from a hotlink-blocking CDN, or a 404: asking
                        // again changes nothing and costs the host.
                        return Err(last);
                    }
                }
                Err(e) => last = ScrapeError::Http(e.to_string()),
            }

            if attempt < self.attempts {
                tokio::time::sleep(backoff_delay(attempt)).await;
            }
        }
        Err(last)
    }

    /// GET and deserialise.
    ///
    /// **8**
    pub async fn fetch_json<T: DeserializeOwned>(&self, url: &str) -> Result<T> {
        let body = self.fetch_text(url).await?;
        serde_json::from_str(&body).map_err(|e| ScrapeError::Parse(e.to_string()))
    }

    /// POST JSON and deserialise — GraphQL sources (AniList, Printables) answer
    /// only to POST; a GET returns 404 or 400.
    ///
    /// **9**
    pub async fn post_json<T: DeserializeOwned>(&self, url: &str, body: &Value) -> Result<T> {
        self.limiter.wait(url).await;
        let response = self
            .client
            .post(url)
            .json(body)
            .send()
            .await
            .map_err(|e| ScrapeError::Http(e.to_string()))?;

        let status = response.status().as_u16();
        if !response.status().is_success() {
            // 429 is its own variant so a caller can tell "slow down" from
            // "this is not here" — which for a thumbnail is the difference
            // between retrying later and hiding the row forever.
            return Err(if status == 429 {
                ScrapeError::RateLimited(url.to_string())
            } else {
                ScrapeError::Status(status, url.to_string())
            });
        }
        response.json::<T>().await.map_err(|e| ScrapeError::Parse(e.to_string()))
    }

    /// POST a `application/x-www-form-urlencoded` body and return the response
    /// text — a reverse-image form post (iqdb), where the "query" is a set of
    /// fields rather than a URL.
    ///
    /// Deliberately uncached, unlike `fetch_text`: caching is keyed by URL, and
    /// the URL here is iqdb's fixed endpoint, not the query. Caching it would
    /// hand back whatever picture's matches happened to be cached first —
    /// wrong for every request after the one that filled the cache. A reverse
    /// search is a fresh question every time and must hit the network every
    /// time.
    ///
    /// Rate limited through `form_limiter`, not the GET path's `limiter` — see
    /// that field's doc comment. On a 429 the error is `RateLimited`, not the
    /// generic `Status`, so a caller (and the message shown to a human) can
    /// tell "back off, this host is strict" apart from a genuine bad request;
    /// a 429 is still transient and gets the same retry/backoff as any other.
    ///
    /// **9b**
    /// A GET carrying a bearer token, uncached.
    ///
    /// Separate from `fetch_text` on purpose: an authenticated response is
    /// tied to a token that expires, and putting it in the shared URL cache
    /// would serve it back after the token — and possibly the session — is
    /// gone. It also must not be logged anywhere, which the cache would do by
    /// writing it to disk under a key.
    pub async fn fetch_text_bearer(&self, url: &str, token: &str) -> Result<String> {
        self.fetch_text_bearer_as(url, token, USER_AGENT).await
    }

    /// The same, sending a specific User-Agent.
    ///
    /// Reddit refuses its own OAuth API with a 403 unless the request carries
    /// the User-Agent the app was registered with — the token is necessary and
    /// not sufficient. Nothing in the error says so: it is a bare 403 on an
    /// endpoint that has just accepted your credentials, which reads as a
    /// permissions problem rather than a header one.
    pub async fn fetch_text_bearer_as(
        &self,
        url: &str,
        token: &str,
        user_agent: &str,
    ) -> Result<String> {
        let mut last = ScrapeError::Http("no attempt made".into());
        for attempt in 1..=self.attempts {
            self.limiter.wait(url).await;
            match self
                .client
                .get(url)
                .bearer_auth(token)
                .header(reqwest::header::USER_AGENT, user_agent)
                .send()
                .await
            {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if response.status().is_success() {
                        return response.text().await.map_err(|e| ScrapeError::Http(e.to_string()));
                    }
                    // A 401 means the token died early — a retry with the same
                    // one cannot help, and the caller has to mint another.
                    if status == 401 {
                        return Err(ScrapeError::Status(401, url.to_string()));
                    }
                    last = if status == 429 {
                        ScrapeError::RateLimited(url.to_string())
                    } else {
                        ScrapeError::Status(status, url.to_string())
                    };
                    if !is_transient(status) {
                        return Err(last);
                    }
                }
                Err(e) => last = ScrapeError::Http(e.to_string()),
            }
            if attempt < self.attempts {
                tokio::time::sleep(backoff_delay(attempt)).await;
            }
        }
        Err(last)
    }

    /// A form POST with HTTP basic auth — an OAuth token exchange, and nothing
    /// else so far.
    pub async fn post_form_basic(
        &self,
        url: &str,
        user: &str,
        password: &str,
        fields: &[(&str, &str)],
    ) -> Result<String> {
        self.post_form_basic_as(url, USER_AGENT, user, password, fields).await
    }

    /// The same, with the User-Agent the credentials belong to — see
    /// `fetch_text_bearer_as`.
    pub async fn post_form_basic_as(
        &self,
        url: &str,
        user_agent: &str,
        user: &str,
        password: &str,
        fields: &[(&str, &str)],
    ) -> Result<String> {
        self.form_limiter.wait(url).await;
        let response = self
            .client
            .post(url)
            .basic_auth(user, Some(password))
            .header(reqwest::header::USER_AGENT, user_agent)
            .form(fields)
            .send()
            .await
            .map_err(|e| ScrapeError::Http(e.to_string()))?;

        let status = response.status().as_u16();
        if !response.status().is_success() {
            // Deliberately without the body: an auth failure's response can
            // echo back what was sent.
            return Err(ScrapeError::Status(status, "token exchange".into()));
        }
        response.text().await.map_err(|e| ScrapeError::Http(e.to_string()))
    }

    pub async fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<String> {
        let mut last = ScrapeError::Http("no attempt made".into());
        for attempt in 1..=self.attempts {
            self.form_limiter.wait(url).await;

            match self.client.post(url).form(fields).send().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if response.status().is_success() {
                        return response
                            .text()
                            .await
                            .map_err(|e| ScrapeError::Http(e.to_string()));
                    }
                    last = if status == 429 {
                        ScrapeError::RateLimited(url.to_string())
                    } else {
                        ScrapeError::Status(status, url.to_string())
                    };
                    if !is_transient(status) {
                        // A 4xx that is not a rate limit: the request itself
                        // is the problem, and asking again changes nothing.
                        return Err(last);
                    }
                }
                Err(e) => last = ScrapeError::Http(e.to_string()),
            }

            if attempt < self.attempts {
                tokio::time::sleep(backoff_delay(attempt)).await;
            }
        }
        Err(last)
    }

    /*
     * POST A FILE AS THE WHOLE BODY.
     *
     * Not a multipart form. Yandex's image uploader — the only caller so far,
     * and the reason this exists — answers `400 Incorrect avatar size` to an
     * `upfile=` part, to a `file=` part, and to every combination of its query
     * parameters; it answers 200 with the picture's handle when the bytes are
     * the entire body and the content type names the format. Measured
     * 2026-09-17. So this is deliberately NOT `post_form` with a file in it.
     *
     * Paced by the form limiter, not the GET one: an upload hands a small free
     * service a megabyte, which is the politeness question `post_form` already
     * answers for iqdb.
     */
    pub async fn post_bytes(
        &self,
        url: &str,
        content_type: &str,
        body: &[u8],
    ) -> Result<String> {
        let mut last = ScrapeError::Http("no attempt made".into());
        for attempt in 1..=self.attempts {
            self.form_limiter.wait(url).await;

            let request = self
                .client
                .post(url)
                .header(reqwest::header::CONTENT_TYPE, content_type)
                .body(body.to_vec());
            match request.send().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if response.status().is_success() {
                        return response
                            .text()
                            .await
                            .map_err(|e| ScrapeError::Http(e.to_string()));
                    }
                    last = if status == 429 {
                        ScrapeError::RateLimited(url.to_string())
                    } else {
                        ScrapeError::Status(status, url.to_string())
                    };
                    if !is_transient(status) {
                        // The request itself is wrong — the bytes, the type or
                        // the endpoint. Sending them again costs the host and
                        // changes nothing.
                        return Err(last);
                    }
                }
                Err(e) => last = ScrapeError::Http(e.to_string()),
            }

            if attempt < self.attempts {
                tokio::time::sleep(backoff_delay(attempt)).await;
            }
        }
        Err(last)
    }

    /*
     * A LARGE FILE, STRAIGHT TO DISK.
     *
     * `fetch_bytes` holds the body in memory under the client's 20-second
     * limit, which is right for a thumbnail and wrong for a video: a Commons
     * clip's 480p transcode is 74 MB and did not arrive in 20 seconds, so it
     * failed as "error decoding response body". This streams chunk by chunk
     * into `path.part` with a ten-minute budget, stops at `max_bytes`, and
     * renames only a complete file into place.
     */
    pub async fn download_to(&self, url: &str, path: &str, max_bytes: u64) -> Result<u64> {
        use tokio::io::AsyncWriteExt;
        self.limiter.wait(url).await;
        let mut request = self.client.get(url).timeout(Duration::from_secs(600));
        if let Some(referer) = referer_for(url) {
            request = request.header(reqwest::header::REFERER, referer);
        }
        for (name, value) in headers_for(url) {
            request = request.header(name, value);
        }
        let mut response = request.send().await.map_err(|e| ScrapeError::Http(e.to_string()))?;
        let status = response.status().as_u16();
        if !response.status().is_success() {
            return Err(if status == 429 {
                ScrapeError::RateLimited(url.to_string())
            } else {
                ScrapeError::Status(status, url.to_string())
            });
        }
        if response.content_length().is_some_and(|len| len > max_bytes) {
            return Err(ScrapeError::Io(format!("larger than {} MB", max_bytes / (1024 * 1024))));
        }
        let partial = format!("{path}.part");
        let mut file = tokio::fs::File::create(&partial)
            .await
            .map_err(|e| ScrapeError::Io(format!("create {partial}: {e}")))?;
        let mut written = 0u64;
        loop {
            let chunk = match response.chunk().await {
                Ok(Some(chunk)) => chunk,
                Ok(None) => break,
                Err(e) => {
                    let _ = tokio::fs::remove_file(&partial).await;
                    return Err(ScrapeError::Http(e.to_string()));
                }
            };
            written += chunk.len() as u64;
            if written > max_bytes {
                let _ = tokio::fs::remove_file(&partial).await;
                return Err(ScrapeError::Io(format!("larger than {} MB", max_bytes / (1024 * 1024))));
            }
            if let Err(e) = file.write_all(&chunk).await {
                let _ = tokio::fs::remove_file(&partial).await;
                return Err(ScrapeError::Io(format!("write {partial}: {e}")));
            }
        }
        file.flush().await.ok();
        drop(file);
        tokio::fs::rename(&partial, path)
            .await
            .map_err(|e| ScrapeError::Io(format!("rename {partial}: {e}")))?;
        Ok(written)
    }

    /// Raw bytes for a picture someone is waiting to see: the thumbnail lane,
    /// which is paced separately from the crawl's.
    pub async fn fetch_bytes_now(&self, url: &str) -> Result<Vec<u8>> {
        self.fetch_bytes_with(url, &self.thumb_limiter).await
    }

    /// Raw bytes, for thumbnails and originals.
    ///
    /// **10**
    pub async fn fetch_bytes(&self, url: &str) -> Result<Vec<u8>> {
        self.fetch_bytes_with(url, &self.limiter).await
    }

    async fn fetch_bytes_with(&self, url: &str, limiter: &RateLimiter) -> Result<Vec<u8>> {
        /*
         * A PICTURE YOU ALREADY HAVE.
         *
         * The local folder source describes its rows with `file://` URLs so
         * that everything downstream — the thumbnailer, the exporter, the
         * detail view — can treat them like any other row. That only works if
         * the one place bytes are fetched knows how to read a disk, which an
         * HTTP client does not: reqwest rejects the scheme outright, so every
         * local tile would have failed to load and then been marked broken.
         *
         * No rate limiter, no retry: it is a file.
         */
        if let Some(path) = url.strip_prefix("file://") {
            let path = path.split(['?', '#']).next().unwrap_or(path);
            return tokio::fs::read(path)
                .await
                .map_err(|e| ScrapeError::Io(format!("read {path}: {e}")));
        }

        limiter.wait(url).await;
        let mut request = self.client.get(url);
        // A host that answers only a browser applies to its pictures as well as
        // its listings — a 403 on the image is the same empty tile.
        if let Some(agent) = agent_for(url) {
            request = request.header(reqwest::header::USER_AGENT, agent);
        }
        // Hotlink protection, honoured — see REFERERS.
        if let Some(referer) = referer_for(url) {
            request = request.header(reqwest::header::REFERER, referer);
        }
        for (name, value) in headers_for(url) {
            request = request.header(name, value);
        }
        let response = request
            .send()
            .await
            .map_err(|e| ScrapeError::Http(e.to_string()))?;
        let status = response.status().as_u16();
        if !response.status().is_success() {
            // 429 is its own variant so a caller can tell "slow down" from
            // "this is not here" — which for a thumbnail is the difference
            // between retrying later and hiding the row forever.
            return Err(if status == 429 {
                limiter.slow_down(url, retry_after(response.headers()));
                ScrapeError::RateLimited(url.to_string())
            } else {
                ScrapeError::Status(status, url.to_string())
            });
        }
        limiter.speed_up(url);
        response
            .bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| ScrapeError::Http(e.to_string()))
    }

    /// Is this source answering at all? `doctor` uses it to name the broken
    /// adapter instead of showing an empty gallery.
    ///
    /// **11**
    pub async fn probe(&self, url: &str) -> (u16, String) {
        let mut request = self.client.get(url);
        for (name, value) in headers_for(url) {
            request = request.header(name, value);
        }
        match request.send().await {
            Ok(r) => {
                let code = r.status().as_u16();
                let len = r.content_length().unwrap_or(0);
                (code, format!("{code}, {len} bytes"))
            }
            Err(e) => (0, e.to_string()),
        }
    }
}

// ── parsing ─────────────────────────────────────────────────────────────────

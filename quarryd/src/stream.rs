//! A local HTTP door for streams a media player cannot fetch itself.
//!
//! Tube sites serve HLS and answer 410/412 without the page's Referer, which
//! Qt's player has no way to send. Downloading the whole file first works and
//! takes minutes (measured: 6 for a 3-minute clip). This listens on loopback,
//! re-requests upstream with the headers the host wants, and streams the bytes
//! back — so playback starts at once and seeking still works.
//!
//! Playlists are rewritten so their segments come back through here too.

use std::collections::HashMap;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

pub struct Proxy {
    http: Arc<crate::scrape::Http>,
    /// token → (url, referer). Small and short-lived: one entry per video the
    /// viewer has opened this run.
    targets: Mutex<HashMap<String, (String, String)>>,
    port: u16,
}

impl Proxy {
    /// Bind on loopback and serve until the daemon stops. `None` when the port
    /// cannot be had, which is not fatal — callers fall back to downloading.
    pub async fn start(http: Arc<crate::scrape::Http>) -> Option<Arc<Proxy>> {
        let listener = TcpListener::bind("127.0.0.1:0").await.ok()?;
        let port = listener.local_addr().ok()?.port();
        let proxy = Arc::new(Proxy {
            http,
            targets: Mutex::new(HashMap::new()),
            port,
        });

        let serving = Arc::clone(&proxy);
        tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else { continue };
                let serving = Arc::clone(&serving);
                tokio::spawn(async move {
                    let _ = serving.serve(socket).await;
                });
            }
        });
        Some(proxy)
    }

    /// Register a stream and answer the local URL that plays it.
    pub async fn offer(&self, url: &str, referer: &str) -> String {
        let token = format!("{:08x}", url.bytes().fold(2166136261u32, |h, b| (h ^ b as u32).wrapping_mul(16777619)));
        self.targets.lock().await.insert(token.clone(), (url.to_string(), referer.to_string()));
        format!("http://127.0.0.1:{}/s/{token}", self.port)
    }

    async fn serve(&self, socket: TcpStream) -> std::io::Result<()> {
        let (read, mut write) = socket.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await?;
        let mut parts = line.split_whitespace();
        let (_method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or("").to_string());

        // The player's Range header is forwarded so seeking works.
        let mut range = String::new();
        loop {
            let mut header = String::new();
            if reader.read_line(&mut header).await? == 0 || header.trim().is_empty() {
                break;
            }
            if let Some(value) = header.to_ascii_lowercase().strip_prefix("range:") {
                range = value.trim().to_string();
            }
        }

        let (token, upstream) = match parse_path(&path) {
            Some(parsed) => parsed,
            None => return write.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await,
        };
        let Some((registered, referer)) = self.targets.lock().await.get(&token).cloned() else {
            return write.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await;
        };
        let url = upstream.unwrap_or(registered);

        let send_with = |target: &str, keep_range: bool, keep_referer: bool| {
            let mut request = self.http.raw().get(target);
            if keep_referer && !referer.is_empty() {
                request = request.header(reqwest::header::REFERER, &referer);
            }
            if keep_range && !range.is_empty() {
                request = request.header(reqwest::header::RANGE, &range);
            }
            request.send()
        };

        /*
         * ALWAYS ASK FOR WHAT WAS ACTUALLY ASKED FOR, and let the ladder sort
         * out a refusal.
         *
         * A cache of "what this host wanted last time" was tried here and
         * removed, because the quirk does not belong to the host. Measured on
         * one pornhub video: its `.m4s` segments answer 410 to a ranged request
         * and 200 without, and its `.ts` segments do the exact opposite — 470
         * without a range, 200 with one, from the SAME host. Remembering either
         * answer breaks the other, and the cache was also worth nothing:
         * decoding 12s of video took 1.1s with it and 1.4s without.
         */
        let mut response = match send_with(&url, true, true).await {
            Ok(response) => response,
            Err(_) => return write.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n").await,
        };

        /*
         * WHEN THE UPSTREAM REFUSES, DROP THE THINGS IT MIGHT BE REFUSING.
         *
         * Three independent faults, all measured, and all of which looked the
         * same from here — a refusal on a URL that was perfectly good:
         *
         *  1. THE EDGE. Four of six pornhub videos were handed out on
         *     `hv-h.phncdn.com` and every one answered 410 Gone, while the
         *     identical path and signature on `ev-h.phncdn.com` answered 200.
         *     The token had 59 minutes left; the edge simply refused.
         *
         *  2. THE RANGE. A pornhub segment fetched plainly returns 200; the
         *     same segment with `Range: bytes=0-` returns 410 on BOTH hosts.
         *     Every player sends that header and curl does not, which is how
         *     the whole chain tested clean by hand and still would not play.
         *
         *  3. THE REFERER. hqporner's link redirects to an ahcdn host which
         *     answers 200 with no Referer and 403 with `hqporner.com` — and
         *     reqwest carries the header across the redirect, so sending the
         *     page's own referer is what got it refused.
         *
         * Each axis is dropped only AFTER a failure, never up front: the
         * referer is what makes most of these hosts serve at all, and a
         * progressive mp4 needs the range to seek. The first 2xx wins.
         */
        if !(200..300).contains(&response.status().as_u16()) {
            for (target, keep_range, keep_referer) in retry_ladder(&url, !range.is_empty()) {
                let Ok(retry) = send_with(&target, keep_range, keep_referer).await else {
                    continue;
                };
                if (200..300).contains(&retry.status().as_u16()) {
                    response = retry;
                    break;
                }
            }
        }

        let status = response.status().as_u16();
        let kind = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();

        // A playlist is rewritten, because its segment URLs need these headers
        // too; anything else is passed through as it arrives.
        /*
         * AN UPSTREAM FAILURE IS NOT A 200 WITH NOTHING IN IT.
         *
         * This answered 200 and an empty body whenever the upstream refused —
         * measured: phncdn returns 410 for an expired signed playlist and the
         * player received `200 OK, Content-Length: 1`. A player given an empty
         * playlist does not error; it waits, which is the black rectangle, and
         * nothing anywhere said the link was dead.
         */
        if !(200..300).contains(&status) {
            let head = format!(
                "HTTP/1.1 {status} Upstream Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            write.write_all(head.as_bytes()).await?;
            return write.shutdown().await;
        }

        if url.split(['?', '#']).next().unwrap_or("").ends_with(".m3u8") || kind.contains("mpegurl") {
            let body = response.text().await.unwrap_or_default();
            let rewritten = self.rewrite(&body, &url, &token);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: {}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
                rewritten.len()
            );
            write.write_all(head.as_bytes()).await?;
            write.write_all(rewritten.as_bytes()).await?;
            return write.shutdown().await;
        }

        let length = response.content_length();
        /*
         * `Connection: close`, always.
         *
         * Without it the player keeps the connection open waiting for more
         * body — and when the upstream is chunked there is no Content-Length
         * to say where it ended, so playback sat at "buffering" for ever.
         * Closing the socket is what ends the message here.
         */
        let mut head = format!("HTTP/1.1 {status} OK\r\nContent-Type: {kind}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n");
        if let Some(len) = length {
            head.push_str(&format!("Content-Length: {len}\r\n"));
        }
        for name in [reqwest::header::CONTENT_RANGE] {
            if let Some(value) = response.headers().get(&name).and_then(|v| v.to_str().ok()) {
                head.push_str(&format!("{name}: {value}\r\n"));
            }
        }
        head.push_str("\r\n");
        write.write_all(head.as_bytes()).await?;

        let mut response = response;
        while let Ok(Some(chunk)) = response.chunk().await {
            if write.write_all(&chunk).await.is_err() {
                break;      // the player stopped listening: seek, or closed
            }
        }
        write.shutdown().await.ok();
        Ok(())
    }

    /// Point every URI in a playlist back at this proxy, keeping its token.
    fn rewrite(&self, body: &str, base: &str, token: &str) -> String {
        body.lines()
            .map(|line| {
                let trimmed = line.trim();
                if trimmed.is_empty() || trimmed.starts_with('#') {
                    return rewrite_attribute(line, base, token, self.port);
                }
                let absolute = crate::scrape::abs_url(base, trimmed).unwrap_or_else(|| trimmed.to_string());
                format!(
                    "http://127.0.0.1:{}/p/{token}/{}?u={}",
                    self.port,
                    part_name(&absolute),
                    crate::scrape::urlencode(&absolute)
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// `#EXT-X-KEY:...URI="..."` and friends carry URLs in an attribute.
fn rewrite_attribute(line: &str, base: &str, token: &str, port: u16) -> String {
    let Some(start) = line.find("URI=\"") else { return line.to_string() };
    let rest = &line[start + 5..];
    let Some(end) = rest.find('"') else { return line.to_string() };
    let absolute = crate::scrape::abs_url(base, &rest[..end]).unwrap_or_else(|| rest[..end].to_string());
    format!(
        "{}URI=\"http://127.0.0.1:{port}/p/{token}/{}?u={}\"{}",
        &line[..start],
        part_name(&absolute),
        crate::scrape::urlencode(&absolute),
        &rest[end + 1..]
    )
}

/*
 * `/s/<token>` is the stream; `/p/<token>/<name>?u=<url>` one of its parts.
 *
 * The name carries the upstream's own extension because ffmpeg's HLS demuxer
 * refuses a segment whose URL has none — "not a common multimedia extension,
 * blocked for security reasons" — and every proxied segment looked like that.
 */
fn parse_path(path: &str) -> Option<(String, Option<String>)> {
    let (route, query) = match path.split_once('?') {
        Some((route, query)) => (route, Some(query)),
        None => (path, None),
    };
    if let Some(token) = route.strip_prefix("/s/") {
        return Some((token.to_string(), None));
    }
    let rest = route.strip_prefix("/p/")?;
    let token = rest.split('/').next()?.to_string();
    let raw = query?.strip_prefix("u=")?;
    Some((token, Some(crate::scrape::urldecode(raw))))
}

/// The upstream's own file name, so the proxied URL keeps its extension.
fn part_name(url: &str) -> String {
    let path = url.split(['?', '#']).next().unwrap_or("");
    let name = path.rsplit('/').next().unwrap_or("");
    let clean: String = name.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_').collect();
    if clean.contains('.') && clean.len() <= 80 { clean } else { "part.ts".to_string() }
}

#[cfg(test)]
mod tests {
    use super::{parse_path, rewrite_attribute};

    #[test]
    fn paths_name_a_stream_or_one_of_its_parts() {
        assert_eq!(parse_path("/s/abcd1234"), Some(("abcd1234".into(), None)));
        let (token, url) = parse_path("/p/abcd1234/seg1.ts?u=https%3A%2F%2Fcdn.example%2Fseg1.ts").unwrap();
        assert_eq!(token, "abcd1234");
        assert_eq!(url.as_deref(), Some("https://cdn.example/seg1.ts"));
        assert_eq!(parse_path("/nope"), None);
    }

    #[test]
    fn a_key_uri_is_pointed_back_at_the_proxy() {
        let line = r#"#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1"#;
        let out = rewrite_attribute(line, "https://cdn.example/a/master.m3u8", "tok", 7000);
        assert!(out.contains("http://127.0.0.1:7000/p/tok/key.bin?u=https%3A%2F%2Fcdn.example%2Fa%2Fkey.bin"));
        assert!(out.ends_with(",IV=0x1"), "the rest of the line is untouched");
        assert_eq!(rewrite_attribute("#EXTINF:4.0,", "https://x/y.m3u8", "tok", 7000), "#EXTINF:4.0,");
    }
}

/*
 * ANOTHER EDGE TO ASK, for a CDN that hands out hosts which refuse.
 *
 * Returns None when there is nothing useful to try — a different CDN, or the
 * host that already works — so the caller retries exactly once and only where
 * a retry has been shown to help.
 */
/*
 * The order things are dropped in, after a refusal. Nearest-to-working first:
 * a different edge is the smallest change, then the range, then the referer —
 * which is last because it is the header most hosts require.
 */
fn retry_ladder(url: &str, has_range: bool) -> Vec<(String, bool, bool)> {
    let mut out: Vec<(String, bool, bool)> = Vec::new();
    let alternate = alternate_edge(url);

    if let Some(second) = &alternate {
        out.push((second.clone(), true, true));
    }
    if has_range {
        out.push((url.to_string(), false, true));
        if let Some(second) = &alternate {
            out.push((second.clone(), false, true));
        }
    }
    out.push((url.to_string(), has_range, false));
    if has_range {
        out.push((url.to_string(), false, false));
    }
    out
}

fn alternate_edge(url: &str) -> Option<String> {
    let host = url.split("://").nth(1)?.split('/').next()?;
    if !host.ends_with(".phncdn.com") || host.starts_with("ev-h.") {
        return None;
    }
    Some(url.replacen(host, "ev-h.phncdn.com", 1))
}

#[cfg(test)]
mod alternate_edge_tests {
    use super::{alternate_edge, retry_ladder};

    /// hqporner: the CDN it redirects to answers 200 with no referer and 403
    /// with the page's own. Dropping it has to be one of the things tried.
    #[test]
    fn the_referer_is_eventually_dropped() {
        let ladder = retry_ladder("https://video.flyflv.com/key=abc/x.mp4", true);
        assert!(
            ladder.iter().any(|(_, _, keep_referer)| !keep_referer),
            "no attempt without the referer: {ladder:?}"
        );
    }

    /// Every attempt keeps the referer until one has failed with it — it is
    /// what most of these hosts serve on.
    #[test]
    fn the_referer_is_kept_for_as_long_as_possible() {
        let ladder = retry_ladder("https://hv-h.phncdn.com/a/b.m3u8", true);
        let first_without = ladder.iter().position(|(_, _, keep)| !keep).unwrap();
        assert!(first_without > 0, "gave the referer up first: {ladder:?}");
    }

    /// Without a range there is nothing to drop, so those rungs are not there.
    #[test]
    fn a_rangeless_request_has_no_range_rungs() {
        let ladder = retry_ladder("https://video.flyflv.com/a.mp4", false);
        assert!(ladder.iter().all(|(_, keep_range, _)| !keep_range));
    }

    /// The measured case: hv-h answers 410, ev-h answers 200 for the same path.
    #[test]
    fn a_refusing_phncdn_edge_is_retried_on_the_one_that_answers() {
        let got = alternate_edge(
            "https://hv-h.phncdn.com/hls/videos/202609/20/1080P_4000K.mp4/master.m3u8?e=1791454885",
        );
        assert_eq!(
            got.as_deref(),
            Some("https://ev-h.phncdn.com/hls/videos/202609/20/1080P_4000K.mp4/master.m3u8?e=1791454885")
        );
    }

    /// The signature is part of the path and query, so it must survive intact —
    /// swapping the host is the whole change.
    #[test]
    fn the_signature_is_carried_over_untouched() {
        let got = alternate_edge("https://hv-h.phncdn.com/a/b.m3u8?h=x%2FY%3D&e=1&f=1").unwrap();
        assert!(got.ends_with("/a/b.m3u8?h=x%2FY%3D&e=1&f=1"), "mangled: {got}");
    }

    #[test]
    fn the_host_that_already_works_is_not_retried() {
        assert_eq!(alternate_edge("https://ev-h.phncdn.com/a/b.m3u8"), None);
    }

    #[test]
    fn another_cdn_is_left_alone() {
        assert_eq!(alternate_edge("https://cdn.example.test/a/b.m3u8"), None);
        assert_eq!(alternate_edge("not a url"), None);
    }
}

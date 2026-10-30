/*
 * URLs: which host, resolving a relative one, what extension it implies, and
 * whether it carries a signature that will expire.
 */

#![allow(dead_code)]

use std::path::Path;



/*
 * A URL THAT WAS ONLY EVER GOING TO WORK FOR A DAY.
 *
 * Pornhub's posters arrive as `…?hdnea=st=…~exp=…~hmac=…`; S3 and CloudFront
 * sign theirs differently and mean the same thing. The picture behind one is
 * fine — the signature aged out, and the next listing hands over the same row
 * with a new one.
 *
 * This matters because 403 is otherwise PERMANENT here, and rightly: a hotlink
 * block from cdn.donmai.us or the Art Institute is an answer, not a hiccup, and
 * retrying it for ever is what that rule exists to stop. A signed url is the one
 * case where the same status means "too late" rather than "not for you", so the
 * caller asks this before writing a row off.
 */
pub fn is_signed_url(url: &str) -> bool {
    ["hdnea=", "~exp=", "Expires=", "X-Amz-Expires=", "token=", "Key-Pair-Id="]
        .iter()
        .any(|marker| url.contains(marker))
}

/// The host part of a URL, for rate limiting and cache keys.
///
/// **4**
pub fn host_of(url: &str) -> Option<String> {
    url::Url::parse(url).ok()?.host_str().map(|h| h.to_string())
}

/// Resolve a possibly-relative href against the page it was found on.
///
/// **5**
pub fn abs_url(base: &str, href: &str) -> Option<String> {
    if href.starts_with("http://") || href.starts_with("https://") {
        return Some(href.to_string());
    }
    url::Url::parse(base).ok()?.join(href).ok().map(|u| u.to_string())
}

/// The extension, from the URL path and then from the content type. Query
/// strings are everywhere on image CDNs (`?width=256`), so a naive rsplit('.')
/// gets it wrong constantly.
///
/// **20**
pub fn guess_ext(url: &str, content_type: Option<&str>) -> String {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
        let ext = ext.to_ascii_lowercase();
        if ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            return ext;
        }
    }
    match content_type.unwrap_or("") {
        t if t.contains("png") => "png",
        t if t.contains("jpeg") || t.contains("jpg") => "jpg",
        t if t.contains("webp") => "webp",
        t if t.contains("gif") => "gif",
        t if t.contains("svg") => "svg",
        t if t.contains("avif") => "avif",
        _ => "bin",
    }
    .to_string()
}


pub fn urlencode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b' ' => "+".to_string(),
            other => format!("%{other:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_resolve_against_their_page() {
        assert_eq!(
            abs_url("https://pfps.gg/pfps/anime", "/pfps/cat").as_deref(),
            Some("https://pfps.gg/pfps/cat")
        );
        assert_eq!(
            abs_url("https://pfps.gg/", "https://cdn.pfps.gg/a.png").as_deref(),
            Some("https://cdn.pfps.gg/a.png")
        );
        assert_eq!(host_of("https://cdn.pfps.gg/pfps/1-2-x.png").as_deref(), Some("cdn.pfps.gg"));
    }

    #[test]
    fn extensions_survive_query_strings() {
        // Poly Haven's thumbnails, which is where a naive rsplit('.') breaks.
        assert_eq!(guess_ext("https://cdn.polyhaven.com/a/x.png?width=256&height=256", None), "png");
        assert_eq!(guess_ext("https://api.iconify.design/mdi/home.svg?height=128", None), "svg");
        assert_eq!(guess_ext("https://example.com/image", Some("image/webp")), "webp");
        assert_eq!(guess_ext("https://example.com/whatever", None), "bin");
    }
}

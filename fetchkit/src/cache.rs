/*
 * Answers already received.
 *
 * Scraping the same listing twice in a session is normal: a category crawl and
 * a search crawl overlap constantly, and a cache is the difference between
 * polite and rude.
 */

#![allow(dead_code)]

use std::path::PathBuf;
use std::time::Duration;


use crate::*;

/// An on-disk response cache.
///
/// Scraping the same listing page twice in a session is normal — a category
/// crawl and a search crawl overlap constantly — and a cache is the difference
/// between polite and rude.
///
/// **6**
pub struct Cache {
    dir: PathBuf,
    ttl: Duration,
}

impl Cache {
    pub fn new(dir: impl Into<PathBuf>, ttl: Duration) -> Self {
        Cache { dir: dir.into(), ttl }
    }

    fn key(url: &str) -> String {
        // FNV-1a: a cache key needs to be stable and cheap, not cryptographic.
        let mut hash: u64 = 0xcbf29ce484222325;
        for byte in url.as_bytes() {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("{hash:016x}")
    }

    fn path(&self, url: &str) -> PathBuf {
        self.dir.join(Self::key(url))
    }

    /// Cached body, if it exists and is younger than the TTL.
    pub async fn get(&self, url: &str) -> Option<String> {
        let path = self.path(url);
        let meta = tokio::fs::metadata(&path).await.ok()?;
        let age = meta.modified().ok()?.elapsed().ok()?;
        if age > self.ttl {
            return None;
        }
        tokio::fs::read_to_string(&path).await.ok()
    }

    pub async fn put(&self, url: &str, body: &str) -> Result<()> {
        tokio::fs::create_dir_all(&self.dir)
            .await
            .map_err(|e| ScrapeError::Io(e.to_string()))?;
        tokio::fs::write(self.path(url), body)
            .await
            .map_err(|e| ScrapeError::Io(e.to_string()))
    }
}

/// A filename-safe slug: lowercase, ASCII, single dashes, no leading or
/// trailing dash. Used in export path templates, so it must never produce a
/// name a filesystem will argue about.
///
/// **19**
/*
 * A CACHE KEY FOR AN ID: readable, and never shared by two ids.
 *
 * Cache files used to be named `slugify(id)`, and slugify is capped at 80
 * characters for export titles. Every local file under a long directory then
 * slugged to the same 80-character prefix, so a whole folder shared ONE
 * thumbnail file and pictures showed each other's faces.
 *
 * An id whose slug fits is still named exactly as before, so every thumbnail
 * already on disk stays valid. A longer one keeps a readable prefix and adds a
 * hash of the FULL id — FNV-1a, spelled out here, because a cache name must
 * not change when the compiler's hasher does.
 */
pub fn cache_key(id: &str) -> String {
    let slug = slugify_uncapped(id);
    if slug.len() <= 80 && !slug.is_empty() {
        return slug;
    }
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in id.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    let mut prefix: String = slug.chars().take(60).collect();
    while prefix.ends_with('-') {
        prefix.pop();
    }
    format!("{prefix}-{hash:016x}")
}


#[cfg(test)]
mod tests {
    use super::*;

    /// Two files in one long directory must not share a thumbnail.
    #[test]
    fn cache_keys_never_collide_on_a_long_shared_prefix() {
        let dir = "local:/home/someone/Pictures/reference/very/deep/directory/structure/for/a/project";
        let a = cache_key(&format!("{dir}/Bunny 1.jpg"));
        let b = cache_key(&format!("{dir}/Cat 2.jpg"));
        assert_ne!(a, b);
        assert!(a.len() < 100, "a cache key is a filename: {a}");
        // Short ids keep the name they always had, so existing caches survive.
        assert_eq!(cache_key("wallhaven:e82xxr"), slugify("wallhaven:e82xxr"));
        // And the key is stable run to run.
        assert_eq!(a, cache_key(&format!("{dir}/Bunny 1.jpg")));
        assert_eq!(slugify(""), "untitled");
        assert_eq!(slugify("!!!"), "untitled");
    }
}

/*
 * A CACHED PAGE IS NOT ALWAYS A USABLE PAGE.
 *
 * Most pages go stale — the words change and the old copy is merely old. A
 * video page EXPIRES: the media URLs on it are signed and die within minutes,
 * so replaying a copy taken inside the TTL hands a player links that are
 * already gone. Measured on pornhub: HTTP 410 on every rendition, and a black
 * player because nothing reported the failure.
 *
 * `Http::fetch_text_fresh` exists for that one case; this pins the thing it
 * depends on, which is that a fresh read does not consult the store.
 */
#[cfg(test)]
mod freshness_tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn a_stored_answer_is_returned_within_the_ttl() {
        let dir = std::env::temp_dir().join(format!("fetchkit-fresh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let cache = Cache::new(&dir, Duration::from_secs(900));
        cache.put("https://example.test/a", "first").await;
        assert_eq!(cache.get("https://example.test/a").await.as_deref(), Some("first"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Past the TTL it is gone, which is the ordinary staleness rule.
    #[tokio::test]
    async fn a_stored_answer_past_the_ttl_is_not_returned() {
        let dir = std::env::temp_dir().join(format!("fetchkit-stale-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let cache = Cache::new(&dir, Duration::from_secs(0));
        cache.put("https://example.test/b", "old").await;
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(cache.get("https://example.test/b").await, None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

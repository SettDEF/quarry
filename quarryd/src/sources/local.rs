//! Your own pictures.
//!
//! Every other source in this directory is somebody else's catalogue reached
//! over HTTP. This one is the folder on your disk, and for an app whose premise
//! is *every image slot on your desktop* it was the biggest hole in the
//! product: quarry knew about a million pictures and nothing about the
//! wallpaper you have had for two years.
//!
//! It is a `Source` like the rest — same push-down, same crawl loop, same
//! dedupe, same tagging — because the alternative was a second way to get rows
//! into the catalogue, with its own bugs. What makes that possible is a `file://`
//! URL: `build_url` names a directory and a page, the daemon lists it instead
//! of fetching it, and `parse` reads the listing. Everything downstream cannot
//! tell the difference and does not need to.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

#[derive(Default)]
pub struct Local;

impl Local {
    /// Where to look. `$QUARRY_LOCAL_DIRS` is a colon-separated list; without
    /// it, the places a person actually keeps pictures.
    pub fn roots() -> Vec<std::path::PathBuf> {
        if let Ok(list) = std::env::var("QUARRY_LOCAL_DIRS") {
            let dirs: Vec<std::path::PathBuf> = list
                .split(':')
                .filter(|s| !s.is_empty())
                .map(std::path::PathBuf::from)
                .collect();
            if !dirs.is_empty() {
                return dirs;
            }
        }

        let home = std::env::var("HOME").unwrap_or_default();
        ["Pictures", "Pictures/Wallpapers", "Videos"]
            .iter()
            .map(|leaf| std::path::PathBuf::from(format!("{home}/{leaf}")))
            .filter(|p| p.is_dir())
            .collect()
    }

    /// Extensions worth indexing — the ones the pipeline can actually open.
    fn wanted(ext: &str) -> bool {
        matches!(
            ext,
            "jpg" | "jpeg" | "png" | "webp" | "gif" | "avif" | "bmp" | "svg"
                | "mp4" | "webm" | "mkv" | "mov" | "m4v"
        )
    }

    /// Walk the roots and describe what is there, as the JSON `parse` expects.
    ///
    /// Called by the daemon when it sees this source's `file://` URL. Bounded
    /// rather than complete: a page at a time, so indexing a folder of forty
    /// thousand photographs does not block a crawl on the first call.
    pub fn scan(page: u32, per_page: usize) -> String {
        let mut found: Vec<serde_json::Value> = Vec::new();
        let skip = (page.saturating_sub(1) as usize) * per_page;
        let mut seen = 0usize;

        for root in Self::roots() {
            let mut stack = vec![root];
            while let Some(dir) = stack.pop() {
                let Ok(entries) = std::fs::read_dir(&dir) else { continue };
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        // A thumbnail cache under Pictures is not a picture
                        // library; nor is a hidden directory.
                        let name = entry.file_name();
                        let name = name.to_string_lossy();
                        if !name.starts_with('.') && name != "quarry" {
                            stack.push(path);
                        }
                        continue;
                    }

                    let ext = path
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or_default()
                        .to_lowercase();
                    if !Self::wanted(&ext) {
                        continue;
                    }

                    seen += 1;
                    if seen <= skip {
                        continue;
                    }
                    if found.len() >= per_page {
                        return serde_json::json!({ "files": found, "more": true }).to_string();
                    }

                    let bytes = entry.metadata().map(|m| m.len()).unwrap_or(0);
                    // Dimensions from the header alone: opening every file to
                    // decode it would make a scan of a picture folder a
                    // minutes-long job, and nothing here needs the pixels.
                    let (w, h) = image::image_dimensions(&path).unwrap_or((0, 0));

                    found.push(serde_json::json!({
                        "path": path.to_string_lossy(),
                        "name": path.file_stem().map(|s| s.to_string_lossy().to_string())
                            .unwrap_or_default(),
                        "ext": ext,
                        "w": w,
                        "h": h,
                        "bytes": bytes,
                    }));
                }
            }
        }

        serde_json::json!({ "files": found, "more": false }).to_string()
    }
}

impl Source for Local {
    fn id(&self) -> &'static str {
        "local"
    }

    fn category(&self) -> &'static str {
        "local"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            // Everything is filtered locally here — there is no remote side to
            // push anything down to, and the residue matcher is exact.
            text: false,
            tags: false,
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: false,
            colors: false,
            video: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        // Not a URL to fetch: a URL to READ. The daemon branches on the scheme.
        format!("file://local?page={}", query.page.max(1))
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let document: serde_json::Value =
            serde_json::from_str(body).map_err(|e| format!("local: {e}"))?;
        let files = document
            .get("files")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "local: no files in listing".to_string())?;

        let mut items = Vec::with_capacity(files.len());
        for file in files {
            let path = scrape::json_str(file, "path");
            if path.is_empty() {
                continue;
            }
            let w = scrape::json_pluck(file, "w").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let h = scrape::json_pluck(file, "h").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

            /*
             * A FILE URL, so everything downstream works unchanged.
             *
             * The thumbnailer fetches `url`, the exporter reads it, the detail
             * view shows it. Giving a local file the same shape as a remote one
             * means none of them needs to know where it came from — which is
             * the same reason the scan pretends to be an HTTP fetch.
             */
            let url = format!("file://{path}");
            let mut item = scrape::normalize(
                self.id(),
                &path,
                &scrape::json_str(file, "name"),
                &url,
                &url,
                &url,
                w,
                h,
                Vec::new(),
            );
            item.bytes = scrape::json_pluck(file, "bytes").and_then(|v| v.as_u64()).unwrap_or(0);
            // The folder it lives in is the only description a file has, and it
            // is usually a good one: `Pictures/Wallpapers/anime` says plenty.
            if let Some(parent) = std::path::Path::new(&path).parent() {
                if let Some(dir) = parent.file_name().and_then(|d| d.to_str()) {
                    item.tags.push(dir.to_lowercase());
                }
            }
            items.push(item);
        }
        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<serde_json::Value>(body)
            .ok()
            .and_then(|v| v.get("more").and_then(|m| m.as_bool()))
            .unwrap_or(false)
    }
}

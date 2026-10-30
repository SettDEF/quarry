//! pfps.gg — avatars and banners, from server-rendered HTML.
//!
//! There is no JSON API (`/api/pfps` is a 404), and none is needed: every card
//! on a listing page carries its image URL, and that URL carries the id, the
//! numeric key and the slug — which is also exactly how a detail page is
//! addressed. So one regex over a listing yields complete, linkable rows.
//!
//! The detail page (`/pfp/<id>-<n>-<slug>`) is where the rest lives — the
//! title, the uploader, the tags, and a "more like this" strip. That is fetched
//! per item on demand rather than during a crawl: a listing is 40 rows for one
//! request, and 40 detail pages for the same rows would be forty.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

#[derive(Default)]
pub struct PfpsGg {
    /// Set when the query asked for banners, so `parse` labels the rows it gets
    /// back correctly — a listing looks identical either way.
    pub wants_banners: bool,
}

/// One row on a listing page.
///
/// Avatars and banners live under different CDN paths — `/pfps/` and
/// `/banners/` — and the section is the only thing that distinguishes them,
/// since a listing looks identical either way. One pattern covers both and
/// captures which it was.
const CARD: &str = r"https://cdn\.pfps\.gg/(?P<section>pfps|banners)/(?P<id>\d+)-(?P<key>\d+)-(?P<slug>[a-z0-9-]+)\.(?P<ext>png|jpeg|jpg|gif|webp)";

/// What a detail page adds to a row.
#[derive(Debug, Default, PartialEq)]
pub struct Detail {
    pub title: String,
    pub author: String,
    pub tags: Vec<String>,
    pub image: String,
    /// The "More like this" strip, as ids — a related-items graph the site
    /// maintains and we would otherwise have to infer.
    pub related: Vec<String>,
}

impl PfpsGg {
    /// The categories the site itself puts in its footer — its own idea of what
    /// people come looking for. Offered as suggestions rather than crawled
    /// wholesale: they are a starting point for a query, not a catalogue.
    pub fn popular() -> &'static [&'static str] {
        &[
            "matching", "aesthetic", "anime", "cool", "cute", "animated", "gif",
            "naruto", "killua", "luffy", "itachi", "kaneki", "valorant",
            "minecraft", "sonic", "fortnite", "league", "egirl", "grunge",
            "y2k", "kawaii", "pastel", "dark", "goth",
        ]
    }

    /// The same terms, in the groups the site itself puts them in.
    ///
    /// They were already stored in that order and then flattened, so the
    /// structure survived as a coincidence of ordering and was invisible to
    /// anything reading them. A flat list of twenty-four words is not
    /// categories; these are.
    pub fn popular_groups() -> &'static [(&'static str, &'static [&'static str])] {
        &[
            ("Trending", &["matching", "aesthetic", "anime", "cool", "cute", "animated", "gif"]),
            ("Anime", &["naruto", "killua", "luffy", "itachi", "kaneki"]),
            ("Gaming", &["valorant", "minecraft", "sonic", "fortnite", "league"]),
            ("Aesthetic", &["egirl", "grunge", "y2k", "kawaii", "pastel", "dark", "goth"]),
        ]
    }

    /// Where a row's detail page lives. The id triple in the image URL *is* the
    /// address, so no extra request is needed to find it.
    pub fn page_url(id: &str, key: &str, slug: &str) -> String {
        format!("https://pfps.gg/pfp/{id}-{key}-{slug}")
    }

    fn banner_page_url(id: &str, key: &str, slug: &str) -> String {
        format!("https://pfps.gg/banner/{id}-{key}-{slug}")
    }

    pub fn parse_detail(html: &str) -> Detail {
        let mut detail = Detail::default();

        // "<title>Anime Pfp by 7429600522</title>" — the name and the uploader
        // in one string, which is all the page states plainly.
        if let Ok(titles) = scrape::regex_all(html, r"<title>\s*(.*?)\s*</title>", 1) {
            if let Some(raw) = titles.first() {
                let text = raw.replace(" Pfp", "");
                match text.split_once(" by ") {
                    Some((name, author)) => {
                        detail.title = name.trim().to_string();
                        detail.author = author.trim().to_string();
                    }
                    None => detail.title = text.trim().to_string(),
                }
            }
        }

        if let Ok(images) = scrape::select_attrs(html, r#"meta[property="og:image"]"#, "content") {
            detail.image = images.into_iter().next().unwrap_or_default();
        }

        if let Ok(tags) = scrape::regex_all(html, r#"href="/pfps/([a-z0-9-]+)""#, 1) {
            for tag in tags {
                // Navigation categories are on every page and say nothing about
                // this picture.
                if matches!(tag.as_str(), "latest" | "popular" | "featured" | "new") {
                    continue;
                }
                if !detail.tags.contains(&tag) {
                    detail.tags.push(tag);
                }
            }
        }

        if let Ok(rows) = scrape::regex_captures(html, CARD) {
            for row in rows {
                let (Some(id), Some(key), Some(slug)) =
                    (row.get("id"), row.get("key"), row.get("slug"))
                else {
                    continue;
                };
                let related = format!("{id}-{key}-{slug}");
                if !detail.related.contains(&related) {
                    detail.related.push(related);
                }
            }
        }

        detail
    }
}

impl Source for PfpsGg {
    fn id(&self) -> &'static str {
        "pfps.gg"
    }

    fn category(&self) -> &'static str {
        "art"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            // Its search is a category path rather than a query parameter, so
            // one term can be pushed down and the rest is filtered locally.
            text: true,
            tags: true,
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: true,
            video: false,
            colors: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        /*
         * The WHOLE phrase, as the site's own search box sends it.
         *
         * `pfps.gg/search?q=red+car` answers a redirect to `/pfps/red-car` —
         * the category page is its search. Taking only the first word turned
         * `red car` into `/pfps/red`: a real page, about something else.
         */
        let term = match query.tags.first() {
            Some(tag) => Some(scrape::slugify(tag)),
            None if !query.text.is_empty() => Some(scrape::slugify(&query.text.join(" "))),
            None => None,
        };

        let page = query.page.max(1);

        // Banners are a section of their own on the site, and the only place
        // its wide art lives.
        if query.kind == "banner" {
            return match &term {
                Some(slug) if !slug.is_empty() && slug != "untitled" => {
                    format!("https://pfps.gg/banners/{slug}?page={page}")
                }
                _ => format!("https://pfps.gg/banners?page={page}"),
            };
        }

        match term {
            // A category page is the site's own idea of a search, and it is a
            // better answer than a text match over titles.
            Some(slug) if !slug.is_empty() && slug != "untitled" => {
                format!("https://pfps.gg/pfps/{slug}?page={page}")
            }
            _ => {
                let sort = match query.sort {
                    crate::query::Sort::Newest => "new",
                    crate::query::Sort::Random => "random",
                    _ => "featured",
                };
                format!("https://pfps.gg/?page={page}&sort={sort}")
            }
        }
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let rows = scrape::regex_captures(body, CARD).map_err(|e| e.to_string())?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let (Some(id), Some(key), Some(slug), Some(ext)) = (
                row.get("id"),
                row.get("key"),
                row.get("slug"),
                row.get("ext"),
            ) else {
                continue;
            };

            let section = row.get("section").map(String::as_str).unwrap_or("pfps");
            let url = format!("https://cdn.pfps.gg/{section}/{id}-{key}-{slug}.{ext}");
            let mut item = scrape::normalize(
                "pfps.gg",
                &format!("{id}-{key}-{slug}"),
                &slug.replace('-', " "),
                &url,
                &url,
                &if section == "banners" {
                    Self::banner_page_url(id, key, slug)
                } else {
                    Self::page_url(id, key, slug)
                },
                0,
                0,
                vec![],
            );
            // The site is avatars and banners, and the two are different
            // shapes. Dimensions are not in a listing, so the section the row
            // came from is the only thing that knows.
            if section == "banners" {
                item.kind = "banner".into();
                item.ratio = 2.5;
                item.w = 1000;
                item.h = 400;
            } else {
                item.kind = "avatar".into();
                item.ratio = 1.0;
                item.w = 400;
                item.h = 400;
            }
            item.ext = ext.clone();
            item.animated = ext == "gif";
            items.push(item);
        }

        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        scrape::regex_all(body, CARD, 0).map(|m| !m.is_empty()).unwrap_or(false)
    }
}

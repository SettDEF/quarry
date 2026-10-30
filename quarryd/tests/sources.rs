//! Adapter tests: URL construction and response parsing, both offline.
//!
//! The fixtures are synthetic: documents in the shape each source serves, with
//! invented titles, handles and ids. They pin the parsers, not the sites — a
//! source that changes its markup must fail in `doctor` against the live site,
//! not randomly here.

use std::fs;

// The daemon is a binary, so its modules are reachable through the bin target
// only; these tests exercise the same code paths through the public surface the
// integration harness needs.
#[path = "../src/protocol.rs"]
mod protocol;
#[path = "../src/query.rs"]
mod query;
#[path = "../src/scrape.rs"]
mod scrape;
#[path = "../src/sources/mod.rs"]
mod sources;
#[path = "../src/util.rs"]
mod util;

use sources::{pushdown, Source};

fn fixture(name: &str) -> String {
    fs::read_to_string(format!("tests/fixtures/{name}")).expect("fixture")
}

#[test]
fn wallhaven_url_carries_every_pushable_predicate() {
    let parsed = query::parse("mountain w>=3440 h>=1440 ratio:21:9 -nsfw sort:new");
    let source = sources::wallhaven::Wallhaven;
    let (pushed, residue) = pushdown(&parsed, &source.capabilities());
    let url = source.build_url(&pushed);

    assert!(url.contains("q=mountain"), "{url}");
    assert!(url.contains("atleast=3440x1440"), "{url}");
    assert!(url.contains("ratios=21x9"), "{url}");
    assert!(url.contains("purity=100"), "{url}");
    assert!(url.contains("sorting=date_added"), "{url}");

    // Minimums are re-checked locally because `atleast` is the source's idea of
    // the bound, not ours.
    assert!(!residue.clauses.is_empty(), "size bounds should still be verified locally");
}

#[test]
fn wallhaven_unsupported_predicates_stay_local() {
    let parsed = query::parse("kind:wallpaper animated -source:danbooru w<=2000");
    let source = sources::wallhaven::Wallhaven;
    let (pushed, residue) = pushdown(&parsed, &source.capabilities());

    // None of those are wallhaven parameters, so none of them appear.
    let url = source.build_url(&pushed);
    assert!(!url.contains("animated"), "{url}");
    assert!(!url.contains("danbooru"), "{url}");
    // …and all four survive in the residue, so the answer is still correct:
    // kind:wallpaper, animated, -source:danbooru and w<=2000.
    assert_eq!(residue.clauses.len(), 4);
}

#[test]
fn wallhaven_parses_a_real_response() {
    let source = sources::wallhaven::Wallhaven;
    let items = source.parse(&fixture("wallhaven.json")).expect("parses");
    assert!(!items.is_empty());

    let first = &items[0];
    assert_eq!(first.source, "wallhaven");
    assert_eq!(first.kind, "wallpaper");
    assert!(first.w > 0 && first.h > 0);
    assert!(first.ratio > 0.0, "ratio is the invariant the wall depends on");
    assert!(first.url.starts_with("https://"));
    assert!(!first.thumb.is_empty());
    // The palette arrives with the row, so colour matching costs no decoding.
    assert!(first.dominant.starts_with('#'), "dominant was {:?}", first.dominant);
    assert!(source.has_more(&fixture("wallhaven.json")));
}

#[test]
fn wallhaven_respects_the_filters_it_was_given() {
    let source = sources::wallhaven::Wallhaven;
    let items = source.parse(&fixture("wallhaven.json")).expect("parses");
    // The fixture was fetched with atleast=1920x1080&ratios=16x9&purity=100.
    for item in &items {
        assert!(item.w >= 1920 && item.h >= 1080, "{}x{} slipped through", item.w, item.h);
        assert!(!item.nsfw, "purity=100 must mean sfw only");
        assert!((item.ratio - 16.0 / 9.0).abs() < 0.05, "ratio {} is not 16:9", item.ratio);
    }
}

#[test]
fn danbooru_speaks_its_own_tag_syntax() {
    let parsed = query::parse("cat w>=1920 -nsfw sort:large");
    let source = sources::danbooru::Danbooru;
    let (pushed, _) = pushdown(&parsed, &source.capabilities());
    let url = source.build_url(&pushed);

    // quarry's predicates, expressed the way danbooru expects them.
    // Encoded, because danbooru's parser rejects a raw `>` outright.
    assert!(url.contains("tags=cat"), "{url}");
    assert!(!url.contains('>'), "the tag string must be percent-encoded: {url}");
    let decoded = url.replace("%3A", ":").replace("%3E", ">").replace("%3D", "=").replace('+', " ");
    assert!(decoded.contains("rating:general") || decoded.contains("width:>=1920"), "{decoded}");
    assert!(url.contains("limit=50"), "{url}");
}

#[test]
fn danbooru_parses_a_real_response() {
    let source = sources::danbooru::Danbooru;
    let items = source.parse(&fixture("danbooru.json")).expect("parses");
    assert!(!items.is_empty());
    for item in &items {
        assert_eq!(item.source, "danbooru");
        assert!(item.ratio > 0.0);
        assert!(!item.url.is_empty());
        assert!(item.page_url.contains("/posts/"));
    }
    // large_file_url is danbooru's mid-size render — it must reach `sample`,
    // not get dropped, so a 1280 request has something between the ~180px
    // preview and the multi-MB original to fall back on.
    assert_eq!(items[0].sample, "https://cdn.donmai.us/sample/2a/89/sample-2a894605463be6f53024966bb9c66188.jpg");
}

#[test]
fn pushdown_never_pushes_a_negation_it_cannot_express() {
    let parsed = query::parse("-cat -tag:anime");
    let source = sources::wallhaven::Wallhaven;
    let (pushed, residue) = pushdown(&parsed, &source.capabilities());

    // Neither negation is expressible in wallhaven's API, so neither is sent —
    // a half-applied negation is worse than none — and both survive locally.
    assert!(pushed.text.is_empty());
    assert_eq!(residue.clauses.len(), 2);
}

#[test]
fn every_adapter_declares_itself() {
    let ids: Vec<&str> = sources::all().iter().map(|s| s.id()).collect();
    assert!(ids.contains(&"wallhaven"));
    assert!(ids.contains(&"danbooru"));
    assert!(sources::by_id("wallhaven").is_some());
    assert!(sources::by_id("nope").is_none());
}

#[test]
fn danbooru_never_orders_an_unfiltered_query() {
    // `order:id` / `order:score` with nothing else times out danbooru's
    // database and answers 500. Newest is its default anyway.
    let source = sources::danbooru::Danbooru;
    for text in ["sort:new", "sort:large", "sort:random", ""] {
        let parsed = query::parse(text);
        let (pushed, _) = pushdown(&parsed, &source.capabilities());
        let url = source.build_url(&pushed);
        assert!(!url.contains("order"), "{text:?} produced {url}");
    }
}

#[test]
fn danbooru_orders_alongside_a_filter() {
    let source = sources::danbooru::Danbooru;
    let parsed = query::parse("cat sort:large");
    let (pushed, _) = pushdown(&parsed, &source.capabilities());
    let url = source.build_url(&pushed);
    let decoded = url.replace("%3A", ":").replace('+', " ");
    assert!(decoded.contains("cat"), "{decoded}");
    assert!(decoded.contains("order:score"), "{decoded}");
}

#[test]
fn wallhaven_browsing_without_a_query_sorts_by_date() {
    // `sorting=relevance` with an empty `q` returns zero rows on wallhaven, so
    // an unsearched browse must not ask for relevance.
    let source = sources::wallhaven::Wallhaven;
    let (pushed, _) = pushdown(&query::parse(""), &source.capabilities());
    let url = source.build_url(&pushed);
    assert!(url.contains("sorting=date_added"), "{url}");

    // With a term, relevance is the right default again.
    let (with_text, _) = pushdown(&query::parse("mountain"), &source.capabilities());
    assert!(source.build_url(&with_text).contains("sorting=relevance"));
}

#[test]
fn paging_produces_distinct_urls_per_page() {
    // Endless scroll fetches several pages at once, so each page must be its
    // own URL — a source whose page parameter was ignored would fetch the same
    // rows N times and look like it had run out.
    let source = sources::wallhaven::Wallhaven;
    let (pushed, _) = pushdown(&query::parse("forest"), &source.capabilities());

    let mut seen = std::collections::HashSet::new();
    for page in 1..=4u32 {
        let mut per_page = pushed.clone();
        per_page.page = page;
        let url = source.build_url(&per_page);
        assert!(url.contains(&format!("page={page}")), "{url}");
        assert!(seen.insert(url), "two pages produced the same URL");
    }

    let danbooru = sources::danbooru::Danbooru;
    let (pushed, _) = pushdown(&query::parse("cat"), &danbooru.capabilities());
    for page in 1..=3u32 {
        let mut per_page = pushed.clone();
        per_page.page = page;
        assert!(danbooru.build_url(&per_page).contains(&format!("page={page}")));
    }
}

#[test]
fn pfps_gg_listing_yields_linkable_rows() {
    let source = sources::pfps_gg::PfpsGg::default();
    let items = source.parse(&fixture("pfps-gg-category.html")).expect("parses");
    assert!(items.len() > 10, "expected a page of avatars, got {}", items.len());

    let first = &items[0];
    assert_eq!(first.source, "pfps.gg");
    assert_eq!(first.kind, "avatar");
    assert!(first.url.starts_with("https://cdn.pfps.gg/pfps/"));
    // The id triple in the image URL is also the address of its page, so a row
    // is linkable without a second request.
    assert!(first.page_url.starts_with("https://pfps.gg/pfp/"), "{}", first.page_url);
    assert!(first.page_url.ends_with(&first.source_id));
    assert!(first.ratio > 0.0);
}

#[test]
fn pfps_gg_search_uses_its_own_category_pages() {
    let source = sources::pfps_gg::PfpsGg::default();
    let (pushed, _) = pushdown(&query::parse("Homer Simpson"), &source.capabilities());
    let url = source.build_url(&pushed);
    // The site's own category is a better answer than a title match.
    assert!(url.contains("/pfps/homer"), "{url}");

    let (browse, _) = pushdown(&query::parse("sort:new"), &source.capabilities());
    assert!(source.build_url(&browse).contains("sort=new"));
}

#[test]
fn pfps_gg_detail_page_adds_what_the_listing_lacks() {
    let detail = sources::pfps_gg::PfpsGg::parse_detail(&fixture("pfps-gg-detail.html"));

    // "<title>Moth Pfp by 4155200918</title>" — the name and the uploader in
    // one string, which is all the page states plainly.
    assert_eq!(detail.title, "Moth");
    assert_eq!(detail.author, "4155200918");
    assert!(detail.image.starts_with("https://cdn.pfps.gg/pfps/"), "{}", detail.image);

    // Navigation categories appear on every page and say nothing about the
    // picture, so they must not become its tags.
    assert!(!detail.tags.iter().any(|t| t == "latest"));

    // The "more like this" strip is a related-items graph the site already
    // maintains.
    assert!(detail.related.len() > 3, "related: {:?}", detail.related.len());
}

#[test]
fn pfps_gg_page_urls_are_built_from_the_image_url() {
    assert_eq!(
        sources::pfps_gg::PfpsGg::page_url("9998", "841229", "anime"),
        "https://pfps.gg/pfp/9998-841229-anime"
    );
}

#[test]
fn pfps_gg_banners_are_their_own_section() {
    let source = sources::pfps_gg::PfpsGg::default();

    // The site keeps banners in a section, not behind a filter.
    let (pushed, _) = pushdown(&query::parse("kind:banner"), &source.capabilities());
    assert!(source.build_url(&pushed).contains("/banners"), "{}", source.build_url(&pushed));

    // And they come back labelled as banners, with a banner's shape.
    let items = source.parse(&fixture("pfps-gg-banners.html")).expect("parses");
    assert!(!items.is_empty(), "no banners parsed");
    for item in items.iter().take(5) {
        assert_eq!(item.kind, "banner");
        assert!(item.url.contains("/banners/"), "{}", item.url);
        assert!(item.ratio > 1.5, "a banner is wide: {}", item.ratio);
        assert!(item.page_url.contains("/banner/"), "{}", item.page_url);
    }
}

#[test]
fn deviantart_pages_by_row_offset() {
    // The feed has no page number: `offset` steps sixty deviations at a time,
    // so page four is offset 180 and not offset 4.
    let source = sources::deviantart::DeviantArt;
    let (pushed, _) = pushdown(&query::parse("cat"), &source.capabilities());

    let mut seen = std::collections::HashSet::new();
    for (page, offset) in [(1u32, 0u32), (2, 60), (3, 120), (4, 180)] {
        let mut per_page = pushed.clone();
        per_page.page = page;
        let url = source.build_url(&per_page);
        assert!(url.contains("q=cat"), "{url}");
        assert!(url.contains(&format!("offset={offset}")), "page {page} produced {url}");
        assert!(seen.insert(url), "two pages produced the same URL");
    }
}

#[test]
fn deviantart_parses_a_real_feed() {
    let source = sources::deviantart::DeviantArt;
    let body = fixture("deviantart-cat.rss");
    let items = source.parse(&body).expect("parses");
    assert_eq!(items.len(), 60, "the feed is sixty deviations a page");

    for item in &items {
        assert_eq!(item.source, "deviantart");
        assert_eq!(item.family, "raster");
        assert!(!item.url.is_empty());
        assert!(item.ratio > 0.0, "ratio is the invariant the wall depends on");
        assert!(item.page_url.contains("deviantart.com/"), "{}", item.page_url);
        // Nothing here is one shape, so the kind has to come from the picture.
        assert!(
            ["avatar", "wallpaper", "banner", "cover"].contains(&item.kind.as_str()),
            "kind was {:?}",
            item.kind
        );
    }

    let first = &items[0];
    assert_eq!(first.source_id, "900000000", "the id is the tail of the deviation URL");
    // `media:credit` is published twice per deviation — the name, then the
    // artist's avatar image — so an author that survived is one taken from the
    // link rather than the last credit seen.
    assert_eq!(first.author, "aurelquill");
    assert!(!first.author.starts_with("http"), "{}", first.author);

    assert!(source.has_more(&body), "the feed advertises its own next page");
}

#[test]
fn anilist_pages_through_its_body() {
    // A GraphQL endpoint has one URL; the page is in the document it is sent,
    // so that is where paging has to be visible.
    let source = sources::anilist::AniList;
    let (pushed, _) = pushdown(&query::parse("gojo"), &source.capabilities());
    assert_eq!(source.build_url(&pushed), "https://graphql.anilist.co");

    let mut seen = std::collections::HashSet::new();
    for page in 1..=4u32 {
        let mut per_page = pushed.clone();
        per_page.page = page;
        let body = source.body(&per_page).expect("a POST source has a body");
        assert_eq!(body["variables"]["page"], page);
        assert_eq!(body["variables"]["q"], "gojo");
        assert!(seen.insert(body.to_string()), "two pages produced the same request");
    }

    // Relevance needs something to be relevant to: an unsearched browse asks
    // for the most-loved characters instead of a page in no order at all.
    let (browse, _) = pushdown(&query::parse(""), &source.capabilities());
    let body = source.body(&browse).expect("body");
    assert!(body["variables"]["q"].is_null());
    assert_eq!(body["variables"]["sort"], "FAVOURITES_DESC");
}

#[test]
fn anilist_parses_a_real_response() {
    let source = sources::anilist::AniList;
    let body = fixture("anilist-characters.json");
    let items = source.parse(&body).expect("parses");
    assert_eq!(items.len(), 50, "perPage is 50 and the fixture is a full page");

    for item in &items {
        assert_eq!(item.source, "anilist");
        assert_eq!(item.kind, "avatar", "character art is what this source is for");
        assert_eq!(item.family, "raster");
        assert!(!item.url.is_empty());
        assert!(item.ratio > 0.0);
        assert!(item.page_url.starts_with("https://anilist.co/character/"), "{}", item.page_url);
    }

    let first = &items[0];
    assert_eq!(first.title, "Aveline Marsk");
    assert_eq!(first.id, "anilist:500");
    assert!(source.has_more(&body));
}

#[test]
fn iconify_pages_by_growing_its_window() {
    // `limit` is the size of the whole result set here, not a page size, and a
    // `start` at or past it is a 400 — so both parameters have to move.
    let source = sources::iconify::Iconify;
    let (pushed, _) = pushdown(&query::parse("arrow"), &source.capabilities());

    let mut seen = std::collections::HashSet::new();
    for (page, start, limit) in [(1u32, 0u32, 64u32), (2, 64, 128), (3, 128, 192)] {
        let mut per_page = pushed.clone();
        per_page.page = page;
        let url = source.build_url(&per_page);
        assert!(url.contains("query=arrow"), "{url}");
        assert!(url.contains(&format!("start={start}")), "page {page} produced {url}");
        assert!(url.contains(&format!("limit={limit}")), "page {page} produced {url}");
        assert!(seen.insert(url), "two pages produced the same URL");
    }

    // Past the service's own ceiling the request is clamped rather than sent to
    // be rejected: a 400 reads as a broken source, not as the end of a scroll.
    let mut deep = pushed.clone();
    deep.page = 400;
    let url = source.build_url(&deep);
    assert!(url.contains("start=998") && url.contains("limit=999"), "{url}");

    // An empty query is a 400 too, so a browse needs a seed term.
    let (browse, _) = pushdown(&query::parse(""), &source.capabilities());
    assert!(!source.build_url(&browse).contains("query=&"), "{}", source.build_url(&browse));
}

#[test]
fn iconify_parses_a_real_response() {
    let source = sources::iconify::Iconify;
    let body = fixture("iconify-home.json");
    let items = source.parse(&body).expect("parses");
    assert_eq!(items.len(), 64, "one full window of icons");

    for item in &items {
        assert_eq!(item.source, "iconify");
        assert_eq!(item.family, "vector");
        assert_eq!(item.kind, "icon");
        assert_eq!(item.ext, "svg");
        assert!(item.tintable, "an icon that cannot take a colour is half an icon");
        assert!(item.url.starts_with("https://api.iconify.design/"), "{}", item.url);
        assert!(item.url.ends_with(".svg"), "{}", item.url);
        assert!(item.ratio > 0.0);
        assert_eq!(item.ratio, 1.0);
        assert!(
            item.page_url.starts_with("https://icon-sets.iconify.design/"),
            "{}",
            item.page_url
        );
    }

    let first = &items[0];
    // `prefix:name` is both the id and the path to the file.
    assert_eq!(first.source_id, "material-symbols:home");
    assert_eq!(first.url, "https://api.iconify.design/material-symbols/home.svg");
    assert_eq!(first.tags, vec!["material-symbols".to_string()], "the set is a tag");
    assert!(source.has_more(&body));
}

#[test]
fn the_new_adapters_are_registered() {
    let ids: Vec<&str> = sources::all().iter().map(|s| s.id()).collect();
    for id in ["deviantart", "anilist", "iconify"] {
        assert!(ids.contains(&id), "{id} is missing from all()");
        assert!(sources::by_id(id).is_some(), "{id} is missing from by_id");
    }

    // Only the GraphQL sources POST; everything else is a URL and nothing more,
    // which is what the default on the trait is for.
    for source in sources::all() {
        let has_body = source.body(&sources::SourceQuery::default()).is_some();
        let graphql = matches!(source.id(), "anilist" | "7tv");
        assert_eq!(has_body, graphql, "{} disagrees", source.id());
    }
}

// ── yandex ──────────────────────────────────────────────────────────────────

/// A trimmed real capture: the live page is 420 KB and all but three results
/// of it is the search UI. The `data-state` blob is untouched.
fn yandex_page() -> String {
    fs::read_to_string("tests/fixtures/yandex-search.html").expect("yandex fixture")
}

#[test]
fn yandex_reads_results_out_of_the_page_state() {
    let source = sources::yandex::Yandex;
    let rows = source.parse(&yandex_page()).expect("parses");

    assert_eq!(rows.len(), 3, "three results in the fixture");

    let first = &rows[0];
    assert_eq!(first.source, "yandex");
    assert!(first.url.starts_with("https://"), "the ORIGINAL, not yandex's viewer: {}", first.url);
    assert_eq!((first.w, first.h), (1080, 1920));
    assert!(!first.title.is_empty());
    // The site it came from — the only provenance a search engine gives.
    assert_eq!(first.author, "moodboard.test");
    // Yandex's own CDN copy, which is what makes a tile cost nothing.
    assert!(first.thumb.starts_with("https://avatars.mds.yandex.net/"), "{}", first.thumb);
    // ...and the mid-size preview, so the wall never touches the origin host.
    assert!(!first.sample.is_empty());
    assert!(first.page_url.contains("moodboard.test"), "the page, not the search: {}", first.page_url);
}

/// The failure that costs an afternoon: a captcha is a 200 with a page in it,
/// and parses to zero rows exactly like "no results".
#[test]
fn yandex_says_when_it_has_been_captchad() {
    let source = sources::yandex::Yandex;

    let captcha = r#"<html><body><div class="showcaptcha">Are you not a robot?</div></body></html>"#;
    let err = source.parse(captcha).expect_err("a captcha is not an empty result");
    assert!(err.to_lowercase().contains("captcha"), "{err}");

    let empty_state = r#"<html><body><div data-state="{&quot;initialState&quot;:{}}"></div></body></html>"#;
    assert_eq!(source.parse(empty_state).unwrap().len(), 0, "a genuinely empty result is empty");

    let nonsense = "<html><body>nothing here at all</body></html>";
    assert!(source.parse(nonsense).is_err(), "a page with no state is a failure, not a blank");
}

/// Its results are only as good as the size filter you push down: unfiltered,
/// a wallpaper search is thirty 736px re-uploads.
#[test]
fn yandex_pushes_down_size_and_orientation() {
    let source = sources::yandex::Yandex;
    let caps = source.capabilities();

    let wide = query::parse("cyberpunk w>=3440 ratio:21:9");
    let (mut pushed, _) = sources::pushdown(&wide, &caps);
    pushed.page = 1;
    let url = source.build_url(&pushed);
    assert!(url.contains("isize=wallpaper"), "{url}");
    assert!(url.contains("iorient=horizontal"), "{url}");

    // Page two is `p=1`: it counts from zero, and an off-by-one here silently
    // re-crawls page one forever.
    pushed.page = 2;
    assert!(source.build_url(&pushed).contains("&p=1"));

    // A search engine with no query answers nothing at all.
    let (empty, _) = sources::pushdown(&query::parse(""), &caps);
    assert!(source.build_url(&empty).contains("text="), "an empty query still needs a term");
    assert!(!source.build_url(&empty).ends_with("text="));
}

// ── the manifests that ship ─────────────────────────────────────────────────

/// Every shipped manifest must load, and mean what it says.
///
/// A manifest is data, so a typo in one is not a compile error — it is a
/// source that quietly stops existing, or worse, one that loads and returns
/// rows with an empty URL. The daemon reads these at startup; this reads the
/// same files and checks the claims that matter.
#[test]
fn the_shipped_manifests_are_coherent() {
    let dir = std::path::Path::new("../sources");
    let mut checked = 0;

    for entry in fs::read_dir(dir).expect("sources/") {
        let path = entry.expect("entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("toml") {
            continue;
        }
        let text = fs::read_to_string(&path).expect("read manifest");
        let manifest: toml::Value = toml::from_str(&text)
            .unwrap_or_else(|e| panic!("{}: {e}", path.display()));

        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let request = manifest.get("request").unwrap_or_else(|| panic!("{name}: no [request]"));
        let url = request.get("url").and_then(|v| v.as_str())
            .unwrap_or_else(|| panic!("{name}: no request.url"));
        assert!(url.starts_with("https://"), "{name}: {url} is not https");

        let map = manifest.get("map").unwrap_or_else(|| panic!("{name}: no [map]"));
        for required in ["id", "url"] {
            assert!(map.get(required).is_some(), "{name}: map.{required} is what makes a row a row");
        }

        // A source paged by a list must have `{page_value}` in its URL, or the
        // list is decoration and every page is the same page. A single value is
        // not a list to cycle: it is how a one-page source (osu_seasonal) says so.
        let values = request.get("page_values").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
        let placeholder = url.contains("{page_value}");
        assert!(values <= 1 || placeholder, "{name}: page_values without {{page_value}} in the url");
        assert!(!placeholder || values >= 1, "{name}: {{page_value}} in the url without page_values");

        // A source with no paging token at all would crawl its first page
        // forever — every "next page" identical to the last.
        assert!(
            url.contains("{page}") || url.contains("{page0}") || url.contains("{offset}")
                || url.contains("{page_value}")
                // or it says it has one page (a single page value), and there is no next
                || values == 1,
            "{name}: nothing in the URL advances a page"
        );

        // Adult sources must be marked, or `-nsfw` cannot do its job.
        if ["e621.toml", "rule34.toml"].contains(&name.as_str()) {
            assert_eq!(
                manifest.get("adult").and_then(|v| v.as_bool()),
                Some(true),
                "{name}: an adult source must say so"
            );
        }

        // A credentialed source must explain itself: which variables, and
        // where to get them. Otherwise it is a source that silently is not there.
        if let Some(auth) = manifest.get("auth") {
            assert!(auth.get("vars").and_then(|v| v.as_array()).is_some_and(|v| !v.is_empty()),
                "{name}: [auth] with no vars");
            assert!(auth.get("hint").and_then(|v| v.as_str()).is_some_and(|h| h.starts_with("http")),
                "{name}: [auth] must say where to get the credentials");
        }

        checked += 1;
    }

    assert!(checked >= 8, "expected the shipped manifests, found {checked}");
}

#[test]
fn seventv_parses_animated_emotes_with_their_real_gif_size() {
    let source = sources::seventv::SevenTv;
    let body = fixture("7tv-search.json");
    let items = source.parse(&body).expect("parses");
    // The third has no GIF rendition yet, so there is nothing to export.
    assert_eq!(items.len(), 2);

    let cat = &items[0];
    assert_eq!(cat.id, "7tv:01AAAAAAAAAAAAAAAAAAAAAAAA");
    assert_eq!(cat.url, "https://cdn.7tv.app/emote/01AAAAAAAAAAAAAAAAAAAAAAAA/4x.gif");
    assert_eq!(cat.thumb, "https://cdn.7tv.app/emote/01AAAAAAAAAAAAAAAAAAAAAAAA/2x.gif");
    assert_eq!(cat.page_url, "https://7tv.app/emotes/01AAAAAAAAAAAAAAAAAAAAAAAA");
    assert_eq!((cat.w, cat.h, cat.bytes), (128, 128, 210000), "the 4x GIF's own size");
    assert_eq!(cat.kind, "emote");
    assert_eq!(cat.author, "FixtureOwner");
    assert!(cat.animated);

    let wide = &items[1];
    assert_eq!(wide.thumb, wide.url, "no 2x GIF: the tile uses the 4x one");
    assert!(wide.ratio > 1.7, "{}", wide.ratio);
    assert_eq!(wide.author, "");
    assert!(!source.has_more(&body), "a short page is the last one");
}

#[test]
fn seventv_asks_for_animated_emotes_by_post() {
    let source = sources::seventv::SevenTv;
    let (q, _) = pushdown(&query::parse("cat dance"), &source.capabilities());
    let body = source.body(&q).expect("a GraphQL source posts");
    assert_eq!(body["variables"]["q"], "cat dance");
    assert!(body["query"].as_str().unwrap().contains("animated: true"));
    // Past 7TV's last page the answer is an error; it must read as one.
    assert!(source.parse(r#"{"errors":[{"message":"page out of range"}],"data":null}"#).is_err());
}

// ── erome ───────────────────────────────────────────────────────────────────

#[test]
fn erome_reads_albums_off_the_listing() {
    let albums = sources::erome::listing(&fixture("erome-search.html"));
    // The third card has no cover, so there is nothing to show for it.
    assert_eq!(albums.len(), 2);
    assert_eq!(albums[0].id, "11110001");
    assert_eq!(albums[0].url, "https://www.erome.com/a/FixAlbA1");
    assert_eq!(albums[0].cover, "https://s1.erome.com/1000/FixAlbA1/thumbs/AaaPic01.jpg?v=1", "not the data: placeholder");
    assert_eq!(albums[1].url, "https://www.erome.com/a/FixAlbB2", "a relative link is made absolute");
    assert!(sources::erome::Erome.has_more(&fixture("erome-search.html")));
}

#[test]
fn erome_opens_an_album_into_its_pictures_and_clips() {
    let (title, author, media) = sources::erome::album(&fixture("erome-album.html"));
    assert_eq!((title.as_str(), author.as_str()), ("Fixture Album One", "FixturePoster"));
    assert_eq!(media.len(), 3, "{media:?}");
    let clip = &media[0];
    assert!(clip.video);
    assert_eq!(clip.url, "https://v1.erome.com/1000/FixAlbA1/AaaVid01_720p.mp4", "the best res, once");
    assert_eq!(clip.thumb, "https://s1.erome.com/1000/FixAlbA1/AaaVid01.jpg");
    assert_eq!(clip.seconds, 3723.0);
    assert_eq!((media[1].key.as_str(), media[1].w, media[1].h), ("AaaPic01", 599, 487));
    assert_eq!(media[2].key, "AaaPic02");
}

#[test]
fn erome_rows_are_the_album_where_it_opened_and_the_cover_where_not() {
    let albums = sources::erome::listing(&fixture("erome-search.html"));
    let rows = sources::erome::rows(&albums, &[Some(fixture("erome-album.html")), None]);
    assert_eq!(rows.len(), 4, "three from the opened album, one cover");

    let clip = &rows[0];
    assert_eq!(clip.id, "erome:FixAlbA1-AaaVid01");
    assert_eq!(clip.family, "video");
    assert_eq!(clip.title, "Fixture Album One · 1/3");
    assert_eq!(clip.page_url, "https://www.erome.com/a/FixAlbA1", "the Referer the clip host wants");
    assert_eq!(clip.author, "FixturePoster");
    assert_eq!(clip.duration, 3723.0);
    assert!(rows.iter().all(|r| r.nsfw));
    assert!(rows[2].animated, "a GIF in an album moves");
    assert!(rows[2].ratio < 1.0);

    let cover = &rows[3];
    assert_eq!(cover.id, "erome:11110002", "the old id, so old rows are the same row");
    assert_eq!(cover.title, "Fixture Album Two", "the file key after the title is not part of it");

    // Under test the album fetches fail, so parse degrades to covers, not to nothing.
    assert_eq!(sources::erome::Erome.parse(&fixture("erome-search.html")).unwrap().len(), 2);
}

// ── baidu ───────────────────────────────────────────────────────────────────

#[test]
fn baidu_unscrambles_its_addresses() {
    assert_eq!(sources::baidu::unscramble("ippr_z2C$qAzdH3FAzdH3F4k1_z&e3Bkwt17_z&e3Bv54"), "http://mbd.baidu.com");
}

#[test]
fn baidu_reads_originals_sizes_and_pages() {
    let source = sources::baidu::Baidu;
    let items = source.parse(&fixture("baidu-acjson.json")).expect("parses");
    // The empty object at the end is a row Baidu pads the list with.
    assert_eq!(items.len(), 2);

    let one = &items[0];
    assert_eq!(one.url, "https://cdn.fixture-pics.example/cat-one-original.jpg", "replaceUrl's original first");
    assert_eq!(one.thumb, "https://img0.baidu.com/it/u=111,222&fm=253&f=JPEG?w=500&h=500");
    assert_eq!(one.page_url, "https://fixture-blog.example/post/7", "fromURL, unscrambled");
    assert_eq!((one.w, one.h), (1920, 1080));
    assert_eq!(one.id, "baidu:1001,2002");

    let two = &items[1];
    assert_eq!(two.url, "https://fixture-pics.example/cat-two.png", "no replaceUrl: objURL, unscrambled");
    assert_eq!(two.page_url, "https://fixture-forum.example/", "no fromURL: the host");
    assert_eq!((two.w, two.h), (1000, 1500), "numbers as numbers too");
    assert_eq!(two.title, "Fixture cat's two", "Baidu's \\' repaired");
}

#[test]
fn baidu_names_a_refusal_rather_than_returning_nothing() {
    let err = sources::baidu::Baidu
        .parse(r#"{"antiFlag":1,"message":"Forbid spider access","bfe_log_id":"1"}"#)
        .expect_err("a refusal is an error");
    assert!(err.contains("Forbid spider access"), "{err}");
}

#[test]
fn erome_rows_carry_their_album_and_author_searches_the_uploaders_page() {
    let albums = sources::erome::listing(&fixture("erome-search.html"));
    let rows = sources::erome::rows(&albums, &[Some(fixture("erome-album.html")), None]);
    assert!(rows[..3].iter().all(|r| r.tags == vec!["album:fixalba1".to_string()]), "{:?}", rows[0].tags);
    assert_eq!(rows[3].tags, vec!["album:fixalbb2".to_string()], "a cover row too");

    let source = sources::erome::Erome;
    let (q, residue) = pushdown(&query::parse("author:FixturePoster"), &source.capabilities());
    assert_eq!(source.build_url(&q), "https://www.erome.com/fixtureposter?page=1");
    assert!(residue.clauses.is_empty(), "the uploader is asked, not filtered for: {:?}", residue.clauses);
}

#[test]
fn an_album_tag_survives_the_query_parser() {
    let q = query::parse("tag:album:fixalba1");
    assert!(q.unknown.is_empty(), "{:?}", q.unknown);
    let shown = format!("{:?}", q.clauses);
    assert!(shown.contains("album:fixalba1"), "{shown}");
}

#[test]
fn erome_asks_for_newest_first_when_the_query_does() {
    let source = sources::erome::Erome;
    let (q, _) = pushdown(&query::parse("beach sort:new"), &source.capabilities());
    assert_eq!(source.build_url(&q), "https://www.erome.com/search?q=beach&o=new&page=1");
    let (q, _) = pushdown(&query::parse("beach"), &source.capabilities());
    assert_eq!(source.build_url(&q), "https://www.erome.com/search?q=beach&page=1");
}

// ── a site's whole lists ────────────────────────────────────────────────────

#[test]
fn a_sites_full_list_is_read_from_json_or_html() {
    use sources::declarative::SectionsFrom;
    let json = SectionsFrom {
        group: "Tags".into(), url: "https://x.test".into(), format: String::new(),
        root: "tags".into(), label: "tag.tag_name".into(), select: String::new(), adult: false,
    };
    let names = json.names(r#"{"tags":[{"tag":{"tag_name":"fixture  one"}},{"tag":{"tag_name":"Fixture One"}},{"tag":{"tag_name":"two"}},{"tag":{}}]}"#);
    assert_eq!(names, vec!["fixture one".to_string(), "two".to_string()], "spaces squeezed, case-insensitive dupes and blanks dropped");

    let html = SectionsFrom {
        group: "Categories".into(), url: "https://x.test".into(), format: "html".into(),
        root: String::new(), label: String::new(), select: "ul.cats a".into(), adult: false,
    };
    assert_eq!(html.names(r#"<ul class="cats"><li><a href="/c/1">Alpha</a></li><li><a href="/c/2"> Beta </a></li></ul><a>not this</a>"#), vec!["Alpha", "Beta"]);
}

#[test]
fn every_sections_from_names_a_url_and_a_way_to_read_it() {
    for entry in fs::read_dir("../sources").expect("sources/") {
        let path = entry.expect("entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("toml") {
            continue;
        }
        let text = fs::read_to_string(&path).expect("read");
        let manifest: sources::declarative::Manifest = toml::from_str(&text).expect("parses");
        let name = path.display().to_string();
        for spec in &manifest.sections_from {
            assert!(spec.url.starts_with("https://"), "{name}: {}", spec.url);
            if spec.format.eq_ignore_ascii_case("html") {
                assert!(!spec.select.is_empty(), "{name}: html needs `select`");
            } else {
                assert!(!spec.label.is_empty(), "{name}: json needs `label`");
            }
        }
    }
}

#[test]
fn redtube_rows_carry_the_sites_tags() {
    let source = sources::declarative::Declarative::load(std::path::Path::new("../sources/redtube.toml")).expect("loads");
    let body = r#"{"videos":[{"video":{"video_id":"9","title":"Fixture clip","url":"https://www.redtube.com/9","thumbs":[{"src":"https://ei.fixture.example/9-1.jpg","width":640,"height":360}],"tags":[{"tag_name":"fixture tag"},{"tag_name":"second"}]}}]}"#;
    let items = source.parse(body).expect("parses");
    assert_eq!(items.len(), 1);
    assert!(items[0].tags.iter().any(|t| t == "fixture tag") && items[0].tags.iter().any(|t| t == "second"), "{:?}", items[0].tags);
}

// ── a video's tags, from its own page ───────────────────────────────────────

fn page_tags_of(toml_block: &str) -> sources::declarative::PageTags {
    toml::from_str(toml_block).expect("page_tags parses")
}

#[test]
fn page_tags_come_from_attributes_selectors_meta_and_page_json() {
    let attrs = page_tags_of(r#"attrs = ["data-context-tag", "data-context-category"]
skip = ["hd"]"#);
    assert_eq!(
        attrs.read(r#"<div data-context-tag='fixture-one,second-tag' data-context-category='HD,Fixture Cat'></div>"#),
        vec!["fixture one", "second tag", "fixture cat"]
    );

    let select = page_tags_of(r#"select = ".video-tags a.is-keyword""#);
    assert_eq!(
        select.read(r#"<nav><a class="is-keyword">menu</a></nav><div class="video-tags"><a class="is-keyword">alpha</a><a class="is-keyword">Beta</a></div>"#),
        vec!["alpha", "beta"],
        "only the row under the player, not the menu"
    );

    let meta = page_tags_of(r#"meta = "keywords"
trim_suffix = " porn"
skip = ["hd porn video"]
dashes = true"#);
    assert_eq!(
        meta.read(r#"<meta name="keywords" content="hd porn video, fixture porn, small-tits porn">"#),
        vec!["fixture", "small tits"]
    );

    let json = page_tags_of(r#"json_array = "tags"
field = "name""#);
    assert_eq!(
        json.read(r#"<script>window.x = {"videoId":1,"tags":[{"name":"Fixture Creator","isTag":false},{"name":"with ] bracket","isTag":true}],"other":[1]};</script>"#),
        vec!["fixture creator", "with ] bracket"],
        "a bracket inside a string does not end the array"
    );
}

#[test]
fn every_page_tags_block_names_a_place_to_look() {
    for entry in fs::read_dir("../sources").expect("sources/") {
        let path = entry.expect("entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("toml") {
            continue;
        }
        let manifest: sources::declarative::Manifest = toml::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        if let Some(spec) = manifest.page_tags {
            assert!(
                !spec.attrs.is_empty() || !spec.select.is_empty() || !spec.meta.is_empty() || !spec.json_array.is_empty(),
                "{}: [page_tags] says nowhere to look",
                path.display()
            );
            assert!(spec.json_array.is_empty() || !spec.field.is_empty(), "{}: json_array needs field", path.display());
        }
    }
}

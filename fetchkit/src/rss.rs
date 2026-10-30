/*
 * RSS and Atom, which most of the news web still speaks.
 */

#![allow(dead_code)]



use crate::*;

/// One item of an RSS feed, flattened to what a catalogue needs.
#[derive(Debug, Default, Clone)]
pub struct RssItem {
    pub title: String,
    pub link: String,
    pub author: String,
    pub media_url: String,
    pub thumb_url: String,
    pub width: u32,
    pub height: u32,
    /// The item's own text, where the feed gives one. Empty for the image
    /// feeds this parser was first written for; a news feed's summary is
    /// often the only sentence you get without a paywall.
    pub description: String,
    /// Unix seconds, or 0 when the feed publishes no date — which happens, and
    /// a caller should treat as "old", never as "now".
    pub published: i64,
    /// `media:rating` — "adult" or "nonadult". Empty when the feed omits it.
    ///
    /// Parsed because it is the only maturity signal DeviantArt publishes, and
    /// without it `-nsfw` cannot mean anything for that source: the adapter
    /// declared `nsfw: false` in its capabilities, so the flag was never even
    /// pushed down and mature work came back regardless of what was asked.
    pub rating: String,
}

/// Parse an RSS feed with Yahoo media extensions — DeviantArt's public backend
/// speaks exactly this, and it is the reason that source needs no API key.
///
/// **16**
/*
 * WHAT THE FEED CALLS ITSELF.
 *
 * The `<title>` of the channel, not of an item — the one before the first
 * `<item>`/`<entry>` opens. Wanted by anything that subscribes to a URL a
 * person typed: a reader that files it under `feeds_arstechnica_com` when the
 * document says "Ars Technica" is making the person do the work the document
 * already did.
 *
 * Empty rather than an error when there is no title. A feed without one is
 * unusual, not unusable, and the caller has the host to fall back on.
 */
pub fn feed_title(xml: &str) -> String {
    use quick_xml::events::Event;

    let mut reader = quick_xml::Reader::from_str(xml);
    // Not trimmed per event, for the reason given in `parse_rss`: an entity
    // splits the text into fragments and trimming each one eats the space
    // beside it, so "Tom &amp; Jerry" arrives as "TomJerry".
    reader.config_mut().trim_text(false);

    let mut in_title = false;
    let mut title = String::new();
    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => match e.name().as_ref() {
                // Past here the titles belong to articles.
                b"item" | b"entry" => break,
                b"title" => in_title = true,
                _ => {}
            },
            Ok(Event::Text(t)) if in_title => {
                title.push_str(&t.decode().unwrap_or_default());
            }
            Ok(Event::CData(t)) if in_title => {
                title.push_str(&String::from_utf8_lossy(&t));
            }
            // See the note on `GeneralRef` in `parse_rss`.
            Ok(Event::GeneralRef(r)) if in_title => {
                title.push_str(&format!("&{};", String::from_utf8_lossy(r.as_ref())));
            }
            Ok(Event::End(e)) if e.name().as_ref() == b"title" => {
                if !title.trim().is_empty() {
                    break;
                }
                in_title = false;
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    html_unescape(&title).split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn parse_rss(xml: &str) -> Result<Vec<RssItem>> {
    use quick_xml::events::Event;

    let mut reader = quick_xml::Reader::from_str(xml);
    /*
     * Trimming is done ONCE, when the item is finished — see `tidy`.
     *
     * Trimming each event instead ate the space at a fragment boundary, so a
     * headline split by an entity came out as "Pope fevertakes hold". The
     * whitespace between two elements lands in whichever field was last open
     * and is collapsed away by the same pass.
     */
    reader.config_mut().trim_text(false);

    let mut items = Vec::new();
    let mut current: Option<RssItem> = None;
    let mut field = String::new();
    let mut buf = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                match name.as_str() {
                    // Atom calls it `entry`; RDF and RSS call it `item`. The
                    // three differ in more than this, but not in ways that
                    // change what a reader wants out of them.
                    "item" | "entry" => current = Some(RssItem::default()),
                    // Atom puts the URL in an attribute rather than in text,
                    // and publishes several links per entry — the alternate
                    // (or unlabelled) one is the article.
                    "link" if current.is_some() && e.attributes().count() > 0 => {
                        if let Some(item) = current.as_mut() {
                            let mut href = String::new();
                            let mut rel = String::new();
                            for attr in e.attributes().flatten() {
                                let key = String::from_utf8_lossy(attr.key.as_ref()).to_string();
                                let value = attr.unescape_value().unwrap_or_default().to_string();
                                match key.as_str() {
                                    "href" => href = value,
                                    "rel" => rel = value,
                                    _ => {}
                                }
                            }
                            if item.link.is_empty() && (rel.is_empty() || rel == "alternate") {
                                item.link = href;
                            }
                        }
                    }
                    "media:content" | "media:thumbnail" => {
                        if let Some(item) = current.as_mut() {
                            let mut url = String::new();
                            let mut w = 0u32;
                            let mut h = 0u32;
                            for attr in e.attributes().flatten() {
                                let key = String::from_utf8_lossy(attr.key.as_ref()).to_string();
                                let value = attr.unescape_value().unwrap_or_default().to_string();
                                match key.as_str() {
                                    "url" => url = value,
                                    "width" => w = value.parse().unwrap_or(0),
                                    "height" => h = value.parse().unwrap_or(0),
                                    _ => {}
                                }
                            }
                            // media:content is the full image; media:thumbnail
                            // is the preview. Keep the largest of each.
                            if name == "media:content" {
                                if w >= item.width {
                                    item.media_url = url;
                                    item.width = w;
                                    item.height = h;
                                }
                            } else if item.thumb_url.is_empty() {
                                item.thumb_url = url;
                            }
                        }
                    }
                    other => field = other.to_string(),
                }
            }
            /*
             * TEXT AND CDATA ARE THE SAME THING TO A READER.
             *
             * quick-xml reports `<![CDATA[...]]>` as its own event, and
             * handling only `Text` meant every BBC and Hacker News item came
             * back with an empty title and was dropped — a feed that fetched
             * fine, parsed fine, and yielded nothing at all.
             *
             * Text also ARRIVES IN PIECES: an entity or a CDATA boundary
             * splits one title across several events, so these append rather
             * than assign. Assigning kept only the last fragment, which is how
             * a headline came out reading "could undermine humanity on his
             * France visit" — the half it began with had been overwritten.
             */
            /*
             * `GeneralRef` IS THE THIRD KIND OF TEXT, AND IT WAS BEING BINNED.
             *
             * quick-xml 0.38 stopped folding `&amp;` and `&#8217;` into the
             * surrounding text and emits each one as its own event. Matching
             * only Text and CData therefore DELETED every character anybody
             * wrote as an entity: "Tom &amp; Jerry" came out "Tom Jerry",
             * "caf&#233;" came out "caf", and every curly apostrophe in every
             * headline from every feed quietly vanished. It looked like nothing
             * at all, which is why it lasted.
             *
             * Put back verbatim as `&name;` rather than resolved here: the
             * callers already run `html_unescape` over these fields, so this
             * hands it the thing it knows how to read instead of adding a
             * second, differently-wrong decoder.
             */
            Ok(event @ (Event::Text(_) | Event::CData(_) | Event::GeneralRef(_))) => {
                let text = match &event {
                    Event::Text(t) => t.decode().unwrap_or_default().to_string(),
                    Event::CData(c) => String::from_utf8_lossy(c.as_ref()).to_string(),
                    Event::GeneralRef(r) => format!("&{};", String::from_utf8_lossy(r.as_ref())),
                    _ => String::new(),
                };
                if let Some(item) = current.as_mut() {
                    match field.as_str() {
                        "title" => item.title.push_str(&text),
                        "link" => item.link.push_str(&text),
                        // `content:encoded` is the whole article and is not
                        // what a summary is for, so it only fills in when the
                        // feed gave nothing shorter.
                        "description" | "summary" => item.description.push_str(&text),
                        "content:encoded" => {
                            if item.description.is_empty() {
                                item.description = text;
                            }
                        }
                        "pubDate" | "dc:date" | "published" | "updated" => {
                            if item.published == 0 {
                                item.published = parse_date(&text);
                            }
                        }
                        "media:rating" => {
                            item.rating = text.trim().to_ascii_lowercase();
                        }
                        "media:credit" | "dc:creator" => {
                            /*
                             * The first credit wins, and it must not be a URL.
                             *
                             * DeviantArt publishes two `media:credit` per item —
                             * the author's name, then the URL of their avatar —
                             * so taking the last one made every author a
                             * `.gif` link. Feeds that credit once are
                             * unaffected; feeds that credit twice mean the
                             * first one.
                             */
                            if item.author.is_empty() && !text.starts_with("http") {
                                item.author = text;
                            }
                        }
                        _ => {}
                    }
                }
            }
            Ok(Event::End(e)) => {
                if e.name().as_ref() == b"item" || e.name().as_ref() == b"entry" {
                    if let Some(mut item) = current.take() {
                        item.title = tidy(&item.title);
                        /*
                         * A URL is decoded HERE, unlike the text fields.
                         *
                         * `&` inside a query string must be written `&amp;` in
                         * XML, so a feed that links to `?a=1&amp;b=2` is
                         * correct and the entity is not content — leaving it in
                         * hands the caller a URL with a literal "&amp;" in it,
                         * which is a different page or a 404. The text fields
                         * are left alone because their caller unescapes them
                         * for display and doing it twice turns a headline
                         * about "&amp;" into one about "&".
                         */
                        item.link = crate::html_unescape(&tidy(&item.link));
                        item.media_url = crate::html_unescape(item.media_url.trim());
                        item.thumb_url = crate::html_unescape(item.thumb_url.trim());
                        item.description = tidy(&item.description);
                        item.author = tidy(&item.author);
                        items.push(item);
                    }
                }
                field.clear();
            }
            Ok(Event::Eof) => break,
            Err(e) => return Err(ScrapeError::Parse(e.to_string())),
            _ => {}
        }
        buf.clear();
    }

    Ok(items)
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture;

    /*
     * ENTITIES ARE CHARACTERS, NOT NOISE.
     *
     * quick-xml 0.38 emits `&amp;` as its own event; the parser matched only
     * Text and CData, so every one of them was dropped on the floor. This is
     * the regression test for a fault that showed up as headlines missing
     * their ampersands, their accents and their apostrophes, with nothing
     * anywhere saying a character had been lost.
     */
    #[test]
    fn entities_survive_into_the_text() {
        let xml = r#"<rss><channel><item>
            <title>Tom &amp; Jerry, and the caf&#233; Google&#8217;s lawyers built</title>
            <link>https://x.test/a?a=1&amp;b=2</link>
            <description>Half &amp; half</description>
        </item></channel></rss>"#;
        let items = parse_rss(xml).expect("parses");
        assert_eq!(
            crate::html_unescape(&items[0].title),
            "Tom & Jerry, and the café Google\u{2019}s lawyers built"
        );
        assert_eq!(items[0].link, "https://x.test/a?a=1&b=2", "and in a query string");
        assert_eq!(crate::html_unescape(&items[0].description), "Half & half");
    }

    #[test]
    fn a_feed_names_itself_before_its_first_item() {
        // RSS, Atom, CDATA, and the trap: the channel title must win over the
        // first article's, which is the one a naive `<title>` grab returns.
        assert_eq!(
            feed_title(r#"<rss><channel><title>Ars Technica</title>
                <item><title>Some article</title></item></channel></rss>"#),
            "Ars Technica"
        );
        assert_eq!(
            feed_title(r#"<feed><title>LWN.net</title><entry><title>An article</title></entry></feed>"#),
            "LWN.net"
        );
        assert_eq!(
            feed_title(r#"<rss><channel><title><![CDATA[Tom & Jerry]]></title></channel></rss>"#),
            "Tom & Jerry"
        );
        assert_eq!(
            feed_title(r#"<rss><channel><title>Tom &amp; Jerry</title></channel></rss>"#),
            "Tom & Jerry"
        );
    }

    #[test]
    fn a_feed_with_no_title_is_empty_rather_than_an_error() {
        for bad in ["", "<rss><channel></channel></rss>", "not xml", "<html><title>A page</title></html>"] {
            let got = feed_title(bad);
            assert!(got.is_empty() || got == "A page", "{bad:?} gave {got:?}");
        }
    }

    #[test]
    fn rss_authors_are_names_not_avatar_urls() {
        // DeviantArt credits twice per item: the name, then the avatar's URL.
        let items = parse_rss(&fixture("deviantart.rss")).expect("feed parses");
        let credited = items.iter().find(|i| !i.author.is_empty()).expect("someone is credited");
        assert!(!credited.author.starts_with("http"), "author was {:?}", credited.author);
        assert!(!credited.author.ends_with(".gif"), "author was {:?}", credited.author);
    }

    #[test]
    fn deviantart_rss_carries_its_maturity_rating() {
        /*
         * `media:rating` is the only maturity signal DeviantArt publishes, and
         * it was not being read — so every row claimed to be safe, `-nsfw`
         * filtered nothing from that source, and the mature work the site
         * serves BLURRED to a logged-out client arrived looking fine.
         *
         * Tested both ways on purpose: reading the field is worthless if
         * "adult" does not survive it, and this fixture is all `nonadult`, so
         * the negative case has to be constructed.
         */
        let feed = fixture("deviantart.rss");
        let items = parse_rss(&feed).expect("feed parses");
        assert!(!items.is_empty(), "no items in feed");
        assert!(
            items.iter().all(|i| i.rating == "nonadult"),
            "this fixture is entirely nonadult; got {:?}",
            items.iter().map(|i| i.rating.clone()).collect::<Vec<_>>()
        );

        let mature = feed.replace(
            "<media:rating>nonadult</media:rating>",
            "<media:rating>adult</media:rating>",
        );
        let flagged = parse_rss(&mature).expect("feed parses");
        assert!(
            flagged.iter().all(|i| i.rating == "adult"),
            "an adult rating must survive the parse"
        );
    }

    #[test]
    fn deviantart_rss_carries_media_dimensions() {
        let items = parse_rss(&fixture("deviantart.rss")).expect("feed parses");
        assert!(!items.is_empty(), "no items in feed");

        let with_media = items.iter().filter(|i| !i.media_url.is_empty()).count();
        assert!(with_media > 0, "no media:content urls");

        let sized = items.iter().find(|i| i.width > 0 && i.height > 0).expect("dimensions");
        assert!(!sized.title.is_empty());
        assert!(sized.link.starts_with("http"));
    }
}

/*
 * THE TWO DATE FORMATS FEEDS ACTUALLY PUBLISH.
 *
 * RFC 822 as RSS uses it (`Tue, 23 Sep 2026 10:00:00 GMT`) and ISO 8601 as
 * Atom does (`2026-09-23T10:00:00Z`). Written out rather than pulled in as a
 * dependency: a date crate brings a timezone database to solve a problem these
 * two shapes do not have, and the failure mode here is a story sorted slightly
 * wrong rather than a wrong answer.
 *
 * Offsets are honoured; anything unparseable is 0, which every caller is told
 * to read as "old".
 */
/// Collapse runs of whitespace and trim — applied to a finished field rather
/// than to each fragment that built it.
fn tidy(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn parse_date(text: &str) -> i64 {
    let t = text.trim();
    if t.is_empty() {
        return 0;
    }
    iso8601(t).or_else(|| rfc822(t)).unwrap_or(0)
}

/// Days since the Unix epoch for a civil date — Howard Hinnant's days_from_civil.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn stamp(y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64, offset_secs: i64) -> i64 {
    days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset_secs
}

fn iso8601(t: &str) -> Option<i64> {
    let bytes = t.as_bytes();
    if bytes.len() < 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    let num = |a: usize, b: usize| t.get(a..b)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (mut h, mut mi, mut s) = (0, 0, 0);
    let mut offset = 0;
    if bytes.len() >= 19 && (bytes[10] == b'T' || bytes[10] == b' ') {
        h = num(11, 13)?;
        mi = num(14, 16)?;
        s = num(17, 19)?;
        let tail = &t[19..];
        if let Some(sign_at) = tail.find(['+', '-']) {
            let sign = if tail.as_bytes()[sign_at] == b'-' { -1 } else { 1 };
            let z = &tail[sign_at + 1..].replace(':', "");
            if z.len() >= 4 {
                offset = sign * (z[0..2].parse::<i64>().ok()? * 3600 + z[2..4].parse::<i64>().ok()? * 60);
            }
        }
    }
    Some(stamp(y, mo, d, h, mi, s, offset))
}

fn rfc822(t: &str) -> Option<i64> {
    const MONTHS: [&str; 12] =
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    // The leading day name is optional in the spec and present in practice.
    let rest = t.split_once(", ").map(|(_, r)| r).unwrap_or(t);
    let parts: Vec<&str> = rest.split_whitespace().collect();
    if parts.len() < 4 {
        return None;
    }
    let d: i64 = parts[0].parse().ok()?;
    let mo = MONTHS.iter().position(|m| parts[1].to_ascii_lowercase().starts_with(m))? as i64 + 1;
    let y: i64 = parts[2].parse().ok()?;
    let y = if y < 100 { y + 2000 } else { y };
    let mut hms = parts.get(3).unwrap_or(&"00:00:00").split(':');
    let h: i64 = hms.next()?.parse().ok()?;
    let mi: i64 = hms.next().unwrap_or("0").parse().unwrap_or(0);
    let s: i64 = hms.next().unwrap_or("0").parse().unwrap_or(0);
    let offset = match parts.get(4) {
        Some(z) if z.starts_with('+') || z.starts_with('-') => {
            let sign = if z.starts_with('-') { -1 } else { 1 };
            let digits = &z[1..];
            if digits.len() >= 4 {
                sign * (digits[0..2].parse::<i64>().ok()? * 3600 + digits[2..4].parse::<i64>().ok()? * 60)
            } else {
                0
            }
        }
        // GMT/UT/Z are zero; the obsolete US zone names are not worth the table.
        _ => 0,
    };
    Some(stamp(y, mo, d, h, mi, s, offset))
}

#[cfg(test)]
mod date_tests {
    use super::*;

    /// The epoch itself, both ways round, so an off-by-one in the civil-date
    /// arithmetic cannot hide.
    #[test]
    fn the_epoch_is_zero_in_both_shapes() {
        assert_eq!(parse_date("1970-01-01T00:00:00Z"), 0);
        assert_eq!(parse_date("Thu, 01 Jan 1970 00:00:00 GMT"), 0);
    }

    #[test]
    fn the_two_shapes_agree_on_the_same_moment() {
        let iso = parse_date("2026-09-23T10:00:00Z");
        let rfc = parse_date("Wed, 23 Sep 2026 10:00:00 GMT");
        assert_eq!(iso, rfc);
        assert!(iso > 1_750_000_000, "and it is in the right decade");
    }

    #[test]
    fn an_offset_moves_the_moment_the_right_way() {
        let utc = parse_date("2026-09-23T10:00:00Z");
        assert_eq!(parse_date("2026-09-23T12:00:00+02:00"), utc, "noon in Berlin is ten UTC");
        assert_eq!(parse_date("Wed, 23 Sep 2026 06:00:00 -0400"), utc, "six in New York is ten UTC");
    }

    #[test]
    fn a_date_with_no_time_still_lands_on_the_day() {
        assert_eq!(parse_date("2026-09-23"), parse_date("2026-09-23T00:00:00Z"));
    }

    /// Nothing parseable is 0 — never `now`, which would put a broken feed at
    /// the top of the page for ever.
    #[test]
    fn nonsense_is_old_rather_than_new() {
        for bad in ["", "   ", "yesterday", "23/09/2026", "Mon, 32 Xxx 2026"] {
            assert_eq!(parse_date(bad), 0, "{bad:?}");
        }
    }
}

#[cfg(test)]
mod cdata_tests {
    use super::*;

    /// The BBC's shape: every field in CDATA. Handling only `Event::Text`
    /// meant 33 items parsed into 33 empty titles and were dropped by the
    /// caller — a feed that fetched fine and yielded nothing.
    #[test]
    fn a_feed_that_wraps_everything_in_cdata_still_parses() {
        let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel>
          <item>
            <title><![CDATA[Ceasefire agreed after months of talks]]></title>
            <description><![CDATA[Mediators say the deal takes effect at dawn.]]></description>
            <link>https://example.test/1</link>
            <pubDate>Wed, 23 Sep 2026 10:00:00 GMT</pubDate>
          </item>
        </channel></rss>"#;
        let items = parse_rss(xml).expect("parse");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Ceasefire agreed after months of talks");
        assert_eq!(items[0].description, "Mediators say the deal takes effect at dawn.");
        assert!(items[0].published > 0, "and its date came with it");
    }

    /// An entity splits the text into several events. Assigning each one kept
    /// the LAST fragment, so a headline arrived beheaded.
    #[test]
    fn a_title_split_by_an_entity_arrives_whole() {
        let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel>
          <item><title>Macron&#8217;s warning that AI could undermine humanity</title>
          <link>https://example.test/2</link></item>
        </channel></rss>"#;
        let items = parse_rss(xml).expect("parse");
        assert!(
            items[0].title.starts_with("Macron"),
            "the whole headline, not its tail: {:?}",
            items[0].title
        );
        assert!(items[0].title.ends_with("humanity"));
    }

    /// Atom, which several outlets serve instead of RSS: `entry` rather than
    /// `item`, and the URL in an attribute rather than in text.
    #[test]
    fn an_atom_entry_is_read_like_an_item() {
        let xml = r#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>Court blocks the deportation flights</title>
            <link rel="alternate" href="https://example.test/3"/>
            <summary>The ruling lands hours before takeoff.</summary>
            <published>2026-09-23T10:00:00Z</published>
          </entry>
        </feed>"#;
        let items = parse_rss(xml).expect("parse");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Court blocks the deportation flights");
        assert_eq!(items[0].link, "https://example.test/3", "the href, not empty text");
        assert!(items[0].published > 0);
    }
}

#[cfg(test)]
mod boundary_tests {
    use super::*;

    /// The join that trimming each fragment destroyed: "Pope fever" and
    /// "takes hold" arrived as two events and were concatenated into
    /// "Pope fevertakes hold".
    #[test]
    fn the_space_at_a_fragment_boundary_survives() {
        let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel>
          <item><title>Pope fever <![CDATA[takes hold]]> as Leo visits France</title>
          <link>https://example.test/4</link></item>
        </channel></rss>"#;
        let items = parse_rss(xml).expect("parse");
        assert_eq!(items[0].title, "Pope fever takes hold as Leo visits France");
    }

    /// And the indentation between elements does not end up in the field that
    /// happened to be open when it arrived.
    #[test]
    fn pretty_printing_is_not_content() {
        let xml = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel>\n  <item>\n    <title>A headline</title>\n    <link>https://example.test/5</link>\n  </item>\n</channel></rss>";
        let items = parse_rss(xml).expect("parse");
        assert_eq!(items[0].title, "A headline");
        assert_eq!(items[0].link, "https://example.test/5");
    }
}

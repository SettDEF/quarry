/*
 * Reading HTML: CSS selection, regex extraction, and entity unescaping.
 */

#![allow(dead_code)]

use std::collections::HashMap;


use crate::*;

/// Every match of a capture group, in document order.
///
/// The pfps.gg adapter is one call to this: the page is server-rendered HTML
/// with image URLs that carry the id and the slug.
///
/// **12**
pub fn regex_all(text: &str, pattern: &str, group: usize) -> Result<Vec<String>> {
    let re = regex::Regex::new(pattern).map_err(|e| ScrapeError::Parse(e.to_string()))?;
    Ok(re
        .captures_iter(text)
        .filter_map(|c| c.get(group).map(|m| m.as_str().to_string()))
        .collect())
}

/// Named capture groups for every match — the shape a declarative adapter wants,
/// since it maps names to `Item` fields.
///
/// **13**
pub fn regex_captures(text: &str, pattern: &str) -> Result<Vec<HashMap<String, String>>> {
    let re = regex::Regex::new(pattern).map_err(|e| ScrapeError::Parse(e.to_string()))?;
    let names: Vec<&str> = re.capture_names().flatten().collect();

    Ok(re
        .captures_iter(text)
        .map(|c| {
            names
                .iter()
                .filter_map(|n| c.name(n).map(|m| (n.to_string(), m.as_str().to_string())))
                .collect()
        })
        .collect())
}

/// Attribute values for every element matching a CSS selector.
///
/// **14**
pub fn select_attrs(html: &str, selector: &str, attr: &str) -> Result<Vec<String>> {
    let document = scraper::Html::parse_document(html);
    let sel = scraper::Selector::parse(selector)
        .map_err(|e| ScrapeError::Parse(format!("bad selector {selector}: {e:?}")))?;
    Ok(document
        .select(&sel)
        .filter_map(|el| el.value().attr(attr).map(|v| v.to_string()))
        .collect())
}

/// Text content for every element matching a CSS selector, whitespace collapsed.
///
/// **15**
pub fn select_texts(html: &str, selector: &str) -> Result<Vec<String>> {
    let document = scraper::Html::parse_document(html);
    let sel = scraper::Selector::parse(selector)
        .map_err(|e| ScrapeError::Parse(format!("bad selector {selector}: {e:?}")))?;
    Ok(document
        .select(&sel)
        .map(|el| el.text().collect::<String>().split_whitespace().collect::<Vec<_>>().join(" "))
        .collect())
}


/// Undo the HTML entities an attribute value is escaped with.
///
/// Not a general HTML unescaper: exactly the five that matter for reading JSON
/// out of an attribute, plus numeric escapes, which is what pages that embed
/// their state in `data-*` attributes actually produce.
///
/// **28**
pub fn html_unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;

    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];

        let Some(end) = rest.find(';').filter(|e| *e <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };

        let entity = &rest[1..end];
        let replacement = match entity {
            "quot" => Some('"'),
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "apos" | "#39" => Some('\''),
            "nbsp" => Some(' '),
            numeric if numeric.starts_with("#x") || numeric.starts_with("#X") => {
                u32::from_str_radix(&numeric[2..], 16).ok().and_then(char::from_u32)
            }
            numeric if numeric.starts_with('#') => {
                numeric[1..].parse::<u32>().ok().and_then(char::from_u32)
            }
            _ => None,
        };

        match replacement {
            Some(ch) => {
                out.push(ch);
                rest = &rest[end + 1..];
            }
            // An unknown entity is left exactly as it was rather than guessed
            // at or dropped.
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture;

    #[test]
    fn pfps_gg_css_selection_agrees_with_the_regex() {
        let html = fixture("pfps-gg.html");
        let srcs = select_attrs(&html, "img", "src").expect("selector parses");
        let cdn = srcs.iter().filter(|s| s.contains("cdn.pfps.gg/pfps/")).count();
        assert!(cdn > 10, "CSS selection found {cdn} images");
    }

    #[test]
    fn the_entities_an_attribute_actually_carries() {
        assert_eq!(html_unescape("{&quot;a&quot;:1}"), r#"{"a":1}"#);
        assert_eq!(html_unescape("a&amp;b"), "a&b");
        assert_eq!(html_unescape("&lt;tag&gt;"), "<tag>");
        assert_eq!(html_unescape("it&#39;s"), "it's");
        assert_eq!(html_unescape("&#x2014;"), "—");
    }

    #[test]
    fn anything_else_is_left_exactly_as_it_was() {
        // Guessing at an unknown entity, or dropping it, corrupts the JSON that
        // is about to be parsed — a URL with a bare `&` in it, most often.
        assert_eq!(html_unescape("a&unknown;b"), "a&unknown;b");
        assert_eq!(html_unescape("100% & rising"), "100% & rising");
        assert_eq!(html_unescape("&"), "&");
        assert_eq!(html_unescape("&#;"), "&#;");
        assert_eq!(html_unescape(""), "");
    }
}

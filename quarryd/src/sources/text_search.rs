//! Whether a source can be asked a typed search at all.
//!
//! A source whose capabilities say `text: false` never sees the words: the
//! push-down leaves them in the residue, the source is asked for its ordinary
//! feed, and the words are matched locally against whatever titles came back.
//! For a feed like Peapix (the Bing picture of the day, which has no search)
//! that is not a search of the site — it is the site's front page filtered, and
//! it shows pictures that were never an answer to the question.
//!
//! So a caller running a typed query asks here first and skips the source,
//! with the reason, rather than fetching it. The local folder is the exception:
//! it has no remote side, and matching locally IS its search.

use super::{Capabilities, Source};
use crate::query::{Query, Term};

/// What a query is actually looking FOR, as opposed to what it filters by.
///
/// Size and rating narrow a feed; words, tags and a creator name select from
/// one. A source that can express none of what a query selects by has nothing
/// to answer with but its front page.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Selectors {
    pub words: bool,
    pub tags: bool,
    pub author: bool,
}

impl Selectors {
    pub fn any(&self) -> bool {
        self.words || self.tags || self.author
    }
}

/// The selective terms a query carries. Negation is a local filter, not a
/// thing to search for, so it is not counted.
pub fn selectors(query: &Query) -> Selectors {
    let mut out = Selectors::default();
    for clause in query.clauses.iter().filter(|c| !c.negated) {
        match &clause.term {
            Term::Text(_) => out.words = true,
            Term::Field { key, .. } if key == "tag" || key == "tags" => out.tags = true,
            Term::Field { key, .. } if key == "author" => out.author = true,
            _ => {}
        }
    }
    out
}

/// Whether the query carries words the source would have to search for.
pub fn has_words(query: &Query) -> bool {
    selectors(query).any()
}

/// `Some(reason)` when `source` should be skipped for `query`: the query
/// selects by something, and the source can express none of it.
///
/// Partial ability is enough to be worth asking — a booru that can take the
/// words but not the artist still returns a page about the right subject, and
/// the artist is re-checked locally.
pub fn skip_reason(query: &Query, id: &str, caps: &Capabilities) -> Option<String> {
    if id == "local" {
        return None;
    }
    let wanted = selectors(query);
    if !wanted.any() {
        return None;
    }

    let can_words = wanted.words && (caps.text || caps.tags);
    let can_tags = wanted.tags && (caps.tags || caps.text);
    let can_author = wanted.author && caps.author;
    if can_words || can_tags || can_author {
        return None;
    }

    // Name what it could not do, so the report is a sentence rather than a
    // shrug: "no search" and "no author search" are different problems.
    let missing = match (wanted.words || wanted.tags, wanted.author) {
        (true, true) => "cannot search for words or by author",
        (true, false) => "has no search of its own",
        (false, true) => "cannot search by author",
        (false, false) => unreachable!("checked above"),
    };
    Some(format!(
        "{id} {missing} — skipped for this query rather than showing its unrelated front page"
    ))
}

/// The same, for a boxed source.
pub fn skip_source(query: &Query, source: &dyn Source) -> Option<String> {
    skip_reason(query, source.id(), &source.capabilities())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_feed_without_search_is_skipped_only_for_typed_words() {
        let feed = Capabilities::default();
        let words = crate::query::parse("mountain lake");
        assert!(skip_reason(&words, "peapix", &feed).unwrap().contains("peapix"));

        // Filters alone are not a search; the feed still answers them.
        let filters = crate::query::parse("w>=1920 -nsfw");
        assert!(skip_reason(&filters, "peapix", &feed).is_none());
        // A negated word is a local filter, not a search.
        assert!(skip_reason(&crate::query::parse("-cat"), "peapix", &feed).is_none());

        let searchable = Capabilities { text: true, ..Default::default() };
        assert!(skip_reason(&words, "wallhaven", &searchable).is_none());
        assert!(skip_reason(&words, "local", &feed).is_none());
    }

    /// The bug this was written for: `author:x` selects, but nothing treated it
    /// as selective, so every source fetched its front page and every row was
    /// filtered away. Measured before the fix: 7,853 rows fetched, 0 kept.
    #[test]
    fn an_author_query_is_a_search_not_a_filter() {
        let by_author = crate::query::parse("author:brixxam004");
        assert!(selectors(&by_author).author);
        assert!(has_words(&by_author), "an author query selects");

        // A source that cannot name a creator must not be asked at all.
        let text_only = Capabilities { text: true, ..Default::default() };
        let reason = skip_reason(&by_author, "eporner", &text_only).expect("skipped");
        assert!(reason.contains("author"), "{reason}");

        // One that can is asked, and gets the name pushed down.
        let by_creator = Capabilities { author: true, ..Default::default() };
        assert!(skip_reason(&by_author, "reddit", &by_creator).is_none());
        let (pushed, _) = super::super::pushdown(&by_author, &by_creator);
        assert_eq!(pushed.author, "brixxam004");
    }

    /// Words plus an author the source cannot express is still worth asking:
    /// the words narrow it, and the name is re-checked locally.
    #[test]
    fn partial_ability_is_still_worth_asking() {
        let mixed = crate::query::parse("sunset author:someone");
        let text_only = Capabilities { text: true, ..Default::default() };
        assert!(skip_reason(&mixed, "wallhaven", &text_only).is_none());
    }
}

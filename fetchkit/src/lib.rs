/*
 * POLITE FETCHING, SHARED.
 *
 * One rate limiter that backs off when a host asks it to, one on-disk cache,
 * one honest User-Agent with one documented list of the hosts sent something
 * else, one retry policy — used by quarry and by cairn rather than each
 * growing its own half-right copy.
 *
 * What is NOT here is anything that knows what a row MEANS. A picture's family
 * and an article's section are the collector's vocabulary, not the fetcher's;
 * `normalize` stayed in quarry for exactly that reason. The line is
 * deliberate: this crate ends at "bytes, and the shapes the web serves them
 * in".
 *
 * Laid out one concern per file. Everything is re-exported flat, so a caller
 * writes `fetchkit::parse_rss` and never has to know which file it lives in —
 * the modules are for whoever is READING the code, not for whoever calls it.
 */

mod agent;
mod cache;
mod error;
mod html;
mod http;
mod json;
mod limiter;
mod rss;
mod text;
mod uri;

pub use agent::*;
pub use cache::*;
pub use error::*;
pub use html::*;
pub use http::*;
pub use json::*;
pub use limiter::*;
pub use rss::*;
pub use text::*;
pub use uri::*;

/*
 * Fixtures are real captures, never hand-written: a parser test that invents
 * its own input proves the parser agrees with the person who wrote the test.
 * Provenance for each file is recorded beside the test that reads it.
 */
#[cfg(test)]
pub(crate) fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("tests/fixtures/{name}"))
        .unwrap_or_else(|e| panic!("missing fixture {name}: {e}"))
}

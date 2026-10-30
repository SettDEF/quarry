/*
 * What went wrong, and whether it is worth asking again.
 *
 * A 429 is split out from the other statuses deliberately: "this host is
 * unhappy with the pace" and "this host is unhappy with the request" look
 * identical as a bare number and need opposite responses.
 */

#![allow(dead_code)]

use std::time::{Duration, SystemTime};



#[derive(Debug)]
pub enum ScrapeError {
    Http(String),
    Status(u16, String),
    /// A 429, called out on its own rather than folded into `Status`: a
    /// caller (and a human reading the message) needs to tell "this host is
    /// unhappy with the pace" apart from "this host is unhappy with the
    /// request", and the two look identical as a bare status code.
    RateLimited(String),
    Parse(String),
    Io(String),
}

pub type Result<T> = std::result::Result<T, ScrapeError>;

/// A status worth trying again: a dropped connection, a rate limit, or a server
/// that is briefly unwell. A 403 or a 404 is an answer, not a hiccup — retrying
/// those is how a crawler earns a permanent block.
///
/// **1**
impl ScrapeError {
    /*
     * Is this failure the last word on this URL?
     *
     * The distinction earns its keep in exactly one place and it matters a
     * lot: a thumbnail that cannot be fetched marks its row broken, and a
     * broken row stops being returned by any query, permanently, surviving
     * restarts. Doing that to a row whose host merely said "too fast" — which
     * Wikimedia's upload host does readily when a wall of ninety tiles opens
     * at once — deletes pictures from a catalogue for the crime of being
     * popular. Found exactly that way: a 4K Wikimedia video that answered 200
     * a few seconds later.
     */
    pub fn is_permanent(&self) -> bool {
        match self {
            ScrapeError::Status(status, _) => !is_transient(*status),
            // A parse failure is about the bytes, and they will be the same
            // bytes next time.
            ScrapeError::Parse(_) => true,
            // Rate limits, 5xx, connection failures and timeouts: all "later".
            ScrapeError::RateLimited(_) | ScrapeError::Http(_) | ScrapeError::Io(_) => false,
        }
    }
}

/// What a host's own `Retry-After` header says, in seconds or as an HTTP date.
/// Capped: a host asking for an hour is asking for more than a crawl can wait,
/// and the caller clamps to its own ceiling anyway.
pub fn retry_after(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    let raw = headers.get(reqwest::header::RETRY_AFTER)?.to_str().ok()?.trim().to_string();
    // Seconds is the form these hosts send. The HTTP-date form is legal and
    // unused here; ignoring it costs one doubled delay, not a dependency.
    raw.parse::<u64>().ok().map(|seconds| Duration::from_secs(seconds.min(3600)))
}

pub fn is_transient(status: u16) -> bool {
    status == 0 || status == 429 || (500..600).contains(&status)
}

/// Exponential backoff with jitter, in milliseconds.
///
/// The jitter matters when several adapters wake on the same timer: without it
/// they retry in lockstep and hit the same host at the same instant.
///
/// **2**
pub fn backoff_delay(attempt: u32) -> Duration {
    let base = 600u64.saturating_mul(3u64.saturating_pow(attempt.saturating_sub(1)));
    let jitter = (SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.subsec_millis() as u64)
        .unwrap_or(0))
        % 250;
    Duration::from_millis(base.min(20_000) + jitter)
}


impl std::fmt::Display for ScrapeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScrapeError::Http(e) => write!(f, "http: {e}"),
            ScrapeError::Status(code, url) => write!(f, "http {code} for {url}"),
            ScrapeError::RateLimited(url) => write!(f, "rate limited (429) for {url}"),
            ScrapeError::Parse(e) => write!(f, "parse: {e}"),
            ScrapeError::Io(e) => write!(f, "io: {e}"),
        }
    }
}


impl std::error::Error for ScrapeError {}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transient_statuses_are_the_retryable_ones() {
        assert!(is_transient(0));
        assert!(is_transient(429));
        assert!(is_transient(503));
        // A hotlink block and a missing page are answers, not hiccups —
        // cdn.donmai.us and the Art Institute both answer 403 by design.
        assert!(!is_transient(403));
        assert!(!is_transient(404));
        assert!(!is_transient(200));
    }

    #[test]
    fn rate_limited_reads_differently_from_a_generic_status() {
        // The whole point of the variant: a 429 and a plain bad status must
        // not read the same in a message a human sees.
        let limited = ScrapeError::RateLimited("https://iqdb.org/".into()).to_string();
        let status = ScrapeError::Status(403, "https://iqdb.org/".into()).to_string();
        assert!(limited.contains("rate limited"), "{limited}");
        assert!(limited.contains("429"));
        assert_ne!(limited, status);
    }

    #[test]
    fn backoff_grows_and_is_capped() {
        let first = backoff_delay(1).as_millis();
        let second = backoff_delay(2).as_millis();
        assert!(second > first, "{second} should exceed {first}");
        assert!(backoff_delay(9).as_millis() <= 20_250);
    }

    #[test]
    fn retry_after_is_read_in_seconds_and_capped() {
        use reqwest::header::{HeaderMap, HeaderValue, RETRY_AFTER};
        let mut headers = HeaderMap::new();
        headers.insert(RETRY_AFTER, HeaderValue::from_static("12"));
        assert_eq!(super::retry_after(&headers), Some(Duration::from_secs(12)));
        headers.insert(RETRY_AFTER, HeaderValue::from_static("99999"));
        assert_eq!(super::retry_after(&headers), Some(Duration::from_secs(3600)));
        headers.insert(RETRY_AFTER, HeaderValue::from_static("Wed, 21 Oct 2026 07:28:00 GMT"));
        assert_eq!(super::retry_after(&headers), None, "the date form is ignored, not mis-parsed");
        assert_eq!(super::retry_after(&HeaderMap::new()), None);
    }

    /// `is_permanent` and `is_transient` are one decision; they must not drift
    /// into disagreeing about a status code.
    #[test]
    fn the_two_views_of_a_status_code_agree() {
        for status in [200u16, 301, 400, 403, 404, 410, 418, 429, 500, 502, 503, 504] {
            assert_eq!(
                ScrapeError::Status(status, "u".into()).is_permanent(),
                !is_transient(status),
                "disagreement about {status}"
            );
        }
    }

    /// The distinction that decides whether a row is hidden forever.
    #[test]
    fn only_a_real_absence_is_permanent() {
        // Gone, refused, or malformed: asking again changes nothing.
        assert!(ScrapeError::Status(404, "u".into()).is_permanent());
        assert!(ScrapeError::Status(410, "u".into()).is_permanent());
        assert!(ScrapeError::Status(403, "u".into()).is_permanent());
        assert!(ScrapeError::Parse("not an image".into()).is_permanent());

        // Busy, broken or unreachable: all of these answer differently later,
        // and every one of them used to hide the row for good.
        assert!(!ScrapeError::RateLimited("u".into()).is_permanent());
        assert!(!ScrapeError::Status(429, "u".into()).is_permanent());
        assert!(!ScrapeError::Status(503, "u".into()).is_permanent());
        assert!(!ScrapeError::Status(500, "u".into()).is_permanent());
        assert!(!ScrapeError::Http("connection reset".into()).is_permanent());
        assert!(!ScrapeError::Io("timed out".into()).is_permanent());
    }
}

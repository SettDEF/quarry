/*
 * How often one host may be asked.
 *
 * Per host, not global — one slow site must not throttle the rest — and it
 * speeds up again when a host stops complaining.
 */

#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};


use crate::*;

/*
 * PER-HOST CRAWL DELAY, LEARNED RATHER THAN DECREED.
 *
 * One delay for every host was the wrong shape twice over once the catalogue
 * grew past thirty sources: a keyed JSON API that is happy with four requests
 * a second was held to one, and a small board that starts answering 429 after
 * three quick requests was hit at that same pace until it stopped answering at
 * all. Neither is fixable by choosing a better single number, because the
 * hosts genuinely differ.
 *
 * So each host keeps its own delay, starting at the configured one. A 429
 * doubles it — or jumps straight to what the host's own `Retry-After` says,
 * which is not a guess — and every clean answer shaves 10% off, down to a
 * floor. A host that never complains drifts to the floor and stays there; one
 * that does backs off and recovers on its own.
 */
pub struct RateLimiter {
    delay: Duration,
    floor: Duration,
    ceiling: Duration,
    hosts: Mutex<HashMap<String, HostPace>>,
}

#[derive(Clone)]
struct HostPace {
    /// The earliest moment this host may be touched again.
    next: Instant,
    delay: Duration,
}

impl RateLimiter {
    pub fn new(delay: Duration) -> Self {
        RateLimiter {
            delay,
            // Never faster than four a second, however well a host behaves.
            floor: Duration::from_millis(250).min(delay),
            // A host that keeps saying "later" is asked twice a minute, not
            // dropped: its rows are still wanted, just not now.
            ceiling: Duration::from_secs(30),
            hosts: Mutex::new(HashMap::new()),
        }
    }

    /// Sleep until this host may be hit again. Keyed by host, not by adapter:
    /// several adapters can share one host (every booru mirror, every jsDelivr
    /// icon package) and the host only cares about the total.
    pub async fn wait(&self, url: &str) {
        let host = host_of(url).unwrap_or_default();
        let sleep_for = {
            let mut hosts = self.hosts.lock().unwrap();
            let now = Instant::now();
            let pace = hosts.entry(host).or_insert(HostPace { next: now, delay: self.delay });
            let wait = pace.next.saturating_duration_since(now);
            pace.next = now + wait + pace.delay;
            wait
        };
        if !sleep_for.is_zero() {
            tokio::time::sleep(sleep_for).await;
        }
    }

    /// This host asked us to slow down. `hint` is its own `Retry-After`.
    pub fn slow_down(&self, url: &str, hint: Option<Duration>) {
        let host = host_of(url).unwrap_or_default();
        let mut hosts = self.hosts.lock().unwrap();
        let now = Instant::now();
        let pace = hosts.entry(host).or_insert(HostPace { next: now, delay: self.delay });
        let doubled = pace.delay.saturating_mul(2).min(self.ceiling);
        pace.delay = hint.map(|h| h.min(self.ceiling)).unwrap_or(doubled).max(doubled.min(self.ceiling));
        // Serve the wait now as well, so the next request is not sent into the
        // same refusal.
        pace.next = pace.next.max(now + pace.delay);
    }

    /// A clean answer: inch back toward the floor.
    pub fn speed_up(&self, url: &str) {
        let host = host_of(url).unwrap_or_default();
        let mut hosts = self.hosts.lock().unwrap();
        if let Some(pace) = hosts.get_mut(&host) {
            let eased = pace.delay.mul_f32(0.9);
            pace.delay = eased.max(self.floor);
        }
    }

    /// What this host is being asked at now, for the doctor and for tests.
    pub fn pace_for(&self, url: &str) -> Duration {
        let host = host_of(url).unwrap_or_default();
        self.hosts.lock().unwrap().get(&host).map(|p| p.delay).unwrap_or(self.delay)
    }

    /// The configured per-host delay, for tests that want to compare two
    /// limiters without paying either one's real wait.
    #[cfg(test)]
    fn configured_delay(&self) -> Duration {
        self.delay
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_host_that_says_slow_down_is_asked_less_often() {
        let limiter = RateLimiter::new(Duration::from_millis(700));
        let url = "https://busy.example/1";
        assert_eq!(limiter.pace_for(url), Duration::from_millis(700));

        // Its own Retry-After wins over the doubling guess.
        limiter.slow_down(url, Some(Duration::from_secs(5)));
        assert_eq!(limiter.pace_for(url), Duration::from_secs(5));

        // With no header, the delay doubles, and stops at the ceiling.
        for _ in 0..10 {
            limiter.slow_down(url, None);
        }
        assert_eq!(limiter.pace_for(url), Duration::from_secs(30));

        // Clean answers ease it back down, and one host's pace is its own.
        for _ in 0..200 {
            limiter.speed_up(url);
        }
        assert_eq!(limiter.pace_for(url), Duration::from_millis(250), "eases to the floor, not past it");
        assert_eq!(limiter.pace_for("https://calm.example/1"), Duration::from_millis(700));
    }

    #[test]
    fn form_limiter_is_more_conservative_than_the_get_limiter() {
        // post_form must not share the GET path's 700ms pacing — iqdb has no
        // key and no published limit, so it gets its own stricter,
        // multi-second-per-host limiter. Compared without sleeping: a real
        // wait here would make the suite pay iqdb's own crawl delay.
        let http = Http::new().expect("client builds");
        assert!(http.form_limiter.configured_delay() >= Duration::from_secs(1));
        assert!(http.form_limiter.configured_delay() > http.limiter.configured_delay());
    }
}

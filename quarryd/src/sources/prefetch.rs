//! A request a source has to make BEFORE it can say what its request is.
//!
//! `Source::build_url` is synchronous and returns a string, and the daemon
//! fetches that string. Most sources need nothing more. Two kinds do:
//!
//! - a tag booru asked for free text, which first has to ask the site which of
//!   its tags the words mean (see `tag_resolve`);
//! - DuckDuckGo, whose image endpoint refuses any request without the `vqd`
//!   token its search page hands out for that query.
//!
//! Both answer in a few hundred milliseconds and are cached by their callers,
//! so they are made here, blocking, rather than by widening the trait every
//! adapter implements. The work runs on a thread of its own with a private
//! single-threaded runtime — never on the daemon's runtime, which may be the
//! very thread calling — and on the multi-threaded runtime the caller's worker
//! is handed back with `block_in_place` while it waits.
//!
//! Tests never touch the network: under `cfg(test)` every request fails fast,
//! and the callers are written so that a failed lookup degrades to the old
//! behaviour rather than to an empty answer.

use std::time::Duration;

use crate::scrape;

/// How long one lookup may take. A search that waits longer than this for a
/// tag list is a search the user has already given up on.
const TIMEOUT: Duration = Duration::from_secs(8);

/// GET every URL at once and answer the bodies in the same order.
///
/// Non-2xx answers are errors carrying the status, so a caller can tell a
/// refusal from an empty list.
pub fn get_many(urls: &[String]) -> Vec<Result<String, String>> {
    if cfg!(test) || urls.is_empty() {
        return urls.iter().map(|_| Err("network is off in tests".to_string())).collect();
    }

    let urls = urls.to_vec();
    let count = urls.len();
    let work = move || -> Vec<Result<String, String>> {
        let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(e) => return urls.iter().map(|_| Err(format!("runtime: {e}"))).collect(),
        };
        runtime.block_on(async move {
            // A client per call, on purpose: a reqwest client's connection pool
            // belongs to the runtime that opened its connections, and this
            // runtime is gone the moment the call returns.
            let client = match reqwest::Client::builder()
                .user_agent(scrape::USER_AGENT)
                .timeout(TIMEOUT)
                .connect_timeout(Duration::from_secs(5))
                .gzip(true)
                .build()
            {
                Ok(client) => client,
                Err(e) => return urls.iter().map(|_| Err(format!("client: {e}"))).collect(),
            };

            let handles: Vec<_> = urls
                .into_iter()
                .map(|url| {
                    let client = client.clone();
                    tokio::spawn(async move {
                        let response = client.get(&url).send().await.map_err(|e| e.to_string())?;
                        let status = response.status();
                        if !status.is_success() {
                            return Err(format!("http {}", status.as_u16()));
                        }
                        response.text().await.map_err(|e| e.to_string())
                    })
                })
                .collect();

            let mut out = Vec::with_capacity(handles.len());
            for handle in handles {
                out.push(handle.await.unwrap_or_else(|e| Err(e.to_string())));
            }
            out
        })
    };

    let run = move || {
        std::thread::spawn(work)
            .join()
            .unwrap_or_else(|_| (0..count).map(|_| Err("lookup thread panicked".to_string())).collect())
    };

    match tokio::runtime::Handle::try_current() {
        // Tell the scheduler this worker is about to wait, so the requests
        // other connections are making keep moving meanwhile.
        Ok(handle) if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread => {
            tokio::task::block_in_place(run)
        }
        _ => run(),
    }
}

/// One GET; see `get_many`.
pub fn get(url: &str) -> Result<String, String> {
    get_many(&[url.to_string()]).pop().unwrap_or_else(|| Err("no answer".to_string()))
}

/// The cookies a page sets, as `name=value` pairs — for a site that answers
/// its search only to a visitor it has already seen once (Baidu). Fails fast
/// in tests, like everything here.
pub fn cookies(url: &str) -> Result<Vec<String>, String> {
    if cfg!(test) {
        return Err("network is off in tests".to_string());
    }
    let url = url.to_string();
    let work = move || -> Result<Vec<String>, String> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("runtime: {e}"))?;
        runtime.block_on(async move {
            let client = reqwest::Client::builder()
                .user_agent(scrape::USER_AGENT)
                .timeout(TIMEOUT)
                .build()
                .map_err(|e| format!("client: {e}"))?;
            let response = client.get(&url).send().await.map_err(|e| e.to_string())?;
            Ok(response
                .headers()
                .get_all(reqwest::header::SET_COOKIE)
                .iter()
                .filter_map(|v| v.to_str().ok())
                .filter_map(|v| v.split(';').next())
                .map(|pair| pair.trim().to_string())
                .filter(|pair| pair.contains('='))
                .collect())
        })
    };
    let run = move || std::thread::spawn(work).join().unwrap_or_else(|_| Err("cookie thread panicked".to_string()));
    match tokio::runtime::Handle::try_current() {
        Ok(handle) if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread => {
            tokio::task::block_in_place(run)
        }
        _ => run(),
    }
}

//! Pictures, decoded once and kept as GPU textures.
//!
//! The daemon does the hard part: `thumb` returns a path to a cached file at a
//! ladder step, already downloaded, already resized, never upscaled past the
//! original. So this only has to read a local file, decode it, and hand egui a
//! texture — and decide what to keep.
//!
//! Rules learned the expensive way:
//!
//!   - The step is chosen from the DRAWN size, and while the right one loads
//!     the nearest one already in hand is shown. A better copy replaces it
//!     silently: fading between two versions of one image reads as flicker.
//!   - Newest request first. Pan across a board and the pictures now on
//!     screen matter; the ones asked for two seconds ago have scrolled away.
//!     A small fixed pool, LIFO, instead of a thread per picture.
//!   - A failure is retried, later. A thumbnail that timed out once used to
//!     stay a grey frame until the board was reopened.
//!   - Memory is bounded. Browsing the library touches hundreds of pictures;
//!     the least recently DRAWN go first, never one drawn in the last seconds.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};

use crate::client::Client;
use egui::{ColorImage, TextureHandle, TextureOptions};

/// The steps the daemon will render. It clamps to the original, so asking for
/// more than a picture has costs nothing and returns what there is.
const LADDER: [u32; 7] = [160, 320, 640, 1280, 1920, 2560, 3840];

/// Decoded texture memory to hold before evicting. RGBA8, so a 1920 step
/// picture is ~10 MB and this is roughly sixty of them.
const BUDGET: usize = 640 * 1024 * 1024;

const WORKERS: usize = 4;

/// Requests waiting beyond this are the ones scrolled past; the oldest drop.
const QUEUE_CAP: usize = 192;

pub fn step_for(drawn_px: f32) -> u32 {
    let want = drawn_px.ceil().max(1.0) as u32;
    *LADDER.iter().find(|s| **s >= want).unwrap_or(&3840)
}

/// (id, step, nearest-filtered). Nearest and linear are different uploads of
/// the same bytes, and "hard pixels" has to reach the sampler or it is a
/// setting that does nothing.
type Key = (String, u32, bool);

struct Loaded {
    key: Key,
    image: Result<ColorImage, String>,
}

struct Held {
    handle: TextureHandle,
    bytes: usize,
}

#[derive(Default)]
struct Jobs {
    queue: VecDeque<Key>,
    closed: bool,
}

struct Queue {
    jobs: Mutex<Jobs>,
    ready: Condvar,
}

pub struct Textures {
    held: HashMap<Key, Held>,
    pending: HashSet<Key>,
    /// When a failed key may be asked for again, and how often it has failed.
    failed: HashMap<Key, (f64, u32)>,
    /// When each texture was last handed out for drawing.
    used: HashMap<Key, f64>,
    bytes: usize,
    done: Receiver<Loaded>,
    queue: Option<Arc<Queue>>,
    now: f64,
    swept: f64,
}

impl Textures {
    pub fn new(client: Option<Arc<Client>>) -> Self {
        let (sink, done) = channel::<Loaded>();
        let queue = client.map(|client| {
            let queue = Arc::new(Queue { jobs: Mutex::new(Jobs::default()), ready: Condvar::new() });
            for _ in 0..WORKERS {
                let (queue, client, sink) = (queue.clone(), client.clone(), sink.clone());
                std::thread::spawn(move || worker(&queue, &client, &sink));
            }
            queue
        });
        Textures {
            held: HashMap::new(),
            pending: HashSet::new(),
            failed: HashMap::new(),
            used: HashMap::new(),
            bytes: 0,
            done,
            queue,
            now: 0.0,
            swept: 0.0,
        }
    }

    /// Take delivery of anything decoded since the last frame.
    pub fn pump(&mut self, ctx: &egui::Context) {
        self.now = ctx.input(|i| i.time);
        while let Ok(loaded) = self.done.try_recv() {
            self.pending.remove(&loaded.key);
            match loaded.image {
                Ok(image) => {
                    let bytes = image.size[0] * image.size[1] * 4;
                    let (id, step, sharp) = &loaded.key;
                    let handle = ctx.load_texture(
                        format!("{id}@{step}{}", if *sharp { "!" } else { "" }),
                        image,
                        if *sharp { TextureOptions::NEAREST } else { TextureOptions::LINEAR },
                    );
                    if let Some(old) = self.held.insert(loaded.key.clone(), Held { handle, bytes }) {
                        self.bytes -= old.bytes;
                    }
                    self.bytes += bytes;
                    self.failed.remove(&loaded.key);
                    ctx.request_repaint();
                }
                Err(_) => {
                    let attempts = self.failed.get(&loaded.key).map(|f| f.1).unwrap_or(0) + 1;
                    // 2 s, 4 s, 8 s … never more than a minute between tries.
                    let wait = 2f64.powi(attempts.min(6) as i32).min(60.0);
                    self.failed.insert(loaded.key, (self.now + wait, attempts));
                    ctx.request_repaint_after(std::time::Duration::from_secs_f64(wait));
                }
            }
        }
        if self.bytes > BUDGET && self.now - self.swept > 1.0 {
            self.sweep();
        }
    }

    /// Evict least-recently-drawn textures down to three quarters of the
    /// budget. Anything drawn in the last two seconds is on screen and stays,
    /// even if that means staying over budget.
    fn sweep(&mut self) {
        self.swept = self.now;
        let mut order: Vec<(Key, f64)> = self.held.keys().map(|k| (k.clone(), self.used.get(k).copied().unwrap_or(0.0))).collect();
        order.sort_by(|a, b| a.1.total_cmp(&b.1));
        for (key, last) in order {
            if self.bytes <= BUDGET / 4 * 3 || self.now - last < 2.0 {
                break;
            }
            if let Some(h) = self.held.remove(&key) {
                self.bytes -= h.bytes;
            }
            self.used.remove(&key);
        }
    }

    /*
     * The best texture available for this picture at this size.
     *
     * The exact step when it is decoded; otherwise the closest one that IS,
     * preferring larger (scaling down looks like the picture, scaling up looks
     * like a mistake) and the same filter — so zooming in shows the picture
     * you already have while the sharper one is fetched, rather than a hole.
     */
    pub fn get(&mut self, _ctx: &egui::Context, id: &str, step: u32, sharp: bool) -> Option<TextureHandle> {
        let key: Key = (id.to_string(), step, sharp);
        if let Some(h) = self.held.get(&key) {
            let handle = h.handle.clone();
            self.used.insert(key, self.now);
            return Some(handle);
        }
        self.request(key);

        let mut best: Option<(Key, i64)> = None;
        for candidate in LADDER {
            for filter in [sharp, !sharp] {
                let k: Key = (id.to_string(), candidate, filter);
                if !self.held.contains_key(&k) {
                    continue;
                }
                let distance = (candidate as i64 - step as i64).abs();
                let score = distance + if candidate < step { 100_000 } else { 0 } + if filter != sharp { 1 } else { 0 };
                if best.as_ref().is_none_or(|b| score < b.1) {
                    best = Some((k, score));
                }
            }
        }
        let (k, _) = best?;
        let handle = self.held.get(&k).map(|h| h.handle.clone());
        self.used.insert(k, self.now);
        handle
    }

    fn request(&mut self, key: Key) {
        if self.pending.contains(&key) {
            return;
        }
        if let Some((retry_at, _)) = self.failed.get(&key) {
            if self.now < *retry_at {
                return;
            }
        }
        let Some(queue) = self.queue.as_ref() else { return };
        let Ok(mut jobs) = queue.jobs.lock() else { return };
        if jobs.queue.len() >= QUEUE_CAP {
            if let Some(stale) = jobs.queue.pop_front() {
                self.pending.remove(&stale);
            }
        }
        jobs.queue.push_back(key.clone());
        self.pending.insert(key);
        queue.ready.notify_one();
    }
}

impl Drop for Textures {
    /// A reconnect builds a new cache; the old workers must not wait forever.
    fn drop(&mut self) {
        if let Some(queue) = self.queue.as_ref() {
            if let Ok(mut jobs) = queue.jobs.lock() {
                jobs.closed = true;
            }
            queue.ready.notify_all();
        }
    }
}

fn worker(queue: &Queue, client: &Client, sink: &Sender<Loaded>) {
    loop {
        let key = {
            let Ok(mut jobs) = queue.jobs.lock() else { return };
            loop {
                if jobs.closed {
                    return;
                }
                // Newest first: what was asked for last is what is on screen.
                if let Some(k) = jobs.queue.pop_back() {
                    break k;
                }
                jobs = match queue.ready.wait(jobs) {
                    Ok(j) => j,
                    Err(_) => return,
                };
            }
        };
        let image = load(client, &key.0, key.1);
        if sink.send(Loaded { key, image }).is_err() {
            return;
        }
    }
}

fn load(client: &Client, id: &str, step: u32) -> Result<ColorImage, String> {
    let payload = client.call("thumb", serde_json::json!({ "id": id, "size": step }))?;
    let path = payload.get("path").and_then(|v| v.as_str()).ok_or("thumb answered without a path")?;
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let decoded = image::load_from_memory(&bytes).map_err(|e| e.to_string())?;
    let rgba = decoded.to_rgba8();
    let size = [rgba.width() as usize, rgba.height() as usize];
    Ok(ColorImage::from_rgba_unmultiplied(size, rgba.as_raw()))
}

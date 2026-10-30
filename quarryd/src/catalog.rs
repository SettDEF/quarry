//! The catalog and the query engine.
//!
//! Phase 2 backend: a fixture in memory. The shape of what it answers — a count
//! and one ratio per result, with records fetched by page — is the shape the
//! SQLite catalog answers in Phase 5, so the client never learns the difference.

use crate::db::Db;
use crate::protocol::{Item, QueryParams};
use crate::query::{self, Sort};

pub struct Catalog {
    /*
     * Rows in memory — ONLY when there is no database.
     *
     * With one, nothing loads the catalogue. A query compiles to SQL and comes
     * back as an id, a ratio and a hash per match; records are read a page at a
     * time. Holding every row was the largest thing this process did, and it
     * grew with the crawl: the query engine that needed it now runs in SQLite,
     * next to the index. This vector is the fixture path that `from_fixture`
     * gives the tests.
     */
    items: Vec<Item>,
    /*
     * WHETHER ADULT ROWS ARE ANSWERABLE AT ALL.
     *
     * A field rather than a `Prefs::load()` inside `rank`, for two reasons. It is
     * the query hot path, which has a p95 budget of 10 ms, and a disk read per
     * query is not free. And it makes the rule testable without a prefs file on
     * disk — the lesson a sibling project learned when four tests shared one
     * environment variable and two of them failed.
     *
     * Set from prefs when the daemon starts and whenever they are saved.
     */
    show_adult: bool,
    /// How many rows the last query collapsed as duplicates — so an item
    /// count that shrank can say why.
    last_duplicates: usize,
    /// Why the mirror of the user's own data is not being written — see
    /// `backup_user_data`. `None` while it is being written fine.
    backup_error: std::cell::RefCell<Option<String>>,
    /// The store of record. Without it a crawl lived only as long as the
    /// process, which is how 2,620 rows became 137 again on a restart.
    db: Option<Db>,
    /*
     * Rows that cannot produce a picture.
     *
     * A source can hand back a row whose image 404s, or whose host refuses us
     * even server-side. Left in the results it is an empty cell that never
     * fills — the gallery equivalent of a broken link — so once fetching its
     * picture has actually failed, it stops being returned. This is a fact
     * learned at runtime, not a guess made at parse time: `keep_usable` already
     * drops rows that are malformed, and everything here looked fine.
     */
    broken: std::collections::HashSet<String>,
    /*
     * ROWS THE NO-NETWORK SWEEP HAS ALREADY TRIED AND CANNOT HASH.
     *
     * The backlog window is read in the same order every round, so a row with
     * no cached thumbnail came back every time and was tried again. Measured
     * over ten rounds of 200: hashed 37, 26, 23, 17, 14, 13, 10, 11, 8, 7 while
     * failures climbed 163 → 193. The sweep converged on exactly the rows it
     * could never do and ground to a halt with about 32,000 hashable rows still
     * waiting behind them — which is why "more like this" was unavailable on
     * 97% of the catalogue.
     *
     * In memory only, and deliberately. A thumbnail appears the moment you look
     * at one of these, so the answer changes; a restart is the right time to
     * ask again, and nothing about this is worth a column.
     */
    hash_skip: std::collections::HashSet<String>,
    /// The last query's result, as ids in order. A multiplied query repeats an
    /// id rather than a record, and a page turns ids back into rows.
    result: Vec<String>,
    /*
     * The ratios of that result, in the same order.
     *
     * Kept rather than recomputed because the client reads them a slice at a
     * time: one ratio per row of a 752k catalogue is a 10 MB JSON frame and
     * QV4 segfaults parsing an array that long (see PROTOCOL.md `ratios`), so
     * the wall's geometry arrives in 100k slices and each slice has to be a
     * copy out of this, not another rank() over the whole catalogue.
     *
     * 8 bytes a row — 6 MB for the largest catalogue measured here, against
     * the 875 ms the query itself costs.
     */
    result_ratios: Vec<f64>,
    /// How long the result was before `repeat` multiplied it — what tells a
    /// page which copy of a repeated fixture a position falls in.
    result_unique: usize,
    result_id: u64,
    /*
     * WHAT EACH CRAWLED PAGE TOUCHED, SO `extend` LOOKS AT THAT AND NOTHING ELSE.
     *
     * Re-ranking the whole query per page cost 48 ms on a 40k-row home feed
     * under the catalogue lock, four times a second while a search runs. A row
     * can also START matching without being new — a known row learns the words
     * that fetched it (see `add`) — so a rowid watermark would miss it; this log
     * holds new and re-tagged ids alike. `touched_base` is how many were
     * dropped from its front; a result whose mark falls before it re-ranks.
     */
    touched: Vec<String>,
    touched_base: usize,
    result_mark: usize,
    /// The open result's ids as a set, for `extend` to skip what it holds.
    result_held: std::collections::HashSet<String>,
    /*
     * THE RESULTS A CLIENT MAY STILL BE PAGING THROUGH.
     *
     * There is ONE current result for the whole daemon, and every connection
     * shares it — so a second client running a query replaces the first
     * client's result out from under it. Its in-flight `items` calls then come
     * back "stale queryId", the cells that asked for those rows are already
     * marked pending, and the grid keeps a hole in it where the page should be.
     *
     * That is not hypothetical: a headless test instance, a board window, or
     * `tools/proto.sh query` is enough to punch holes in a gallery somebody is
     * reading. Holding the last few results costs a vector of ids each and
     * makes `queryId` mean what the protocol says it means — a handle to the
     * result you asked for, not a guess about what the daemon is doing now.
     */
    prior: std::collections::VecDeque<(u64, Vec<String>, usize)>,
    pub queries: u64,
}

/// How many superseded results stay pageable. Eight is two windows plus a board
/// and room to spare; a result is ids, not records.
const PRIOR_RESULTS: usize = 8;

/*
 * THE SAME PICTURE, POSTED AGAIN.
 *
 * Equal hashes were already one row. What got through — and what made the wall
 * feel like it kept loading the same pictures — were the copies a few bits
 * apart: the same art re-posted to five boards, each re-encoded, resized or
 * lightly cropped, so its hash moved by one to six bits. Measured on the live
 * catalogue: ~77 such pairs in the first 2,000 rows while only a third of them
 * were hashed at all.
 *
 * Comparing every row with every other is 10^10 pairs. Multi-index hashing
 * makes it a lookup: cut the 64 bits into six bands; two hashes within five
 * bits of each other must agree EXACTLY on at least one band (six bands, at
 * most five differing bits — pigeonhole). So each row only meets the kept rows
 * that share a band with it, a few dozen, not the catalogue.
 *
 * Two guards against merging things that merely resemble each other:
 *   - the shape must match within 4%: a re-encode keeps it, a different
 *     picture that happens to hash close usually does not;
 *   - icon sources are left alone: flat glyphs on a plain ground all hash
 *     alike, and a set of different icons is exactly what someone wants there.
 *
 * Order is preserved, so the copy that survives is the one ranked first.
 */
pub const NEAR_DUPLICATE_BITS: u32 = 5;

fn icon_sources() -> &'static std::collections::HashSet<String> {
    static SET: std::sync::OnceLock<std::collections::HashSet<String>> = std::sync::OnceLock::new();
    SET.get_or_init(|| {
        let mut set: std::collections::HashSet<String> = crate::sources::all()
            .iter()
            .filter(|source| source.category() == "icons")
            .map(|source| source.id().to_string())
            .collect();
        set.insert("iconify".to_string());
        set
    })
}

pub fn collapse_near_duplicates(rows: &mut Vec<(String, f64, String)>, max_bits: u32) -> usize {
    const BANDS: [(u32, u32); 6] = [(0, 11), (11, 11), (22, 11), (33, 11), (44, 10), (54, 10)];
    let icons = icon_sources();
    let mut buckets: Vec<std::collections::HashMap<u64, Vec<(u64, f64)>>> =
        (0..BANDS.len()).map(|_| std::collections::HashMap::new()).collect();
    let mut dropped = 0usize;
    rows.retain(|(id, ratio, phash)| {
        let Ok(hash) = u64::from_str_radix(phash, 16) else {
            return true;
        };
        let source = id.split(':').next().unwrap_or("");
        if icons.contains(source) {
            return true;
        }
        /*
         * A FIXED ARRAY, NOT A Vec.
         *
         * This allocated a six-element vector FOR EVERY ROW — 165,000 heap
         * allocations and frees to compute six numbers, on the one path that
         * runs on every filter change. The band count is a constant six lines
         * above; nothing here was ever dynamic.
         */
        let mut keys = [0u64; BANDS.len()];
        for (i, (shift, width)) in BANDS.iter().enumerate() {
            keys[i] = ((i as u64) << 56) | ((hash >> shift) & ((1u64 << width) - 1));
        }
        for (band, key) in keys.iter().enumerate() {
            if let Some(kept) = buckets[band].get(key) {
                // The newest few hundred in a bucket: a flood of one flat
                // hash must not turn this back into pairwise work.
                let copy = kept.iter().rev().take(512).any(|(other, other_ratio)| {
                    (hash ^ other).count_ones() <= max_bits
                        && (ratio - other_ratio).abs() <= 0.04 * ratio.max(*other_ratio)
                });
                if copy {
                    dropped += 1;
                    return false;
                }
            }
        }
        for (band, key) in keys.into_iter().enumerate() {
            buckets[band].entry(key).or_default().push((hash, *ratio));
        }
        true
    });
    dropped
}

#[cfg(test)]
mod near_duplicate_tests {
    use super::collapse_near_duplicates;

    fn row(id: &str, ratio: f64, hash: u64) -> (String, f64, String) {
        (id.to_string(), ratio, format!("{hash:016x}"))
    }

    #[test]
    fn a_repost_a_few_bits_away_is_one_picture() {
        let base = 0x9f3a_17c4_52e1_08bdu64;
        let mut rows = vec![
            row("danbooru:1", 1.5, base),
            row("safebooru:9", 1.51, base ^ 0b1011),       // 3 bits
            row("konachan:4", 1.5, base ^ (1 << 40 | 1 << 63)), // 2 bits
            row("wallhaven:x", 1.5, !base),                // unrelated
        ];
        let dropped = collapse_near_duplicates(&mut rows, 5);
        assert_eq!(dropped, 2);
        let ids: Vec<&str> = rows.iter().map(|r| r.0.as_str()).collect();
        assert_eq!(ids, vec!["danbooru:1", "wallhaven:x"], "the first-ranked copy survives, order kept");
    }

    #[test]
    fn close_hashes_with_a_different_shape_are_different_pictures() {
        let base = 0x0123_4567_89ab_cdefu64;
        let mut rows = vec![row("a:1", 1.0, base), row("b:1", 1.78, base ^ 1)];
        assert_eq!(collapse_near_duplicates(&mut rows, 5), 0);
    }

    #[test]
    fn icons_and_unhashed_rows_are_never_merged() {
        let base = 0x00ff_00ff_00ff_00ffu64;
        let mut rows = vec![
            row("iconify:mdi-home", 1.0, base),
            row("iconify:mdi-house", 1.0, base ^ 1),
            ("x:1".to_string(), 1.0, String::new()),
            ("x:2".to_string(), 1.0, String::new()),
        ];
        assert_eq!(collapse_near_duplicates(&mut rows, 5), 0);
        assert_eq!(rows.len(), 4);
    }

    #[test]
    fn six_bits_apart_is_past_the_line() {
        let base = 0xdead_beef_cafe_f00du64;
        let mut rows = vec![row("a:1", 1.0, base), row("b:1", 1.0, base ^ 0b11_1111)];
        assert_eq!(collapse_near_duplicates(&mut rows, 5), 0);
    }
}

pub struct QueryResult {
    pub query_id: u64,
    pub count: usize,
    pub ratios: Vec<f64>,
    /// Keys the parser did not understand. Surfaced so the bar can say so
    /// instead of quietly returning everything.
    pub unknown: Vec<String>,
    pub sort: &'static str,
    /// How many rows this query collapsed as the same picture. A count that
    /// came out smaller than expected should be able to say why.
    pub duplicates: usize,
}

impl Catalog {
    /// In-memory only, for tests and for a daemon told not to persist.
    #[allow(dead_code)]
    pub fn from_fixture(text: &str) -> Result<Self, String> {
        #[derive(serde::Deserialize)]
        struct Fixture {
            items: Vec<Item>,
        }

        let fixture: Fixture = serde_json::from_str(text)
            .map_err(|e| format!("fixture does not match ITEM.md: {e}"))?;

        if fixture.items.is_empty() {
            return Err("fixture contains no items".into());
        }

        Ok(Catalog {
            show_adult: crate::prefs::Prefs::load().show_adult,
            items: fixture.items,
            last_duplicates: 0,
            backup_error: std::cell::RefCell::new(None),
            db: None,
            broken: std::collections::HashSet::new(),
            hash_skip: std::collections::HashSet::new(),
            result: Vec::new(),
            result_ratios: Vec::new(),
            prior: std::collections::VecDeque::new(),
            result_unique: 0,
            result_id: 0,
            touched: Vec::new(),
            touched_base: 0,
            result_mark: 0,
            result_held: std::collections::HashSet::new(),
            queries: 0,
        })
    }

    /// Open the catalogue on disk, seeding it from the fixture the first time.
    ///
    /// The fixture stops being data and becomes a starting point: once the
    /// database has rows of its own, it is never consulted again.
    /// `fixture` is a thunk, not a string: it is read ONLY on a first run.
    /// The fixture seeds an empty catalogue and is never consulted again, so
    /// making it a startup dependency meant a daemon with a full database
    /// still died at boot if it could not find the file (a relative default
    /// path, so: launched from anywhere but the source tree).
    pub fn open(
        db_path: &std::path::Path,
        fixture: impl FnOnce() -> Result<String, String>,
    ) -> Result<Self, String> {
        /*
         * A WRECKED FILE IS QUARANTINED, NOT SERVED.
         *
         * A catalogue whose header has gone answers "file is not a database"
         * to everything, and the daemon used to carry on: zero rows for ever
         * while the crawler wrote into nothing and the app showed an empty
         * library. It is moved aside — never deleted, so it can still be
         * carved — and a new one takes its place.
         */
        let mut db = match Db::open(db_path) {
            Ok(db) => db,
            Err(e) if e.starts_with("corrupt:") => {
                let stamp = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                let aside = db_path.with_extension(format!("db.corrupt-{stamp}"));
                eprintln!("[quarryd] the catalogue is unreadable ({e}) — moving it to {} and starting a new one", aside.display());
                let _ = std::fs::rename(db_path, &aside);
                for tail in ["-wal", "-shm"] {
                    let mut side = db_path.as_os_str().to_os_string();
                    side.push(tail);
                    let _ = std::fs::remove_file(std::path::PathBuf::from(side));
                }
                Db::open(db_path)?
            }
            Err(e) => return Err(e),
        };

        /*
         * WHAT YOU CHOSE COMES BACK.
         *
         * Collections, boards and slots are exported beside the database on
         * every change. Putting them back is INSERT OR IGNORE, so it is
         * idempotent and can never undo something newer — on a healthy
         * database it does nothing at all.
         */
        let backup = Self::user_data_path(db_path);
        if let Ok(text) = std::fs::read_to_string(&backup) {
            match db.import_user_data(&text) {
                Ok(n) if n > 0 => eprintln!("[quarryd] put back {n} rows of your own — collections, boards, slots"),
                Err(e) => eprintln!("[quarryd] could not read {}: {e}", backup.display()),
                _ => {}
            }
        }
        if let Ok(text) = db.export_user_data() {
            let _ = std::fs::write(&backup, text);
        }

        /*
         * A ROW WRITTEN OFF A DAY AGO GETS ANOTHER CHANCE.
         *
         * `mark_broken` exists for files that are not images and hosts that
         * will never serve them — but it also catches every transient failure,
         * and those rows are then dropped from each future crawl and denied by
         * every lookup. A live feed ends up full of cards that can never fill.
         * Anything written off more than a day ago is forgiven on the way up;
         * if it is really broken, the next fetch says so again at no cost.
         */
        match db.forgive_stale_fetch_failures(24 * 60 * 60) {
            Ok(n) if n > 0 => eprintln!("[quarryd] {n} rows written off more than a day ago get another go"),
            Err(e) => eprintln!("[quarryd] could not clear the old fetch failures: {e}"),
            _ => {}
        }

        let mut seeded = 0;

        // Whether to seed is a count, not a read of the catalogue.
        if db.count() == 0 {
            #[derive(serde::Deserialize)]
            struct Fixture {
                items: Vec<Item>,
            }
            // A malformed fixture used to leave the catalogue silently empty
            // — no error, no seed, just a daemon that answers 0 items forever.
            // A bad fixture on a first run is exactly the misconfiguration
            // this needs to say out loud, not swallow.
            let text = fixture()?;
            let parsed: Fixture = serde_json::from_str(&text)
                .map_err(|e| format!("fixture does not match ITEM.md: {e}"))?;
            seeded = db.insert_many(&parsed.items)?;
        }
        if seeded > 0 {
            eprintln!("[quarryd] seeded {seeded} rows from fixture");
        }

        let broken = db.hidden_ids()?.into_iter().collect();

        Ok(Catalog {
            show_adult: crate::prefs::Prefs::load().show_adult,
            items: Vec::new(),
            last_duplicates: 0,
            backup_error: std::cell::RefCell::new(None),
            db: Some(db),
            broken,
            hash_skip: std::collections::HashSet::new(),
            result: Vec::new(),
            result_ratios: Vec::new(),
            prior: std::collections::VecDeque::new(),
            result_unique: 0,
            result_id: 0,
            touched: Vec::new(),
            touched_base: 0,
            result_mark: 0,
            result_held: std::collections::HashSet::new(),
            queries: 0,
        })
    }

    pub fn db_path(&self) -> String {
        self.db.as_ref().map(|d| d.path.display().to_string()).unwrap_or_default()
    }

    /// What the database holds, as opposed to what this process has loaded —
    /// the two differing is the first sign of a write that did not land.
    // ── slots ───────────────────────────────────────────────────────────────

    pub fn slot_set(&self, target: &str, item: &str, path: &str, applied: bool) {
        if let Some(db) = self.db.as_ref() {
            match db.slot_set(target, item, path, applied) {
                Err(e) => eprintln!("[quarryd] slot: {e}"),
                Ok(()) => self.backup_user_data(),
            }
        }
    }

    pub fn slots(&self) -> Vec<serde_json::Value> {
        self.db.as_ref().map(|db| db.slots()).unwrap_or_default()
    }

    pub fn slots_of(&self, item: &str) -> Vec<String> {
        self.db.as_ref().map(|db| db.slots_of(item)).unwrap_or_default()
    }

    pub fn slot_items(&self) -> std::collections::HashSet<String> {
        self.db.as_ref().map(|db| db.slot_items().into_iter().collect()).unwrap_or_default()
    }

    // ── boards ──────────────────────────────────────────────────────────────
    //
    // Thin, on purpose: a board is geometry the UI owns, and the daemon's job
    // is to remember it accurately rather than to have opinions about it.

    pub fn boards(&self) -> Vec<serde_json::Value> {
        self.db.as_ref().map(|db| db.boards()).unwrap_or_default()
    }

    pub fn board_items(&self, board: &str) -> Vec<serde_json::Value> {
        self.db.as_ref().map(|db| db.board_items(board)).unwrap_or_default()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn board_place(
        &self,
        board: &str,
        item: &str,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        angle: f64,
        hflip: bool,
        vflip: bool,
        z: i64,
        sharp: bool,
        container: i64,
    ) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.board_place(board, item, x, y, w, h, angle, hflip, vflip, z, sharp, container),
                // Same answer collections give: a board that lasts until the
                // process ends is worse than being told there is nowhere to keep it.
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    pub fn board_containers(&self, board: &str) -> Vec<serde_json::Value> {
        self.db.as_ref().map(|db| db.board_containers(board)).unwrap_or_default()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn board_container_set(
        &self,
        board: &str,
        id: i64,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        label: &str,
        tint: i64,
    ) -> Result<i64, String> {
        match self.db.as_ref() {
            Some(db) => db.board_container_set(board, id, x, y, w, h, label, tint),
            None => Err("no catalogue on disk".into()),
        }
    }

    pub fn board_container_delete(&self, board: &str, id: i64) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.board_container_delete(board, id),
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    pub fn board_remove(&self, board: &str, item: &str) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.board_remove(board, item),
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    pub fn board_view(&self, board: &str, x: f64, y: f64, z: f64) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.board_view(board, x, y, z),
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    pub fn board_rename(&self, from: &str, to: &str) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.board_rename(from, to),
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    pub fn board_delete(&self, board: &str) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.board_delete(board),
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    // ── collections ─────────────────────────────────────────────────────────

    pub fn collections(&self) -> Vec<serde_json::Value> {
        self.db
            .as_ref()
            .map(|db| {
                db.collections()
                    .into_iter()
                    .map(|(name, count)| serde_json::json!({ "name": name, "items": count }))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn collection_set(&self, name: &str, item: &str, member: bool) -> Result<(), String> {
        // A choice of yours changed: refresh the mirror beside the database.
        let done = match self.db.as_ref() {
                Some(db) => db.collection_set(name, item, member),
                // Without a database a collection would last until the process
                // ended, which is worse than saying so.
                None => Err("no catalogue on disk".into()),
            };
        if done.is_ok() {
            self.backup_user_data();
        }
        done
    }

    pub fn collections_of(&self, item: &str) -> Vec<String> {
        self.db.as_ref().map(|db| db.collections_of(item)).unwrap_or_default()
    }

    /// Restrict a result to one collection's members.
    ///
    /// Applied after the query rather than inside it: a collection is a set of
    /// ids, and intersecting a result with a set is both simpler and faster than
    /// teaching every predicate about membership.
    pub fn collection_members(&self, name: &str) -> std::collections::HashSet<String> {
        self.db
            .as_ref()
            .map(|db| db.collection_members(name).into_iter().collect())
            .unwrap_or_default()
    }

    pub fn checkpoint(&self) {
        if let Some(db) = self.db.as_ref() {
            db.checkpoint();
        }
    }

    pub fn rows_on_disk(&self) -> usize {
        self.db.as_ref().map(|d| d.count()).unwrap_or(0)
    }

    /*
     * START OVER: every crawled row out of the database and out of memory.
     *
     * The in-memory copies have to go in the same breath as the rows — this
     * process holds `items` and whatever results clients are paging, and
     * leaving those behind would draw a catalogue that no longer exists and
     * hand out ids the database cannot answer for.
     */
    pub fn empty_catalogue(&mut self) -> Result<u64, String> {
        let removed = match self.db.as_ref() {
            Some(db) => db.empty_catalogue()?,
            None => self.items.len() as u64,
        };
        self.items.clear();
        self.broken.clear();
        self.result.clear();
        self.result_ratios.clear();
        self.prior.clear();
        self.result_unique = 0;
        Ok(removed)
    }

    pub fn db_bytes(&self) -> u64 {
        self.db.as_ref().map(|d| d.size_bytes()).unwrap_or(0)
    }

    /// Follow the saved preference. Called at startup and whenever prefs change,
    /// so a switch flipped in settings applies to the very next query without a
    /// restart and without re-crawling anything.
    pub fn set_show_adult(&mut self, on: bool) {
        self.show_adult = on;
    }

    pub fn show_adult(&self) -> bool {
        self.show_adult
    }

    pub fn persistent(&self) -> bool {
        self.db.is_some()
    }

    pub fn len(&self) -> usize {
        match self.db.as_ref() {
            Some(db) => db.visible_count(),
            None => self.items.len(),
        }
    }

    /// Run a query without keeping its result.
    ///
    /// `query` stores ONE result for the whole daemon, which every client
    /// shares: a second window asking a question would silently invalidate the
    /// paging of the first. `find` answers from the same ranking and holds
    /// nothing, so the board's library can search while quarry is open.
    pub fn find(&self, p: &QueryParams, offset: usize, limit: usize) -> (usize, Vec<Item>) {
        let (base, _, _) = self.rank(p);
        let count = base.len();
        let end = (offset + limit).min(count);
        if offset >= end {
            return (count, Vec::new());
        }
        let ids: Vec<String> = base[offset..end].iter().map(|(id, _, _)| id.clone()).collect();
        (count, self.records_for(&ids))
    }

    /// The ranked, deduplicated rows for a query: (id, ratio, phash).
    fn rank(&self, p: &QueryParams) -> (Vec<(String, f64, String)>, usize, query::Query) {
        self.rank_within(p, None)
    }

    /// `rank`, limited to `within` when given: the same query, asked of a few rows.
    fn rank_within(
        &self,
        p: &QueryParams,
        within: Option<&[String]>,
    ) -> (Vec<(String, f64, String)>, usize, query::Query) {
        /*
         * The chips and the bar are one query.
         *
         * A UI chip is just a predicate the user did not have to type, so the
         * structured fields are folded into the same DSL string rather than
         * filtered separately — one code path, and "kind:avatar" typed by hand
         * behaves identically to the avatar chip.
         */
        let mut text = p.q.clone();
        for (key, value) in [("kind", &p.kind), ("source", &p.source), ("family", &p.family)] {
            if !value.is_empty() {
                text.push_str(&format!(" {key}:{value}"));
            }
        }

        let mut parsed = query::parse(&text);

        /*
         * THE ADULT SWITCH, ENFORCED WHERE EVERY ANSWER PASSES.
         *
         * `rank` is the one road `query`, `find`, `items` and `similar` all take, so
         * a clause added here cannot be gone round. It is pushed as an ORDINARY
         * `nsfw:false` — the same shape `-nsfw` parses to — which means the SQL
         * compiler and the in-memory matcher both already honour it and neither
         * needed a second implementation of the same idea.
         *
         * Appended AFTER the user's text on purpose: clauses are ANDed, so a
         * `nsfw:true` typed into the bar cannot cancel it. It narrows and never
         * widens.
         *
         * This used to live in the app, which appended `-nsfw` to the query string
         * when the switch went off. See PROTOCOL.md for why that was not a switch.
         */
        if !self.show_adult {
            parsed.clauses.push(query::Clause {
                term: query::Term::Flag { key: "nsfw".into(), value: false },
                negated: false,
            });
        }

        // `collection:name` narrows to a saved set; `used:true` to what is in a
        // slot somewhere. Neither is a column on `item`, so both are applied to
        // the rows the query returns rather than inside it.
        let members = parsed.collection.as_ref().map(|name| self.collection_members(name));
        let in_use = if parsed.used { Some(self.slot_items()) } else { None };

        let rows_start = std::time::Instant::now();
        let mut base: Vec<(String, f64, String)> = match self.db.as_ref() {
            Some(db) => {
                let compiled = db.compile_within(&parsed, within);
                if std::env::var_os("QUARRY_TIMING").is_some() {
                    eprintln!("[timing]   sql: {}", compiled.sql);
                }
                match db.rows(&compiled) {
                    Ok(rows) => {
                        let kept: Vec<crate::db::Row> = rows
                        .into_iter()
                        .filter(|row| {
                            if let Some(members) = &members {
                                if !members.contains(&row.id) {
                                    return false;
                                }
                            }
                            if let Some(used) = &in_use {
                                if !used.contains(&row.id) {
                                    return false;
                                }
                            }
                            // Colour is arithmetic over three bytes, which SQL
                            // would need a function for; it is also the rarest
                            // predicate, so it stays here.
                            match parsed.color {
                                Some(target) => crate::util::parse_hex(&row.dominant)
                                    .is_some_and(|rgb| {
                                        crate::util::color_distance(rgb, target)
                                            <= parsed.color_distance
                                    }),
                                None => true,
                            }
                        })
                        .collect();
                        let kept = if parsed.sort == Sort::Relevance {
                            interleave_sources(kept, |row| row.source.as_str(), &crate::prefs::Prefs::load())
                        } else {
                            kept
                        };
                        kept.into_iter()
                            .map(|row| (row.id, if row.ratio > 0.0 { row.ratio } else { 1.0 }, row.phash))
                            .collect()
                    }
                    Err(e) => {
                        // A query that cannot run must say so rather than
                        // answer "0 items", which reads as an empty catalogue.
                        eprintln!("[quarryd] query failed: {e}");
                        Vec::new()
                    }
                }
            }
            None => {
                let mut rows: Vec<&Item> = self
                    .items
                    .iter()
                    .filter(|item| {
                        if let Some(members) = &members {
                            if !members.contains(&item.id) {
                                return false;
                            }
                        }
                        if let Some(used) = &in_use {
                            if !used.contains(&item.id) {
                                return false;
                            }
                        }
                        if within.is_some_and(|ids| !ids.contains(&item.id)) {
                            return false;
                        }
                        !self.broken.contains(&item.id) && query::matches(item, &parsed)
                    })
                    .collect();
                query::sort_items(&mut rows, parsed.sort, parsed.seed);
                if parsed.sort == Sort::Relevance {
                    rows = interleave_sources(rows, |item| item.source.as_str(), &crate::prefs::Prefs::load());
                }
                rows.into_iter()
                    .map(|i| (i.id.clone(), ratio_of(i), i.phash.clone()))
                    .collect()
            }
        };

        /*
         * ONE ROW PER PICTURE.
         *
         * Deduping by id or by URL catches nothing here — the copies are
         * genuinely different rows, posted to different boards, with different
         * ids and different files. What they share is what they LOOK like, and
         * a perceptual hash survives the re-encode each board does, so equal
         * hashes are the common case rather than near-equal ones. That makes
         * this a set membership test rather than a distance comparison: O(n),
         * no pairwise work, nothing to tune.
         *
         * Rows with no hash yet are always kept — a picture nobody has
         * thumbnailed must not vanish because it cannot prove it is unique.
         * Sorted order is preserved, so the copy that survives is the one the
         * ranking already preferred.
         */
        let rows_at = rows_start.elapsed();
        let mut duplicates = 0usize;
        let dedupe_at = std::time::Instant::now();
        if p.dedupe {
            /*
             * THE HASHES, NOT COPIES OF THEIR TEXT.
             *
             * A `HashSet<String>` meant cloning every row's phash to test it —
             * one allocation per row, thrown away immediately. A phash IS a
             * 64-bit number written in hex, so the set holds the number: no
             * allocation, a cheaper hash, and the same answer. A hash that
             * does not parse keeps its row, exactly as an empty one does.
             */
            let mut seen: std::collections::HashSet<u64> = std::collections::HashSet::new();
            base.retain(|(_, _, phash)| {
                if phash.is_empty() {
                    return true;
                }
                let Ok(bits) = u64::from_str_radix(phash, 16) else {
                    return true;
                };
                let fresh = seen.insert(bits);
                if !fresh {
                    duplicates += 1;
                }
                fresh
            });
            let exact_at = dedupe_at.elapsed();
            duplicates += collapse_near_duplicates(&mut base, NEAR_DUPLICATE_BITS);
            if std::env::var_os("QUARRY_TIMING").is_some() {
                eprintln!(
                    "[timing]   rank: rows+filter {:?}, exact dedupe {:?}, near dedupe {:?}",
                    rows_at,
                    exact_at,
                    dedupe_at.elapsed() - exact_at
                );
            }
        }
        (base, duplicates, parsed)
    }

    pub fn query(&mut self, p: &QueryParams) -> QueryResult {
        let repeat = p.repeat.clamp(1, 10_000);
        let (base, duplicates, parsed) = self.rank(p);
        self.last_duplicates = duplicates;


        let mut result = Vec::with_capacity(base.len() * repeat);
        let mut ratios = Vec::with_capacity(base.len() * repeat);
        for _ in 0..repeat {
            for (id, ratio, _) in &base {
                result.push(id.clone());
                ratios.push(*ratio);
            }
        }

        self.remember_result();
        self.result_id += 1;
        self.queries += 1;
        let count = result.len();
        self.result_unique = base.len();
        self.result_held = base.iter().map(|(id, _, _)| id.clone()).collect();
        self.result = result;
        self.result_ratios = ratios.clone();
        self.result_mark = self.touched_base + self.touched.len();

        QueryResult {
            query_id: self.result_id,
            count,
            duplicates,
            ratios,
            unknown: parsed.unknown,
            sort: query::sort_name(parsed.sort),
        }
    }

    /*
     * GROW THE OPEN RESULT INSTEAD OF REPLACING IT.
     *
     * An endless feed crawls while you read it, and the client used to answer
     * "the crawl added rows" by running the query again. That builds a new
     * result, so the row at offset 900 is no longer the picture you were
     * looking at — the whole wall changes contents under the scroll.
     *
     * Extending appends only what the same query now matches and the result
     * does not already hold. Every offset a client already has keeps its row,
     * the count grows at the end, and nothing on screen moves. `None` when the
     * id is stale: the caller has an old result and should query instead.
     */
    /// Rows added or re-tagged so far; grows when a crawl gives `extend` work.
    pub fn changes(&self) -> usize {
        self.touched_base + self.touched.len()
    }

    pub fn extend(&mut self, p: &QueryParams, query_id: u64) -> Option<(usize, Vec<f64>)> {
        if query_id == 0 || query_id != self.result_id {
            return None;
        }
        let end = self.touched_base + self.touched.len();
        let (base, _duplicates, _parsed) = if self.result_mark >= self.touched_base {
            let since = &self.touched[self.result_mark - self.touched_base..];
            if since.is_empty() {
                return Some((self.result.len(), Vec::new()));
            }
            self.rank_within(p, Some(since))
        } else {
            self.rank(p)
        };
        self.result_mark = end;
        let mut ratios = Vec::new();
        for (id, ratio, _) in base {
            if !self.result_held.insert(id.clone()) {
                continue;
            }
            self.result.push(id);
            self.result_ratios.push(ratio);
            ratios.push(ratio);
        }
        // `result_unique` counts the result BEFORE the perf multiplier, so it
        // grows by what was appended — not by the length of the whole list,
        // which would tell `page()` a repeated result was not repeated and
        // hand every copy the same id.
        self.result_unique += ratios.len();
        Some((self.result.len(), ratios))
    }

    /*
     * One slice of the open result's geometry.
     *
     * `None` for a stale id: the wall it described is gone, and stitching a
     * slice of the new result into the old one puts a picture's shape under a
     * different picture — which reads as tiles at random sizes rather than as
     * an error, so it must not be allowed to happen quietly.
     */
    pub fn ratios_slice(
        &self,
        query_id: u64,
        from: usize,
        count: usize,
    ) -> Option<(Vec<f64>, usize)> {
        if query_id == 0 || query_id != self.result_id {
            return None;
        }
        let total = self.result_ratios.len();
        let start = from.min(total);
        let end = start.saturating_add(count).min(total);
        Some((self.result_ratios[start..end].to_vec(), total))
    }

    /*
     * DELETE EVERY ROW THIS QUERY MATCHES.
     *
     * Returns the ids that went, so the caller can remove the files cached for
     * them — the catalogue knows which rows matched, and only the server knows
     * where thumbnails live.
     *
     * THE ADULT GATE IS LIFTED FOR THE MATCH. `rank` appends `nsfw:false` to
     * every query while the switch is off, which is exactly right for reading
     * and exactly wrong here: `purge` with `nsfw:true` would match nothing, and
     * would report "0 rows deleted" over a catalogue that is 80% adult. The one
     * request that has to see the hidden rows is the one asking to delete them.
     * Restored immediately afterwards, including on the error path, because a
     * gate left open by a failed delete is the switch silently turning itself
     * back on.
     *
     * An empty query is refused by the caller, not here — see PROTOCOL.md.
     */
    /// Per-source counts for the delete picker: (source, rows, adult rows).
    pub fn stored_counts(&self) -> Vec<(String, usize, usize)> {
        self.db.as_ref().map(|d| d.stored_counts()).unwrap_or_default()
    }

    /// The ids a purge WOULD delete, without deleting them. Same match as
    /// `purge`, gate lifted the same way, so the count the panel shows cannot
    /// drift from what the button then removes.
    pub fn purge_preview(&mut self, p: &QueryParams) -> Vec<String> {
        let was_showing = self.show_adult;
        self.show_adult = true;
        let (base, _d, _p) = self.rank(&Self::purge_params(p));
        self.show_adult = was_showing;
        base.into_iter().map(|(id, _, _)| id).collect()
    }

    /*
     * A PURGE MATCHES EVERY ROW, NOT THE DEDUPLICATED VIEW OF THEM.
     *
     * `rank` collapses copies of one picture — equal hashes, and near hashes
     * when the shape matches — because a WALL should not show the same picture
     * eight times. A delete is not a wall. The collapsed rows are still rows on
     * the disk, and matching the deduplicated list leaves every one of them
     * behind.
     *
     * Measured before this existed: purging `nsfw:true` over a 46,344-row
     * catalogue deleted 46,327 and left 17 — exactly the duplicates — so the
     * switch said "adult content removed" and seventeen adult pictures were
     * still in the database and still on the disk.
     */
    fn purge_params(p: &QueryParams) -> QueryParams {
        let mut all = p.clone();
        all.dedupe = false;
        all
    }

    pub fn purge(&mut self, p: &QueryParams) -> Result<Vec<String>, String> {
        let was_showing = self.show_adult;
        self.show_adult = true;
        let (base, _duplicates, _parsed) = self.rank(&Self::purge_params(p));
        self.show_adult = was_showing;

        let ids: Vec<String> = base.into_iter().map(|(id, _, _)| id).collect();
        if ids.is_empty() {
            return Ok(ids);
        }

        if let Some(db) = self.db.as_ref() {
            db.purge(&ids)?;
        }

        /*
         * The in-memory copy goes too, or the rows keep answering until the
         * next restart — deleted on disk and present on screen, which reads as
         * the delete having silently failed.
         */
        let gone: std::collections::HashSet<&str> = ids.iter().map(|s| s.as_str()).collect();
        self.items.retain(|i| !gone.contains(i.id.as_str()));
        self.broken.retain(|id| !gone.contains(id.as_str()));

        /*
         * The open result described rows that no longer exist; a page of it
         * would hand the client ids it cannot read.
         *
         * `result_id` is BUMPED, not just cleared. Emptying the result while
         * leaving the id alone means the client's next `items` still matches the
         * live id and is answered with an empty page — which reads as "this
         * query found nothing" rather than as "that result is gone, ask again",
         * and the wall sits empty until something else happens to re-query.
         */
        self.result.clear();
        self.result_ratios.clear();
        self.result_unique = 0;
        self.prior.clear();
        self.result_id += 1;

        Ok(ids)
    }

    /// Distinct values of a field, for query completion. Sorted and capped —
    /// a completion list is a menu, not a data dump.
    pub fn values_of(&self, key: &str) -> Vec<String> {
        let column = match key {
            "kind" => "kind",
            "source" => "source",
            "family" => "family",
            "ext" => "ext",
            "author" => "author",
            "license" => "license",
            // Tags are a JSON array in one column, so the distinct values are
            // not rows; they are unpacked from the rows that have any.
            "tag" | "tags" => {
                let mut out: Vec<String> = match self.db.as_ref() {
                    Some(db) => db
                        .distinct("tags", 400)
                        .iter()
                        .filter_map(|json| serde_json::from_str::<Vec<String>>(json).ok())
                        .flatten()
                        .collect(),
                    None => self.items.iter().flat_map(|i| i.tags.clone()).collect(),
                };
                out.sort();
                out.dedup();
                out.truncate(40);
                return out;
            }
            _ => return Vec::new(),
        };

        match self.db.as_ref() {
            Some(db) => db.distinct(column, 40),
            None => {
                let mut out: Vec<String> = self
                    .items
                    .iter()
                    .map(|i| match column {
                        "kind" => i.kind.clone(),
                        "source" => i.source.clone(),
                        "family" => i.family.clone(),
                        "ext" => i.ext.clone(),
                        "author" => i.author.clone(),
                        _ => i.license.clone(),
                    })
                    .filter(|v| !v.is_empty())
                    .collect();
                out.sort();
                out.dedup();
                out.truncate(40);
                out
            }
        }
    }

    /// A page of records. `None` when the query id is stale — the client asked
    /// against a result that no longer exists, and silently answering from the
    /// new one would hand it rows from a different query.
    /// Where a row sits in a stored result, so a client can jump to it.
    ///
    /// The wall only knows the pages it has loaded, so "reopen this picture"
    /// could only ever find rows near the top. The order lives here.
    pub fn locate(&self, query_id: u64, id: &str) -> Option<usize> {
        let result = match query_id == 0 || query_id == self.result_id {
            true => &self.result,
            false => match self.prior.iter().find(|(qid, _, _)| *qid == query_id) {
                Some((_, ids, _)) => ids,
                None => return None,
            },
        };
        result.iter().position(|row| row == id)
    }

    pub fn page(&self, query_id: u64, offset: usize, limit: usize) -> Option<Vec<Item>> {
        // 0 means "whatever the current result is", which a terminal needs:
        // `proto.sh query … items …` cannot know the id the query just
        // returned. Clients that hold a result still pass the real id and still
        // get the stale check.
        // A superseded result is still pageable while anybody might be
        // reading it — see `prior`. Only a result old enough to have aged out
        // is stale.
        let (result, unique) = match query_id == 0 || query_id == self.result_id {
            true => (&self.result, self.result_unique_len()),
            false => match self.prior.iter().find(|(id, _, _)| *id == query_id) {
                Some((_, ids, unique)) => (ids, *unique),
                None => return None,
            },
        };
        let end = (offset + limit).min(result.len());
        if offset >= end {
            return Some(Vec::new());
        }
        let ids = &result[offset..end];

        let mut items = match self.db.as_ref() {
            Some(db) => match db.records(ids) {
                Ok(items) => items,
                Err(e) => {
                    // A count was already sent for this query. Answering the
                    // page with silence makes the wall contradict the number
                    // printed beside it, with nothing saying why.
                    eprintln!("[quarryd] could not read the rows for a page: {e}");
                    Vec::new()
                }
            },
            None => ids
                .iter()
                .filter_map(|id| self.items.iter().find(|i| &i.id == id).cloned())
                .collect(),
        };

        // A repeated fixture must still look like distinct rows, or the
        // client's per-item state collides. The repeat is a whole number of
        // copies of the same result, so which copy a position falls in is
        // arithmetic on the un-repeated length.
        // `unique` comes from the result being paged, not from the current
        // one — a held result has its own repeat factor.
        if unique > 0 && result.len() > unique {
            for (n, item) in items.iter_mut().enumerate() {
                let copy = (offset + n) / unique;
                if copy > 0 {
                    item.id = format!("{}#{}", item.id, copy);
                }
            }
        }
        Some(items)
    }

    /// How long the result is before the repeat multiplied it.
    ///
    /// Stored rather than recomputed: it used to be `items.len()`, which was
    /// only ever right because an unfiltered fixture query returned everything.
    fn result_unique_len(&self) -> usize {
        self.result_unique
    }

    /// Move the current result into the held window, evicting the oldest.
    fn remember_result(&mut self) {
        // Empty results are held too. A client paging one should be told "no
        // rows", not "stale" — and skipping them made eviction depend on what
        // the queries happened to match.
        self.prior.push_back((
            self.result_id,
            std::mem::take(&mut self.result),
            self.result_unique,
        ));
        while self.prior.len() > PRIOR_RESULTS {
            self.prior.pop_front();
        }
    }

    /// Drop an id from every result anybody could still be paging, not only the
    /// current one — a row deleted here must not reappear from a held page.
    fn forget_everywhere(&mut self, base: &str) {
        let gone = |id: &String| id.split('#').next().unwrap_or(id) == base;
        self.result.retain(|id| !gone(id));
        for (_, ids, _) in self.prior.iter_mut() {
            ids.retain(|id| !gone(id));
        }
    }

    /// Merge crawled rows in, skipping ids already held.
    ///
    /// Returns what was added and what was a duplicate, because "0 added" from
    /// a source that answered 200 is the interesting case — it means the query
    /// pushed down fine and the catalogue already had everything.
    /// Whether the catalogue has written this row off — a fetch that failed
    /// hard, a file that is not an image. `add` refuses them and every lookup
    /// denies them, so a caller holding one is holding nothing.
    pub fn is_broken(&self, id: &str) -> bool {
        self.broken.contains(id)
    }

    pub fn add(&mut self, incoming: Vec<Item>) -> (usize, usize) {
        // Which ids are already held is a question for the store, not for a
        // copy of every id this process would otherwise have to keep.
        let incoming_ids: Vec<String> = incoming.iter().map(|i| i.id.clone()).collect();
        let known: std::collections::HashSet<String> = match self.db.as_ref() {
            Some(db) => db.existing_ids(&incoming_ids),
            None => self.items.iter().map(|i| i.id.clone()).collect(),
        };

        let mut fresh = Vec::new();
        // A row we already have is still allowed to teach us ONE thing.
        //
        // `sample` (the source's mid-size URL) was added after this catalogue
        // was built, so almost every stored row has an empty one. Skipping
        // known ids outright meant a re-crawl could never fill them in: the
        // database upsert that exists for exactly this was unreachable, and the
        // mid-size URL only ever reached rows discovered after the change.
        // Measured on a live crawl before this: 40 fetched, 28 added, 12
        // duplicates — and precisely the 28 gained a sample.
        let mut backfill = Vec::new();
        let mut duplicates_with_tags: Vec<(String, Vec<String>)> = Vec::new();
        let mut resigned: Vec<(String, String)> = Vec::new();
        let mut duplicate = 0;
        for item in incoming {
            if known.contains(&item.id) || self.broken.contains(&item.id) {
                duplicate += 1;
                if !item.tags.is_empty() {
                    duplicates_with_tags.push((item.id.clone(), item.tags.clone()));
                }
                // A signed url that has been reissued: the row is the same
                // picture, the link is not, and the old one is a 403 waiting to
                // happen. See `refresh_signed_url`.
                if !item.url.is_empty() {
                    resigned.push((item.id.clone(), item.url.clone()));
                }
                if !item.sample.is_empty() {
                    backfill.push(item);
                }
                continue;
            }
            fresh.push(item);
        }

        // Disk first: a row the process can see but the database cannot is a
        // row that disappears on restart, which is the whole bug this replaced.
        if let Some(db) = self.db.as_mut() {
            if let Err(e) = db.insert_many(&fresh) {
                eprintln!("[quarryd] catalogue write failed: {e}");
            }
            // The statement itself is the narrow one: it only fills an EMPTY
            // sample and touches no other column, so re-sending a known row
            // cannot trample enrichment the crawl does not have.
            if !backfill.is_empty() {
                if let Err(e) = db.insert_many(&backfill) {
                    eprintln!("[quarryd] sample backfill failed: {e}");
                }
            }
            let mut refreshed = 0;
            for (id, url) in &resigned {
                match db.refresh_signed_url(id, url) {
                    Ok(true) => refreshed += 1,
                    Err(e) => eprintln!("[quarryd] could not refresh a signed url: {e}"),
                    _ => {}
                }
            }
            if refreshed > 0 {
                eprintln!("[quarryd] {refreshed} rows got a fresh signed picture url");
            }
        }

        /*
         * A KNOWN ROW CAN STILL LEARN A WORD.
         *
         * `sample` was the first thing a re-crawl was allowed to teach an
         * existing row; tags are the second, and for the same reason. A
         * wallhaven search result carries no tags at all, so without this the
         * word that fetched a row is recorded only if the row happened to be
         * new — and a catalogue that has already seen a picture can never be
         * searched for it.
         */
        let relearn: Vec<(String, Vec<String>)> = duplicates_with_tags
            .into_iter()
            .filter(|(_, tags)| !tags.is_empty())
            .collect();
        if !relearn.is_empty() {
            if let Some(db) = self.db.as_mut() {
                match db.merge_tags(&relearn) {
                    Ok(n) if n > 0 => eprintln!("[quarryd] {n} known rows learned a new tag"),
                    Err(e) => eprintln!("[quarryd] tag merge failed: {e}"),
                    _ => {}
                }
            }
        }

        let added = fresh.len();
        // Bounded: past the cap the oldest go, and a result older than that
        // re-ranks in full (see `touched`).
        if self.touched.len() > 100_000 {
            self.touched_base += self.touched.len();
            self.touched.clear();
        }
        self.touched.extend(fresh.iter().map(|i| i.id.clone()));
        self.touched.extend(relearn.iter().map(|(id, _)| id.clone()));
        if self.db.is_none() {
            // Fixture mode keeps its rows here; with a database the write above
            // is the whole of it, and the next query reads them back.
            for b in &backfill {
                if let Some(existing) = self.items.iter_mut().find(|i| i.id == b.id) {
                    if existing.sample.is_empty() {
                        existing.sample = b.sample.clone();
                    }
                }
            }
            self.items.extend(fresh);
        }
        /*
         * A CRAWL MUST NOT INVALIDATE THE OPEN RESULT.
         *
         * This used to bump `result_id` on every insert, reasoning that the
         * result no longer reflected the catalogue. But the crawler inserts
         * continuously, so a client that was simply scrolling had its stored
         * result pulled out from under it every few seconds: the next page came
         * back "stale queryId", the client re-queried, and the whole wall
         * reloaded with a different set of pictures while you were reading it.
         *
         * The ids in the result are still valid — a page is an offset into a
         * frozen list. New rows are not in it, and that is correct: a result is
         * a snapshot. `more` reports what it added and the client re-queries
         * when it wants to see it.
         */
        (added, duplicate)
    }

    /// What was searched, opened or exported. No database, no history — the
    /// fixture path has nothing to remember to.
    pub fn history_add(&self, kind: &str, value: &str, item: &str, context: &str) {
        if let Some(db) = self.db.as_ref() {
            // 2,000 lines is months of use and about 100 kB.
            if let Err(e) = db.history_add(kind, value, item, context, 2000) {
                eprintln!("[quarryd] history: {e}");
            }
        }
    }

    pub fn history(
        &self,
        kind: &str,
        needle: &str,
        limit: usize,
    ) -> Vec<(i64, String, String, String, String)> {
        self.db.as_ref().map(|db| db.history(kind, needle, limit)).unwrap_or_default()
    }

    pub fn history_clear(&self, kind: &str) -> usize {
        self.db.as_ref().map(|db| db.history_clear(kind)).unwrap_or(0)
    }

    /// Where the small, irreplaceable half of the catalogue is mirrored.
    pub fn user_data_path(db_path: &std::path::Path) -> std::path::PathBuf {
        db_path.with_extension("user-data.json")
    }

    /*
     * Mirror collections, boards and slots to disk. Best effort by design: a
     * backup that refuses to write must never stop the thing it backs up.
     *
     * But best effort was also SILENT effort. Both failure arms threw the
     * reason away, and this file is the only copy of the half of the catalogue
     * that cannot be fetched again — so the way you would have found out it had
     * stopped writing is the day you needed it. It still never blocks the
     * change; it just says so, and remembers, so the app can say it too.
     */
    pub fn backup_user_data(&self) {
        let Some(db) = self.db.as_ref() else { return };
        let text = match db.export_user_data() {
            Ok(text) => text,
            Err(e) => {
                self.note_backup(format!("could not read your boards out of the catalogue: {e}"));
                return;
            }
        };
        let path = Self::user_data_path(std::path::Path::new(&self.db_path()));
        match std::fs::write(&path, text) {
            Ok(()) => {
                if self.backup_error.borrow().is_some() {
                    eprintln!("[quarryd] the copy of your boards is being written again");
                    *self.backup_error.borrow_mut() = None;
                }
            }
            Err(e) => self.note_backup(format!("could not write {}: {e}", path.display())),
        }
    }

    fn note_backup(&self, why: String) {
        let mut slot = self.backup_error.borrow_mut();
        if slot.as_deref() != Some(why.as_str()) {
            eprintln!("[quarryd] YOUR BOARDS ARE NOT BEING SAVED — {why}");
        }
        *slot = Some(why);
    }

    /// Why the copy of the user's own data is not being written, if it is not.
    pub fn backup_error(&self) -> Option<String> {
        self.backup_error.borrow().clone()
    }

    /// Crawl cursors as stored: (source, query, page, finished_at).
    pub fn cursors(&self) -> Vec<(String, String, u32, i64)> {
        self.db.as_ref().map(|db| db.cursors()).unwrap_or_default()
    }

    /// Remember where each source has been read to. Without a database there
    /// is nothing to remember to — the fixture path has no crawl.
    pub fn remember_cursors(&self, cursors: &[(String, String, u32, i64)]) {
        if let Some(db) = self.db.as_ref() {
            if let Err(e) = db.set_cursors(cursors) {
                eprintln!("[quarryd] could not store crawl cursors: {e}");
            }
        }
    }

    pub fn forget_cursors(&self, query: &str) {
        if let Some(db) = self.db.as_ref() {
            db.clear_cursors(query);
        }
    }

    /// Hide a row because somebody chose to. Never undone by a cleanup.
    pub fn hide_by_hand(&mut self, id: &str) -> bool {
        let base = id.split('#').next().unwrap_or(id).to_string();
        if let Some(db) = self.db.as_ref() {
            if let Err(e) = db.hide(&base, "user") {
                eprintln!("[quarryd] hide {base} failed to persist: {e}");
            }
        }
        self.items.retain(|i| i.id != base);
        self.forget_everywhere(&base);
        self.broken.insert(base)
    }

    /// How many rows are hidden, and why.
    pub fn hidden_tally(&self) -> Vec<(String, usize)> {
        self.db.as_ref().map(|db| db.hidden_tally()).unwrap_or_default()
    }

    /// Stop refusing rows the daemon hid on its own.
    pub fn unhide(&mut self, scope: &str) -> Result<usize, String> {
        let Some(db) = self.db.as_ref() else {
            return Ok(0);
        };
        let removed = db.unhide(scope)?;
        // The in-memory set is the same decision cached; leaving it would keep
        // filtering rows the database no longer refuses.
        if removed > 0 {
            self.broken = db.hidden_ids()?.into_iter().collect();
        }
        Ok(removed)
    }

    /// Record that this row's picture could not be fetched.
    ///
    /// Returns whether it is newly broken, so the caller knows whether anything
    /// changed — the client only has to re-run its query if something did.
    pub fn mark_broken(&mut self, id: &str) -> bool {
        let base = id.split('#').next().unwrap_or(id).to_string();
        if let Some(db) = self.db.as_ref() {
            // Hidden rows outlive the process *and* a re-crawl that would
            // otherwise add them straight back — but only if this write
            // actually lands; if it doesn't, the row is broken again on the
            // very next restart.
            if let Err(e) = db.hide(&base, "fetch") {
                eprintln!("[quarryd] hide {base} failed to persist: {e}");
            }
        }
        self.items.retain(|i| i.id != base);
        // The result still names it; a page that includes it now comes back
        // one row short rather than with a cell that never fills. Held results
        // too — see `forget_everywhere`.
        self.forget_everywhere(&base);
        self.broken.insert(base)
    }

    pub fn broken_count(&self) -> usize {
        self.broken.len()
    }

    /// Replace a row in place, keeping its position so an open view does not
    /// jump when a record gains its details.
    pub fn replace(&mut self, item: Item) {
        let base = item.id.split('#').next().unwrap_or(&item.id).to_string();
        if let Some(db) = self.db.as_ref() {
            if let Err(e) = db.update(&item) {
                eprintln!("[quarryd] replace {base} failed to persist: {e}");
            }
        }
        if let Some(slot) = self.items.iter_mut().find(|i| i.id == base) {
            *slot = item;
        }
        let _ = base;
    }

    /// Do not offer this row to the no-network sweep again — it has been tried
    /// and there is nothing on disk to hash. See `hash_skip`.
    pub fn skip_hashing(&mut self, id: &str) {
        self.hash_skip.insert(id.to_string());
    }

    /// Rows with no perceptual hash yet, as (id, thumb url, original url).
    ///
    /// Hashes are a by-product of making a thumbnail, so a catalogue that has
    /// been crawled but not browsed has almost none — and both dedupe and
    /// "more like this" can only see what has been hashed. This is the worklist
    /// for closing that gap.
    pub fn unhashed(&self, limit: usize) -> Vec<(String, String, String)> {
        /*
         * ROUND-ROBIN BY SOURCE, not the first N in order.
         *
         * Taking them in order handed back one source's rows over and over —
         * and if that source is refusing us (DeviantArt answers 403), every
         * batch spent itself on the same dead rows and the backfill never
         * reached a source that would have answered. One dead source must not
         * starve the rest.
         */
        // Read a window of the backlog rather than all of it: this is consumed
        // a batch at a time, and a round-robin over twenty times the batch is
        // as fair as one over the whole catalogue.
        let backlog: Vec<(String, String, String, String)> = match self.db.as_ref() {
            Some(db) => db.unhashed_rows((limit * 20).clamp(200, 4000)),
            None => self
                .items
                .iter()
                .filter(|i| {
                    i.phash.is_empty()
                        && !self.broken.contains(&i.id)
                        && !self.hash_skip.contains(&i.id)
                })
                .map(|i| (i.id.clone(), i.thumb.clone(), i.url.clone(), i.source.clone()))
                .collect(),
        };

        let mut by_source: std::collections::BTreeMap<&str, Vec<&(String, String, String, String)>> =
            std::collections::BTreeMap::new();
        for row in backlog
            .iter()
            .filter(|r| !self.broken.contains(&r.0) && !self.hash_skip.contains(&r.0))
        {
            by_source.entry(row.3.as_str()).or_default().push(row);
        }

        let mut out = Vec::with_capacity(limit.min(1024));
        let mut round = 0usize;
        while out.len() < limit {
            let mut placed = false;
            for rows in by_source.values() {
                if let Some(row) = rows.get(round) {
                    out.push((row.0.clone(), row.1.clone(), row.2.clone()));
                    placed = true;
                    if out.len() >= limit {
                        break;
                    }
                }
            }
            if !placed {
                break; // every source exhausted
            }
            round += 1;
        }
        out
    }

    /// How many rows have a hash, and how many exist. The honest denominator
    /// for "why did that find nothing".
    pub fn hash_coverage(&self) -> (usize, usize) {
        match self.db.as_ref() {
            Some(db) => db.hash_coverage(),
            None => (
                self.items.iter().filter(|i| !i.phash.is_empty()).count(),
                self.items.len(),
            ),
        }
    }

    /// Keep the perceptual hash and dominant colour worked out while making a
    /// thumbnail.
    ///
    /// These were computed on every thumbnail and thrown away with the
    /// response, so the `phash` column and its index stayed empty and the
    /// "duplicate detection, once phashes are stored" note above the schema
    /// never came true. Written once, on the first thumbnail an item gets.
    pub fn remember_hashes(&mut self, id: &str, phash: &str, dominant: &str) {
        let base = id.split('#').next().unwrap_or(id).to_string();
        let Some(mut item) = self.by_id(&base) else {
            return;
        };
        if item.phash == phash && item.dominant == dominant {
            return; // nothing new to write
        }
        item.phash = phash.to_string();
        item.dominant = dominant.to_string();

        if let Some(db) = self.db.as_ref() {
            // Failing here does not lose the hash for this request, but it
            // would be recomputed from scratch on every restart, forever —
            // which is the bug this method was written to fix, deferred one
            // boot.
            if let Err(e) = db.update(&item) {
                eprintln!("[quarryd] remember_hashes {base} failed to persist: {e}");
            }
        } else if let Some(slot) = self.items.iter_mut().find(|i| i.id == base) {
            *slot = item;
        }
    }

    /// Keep what ffprobe measured about a video.
    ///
    /// Sources describe video badly — dimensions that are the poster's, a
    /// duration that is absent or wrong — so the numbers written here are the
    /// ones taken from the file itself, and only when they are better than
    /// what is stored. A zero never overwrites a real measurement.
    pub fn remember_video(&mut self, id: &str, w: u32, h: u32, duration: f64) {
        let base = id.split('#').next().unwrap_or(id).to_string();
        let Some(mut item) = self.by_id(&base) else {
            return;
        };

        let same_size = (w == 0 || (item.w == w && item.h == h))
            && (duration <= 0.0 || (item.duration - duration).abs() < 0.05);
        if same_size {
            return; // nothing new to write
        }

        if w > 0 && h > 0 {
            item.w = w;
            item.h = h;
            item.ratio = w as f64 / h as f64;
        }
        if duration > 0.0 {
            item.duration = duration;
        }

        if let Some(db) = self.db.as_ref() {
            if let Err(e) = db.update(&item) {
                eprintln!("[quarryd] remember_video {base} failed to persist: {e}");
            }
        } else if let Some(slot) = self.items.iter_mut().find(|i| i.id == base) {
            *slot = item;
        }
    }

    /// One record. Owned rather than borrowed: with a database there is no
    /// resident row to hand out a reference to.
    pub fn by_id(&self, id: &str) -> Option<Item> {
        let base = id.split('#').next().unwrap_or(id);
        match self.db.as_ref() {
            Some(db) => db.item_by_id(base),
            None => self.items.iter().find(|i| i.id == base).cloned(),
        }
    }

    /// Items that LOOK like this one, by perceptual hash — as a RESULT.
    ///
    /// This sets the current result index exactly as `query` does, rather than
    /// handing back rows. Everything downstream — paging, ratios, the masonry
    /// geometry, the dedupe — already works on a result, so "more like this"
    /// costs no new machinery on either side of the socket; it is a different
    /// way of choosing which rows are in one.
    ///
    /// A linear scan, deliberately: the hashes are in memory, 64 bits each, and
    /// an xor plus a popcount per row is nothing against the fetch that put
    /// them there. Returns `(scanned, hashed)` so an empty answer can say which
    /// empty it is — nothing alike, or nothing hashed yet.
    pub fn similar(
        &mut self,
        id: &str,
        max_distance: u32,
        limit: usize,
    ) -> Result<(QueryResult, usize, usize), String> {
        self.similar_with(id, max_distance, limit, &[], true)
    }

    /*
     * The catalogue's own look-alikes, then pictures from beyond it.
     *
     * `extra` is rows just fetched for this question — Yandex's "similar
     * images" for the picture — already added to the catalogue. They follow
     * the perceptual-hash matches, which are measured and closer, and they
     * still count when the picture has no hash yet: the web does not need one.
     */
    pub fn similar_with(
        &mut self,
        id: &str,
        max_distance: u32,
        limit: usize,
        extra: &[String],
        local: bool,
    ) -> Result<(QueryResult, usize, usize), String> {
        let (hits, scanned, hashed) = match self.nearest(id, max_distance, limit) {
            Ok(_) if !local => (Vec::new(), 0, 0),
            Err(_) if !local => (Vec::new(), 0, 0),
            Ok(found) => found,
            Err(_) if !extra.is_empty() => (Vec::new(), 0, 0),
            Err(e) => return Err(e),
        };
        let seed = id.split('#').next().unwrap_or(id).to_string();
        let mut result: Vec<String> = hits.iter().map(|(id, _)| id.clone()).collect();
        let mut ratios: Vec<f64> = hits.iter().map(|(_, r)| *r).collect();
        for other in extra {
            if *other == seed || self.broken.contains(other) || result.contains(other) {
                continue;
            }
            let Some(item) = self.by_id(other) else { continue };
            result.push(other.clone());
            ratios.push(ratio_of(&item));
        }

        self.result_id += 1;
        self.queries += 1;
        let count = result.len();
        // The result being replaced is not this one's length.
        self.result_unique = count;
        self.result_held = result.iter().cloned().collect();
        self.result_mark = self.changes();
        self.result = result;
        self.last_duplicates = 0;

        Ok((
            QueryResult {
                query_id: self.result_id,
                count,
                duplicates: 0,
                ratios,
                unknown: Vec::new(),
                sort: "similar",
            },
            scanned,
            hashed,
        ))
    }

    /*
     * THE TAGS THAT SAY WHAT THIS PICTURE IS, NOT WHAT EVERY PICTURE IS.
     *
     * Asking a booru for "more like this" by tags only works with the right
     * two: `highres solo` matches half the site, `character_x series_y`
     * matches the thing you were looking at. How rare a tag is in this
     * catalogue is a good stand-in for how specific it is — but a tag no other
     * row carries is often a typo or an artist's one-off, so tags seen at
     * least twice come first, rarest first.
     */
    pub fn distinctive_tags(&self, item: &Item, n: usize) -> Vec<String> {
        const NOISE: &[&str] = &[
            "highres", "absurdres", "lowres", "incredibly_absurdres", "commentary", "commentary_request",
            "translated", "translation_request", "english_commentary", "bad_id", "bad_pixiv_id", "tagme",
            "solo", "1girl", "1boy", "female", "male", "safe", "questionable", "explicit", "sensitive",
            "general", "image", "wallpaper", "photo", "video", "animated", "sound", "webm", "mp4", "gif",
            "hi_res", "digital_media_(artwork)", "simple_background", "white_background", "looking_at_viewer",
        ];
        let tags: Vec<&String> = item
            .tags
            .iter()
            .filter(|t| {
                let t = t.to_lowercase();
                !t.is_empty() && !t.contains(':') && t.len() > 2 && !NOISE.contains(&t.as_str())
            })
            .take(60)
            .collect();
        let Some(db) = self.db.as_ref() else {
            return tags.into_iter().take(n).cloned().collect();
        };
        let mut counted: Vec<(usize, &String)> = tags.into_iter().map(|t| (db.tag_count(t), t)).collect();
        counted.sort_by_key(|(count, _)| (if *count >= 2 { 0 } else { 1 }, *count));
        counted.into_iter().take(n).map(|(_, t)| t.clone()).collect()
    }

    /// What `similar` would answer, as records, storing nothing — for a second
    /// window, for the same reason as `find`.
    pub fn similar_records(&self, id: &str, max_distance: u32, limit: usize) -> Result<(Vec<Item>, usize, usize), String> {
        let (hits, scanned, hashed) = self.nearest(id, max_distance, limit)?;
        let ids: Vec<String> = hits.into_iter().map(|(id, _)| id).collect();
        Ok((self.records_for(&ids), scanned, hashed))
    }

    fn records_for(&self, ids: &[String]) -> Vec<Item> {
        match self.db.as_ref() {
            Some(db) => match db.records(ids) {
                Ok(items) => items,
                Err(e) => {
                    // A count was already sent for this query. Answering the
                    // page with silence makes the wall contradict the number
                    // printed beside it, with nothing saying why.
                    eprintln!("[quarryd] could not read the rows for a page: {e}");
                    Vec::new()
                }
            },
            None => ids.iter().filter_map(|id| self.items.iter().find(|i| &i.id == id).cloned()).collect(),
        }
    }

    /// (id, ratio) closest first, plus how many rows were scanned and hashed.
    fn nearest(&self, id: &str, max_distance: u32, limit: usize) -> Result<(Vec<(String, f64)>, usize, usize), String> {
        let seed = self.by_id(id).ok_or_else(|| format!("no such item: {id}"))?;
        let seed_hash = u64::from_str_radix(&seed.phash, 16)
            .map_err(|_| "this item has no perceptual hash yet".to_string())?;
        let seed_id = seed.id.clone();

        let candidates: Vec<(String, f64, String)> = match self.db.as_ref() {
            Some(db) => db
                .hashed_rows()
                .into_iter()
                .map(|r| (r.id, ratio_or(r.ratio), r.phash))
                .collect(),
            None => self
                .items
                .iter()
                .map(|i| (i.id.clone(), ratio_of(i), i.phash.clone()))
                .collect(),
        };

        let mut hashed = 0usize;
        let mut hits: Vec<(u32, usize)> = Vec::new(); // (distance, candidate)
        for (i, (id, _, phash)) in candidates.iter().enumerate() {
            if *id == seed_id || self.broken.contains(id) {
                continue;
            }
            let Ok(h) = u64::from_str_radix(phash, 16) else {
                continue;
            };
            hashed += 1;
            let d = crate::image::hamming(seed_hash, h);
            if d <= max_distance {
                hits.push((d, i));
            }
        }
        // Closest first — the ordering IS the answer here, unlike a query where
        // the sort is a separate choice.
        hits.sort_by_key(|(d, _)| *d);
        hits.truncate(limit);
        let scanned = candidates.len();
        let out = hits.iter().map(|(_, i)| (candidates[*i].0.clone(), candidates[*i].1)).collect();
        Ok((out, scanned, hashed))
    }

    /// Distinct values of a field with their counts, most common first — what a
    /// filter panel needs to show what is worth filtering by.
    fn tally(&self, field: impl Fn(&Item) -> &str) -> Vec<serde_json::Value> {
        let mut counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
        for item in self.items.iter().filter(|i| !self.broken.contains(&i.id)) {
            *counts.entry(field(item)).or_insert(0) += 1;
        }
        let mut rows: Vec<(&str, usize)> = counts.into_iter().filter(|(k, _)| !k.is_empty()).collect();
        rows.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        rows.into_iter()
            .map(|(name, count)| serde_json::json!({ "id": name, "items": count }))
            .collect()
    }

    pub fn kinds(&self) -> Vec<serde_json::Value> {
        match self.db.as_ref() {
            Some(db) => db.tally_column("kind"),
            None => self.tally(|i| i.kind.as_str()),
        }
    }

    pub fn families(&self) -> Vec<serde_json::Value> {
        match self.db.as_ref() {
            Some(db) => db.tally_column("family"),
            None => self.tally(|i| i.family.as_str()),
        }
    }

    /// What the catalogue has failed with, if it has — see `Db::damage`. The
    /// daemon puts this in its answers so a client that got no rows can say
    /// WHY it got no rows.
    pub fn damage(&self) -> Option<String> {
        self.db.as_ref().and_then(|db| db.damage())
    }

    pub fn sources(&self) -> Vec<serde_json::Value> {
        if let Some(db) = self.db.as_ref() {
            return db.source_tally();
        }
        let mut names: Vec<&str> = self.items.iter().map(|i| i.source.as_str()).collect();
        names.sort_unstable();
        names.dedup();

        names
            .into_iter()
            .map(|name| {
                let mut kinds: Vec<&str> = self
                    .items
                    .iter()
                    .filter(|i| i.source == name)
                    .map(|i| i.kind.as_str())
                    .collect();
                kinds.sort_unstable();
                kinds.dedup();

                serde_json::json!({
                    "id": name,
                    "label": name,
                    "kinds": kinds,
                    "items": self.items.iter().filter(|i| i.source == name).count(),
                })
            })
            .collect()
    }
}

/// The aspect ratio a row lays out at, however it happens to be recorded.
fn ratio_of(item: &Item) -> f64 {
    if item.ratio > 0.0 {
        item.ratio
    } else if item.h > 0 {
        item.w as f64 / item.h as f64
    } else {
        1.0
    }
}

fn ratio_or(ratio: f64) -> f64 {
    if ratio > 0.0 {
        ratio
    } else {
        1.0
    }
}

#[cfg(test)]
mod find_tests {
    use super::*;

    fn params(q: &str) -> QueryParams {
        serde_json::from_value(serde_json::json!({ "q": q })).unwrap()
    }

    /*
     * A SECOND CLIENT'S QUERY MUST NOT BLANK THE FIRST CLIENT'S GRID.
     *
     * `find` was built so a second window could search without disturbing the
     * result — but a plain `query` from anything at all (a headless test
     * instance, a board window, `tools/proto.sh query`) replaced it, and every
     * page the reader had in flight came back "stale queryId". The cells that
     * asked were already marked pending, so nobody asked again and the holes
     * stayed until the query changed.
     */
    #[test]
    fn a_superseded_result_is_still_pageable() {
        let text = std::fs::read_to_string("../fixtures/sample.json").expect("fixture");
        let mut catalog = Catalog::from_fixture(&text).unwrap();
        let reader = catalog.query(&params(""));
        let before = catalog.page(reader.query_id, 0, 3).expect("the reader's own page");

        // Somebody else queries. The reader is still holding its queryId.
        let other = catalog.query(&params("a"));
        assert_ne!(other.query_id, reader.query_id, "a query takes a new id");

        let after = catalog.page(reader.query_id, 0, 3).expect("the reader can still page");
        assert_eq!(
            before.iter().map(|i| i.id.clone()).collect::<Vec<_>>(),
            after.iter().map(|i| i.id.clone()).collect::<Vec<_>>(),
            "the same page of the same result"
        );
    }

    /// Held results are a window, not a leak: page far enough back and the
    /// answer is an honest "stale" rather than an ever-growing map.
    #[test]
    fn a_result_old_enough_does_go_stale() {
        let text = std::fs::read_to_string("../fixtures/sample.json").expect("fixture");
        let mut catalog = Catalog::from_fixture(&text).unwrap();
        let oldest = catalog.query(&params("")).query_id;
        for n in 0..=PRIOR_RESULTS {
            catalog.query(&params(&format!("q{n}")));
        }
        assert!(catalog.page(oldest, 0, 1).is_none(), "it should have aged out");
    }

    /// A second window searching must not pull the result out from under the
    /// first one's paging.
    #[test]
    fn find_leaves_the_shared_result_alone() {
        let text = std::fs::read_to_string("../fixtures/sample.json").expect("fixture");
        let mut catalog = Catalog::from_fixture(&text).unwrap();
        let first = catalog.query(&params(""));
        let page_before = catalog.page(first.query_id, 0, 5).expect("page");

        let (count, found) = catalog.find(&params(""), 0, 5);
        assert_eq!(count, first.count);
        assert_eq!(found.len(), page_before.len());

        let page_after = catalog.page(first.query_id, 0, 5).expect("still valid after find");
        let ids = |v: &[Item]| v.iter().map(|i| i.id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(&page_before), ids(&page_after));
        assert_eq!(catalog.queries, 1, "find must not count as a stored query");
    }
}

/*
 * THE DEFAULT ORDER TAKES TURNS BETWEEN SOURCES.
 *
 * "Best match" was newest-added first, which meant whatever was crawled last
 * filled the wall: after one sakugabooru crawl the first 150 results were 130
 * sakugabooru, after a folder scan they were your local files, and the
 * settings panel's "take turns between sources, so no single site fills the
 * wall" was only ever true of the crawl, never of what you saw.
 *
 * Now the rows are dealt out by source, each source's own rows staying newest
 * first. The blend preference decides the dealing: `round-robin` one each per
 * turn, `weighted` one plus the source's weight per turn, `shuffle` the turn
 * order reshuffled from the seed. Explicit sorts (new, large, wide, title,
 * random) are left exactly as asked.
 */
pub fn interleave_sources<T>(rows: Vec<T>, source_of: impl Fn(&T) -> &str, prefs: &crate::prefs::Prefs) -> Vec<T> {
    let total = rows.len();
    let mut order: Vec<String> = Vec::new();
    let mut buckets: std::collections::HashMap<String, std::collections::VecDeque<T>> = std::collections::HashMap::new();
    for row in rows {
        let key = source_of(&row).to_string();
        if !buckets.contains_key(&key) {
            order.push(key.clone());
        }
        buckets.entry(key).or_default().push_back(row);
    }
    if order.len() <= 1 {
        return order.into_iter().flat_map(|k| buckets.remove(&k).unwrap_or_default()).collect();
    }

    // Heavier sources first in each turn; ties keep first appearance (newest).
    let mut weighted: Vec<(i32, usize, String)> =
        order.into_iter().enumerate().map(|(i, k)| (prefs.for_source(&k).weight, i, k)).collect();
    weighted.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let turns: Vec<(String, usize)> = {
        let keys: Vec<String> = weighted.iter().map(|w| w.2.clone()).collect();
        let keys = prefs.blend_order(keys);
        keys.into_iter()
            .map(|k| {
                let per_turn = if prefs.blend == "weighted" { 1 + prefs.for_source(&k).weight.max(0) as usize } else { 1 };
                (k, per_turn)
            })
            .collect()
    };

    let mut out = Vec::with_capacity(total);
    while out.len() < total {
        let before = out.len();
        for (key, per_turn) in &turns {
            if let Some(bucket) = buckets.get_mut(key) {
                for _ in 0..*per_turn {
                    match bucket.pop_front() {
                        Some(row) => out.push(row),
                        None => break,
                    }
                }
            }
        }
        if out.len() == before {
            break;
        }
    }
    out
}

#[cfg(test)]
mod interleave_tests {
    use super::*;

    #[test]
    fn a_fresh_crawl_of_one_source_does_not_fill_the_wall() {
        let rows = vec![("a", 1), ("a", 2), ("a", 3), ("a", 4), ("b", 1), ("c", 1), ("b", 2)];
        let prefs = crate::prefs::Prefs::default();
        let out = interleave_sources(rows, |r| r.0, &prefs);
        let sources: Vec<&str> = out.iter().map(|r| r.0).collect();
        assert_eq!(sources, vec!["a", "b", "c", "a", "b", "a", "a"]);
        // Each source's own rows keep their order.
        let a: Vec<i32> = out.iter().filter(|r| r.0 == "a").map(|r| r.1).collect();
        assert_eq!(a, vec![1, 2, 3, 4]);
    }

    #[test]
    fn nothing_is_lost_or_duplicated() {
        let rows: Vec<(String, usize)> = (0..1000).map(|i| (format!("s{}", i % 7), i)).collect();
        let prefs = crate::prefs::Prefs::default();
        let mut out: Vec<usize> = interleave_sources(rows, |r| r.0.as_str(), &prefs).into_iter().map(|r| r.1).collect();
        out.sort();
        assert_eq!(out, (0..1000).collect::<Vec<_>>());
    }
}

/*
 * THE ADULT SWITCH, WHICH HAS TO BE A PROMISE RATHER THAN A FILTER.
 *
 * Reported as "nsfw is not safe to disable — after disabling it gets displayed
 * again, even locally". It was true: the app expressed the switch by appending
 * `-nsfw` to the query string, so any later assignment to the query dropped it and
 * the rows came straight back out of the local catalogue.
 */
#[cfg(test)]
mod adult_switch_tests {
    use super::*;

    fn params(q: &str) -> QueryParams {
        serde_json::from_value(serde_json::json!({ "q": q })).unwrap()
    }

    /// A catalogue holding one ordinary row and one adult row, built through
    /// `normalize` like every real row is.
    fn mixed() -> Catalog {
        let make = |source: &str, title: &str| {
            crate::scrape::normalize(
                source,
                title,
                title,
                &format!("https://x.test/{title}.jpg"),
                "",
                "",
                1500,
                1000,
                Vec::new(),
            )
        };
        let safe = make("wallhaven", "hillside");
        let mut adult = make("rule34", "other");
        adult.nsfw = true;

        let text = serde_json::to_string(&serde_json::json!({ "items": [safe, adult] })).unwrap();
        Catalog::from_fixture(&text).expect("fixture")
    }

    #[test]
    fn with_the_switch_off_an_adult_row_is_not_in_any_answer() {
        let mut catalog = mixed();
        catalog.set_show_adult(false);

        let (count, rows) = catalog.find(&params(""), 0, 50);
        assert_eq!(count, 1, "one row, not two");
        assert!(!rows[0].nsfw);

        // And through `query`/`page`, which is the path the wall actually uses.
        let result = catalog.query(&params(""));
        assert_eq!(result.count, 1);
        let page = catalog.page(result.query_id, 0, 50).expect("page");
        assert!(page.iter().all(|i| !i.nsfw), "no adult row reaches the wall");
    }

    /*
     * THE ONE THAT MAKES IT A SWITCH.
     *
     * Typing the predicate yourself must not reopen it. Clauses are ANDed and the
     * gate is appended last, so `nsfw:true` asks for rows that are both adult and
     * not adult — which is correctly nothing.
     */
    #[test]
    fn a_query_cannot_ask_its_way_past_the_switch() {
        let mut catalog = mixed();
        catalog.set_show_adult(false);

        for asked in ["nsfw:true", "nsfw", "-nsfw", "nsfw:true a hillside"] {
            let (count, rows) = catalog.find(&params(asked), 0, 50);
            assert!(rows.iter().all(|i| !i.nsfw), "{asked:?} returned an adult row");
            assert!(count <= 1, "{asked:?} returned {count}");
        }
    }

    /// Hidden, not deleted: the rows are still there and come back.
    #[test]
    fn turning_it_back_on_restores_the_rows_without_a_crawl() {
        let mut catalog = mixed();

        catalog.set_show_adult(false);
        assert_eq!(catalog.find(&params(""), 0, 50).0, 1);

        catalog.set_show_adult(true);
        let (count, rows) = catalog.find(&params(""), 0, 50);
        assert_eq!(count, 2, "both rows again");
        assert!(rows.iter().any(|i| i.nsfw), "including the adult one");
    }

    /// With it on, `-nsfw` still means what it says — the gate narrows, and
    /// never widens, whatever the user asked for.
    #[test]
    fn the_switch_being_on_does_not_disable_the_predicate() {
        let mut catalog = mixed();
        catalog.set_show_adult(true);
        let (count, rows) = catalog.find(&params("-nsfw"), 0, 50);
        assert_eq!(count, 1);
        assert!(!rows[0].nsfw);
    }
}

/*
 * THE GEOMETRY ARRIVES IN SLICES, AND THE SLICES HAVE TO LINE UP.
 *
 * `query` cannot send one ratio per row any more: over a 752k catalogue that is a
 * 10.3 MB frame holding a 752,168-element array, and QV4 segfaults parsing an
 * array that long (bisected in pure JS with no socket in it — 500,000 parses,
 * 600,000 kills the engine). So the wall's shape is pulled a slice at a time, and
 * a slice that is off by one puts one picture's shape under another. These tests
 * exist because that failure looks like tiles at random sizes, not like an error.
 */
#[cfg(test)]
mod ratios_slice_tests {
    use super::*;

    fn params(q: &str) -> QueryParams {
        serde_json::from_value(serde_json::json!({ "q": q })).unwrap()
    }

    /// `n` rows with deliberately distinct shapes, so a misaligned slice cannot
    /// pass by accident the way a wall of 16:9 would.
    fn wall(n: usize) -> Catalog {
        let items: Vec<_> = (0..n)
            .map(|i| {
                crate::scrape::normalize(
                    "wallhaven",
                    &format!("row{i}"),
                    &format!("row{i}"),
                    &format!("https://x.test/row{i}.jpg"),
                    "",
                    "",
                    1000 + i as u32,
                    1000,
                    Vec::new(),
                )
            })
            .collect();
        let text = serde_json::to_string(&serde_json::json!({ "items": items })).unwrap();
        Catalog::from_fixture(&text).expect("fixture")
    }

    /// The slices, concatenated, must equal what `query` computed — same values,
    /// same order, no gap and no repeat at the seams.
    #[test]
    fn the_slices_reassemble_into_exactly_the_query_s_ratios() {
        let mut catalog = wall(250);
        let result = catalog.query(&params(""));
        assert_eq!(result.ratios.len(), 250);

        for chunk in [1usize, 7, 100, 250, 1000] {
            let mut rebuilt = Vec::new();
            loop {
                let (got, total) = catalog
                    .ratios_slice(result.query_id, rebuilt.len(), chunk)
                    .expect("live queryId");
                if got.is_empty() {
                    assert_eq!(rebuilt.len(), total, "ran dry before the end");
                    break;
                }
                rebuilt.extend(got);
            }
            assert_eq!(rebuilt, result.ratios, "chunk size {chunk} reassembled wrong");
        }
    }

    /// Asking past the end is empty, not a panic — the client asks once more than
    /// it needs to when a crawl shrinks the result under it.
    #[test]
    fn reading_past_the_end_is_empty_rather_than_a_panic() {
        let mut catalog = wall(10);
        let result = catalog.query(&params(""));
        for (from, count) in [(10, 5), (11, 5), (1000, 1000), (0, 0), (9, 100)] {
            let (got, total) = catalog
                .ratios_slice(result.query_id, from, count)
                .expect("live queryId");
            assert_eq!(total, 10);
            // `from` past the end clamps to the end, so the comparison is against
            // the clamped start — not against `from`, which may be 1000.
            let start = from.min(total);
            assert!(start + got.len() <= total, "slice from {from} ran off the end");
            if from >= total {
                assert!(got.is_empty(), "slice from {from} of a {total}-row result was not empty");
            }
        }
    }

    /*
     * A STALE ID IS REFUSED, NOT SERVED FROM THE NEW RESULT.
     *
     * Answering an old id out of the current result is the quiet version of this
     * bug: every ratio is valid, they are simply the wrong pictures' ratios, so
     * the wall lays out convincingly and wrongly.
     */
    #[test]
    fn a_stale_query_id_is_refused() {
        let mut catalog = wall(20);
        let first = catalog.query(&params(""));
        let second = catalog.query(&params(""));
        assert_ne!(first.query_id, second.query_id);

        assert!(catalog.ratios_slice(first.query_id, 0, 10).is_none(), "served a stale id");
        assert!(catalog.ratios_slice(0, 0, 10).is_none(), "served queryId 0");
        assert!(catalog.ratios_slice(second.query_id, 0, 10).is_some());
    }

    /// `extend` appends to the stored geometry too, or the rows a crawl added
    /// would have no shape and the wall would draw them as squares for good.
    #[test]
    fn extend_grows_the_stored_ratios_alongside_the_result() {
        let mut catalog = wall(10);
        let result = catalog.query(&params(""));
        let (_, total_before) = catalog.ratios_slice(result.query_id, 0, 1).expect("live");
        assert_eq!(total_before, 10);

        // Extending with nothing new to find must not change the geometry.
        let (count, added) = catalog.extend(&params(""), result.query_id).expect("live");
        assert_eq!(added.len(), 0, "nothing new to add");
        assert_eq!(count, 10);
        let (_, total_after) = catalog.ratios_slice(result.query_id, 0, 1).expect("live");
        assert_eq!(total_after, 10, "geometry changed without rows changing");
    }
}

/*
 * HIDING AND DELETING ARE DIFFERENT PROMISES.
 *
 * The adult switch hides: rows stay and come back intact. `purge` deletes. The
 * trap that these tests exist for is the interaction between the two — `rank`
 * appends `nsfw:false` to every query while the switch is off, so a `purge` of
 * `nsfw:true` that went through the ordinary gate would match nothing and
 * report success over a catalogue that is 80% adult.
 */
#[cfg(test)]
mod purge_tests {
    use super::*;

    fn params(q: &str) -> QueryParams {
        serde_json::from_value(serde_json::json!({ "q": q })).unwrap()
    }

    fn mixed() -> Catalog {
        let make = |source: &str, title: &str, nsfw: bool| {
            let mut it = crate::scrape::normalize(
                source,
                title,
                title,
                &format!("https://x.test/{title}.jpg"),
                "",
                "",
                1600,
                900,
                Vec::new(),
            );
            it.nsfw = nsfw;
            it
        };
        let items = vec![
            make("wallhaven", "hillside", false),
            make("wallhaven", "harbour", false),
            make("rule34video", "adultone", true),
            make("gelbooru", "adulttwo", true),
        ];
        let text = serde_json::to_string(&serde_json::json!({ "items": items })).unwrap();
        Catalog::from_fixture(&text).expect("fixture")
    }

    /*
     * THE ONE THAT MATTERS.
     *
     * With the switch off, `nsfw:true` is rewritten to match nothing — so this
     * asserts the gate is lifted for the match and the adult rows actually go.
     * Without the lift the purge returns Ok(0) and looks like it worked.
     */
    #[test]
    fn purging_adult_rows_works_while_the_adult_switch_is_off() {
        let mut catalog = mixed();
        catalog.set_show_adult(false);
        assert_eq!(catalog.query(&params("nsfw:true")).count, 0, "gate is on for reading");

        let gone = catalog.purge(&params("nsfw:true")).expect("purge");
        assert_eq!(gone.len(), 2, "both adult rows deleted");

        catalog.set_show_adult(true);
        assert_eq!(
            catalog.query(&params("")).count,
            2,
            "only the two safe rows remain, even with the switch back on"
        );
    }

    /// The switch must be exactly as it was afterwards — a purge that leaves the
    /// gate open is the setting turning itself back on.
    #[test]
    fn the_adult_switch_is_left_exactly_as_it_was() {
        for start in [true, false] {
            let mut catalog = mixed();
            catalog.set_show_adult(start);
            let _ = catalog.purge(&params("source:wallhaven")).expect("purge");
            assert_eq!(catalog.show_adult(), start, "purge changed the switch");
        }
    }

    /// A purge takes a query, so it is not only for adult rows.
    #[test]
    fn a_purge_can_be_any_query_not_just_adult() {
        let mut catalog = mixed();
        let gone = catalog.purge(&params("source:wallhaven")).expect("purge");
        assert_eq!(gone.len(), 2);
        catalog.set_show_adult(true);
        let rows = catalog.find(&params(""), 0, 50).1;
        assert!(rows.iter().all(|i| i.source != "wallhaven"), "wallhaven rows survived");
        assert_eq!(rows.len(), 2, "the adult rows were not touched");
    }

    /// Matching nothing is success with nothing done, not an error — the
    /// settings panel offers the button whether or not anything matches.
    #[test]
    fn a_query_that_matches_nothing_deletes_nothing() {
        let mut catalog = mixed();
        let gone = catalog.purge(&params("source:nosuchsource")).expect("purge");
        assert!(gone.is_empty());
        catalog.set_show_adult(true);
        assert_eq!(catalog.query(&params("")).count, 4, "nothing else went with it");
    }

    /*
     * DUPLICATES ARE DELETED TOO.
     *
     * `rank` collapses copies of one picture so a wall does not show it eight
     * times. Matching that collapsed list means every copy but one survives the
     * delete — and they are exactly the rows a user purging adult content would
     * be most surprised to find still there.
     *
     * Caught by running it for real: 46,344 adult rows, 46,327 deleted, 17 left.
     */
    #[test]
    fn duplicate_rows_are_purged_rather_than_collapsed_away() {
        let make = |id: &str, phash: &str| {
            let mut it = crate::scrape::normalize(
                "rule34video",
                id,
                id,
                &format!("https://x.test/{id}.jpg"),
                "",
                "",
                1600,
                900,
                Vec::new(),
            );
            it.nsfw = true;
            it.phash = phash.to_string();
            it
        };
        // Three rows that are the same picture as far as the wall is concerned.
        let items = vec![
            make("one", "ffffffffffffffff"),
            make("two", "ffffffffffffffff"),
            make("three", "ffffffffffffffff"),
        ];
        let text = serde_json::to_string(&serde_json::json!({ "items": items })).unwrap();
        let mut catalog = Catalog::from_fixture(&text).expect("fixture");
        catalog.set_show_adult(true);

        // The wall sees one of them…
        assert_eq!(catalog.query(&params("")).count, 1, "dedupe is on for reading");

        // …and the purge has to see all three.
        let gone = catalog.purge(&params("nsfw:true")).expect("purge");
        assert_eq!(gone.len(), 3, "a collapsed duplicate survived the purge");
        assert_eq!(catalog.query(&params("")).count, 0, "rows left behind");
    }

    /// The open result is dropped, or a page of it hands back ids whose rows
    /// have just been deleted.
    #[test]
    fn the_open_result_is_dropped_so_no_page_can_name_a_deleted_row() {
        let mut catalog = mixed();
        catalog.set_show_adult(true);
        let before = catalog.query(&params(""));
        assert_eq!(before.count, 4);

        catalog.purge(&params("nsfw:true")).expect("purge");
        assert!(
            catalog.page(before.query_id, 0, 50).is_none(),
            "a page of the pre-purge result was still served"
        );
    }
}

/*
 * THE SWEEP HAS TO MOVE FORWARD.
 *
 * `unhashed` reads a window of the backlog in the same order every round, so a
 * row it cannot hash came back every time and was tried again. Measured over
 * ten rounds of 200 before this existed: 37, 26, 23, 17, 14, 13, 10, 11, 8, 7
 * hashed while failures climbed 163 → 193 — the sweep converging on exactly the
 * rows it could never do. After: 903 hashed over the same ten rounds instead of
 * 215, and no decay.
 */
#[cfg(test)]
mod hash_backlog_tests {
    use super::*;

    fn unhashed_catalog(n: usize) -> Catalog {
        let items: Vec<_> = (0..n)
            .map(|i| {
                crate::scrape::normalize(
                    "wallhaven",
                    &format!("row{i}"),
                    &format!("row{i}"),
                    &format!("https://x.test/row{i}.jpg"),
                    "",
                    "",
                    1600,
                    900,
                    Vec::new(),
                )
            })
            .collect();
        let text = serde_json::to_string(&serde_json::json!({ "items": items })).unwrap();
        Catalog::from_fixture(&text).expect("fixture")
    }

    /// Nothing is hashed, so every row is work.
    #[test]
    fn every_unhashed_row_is_offered() {
        let catalog = unhashed_catalog(10);
        assert_eq!(catalog.unhashed(50).len(), 10);
    }

    /// The one that stops the grind: a row written off is not offered again.
    #[test]
    fn a_row_that_cannot_be_hashed_is_not_offered_again() {
        let mut catalog = unhashed_catalog(10);
        let first = catalog.unhashed(50);
        assert_eq!(first.len(), 10);

        let written_off = first[0].0.clone();
        catalog.skip_hashing(&written_off);

        let second = catalog.unhashed(50);
        assert_eq!(second.len(), 9, "the batch did not move on");
        assert!(
            !second.iter().any(|(id, _, _)| id == &written_off),
            "a row with nothing to hash was offered a second time"
        );
    }

    /// Writing one off must not take the rest with it.
    #[test]
    fn writing_one_off_leaves_the_others_alone() {
        let mut catalog = unhashed_catalog(6);
        let ids: Vec<String> = catalog.unhashed(50).into_iter().map(|(id, _, _)| id).collect();
        catalog.skip_hashing(&ids[2]);
        let left: Vec<String> = catalog.unhashed(50).into_iter().map(|(id, _, _)| id).collect();
        for id in ids.iter().filter(|i| *i != &ids[2]) {
            assert!(left.contains(id), "{id} went missing with the skipped one");
        }
    }
}

/*
 * `extend` LOOKS ONLY AT WHAT A CRAWL TOUCHED — AND MUST STILL SEE ALL OF IT.
 *
 * The case a rowid watermark would get wrong is the second test: a row the
 * catalogue already held that starts matching because a search taught it the
 * words that fetched it.
 */
#[cfg(test)]
mod extend_tests {
    use super::*;

    fn params(q: &str) -> QueryParams {
        serde_json::from_value(serde_json::json!({ "q": q })).unwrap()
    }

    fn row(id: &str, tags: &[&str]) -> Item {
        crate::scrape::normalize(
            "wallhaven",
            id,
            id,
            &format!("https://x.test/{id}.jpg"),
            "",
            "",
            1920,
            1080,
            tags.iter().map(|t| t.to_string()).collect(),
        )
    }

    fn catalogue(name: &str) -> Catalog {
        let path = std::env::temp_dir().join(format!("quarry-extend-{name}-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        Catalog::open(&path, || Ok(r#"{"items":[]}"#.to_string())).expect("catalogue")
    }

    #[test]
    fn a_new_matching_row_is_appended_and_a_non_matching_one_is_not() {
        let mut catalog = catalogue("new");
        catalog.add(vec![row("a", &["forest"]), row("b", &["city"])]);
        let result = catalog.query(&params("forest"));
        assert_eq!(result.count, 1);

        catalog.add(vec![row("c", &["forest"]), row("d", &["desert"])]);
        let (count, added) = catalog.extend(&params("forest"), result.query_id).expect("live");
        assert_eq!((count, added.len()), (2, 1));

        // Nothing touched since: nothing to add, and no full re-rank needed.
        let (count, added) = catalog.extend(&params("forest"), result.query_id).expect("live");
        assert_eq!((count, added.len()), (2, 0));
    }

    #[test]
    fn a_known_row_that_learns_the_words_is_appended() {
        let mut catalog = catalogue("relearn");
        // Stored with no words, which is the row `merge_tags` teaches.
        catalog.add(vec![row("a", &["forest"]), row("b", &[])]);
        let result = catalog.query(&params("forest"));
        assert_eq!(result.count, 1);

        // "b" again, now fetched by a forest search: not new, but now a match.
        let (added_rows, known) = catalog.add(vec![row("b", &["forest"])]);
        assert_eq!((added_rows, known), (0, 1));
        let (count, added) = catalog.extend(&params("forest"), result.query_id).expect("live");
        assert_eq!((count, added.len()), (2, 1), "the re-tagged row was missed");
    }
}

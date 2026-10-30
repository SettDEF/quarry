//! The catalogue on disk.
//!
//! Until this existed the daemon held its rows in a `Vec` seeded from a
//! fixture, which meant every crawl was thrown away on restart: 2,620 items
//! became 137 again. Everything the app wants to remember — what it found, what
//! you hid, what it has already fetched — needs somewhere to live.
//!
//! **The database is the store of record; memory is the working set.** Rows are
//! written through on insert and read back once at startup, so queries stay in
//! Rust over an in-memory slice (fast, and the query language is already there)
//! while nothing is lost when the process stops. FTS5 is created and indexed
//! now so text search can move into SQL without a migration later.

use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};

use crate::protocol::Item;

pub struct Db {
    conn: Connection,
    pub path: PathBuf,
    /*
     * WHAT THE FILE HAS DONE TO US, REMEMBERED.
     *
     * Half the readers in here answer an unreadable catalogue with an empty
     * list, because a filter panel wants rows and not a Result. That is fine
     * until the file is damaged, and then every one of them says "nothing" —
     * which is how a wrecked search index spent a day looking like an empty
     * library with 15,000 pictures in it.
     *
     * So they say so HERE on the way past. The daemon reads this latch when it
     * answers, and a client that gets no rows can tell the difference between
     * a catalogue with nothing in it and a catalogue it could not read.
     */
    damage: std::cell::RefCell<Option<String>>,
}

/// Bumped when the schema changes; `migrate` walks from whatever is on disk.
/*
 * Bumped when the schema changes.
 *
 * Version 3 exists because two changes independently claimed version 2 — a
 * `sample` column and the collection tables — so a database that had taken one
 * of them refused the other, silently, and the tables simply were not there.
 * Every statement in `migrate` is `IF NOT EXISTS` or tolerates a duplicate, so
 * re-running it is safe; the number only has to move.
 *
 * Version 10 is `crawl_cursor`. It is also the reminder of what forgetting
 * this costs: the table was added with the number left at 9, `migrate`
 * returned early on every existing database, and the daemon then failed every
 * read and write of a table that simply was not there — on a fresh database it
 * worked perfectly.
 */
const SCHEMA_VERSION: i64 = 14;   // v12 the `deal` index; v13 refiles video; v14 history context

/// The searchable blob for one row: everything a person would type looking
/// for it.
///
/// With one addition — words are also indexed with a leading number stripped.
/// Booru tags are written `1girl`, `2boys`, `4koma`, and FTS5 matches from the
/// start of a word, so "girl" found 754 rows of 31,964 where a substring scan
/// found 11,102. The tokenizer is not wrong; the token simply is not the word
/// anyone types. Indexing both costs a few bytes a row and returns the other
/// ten thousand.
fn index_text(item: &Item) -> String {
    fts_row_text(&item.title, &item.slug, &item.source, &item.author, &item.tags)
}

/// The searchable text for a row, from its parts — so a reindex after a tag
/// merge builds the same string an insert does.
fn fts_row_text(title: &str, slug: &str, source: &str, author: &str, tags: &[String]) -> String {
    let mut text =
        format!("{} {} {} {} {}", title, slug.replace('-', " "), source, author, tags.join(" "));

    let mut extra = String::new();
    for word in text.split_whitespace() {
        let stripped = word.trim_start_matches(|c: char| c.is_ascii_digit());
        // Only when stripping leaves a word behind: "4k" must not become "k",
        // and "2024" must not become nothing.
        if stripped.len() != word.len() && stripped.len() > 2 {
            extra.push(' ');
            extra.push_str(stripped);
        }
    }
    text.push_str(&extra);
    text
}

impl Db {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        let path = path.as_ref().to_path_buf();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("catalogue directory: {e}"))?;
        }

        let conn = Connection::open(&path).map_err(|e| format!("open {}: {e}", path.display()))?;

        /*
         * WAL so a crawl writing rows never blocks a query reading them.
         *
         * `synchronous = FULL`, not NORMAL, and the reason is on this machine's
         * disk. NORMAL does not fsync the write-ahead log at each commit: a
         * killed PROCESS still costs only the last transaction, which is what
         * the old comment here claimed, but a machine that goes down takes
         * whatever the kernel had not yet flushed. After one unclean reboot the
         * catalogue came back with b-tree cells pointing at pages 4219-4223 of
         * a file that was 3149 pages long — a tree referring to the far side of
         * a truncation — and 15,000 rows plus every board and collection went
         * with it. That is the second time it happened here.
         *
         * Rows are inserted in batched transactions, so this costs one fsync
         * per batch rather than per row; a crawl is bounded by the network by
         * three orders of magnitude before it is bounded by that.
         *
         * The first thing that touches the file is a pragma, so this is also
         * where a wrecked one announces itself — long before any query runs.
         */
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = FULL;
             PRAGMA foreign_keys = ON;",
        )
        .map_err(|e| Self::classify(&e.to_string(), "pragmas"))?;

        /*
         * IS IT A DATABASE AT ALL?
         *
         * SQLite opens a file lazily, so a wrecked one opens fine and then
         * answers "file is not a database" to every query — which is a daemon
         * reporting zero rows for ever while the crawler happily writes into
         * nothing. Measured on this machine: a 362 MB catalogue whose first
         * page had been zeroed. One cheap read here turns that into a fact the
         * caller can act on.
         */
        if let Err(e) = conn.pragma_query_value(None, "schema_version", |row| row.get::<_, i64>(0)) {
            return Err(Self::classify(&e.to_string(), "open"));
        }

        /*
         * …AND IS IT A WHOLE ONE?
         *
         * The check above only catches a file wrecked at page one. The damage
         * that actually turned up next was LOCAL: the catalogue opened, served
         * queries, and looked healthy, while one table's b-tree pointed off the
         * end of the file. Everything that touched it — the whole source and
         * kind tally the navigation rail is built from — quietly answered
         * nothing, so the app showed 15,000 pictures under an empty rail and
         * had no way to say why.
         *
         * `quick_check` reads the b-trees without the full row-by-row pass, and
         * one report is enough: the caller's answer to any damage is the same.
         */
        match conn.query_row("PRAGMA quick_check(1)", [], |row| row.get::<_, String>(0)) {
            Ok(answer) if answer != "ok" => {
                return Err(format!("corrupt: {}", answer.trim()));
            }
            Err(e) => return Err(Self::classify(&e.to_string(), "quick_check")),
            _ => {}
        }

        let db = Db { conn, path, damage: std::cell::RefCell::new(None) };
        db.migrate()?;
        Ok(db)
    }

    /*
     * THE PART THAT CANNOT BE FETCHED AGAIN.
     *
     * Rows are a cache of public sources and re-crawl in an afternoon. What
     * you chose — collections, boards and their placements, what is in each
     * slot — exists nowhere else, and it is a few kilobytes. So it is exported
     * beside the database on every change, and read back when a fresh database
     * is created. A catalogue can be lost; a board should not be.
     */
    pub fn export_user_data(&self) -> Result<String, String> {
        let rows = |sql: &str| -> Result<Vec<serde_json::Value>, String> {
            let mut stmt = self.conn.prepare(sql).map_err(|e| e.to_string())?;
            let count = stmt.column_count();
            let names: Vec<String> = (0..count)
                .map(|i| stmt.column_name(i).unwrap_or("?").to_string())
                .collect();
            let out = stmt
                .query_map([], |row| {
                    let mut obj = serde_json::Map::new();
                    for (i, name) in names.iter().enumerate() {
                        let value = match row.get_ref(i)? {
                            rusqlite::types::ValueRef::Null => serde_json::Value::Null,
                            rusqlite::types::ValueRef::Integer(v) => serde_json::json!(v),
                            rusqlite::types::ValueRef::Real(v) => serde_json::json!(v),
                            rusqlite::types::ValueRef::Text(v) => {
                                serde_json::json!(String::from_utf8_lossy(v))
                            }
                            rusqlite::types::ValueRef::Blob(_) => serde_json::Value::Null,
                        };
                        obj.insert(name.clone(), value);
                    }
                    Ok(serde_json::Value::Object(obj))
                })
                .map_err(|e| e.to_string())?
                .filter_map(|r| r.ok())
                .collect();
            Ok(out)
        };

        let blob = serde_json::json!({
            "version": 1,
            "collection": rows("SELECT name, created FROM collection")?,
            "collection_item": rows("SELECT collection, item, added FROM collection_item")?,
            "board": rows("SELECT name, created, view_x, view_y, view_z FROM board")?,
            "board_item": rows("SELECT board, item, x, y, w, h, angle, hflip, vflip, z, sharp, added FROM board_item")?,
            "board_container": rows("SELECT board, id, x, y, w, h, label, tint FROM board_container")?,
            "slot": rows("SELECT target, item, path, applied, at FROM slot")?,
        });
        serde_json::to_string_pretty(&blob).map_err(|e| e.to_string())
    }

    /// Put an export back. Existing rows win, so this can never undo a choice
    /// made since the backup was written.
    pub fn import_user_data(&self, json: &str) -> Result<usize, String> {
        let blob: serde_json::Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
        let mut put = 0usize;
        let mut table = |name: &str, columns: &[&str]| -> Result<(), String> {
            let Some(rows) = blob.get(name).and_then(|v| v.as_array()) else { return Ok(()) };
            let marks = columns.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
            let sql = format!("INSERT OR IGNORE INTO {name} ({}) VALUES ({marks})", columns.join(", "));
            for row in rows {
                let values: Vec<rusqlite::types::Value> = columns
                    .iter()
                    .map(|c| match row.get(*c) {
                        Some(serde_json::Value::String(s)) => rusqlite::types::Value::Text(s.clone()),
                        Some(serde_json::Value::Number(n)) if n.is_i64() => rusqlite::types::Value::Integer(n.as_i64().unwrap_or(0)),
                        Some(serde_json::Value::Number(n)) => rusqlite::types::Value::Real(n.as_f64().unwrap_or(0.0)),
                        _ => rusqlite::types::Value::Null,
                    })
                    .collect();
                if self.conn.execute(&sql, rusqlite::params_from_iter(values)).unwrap_or(0) > 0 {
                    put += 1;
                }
            }
            Ok(())
        };
        table("collection", &["name", "created"])?;
        table("board", &["name", "created", "view_x", "view_y", "view_z"])?;
        table("collection_item", &["collection", "item", "added"])?;
        table("board_item", &["board", "item", "x", "y", "w", "h", "angle", "hflip", "vflip", "z", "sharp", "added"])?;
        table("board_container", &["board", "id", "x", "y", "w", "h", "label", "tint"])?;
        table("slot", &["target", "item", "path", "applied", "at"])?;
        Ok(put)
    }

    /// A file that is not a database is a different kind of failure from a
    /// file that will not open: one is recoverable by starting again, and the
    /// caller can only tell them apart if this says so.
    /// Latch a failure if it is the catalogue's fault rather than the query's.
    /// First one wins: what broke first is the useful one.
    fn note(&self, text: &str) {
        if !Self::looks_corrupt(text) {
            return;
        }
        let mut slot = self.damage.borrow_mut();
        if slot.is_none() {
            eprintln!("[quarryd] the catalogue is damaged: {text}");
            *slot = Some(text.to_string());
        }
    }

    /// What the catalogue has failed with, if it has. `None` is healthy.
    pub fn damage(&self) -> Option<String> {
        self.damage.borrow().clone()
    }

    fn looks_corrupt(text: &str) -> bool {
        text.contains("not a database") || text.contains("malformed") || text.contains("file is encrypted")
    }

    fn classify(text: &str, what: &str) -> String {
        if Self::looks_corrupt(text) {
            format!("corrupt: {text}")
        } else {
            format!("{what}: {text}")
        }
    }

    fn migrate(&self) -> Result<(), String> {
        let current: i64 = self
            .conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(|e| format!("user_version: {e}"))?;

        if current >= SCHEMA_VERSION {
            return Ok(());
        }

        // Every statement is `IF NOT EXISTS`, so a database at version 1 gains
        // the new tables and keeps its rows — a migration that dropped and
        // recreated would throw away exactly what this file exists to keep.

        self.conn
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS item (
                    id         TEXT PRIMARY KEY,
                    source     TEXT NOT NULL,
                    source_id  TEXT NOT NULL,
                    family     TEXT NOT NULL,
                    kind       TEXT NOT NULL,
                    title      TEXT NOT NULL DEFAULT '',
                    slug       TEXT NOT NULL DEFAULT '',
                    url        TEXT NOT NULL,
                    thumb      TEXT NOT NULL DEFAULT '',
                    sample     TEXT NOT NULL DEFAULT '',
                    page_url   TEXT NOT NULL DEFAULT '',
                    ext        TEXT NOT NULL DEFAULT '',
                    w          INTEGER NOT NULL DEFAULT 0,
                    h          INTEGER NOT NULL DEFAULT 0,
                    ratio      REAL    NOT NULL DEFAULT 1.0,
                    bytes      INTEGER NOT NULL DEFAULT 0,
                    animated   INTEGER NOT NULL DEFAULT 0,
                    duration   REAL    NOT NULL DEFAULT 0,
                    tintable   INTEGER NOT NULL DEFAULT 0,
                    nsfw       INTEGER NOT NULL DEFAULT 0,
                    author     TEXT NOT NULL DEFAULT '',
                    license    TEXT NOT NULL DEFAULT '',
                    tags       TEXT NOT NULL DEFAULT '[]',
                    added_at   INTEGER NOT NULL DEFAULT 0,
                    phash      TEXT NOT NULL DEFAULT '',
                    dominant   TEXT NOT NULL DEFAULT '',
                    -- Where the row falls in the default deal; see `deal_of`.
                    deal       INTEGER NOT NULL DEFAULT 0
                );

                -- The columns a query filters on most, and the one it sorts by.
                CREATE INDEX IF NOT EXISTS item_kind    ON item(kind);
                CREATE INDEX IF NOT EXISTS item_source  ON item(source);
                CREATE INDEX IF NOT EXISTS item_family  ON item(family);
                CREATE INDEX IF NOT EXISTS item_added   ON item(added_at DESC);
                -- Duplicate detection, once phashes are stored for every row.
                CREATE INDEX IF NOT EXISTS item_phash   ON item(phash) WHERE phash <> '';

                -- Text search. `prefix` so as-you-type matches before a word is
                -- finished, which is what a query bar is.
                CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(
                    id UNINDEXED, text, tokenize = 'unicode61', prefix = '2 3'
                );

                /*
                 * HOW FAR EACH SOURCE HAS BEEN READ, FOR EACH QUERY.
                 *
                 * The crawl cursors lived in the daemon's memory, so every
                 * restart asked all thirty-odd sites for page one again — and
                 * page one is the page whose rows are already in the
                 * catalogue. Kept here, an endless scroll resumes where it
                 * stopped, however many restarts ago.
                 *
                 * `finished_at` is when a source said it had no more pages;
                 * the home feed starts such a source over once it has rested.
                 */
                /*
                 * What you did, so you can get back to it: searches run,
                 * pictures opened, files exported. Bounded by row count, not
                 * by time — a history that grows for ever is a second
                 * catalogue nobody asked for.
                 */
                CREATE TABLE IF NOT EXISTS history (
                    at    INTEGER NOT NULL,
                    kind  TEXT    NOT NULL,
                    value TEXT    NOT NULL DEFAULT '',
                    item  TEXT    NOT NULL DEFAULT '',
                    -- Where you were when you opened it, as a JSON object:
                    -- the query, the lens, the lens screen. Without it an
                    -- entry is an id and a timestamp, and going back to
                    -- something found inside a lens drops you in the
                    -- catalogue instead: the same picture, none of the place.
                    -- Opaque to the daemon on purpose -- what a place means
                    -- belongs to whatever drew the screen.
                    context TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS history_at ON history(at DESC);

                CREATE TABLE IF NOT EXISTS crawl_cursor (
                    source      TEXT    NOT NULL,
                    query       TEXT    NOT NULL,
                    page        INTEGER NOT NULL DEFAULT 0,
                    finished_at INTEGER NOT NULL DEFAULT 0,
                    updated_at  INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (source, query)
                );

                -- Rows you never want to see again. Separate from `item` so
                -- hiding survives a re-crawl that would otherwise re-add them.
                CREATE TABLE IF NOT EXISTS hidden (
                    id TEXT PRIMARY KEY,
                    at INTEGER NOT NULL,
                    -- 'user' (you chose this), 'fetch' (the picture would not
                    -- come), or 'legacy' (hidden before the two were told
                    -- apart). Only the first is safe from a cleanup.
                    reason TEXT NOT NULL DEFAULT 'legacy'
                );

                -- Collections: the difference between searching and keeping.
                --
                -- A membership row survives its item being re-crawled (the id
                -- is stable) and does not care whether the item is currently in
                -- the working set, so a collection is still yours after a
                -- catalogue rebuild.
                CREATE TABLE IF NOT EXISTS collection (
                    name    TEXT PRIMARY KEY,
                    created INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS collection_item (
                    collection TEXT NOT NULL,
                    item       TEXT NOT NULL,
                    added      INTEGER NOT NULL,
                    PRIMARY KEY (collection, item),
                    FOREIGN KEY (collection) REFERENCES collection(name) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS collection_item_item ON collection_item(item);

                -- What is currently in each slot, and what was before it.
                --
                -- Every visual thing about a machine comes from somewhere and
                -- gets replaced, and nothing keeps track: you cannot ask what
                -- your wallpaper is, let alone where it came from. One row per
                -- target holds the current answer; `applied` separates a file
                -- merely exported for a slot from one quarry actually put
                -- there, which it can only do for slots it can reach.
                CREATE TABLE IF NOT EXISTS slot (
                    target  TEXT PRIMARY KEY,
                    item    TEXT NOT NULL,
                    path    TEXT NOT NULL DEFAULT '',
                    applied INTEGER NOT NULL DEFAULT 0,
                    at      INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS slot_history (
                    target TEXT NOT NULL,
                    item   TEXT NOT NULL,
                    at     INTEGER NOT NULL
                );

                CREATE INDEX IF NOT EXISTS slot_item ON slot(item);
                CREATE INDEX IF NOT EXISTS slot_history_target ON slot_history(target, at DESC);

                -- A reference board: pictures ARRANGED, as opposed to merely
                -- kept.
                --
                -- A collection answers \"which of these do I want\"; a board
                -- answers \"how do they sit next to each other\", which is a
                -- different question and the one an artist actually asks of
                -- reference. Membership and geometry are separate tables for
                -- the same reason they are separate ideas: dropping a picture
                -- from a board must not disturb the collection it belongs to.
                --
                -- Geometry is stored in BOARD units, not pixels. The view has
                -- its own offset and scale, so a board laid out on a 4K screen
                -- opens correctly on a laptop instead of arriving off-canvas.
                --
                -- The item is a quarry id, not a path. This is the whole
                -- reason to build it here: RIA — the same idea, on files —
                -- links tags and boards to absolute paths and silently drops
                -- everything when a folder moves. An id survives a re-crawl,
                -- so a board survives the catalogue being rebuilt underneath
                -- it, exactly as `collection_item` above already does.
                CREATE TABLE IF NOT EXISTS board (
                    name    TEXT PRIMARY KEY,
                    created INTEGER NOT NULL,
                    view_x  REAL NOT NULL DEFAULT 0,
                    view_y  REAL NOT NULL DEFAULT 0,
                    view_z  REAL NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS board_item (
                    board  TEXT NOT NULL,
                    item   TEXT NOT NULL,
                    x      REAL NOT NULL DEFAULT 0,
                    y      REAL NOT NULL DEFAULT 0,
                    w      REAL NOT NULL DEFAULT 0,
                    h      REAL NOT NULL DEFAULT 0,
                    angle  REAL NOT NULL DEFAULT 0,
                    hflip  INTEGER NOT NULL DEFAULT 0,
                    vflip  INTEGER NOT NULL DEFAULT 0,
                    -- Which one is on top. RIA raises on select and never
                    -- persists it, so a saved board reopens in a different
                    -- stacking order than the one you arranged.
                    z      INTEGER NOT NULL DEFAULT 0,
                    -- Nearest-neighbour rather than linear, for pixel art —
                    -- the one per-image render setting RIA got right.
                    sharp  INTEGER NOT NULL DEFAULT 0,
                    added  INTEGER NOT NULL,
                    PRIMARY KEY (board, item),
                    FOREIGN KEY (board) REFERENCES board(name) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS board_item_item ON board_item(item);

                -- A CONTAINER: pictures that belong together, said out loud.
                --
                -- A board answers how these sit next to each other, and past a
                -- dozen pictures the answer is usually: in groups — three for
                -- the palette, four for the pose, two for the light.
                -- Without somewhere to say that, the grouping lives only in how
                -- close things happen to be, and the first time you move
                -- anything it is gone.
                --
                -- Its own table rather than a flag on `board_item`, because a
                -- container is not a picture: it has no catalogue id, it can be
                -- empty, and it outlives whatever is currently inside it.
                CREATE TABLE IF NOT EXISTS board_container (
                    board TEXT NOT NULL,
                    id    INTEGER NOT NULL,
                    x     REAL NOT NULL DEFAULT 0,
                    y     REAL NOT NULL DEFAULT 0,
                    w     REAL NOT NULL DEFAULT 600,
                    h     REAL NOT NULL DEFAULT 400,
                    label TEXT NOT NULL DEFAULT '',
                    tint  INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (board, id),
                    FOREIGN KEY (board) REFERENCES board(name) ON DELETE CASCADE
                );",
            )
            .map_err(|e| format!("schema: {e}"))?;

        /*
         * v8 -> v9: which container a placement belongs to, if any.
         *
         * An ALTER for the same reason every other migration here is one: the
         * CREATE above is a no-op on a table that already exists, so a board
         * made before containers would never gain the column. 0 means loose,
         * which is what every existing row is.
         */
        let _ = self
            .conn
            .execute("ALTER TABLE board_item ADD COLUMN container INTEGER NOT NULL DEFAULT 0", []);

        // v13 -> v14: history remembers where you were. Same tolerated-error
        // shape as the other ALTERs — a fresh database already has it.
        let _ = self
            .conn
            .execute("ALTER TABLE history ADD COLUMN context TEXT NOT NULL DEFAULT ''", []);

        // v1 -> v2: `sample` (mid-size URL) added to an item table that may
        // already exist without it. CREATE TABLE IF NOT EXISTS above is a
        // no-op on an existing table, so a real v1 database needs this ALTER
        // to pick the column up; a fresh database already has it from the
        // CREATE TABLE and SQLite rejects the duplicate, which is fine —
        // tolerate that specific error so re-running migrate is safe.
        if let Err(e) = self.conn.execute_batch("ALTER TABLE item ADD COLUMN sample TEXT NOT NULL DEFAULT ''") {
            if !e.to_string().contains("duplicate column name") {
                return Err(format!("migrate v2 (sample column): {e}"));
            }
        }
        // Existing rows keep an empty `sample` until re-crawled: `update()`
        // only rewrites enrichment fields (title/author/tags/phash/dominant),
        // not thumb/sample, so a row already in the catalogue will not pick
        // up a sample URL without a fresh crawl. Acceptable — the alternative
        // is refetching every source's item list just to backfill a string.

        // v6 -> v7: why a row was hidden.
        if let Err(e) = self
            .conn
            .execute_batch("ALTER TABLE hidden ADD COLUMN reason TEXT NOT NULL DEFAULT 'legacy'")
        {
            if !e.to_string().contains("duplicate column name") {
                return Err(format!("migrate v7 (hidden reason): {e}"));
            }
        }

        /*
         * THE DEAL, PRECOMPUTED.
         *
         * The default ordering is a deterministic shuffle so a launch does not
         * open on whatever the crawler added last. It was computed IN THE
         * ORDER BY — `(rowid * 2654435761) % 4294967296` — which no index can
         * satisfy, so every query sorted all 165,000 rows by a value it had to
         * calculate first. Measured with sqlite's own timer: 176 ms with that
         * ORDER BY against 72 ms without it, and it runs on every filter
         * change.
         *
         * Stored in a column with an index on it, the same order is an index
         * scan. The value is the same arithmetic, so the deal people are used
         * to does not change; new rows get theirs on insert (see `upsert`).
         */
        if let Err(e) = self.conn.execute_batch("ALTER TABLE item ADD COLUMN deal INTEGER NOT NULL DEFAULT 0")
        {
            if !e.to_string().contains("duplicate column name") {
                return Err(format!("migrate (deal column): {e}"));
            }
        }
        /*
         * A COVERING INDEX, NOT JUST AN INDEX.
         *
         * Indexing `deal` alone made things WORSE — 140 ms against 176 ms for
         * the computed sort, because ordering by the index then fetches every
         * row's other columns by rowid: 165,000 random lookups across a 168 MB
         * file instead of one sequential scan.
         *
         * Carrying the columns a query READS — and the three it FILTERS on —
         * means the index alone answers it, in order, touching the table not
         * at all. Both halves matter: with the read columns but not `kind`,
         * `kind:wallpaper` went back to fetching every candidate row by
         * rowid and took 296 ms.
         *
         * Measured with sqlite's own timer on this catalogue (165k rows):
         *
         *   everything      176 ms  ->  49 ms
         *   kind:wallpaper  296 ms  ->  60 ms
         *
         * It costs disk — the index carries a copy of those columns — which
         * is the trade this makes deliberately.
         */
        if let Err(e) = self.conn.execute_batch(
            "UPDATE item SET deal = (rowid * 2654435761) % 4294967296 WHERE deal = 0;
             CREATE INDEX IF NOT EXISTS item_deal_cover
                 ON item(deal, kind, family, source, id, ratio, dominant, phash);
             -- Video posters were filed by their SHAPE, so every clip in the
             -- catalogue is a \"wallpaper\" (see `infer_kind`). The rows are
             -- already here; re-crawling would not touch them.
             UPDATE item SET kind = 'video' WHERE family = 'video' AND kind <> 'video'",
        ) {
            return Err(format!("migrate (deal backfill): {e}"));
        }

        // v5 -> v6: `duration` for the video rows. Same ALTER-or-tolerate shape
        // as `sample` above — an existing item table does not gain a column
        // from `CREATE TABLE IF NOT EXISTS`.
        if let Err(e) =
            self.conn.execute_batch("ALTER TABLE item ADD COLUMN duration REAL NOT NULL DEFAULT 0")
        {
            if !e.to_string().contains("duplicate column name") {
                return Err(format!("migrate v6 (duration column): {e}"));
            }
        }

        // v4 -> v5: the text index is rebuilt.
        //
        // Two reasons at once. `index_text` now also indexes a booru tag under
        // its word (`1girl` -> `girl`), which an already-built index does not
        // know; and the index had drifted — 32,261 rows against 31,964 items,
        // the difference being rows deleted from `item` whose index entry
        // stayed. Rebuilding from the rows themselves fixes both, and is a few
        // seconds once rather than a correctness question forever.
        if current < 5 && current > 0 {
            match self.reindex() {
                Ok(rows) => eprintln!("[quarryd] rebuilt the text index over {rows} rows"),
                // A catalogue that will not reindex is still a usable
                // catalogue: searching is degraded, everything else works. It
                // must not refuse to start.
                Err(e) => eprintln!("[quarryd] text index rebuild failed, search may miss rows: {e}"),
            }
        }

        self.conn
            .execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))
            .map_err(|e| format!("user_version set: {e}"))?;
        Ok(())
    }

    /// Add tags a re-crawl learned to rows that already exist.
    ///
    /// `insert_many` skips a known id, which is right — a crawl must not
    /// trample enrichment. But it means a row can never gain the WORD that
    /// found it, and for a source that publishes no tags at all (wallhaven
    /// search results carry an id, a size and nothing else) that is the
    /// difference between a searchable catalogue and 3,354 rows nobody can
    /// ever find again.
    ///
    /// A union, never a replacement: what is already on the row was learned
    /// the same way and is just as true.
    pub fn merge_tags(&mut self, rows: &[(String, Vec<String>)]) -> Result<usize, String> {
        if rows.is_empty() {
            return Ok(0);
        }
        let tx = self.conn.transaction().map_err(|e| format!("merge tags: {e}"))?;
        let mut touched = 0usize;
        {
            // The other columns come too: the reindex below rebuilds the
            // row's search text, and rebuilding it from tags alone dropped the
            // title, slug and author out of the index.
            let mut read = tx
                .prepare("SELECT tags, title, slug, source, author FROM item WHERE id = ?1")
                .map_err(|e| format!("prepare read tags: {e}"))?;
            let mut write = tx
                .prepare("UPDATE item SET tags = ?2 WHERE id = ?1")
                .map_err(|e| format!("prepare write tags: {e}"))?;
            let mut reindex_del = tx
                .prepare("DELETE FROM item_fts WHERE id = ?1")
                .map_err(|e| format!("prepare fts delete: {e}"))?;
            let mut reindex_add = tx
                .prepare("INSERT INTO item_fts (id, text) VALUES (?1, ?2)")
                .map_err(|e| format!("prepare fts insert: {e}"))?;

            for (id, incoming) in rows {
                let stored: Option<(String, String, String, String, String)> = read
                    .query_row(params![id], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                    })
                    .optional()
                    .ok()
                    .flatten();
                let Some((stored, title, slug, source, author)) = stored else { continue };
                let mut tags: Vec<String> =
                    serde_json::from_str(&stored).unwrap_or_default();

                /*
                 * A ROW LEARNS ITS WORDS ONCE.
                 *
                 * Every crawl stamps the query onto the rows it touched (see
                 * tag_with_terms), and a site returns something for every
                 * query — so a row that stayed in the catalogue accumulated
                 * the words of every search that ever swept past it. This is
                 * for the row that arrived describing itself with nothing;
                 * once it has words, it has them.
                 */
                if !tags.is_empty() {
                    continue;
                }

                let before = tags.len();
                for tag in incoming {
                    if !tags.iter().any(|t| t.eq_ignore_ascii_case(tag)) {
                        tags.push(tag.clone());
                    }
                }
                if tags.len() == before {
                    continue;   // nothing new; leave the row and its index alone
                }

                let encoded = serde_json::to_string(&tags).unwrap_or_else(|_| "[]".into());
                write.execute(params![id, encoded]).map_err(|e| format!("write tags: {e}"))?;

                // The index has to learn the word too, or the row is still
                // unfindable by it — which was the entire point.
                let _ = reindex_del.execute(params![id]);
                let _ = reindex_add.execute(params![
                    id,
                    fts_row_text(&title, &slug, &source, &author, &tags)
                ]);
                touched += 1;
            }
        }
        tx.commit().map_err(|e| format!("commit tags: {e}"))?;
        Ok(touched)
    }

    /// How many rows are hidden, by why.
    pub fn hidden_tally(&self) -> Vec<(String, usize)> {
        let Ok(mut stmt) = self
            .conn
            .prepare("SELECT reason, COUNT(*) FROM hidden GROUP BY reason ORDER BY COUNT(*) DESC")
        else {
            return Vec::new();
        };
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as usize)))
            .map(|rows| rows.flatten().map(|(r, n)| (r, n)).collect())
            .unwrap_or_default()
    }

    /// Stop hiding rows that were hidden for a reason that has expired.
    ///
    /// It cannot bring the rows back by itself — `hide` deletes the record, so
    /// the catalogue no longer has one to restore. What it does is stop the
    /// row being *refused*: the next crawl that finds the picture adds it
    /// again, where before it was skipped forever.
    ///
    /// `user` is never touched. That is the whole reason the column exists.
    /// Forget the rows the daemon wrote off a while ago.
    ///
    /// A fetch that failed once is not a broken video: the host had a bad
    /// minute, the daemon was mid-restart, the network was out. Marking those
    /// forever means the row is dropped from every future crawl AND denied by
    /// every lookup, so a lens showing a live feed gets cards that can never
    /// fill — measured here: nine of twenty. A day is long enough that a
    /// genuinely dead file is not retried constantly, and short enough that a
    /// bad afternoon does not cost you the video permanently.
    /*
     * A row whose picture is at a SIGNED url gets the new one.
     *
     * Pornhub (and every CDN like it) hands out `…?hdnea=st=…~exp=…~hmac=…`,
     * good for about a day. The catalogue keeps what it first saw, so a row
     * crawled yesterday has a url that answers 403 today and its tile is empty
     * for good. A re-crawl sees the same row with a fresh signature, and this
     * is what lets that signature land — narrow on purpose: it touches nothing
     * but the url, and only for rows whose url is signed.
     */
    pub fn refresh_signed_url(&self, id: &str, url: &str) -> Result<bool, String> {
        self.conn
            .execute(
                "UPDATE item SET url = ?2
                 WHERE id = ?1 AND url <> ?2 AND (url LIKE '%hdnea=%' OR url LIKE '%~exp=%' OR url LIKE '%Expires=%')",
                params![id, url],
            )
            .map(|n| n > 0)
            .map_err(|e| format!("refresh url {id}: {e}"))
    }

    pub fn forgive_stale_fetch_failures(&self, older_than_secs: i64) -> Result<usize, String> {
        let cutoff = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
            - older_than_secs;
        self.conn
            .execute("DELETE FROM hidden WHERE reason = 'fetch' AND at < ?1", params![cutoff])
            .map_err(|e| format!("forgive: {e}"))
    }

    pub fn unhide(&self, scope: &str) -> Result<usize, String> {
        let sql = match scope {
            "fetch" => "DELETE FROM hidden WHERE reason = 'fetch'",
            "legacy" => "DELETE FROM hidden WHERE reason = 'legacy'",
            // Everything the daemon decided, and nothing the person did.
            "auto" => "DELETE FROM hidden WHERE reason IN ('fetch', 'legacy')",
            other => return Err(format!("unknown scope: {other}")),
        };
        self.conn.execute(sql, []).map(|n| n).map_err(|e| format!("unhide: {e}"))
    }

    /// Rebuild the whole text index from the rows it describes.
    fn reindex(&self) -> Result<usize, String> {
        self.conn
            .execute_batch("DELETE FROM item_fts")
            .map_err(|e| format!("clear index: {e}"))?;

        /*
         * In batches, not all at once.
         *
         * Reading every row to rebuild the index would allocate exactly the
         * working set this release removed — briefly, but at the one moment a
         * catalogue is at its largest and the process has just started. A
         * window of rows at a time keeps the peak flat whatever the catalogue
         * grows to.
         */
        let mut done = 0usize;
        let mut cursor = 0i64;
        loop {
            // Keyset, not OFFSET: `OFFSET n` re-walks the n rows before it, so
            // paging through the catalogue that way is quadratic in its size —
            // fine at 32k rows, minutes at half a million.
            let mut read = self
                .conn
                .prepare_cached(
                    "SELECT rowid, * FROM item WHERE rowid > ?1 ORDER BY rowid LIMIT 2000",
                )
                .map_err(|e| format!("prepare reindex: {e}"))?;
            let batch = read
                .query_map(params![cursor], |row| {
                    Ok((row.get::<_, i64>(0)?, Self::row_to_item(row)?))
                })
                .map_err(|e| format!("reindex: {e}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|e| format!("reindex rows: {e}"))?;
            if batch.is_empty() {
                break;
            }
            cursor = batch.last().map(|(rowid, _)| *rowid).unwrap_or(cursor);

            // One transaction per batch: a separate fsync per row is the
            // difference between a few seconds and a few minutes.
            self.conn.execute_batch("BEGIN").map_err(|e| format!("reindex begin: {e}"))?;
            {
                let mut write = self
                    .conn
                    .prepare_cached("INSERT INTO item_fts (id, text) VALUES (?1, ?2)")
                    .map_err(|e| format!("prepare index insert: {e}"))?;
                for (_, item) in &batch {
                    write
                        .execute(params![item.id, index_text(item)])
                        .map_err(|e| format!("index {}: {e}", item.id))?;
                }
            }
            self.conn.execute_batch("COMMIT").map_err(|e| format!("reindex commit: {e}"))?;
            done += batch.len();
        }

        Ok(done)
    }

    fn row_to_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<Item> {
        let tags: String = row.get("tags")?;
        Ok(Item {
            id: row.get("id")?,
            source: row.get("source")?,
            source_id: row.get("source_id")?,
            family: row.get("family")?,
            kind: row.get("kind")?,
            title: row.get("title")?,
            slug: row.get("slug")?,
            url: row.get("url")?,
            thumb: row.get("thumb")?,
            sample: row.get("sample")?,
            page_url: row.get("page_url")?,
            ext: row.get("ext")?,
            w: row.get("w")?,
            h: row.get("h")?,
            ratio: row.get("ratio")?,
            bytes: row.get("bytes")?,
            animated: row.get::<_, i64>("animated")? != 0,
            // `unwrap_or` rather than `?`: a database opened before the column
            // existed answers with an error here, and a still has no duration
            // anyway.
            duration: row.get("duration").unwrap_or(0.0),
            tintable: row.get::<_, i64>("tintable")? != 0,
            nsfw: row.get::<_, i64>("nsfw")? != 0,
            author: row.get("author")?,
            license: row.get("license")?,
            tags: serde_json::from_str(&tags).unwrap_or_default(),
            added_at: row.get("added_at")?,
            phash: row.get("phash")?,
            dominant: row.get("dominant")?,
            thumb_local: String::new(),
        })
    }

    /*
     * There is deliberately no `load_all`.
     *
     * There was: startup read every row into the working set, because the
     * query engine ran in Rust over a slice. It no longer does, and reading
     * the catalogue would now be work done for nobody — the largest allocation
     * the process made, growing with every crawl, to answer questions SQLite
     * answers next to its own index. `rows` and `records` are what replaced it:
     * three columns for a whole result, full records for one page.
     */

    /// Insert what is new. Returns how many rows were actually added — a crawl
    /// that returns the same page twice should say so rather than double-count.
    pub fn insert_many(&mut self, items: &[Item]) -> Result<usize, String> {
        let tx = self.conn.transaction().map_err(|e| format!("transaction: {e}"))?;
        let mut added = 0;

        {
            let mut insert = tx
                .prepare_cached(
                    /*
                     * `INSERT OR IGNORE` for a row that already exists, EXCEPT
                     * that a missing `sample` is filled in.
                     *
                     * Ignoring the whole row is right for everything a crawl
                     * re-reports — a row you already have should not have its
                     * enrichment (phash, dominant, tags) trampled by a fresh
                     * scrape that has none. But `sample` was added after this
                     * catalogue was built, so 32,222 of 32,241 rows have an
                     * empty one, and OR IGNORE meant re-crawling could never
                     * fill it: the mid-size URL would have reached 0.06% of the
                     * library and no more.
                     *
                     * Narrow on purpose: only when the stored value is empty and
                     * the incoming one is not. A row that already has a sample
                     * keeps it, and no other column is touched.
                     */
                    "INSERT INTO item (
                        id, source, source_id, family, kind, title, slug, url, thumb, sample,
                        page_url, ext, w, h, ratio, bytes, animated, tintable, nsfw,
                        author, license, tags, added_at, phash, dominant, duration, deal
                     ) VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                        ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27
                     )
                     ON CONFLICT(id) DO UPDATE SET
                        sample = CASE
                            WHEN item.sample = '' AND excluded.sample <> '' THEN excluded.sample
                            ELSE item.sample END,
                        /*
                         * AND WORDS, WHEN THE ROW HAS NONE.
                         *
                         * Same rule as `sample`, for the same reason: a
                         * mapping that was not there when a row was first
                         * crawled can never reach it otherwise. Pornhub's
                         * tags, performers and categories were unmapped for
                         * the life of the source, so a re-crawl reported all
                         * 30 rows as duplicates and kept their emptiness for
                         * ever. A row that already HAS words keeps them —
                         * this fills a gap, it does not overwrite.
                         */
                        tags = CASE
                            WHEN item.tags IN ('', '[]') AND excluded.tags NOT IN ('', '[]')
                            THEN excluded.tags ELSE item.tags END,
                        kind = CASE
                            -- A video filed by the shape of its poster; see
                            -- `infer_kind`.
                            WHEN item.family = 'video' AND item.kind <> 'video' THEN 'video'
                            ELSE item.kind END
                       /*
                        * ONLY WHEN THERE IS A GAP TO FILL.
                        *
                        * Without this the update always fires, so sqlite
                        * counts every re-crawled row as changed, and that
                        * count is what a crawl reports as newly added — so a
                        * re-crawl of thirty rows it already had would claim
                        * thirty new ones.
                        */
                       WHERE (item.sample = '' AND excluded.sample <> '')
                          OR (item.tags IN ('', '[]') AND excluded.tags NOT IN ('', '[]'))
                          OR (item.family = 'video' AND item.kind <> 'video')",
                )
                .map_err(|e| format!("prepare insert: {e}"))?;

            let mut index = tx
                .prepare_cached("INSERT INTO item_fts (id, text) VALUES (?1, ?2)")
                .map_err(|e| format!("prepare fts: {e}"))?;

            let mut hidden = tx
                .prepare_cached("SELECT 1 FROM hidden WHERE id = ?1")
                .map_err(|e| format!("prepare hidden: {e}"))?;

            for item in items {
                // A row you hid stays hidden through a re-crawl. A genuine
                // query error here must not read as "not hidden" — that
                // would resurrect a row the user removed on purpose.
                let is_hidden: Option<i64> = hidden
                    .query_row(params![item.id], |r| r.get(0))
                    .optional()
                    .map_err(|e| format!("hidden check {}: {e}", item.id))?;
                if is_hidden.is_some() {
                    continue;
                }

                let tags = serde_json::to_string(&item.tags).unwrap_or_else(|_| "[]".into());
                let changed = insert
                    .execute(params![
                        item.id, item.source, item.source_id, item.family, item.kind,
                        item.title, item.slug, item.url, item.thumb, item.sample, item.page_url,
                        item.ext, item.w, item.h, item.ratio, item.bytes,
                        item.animated as i64, item.tintable as i64, item.nsfw as i64,
                        item.author, item.license, tags, item.added_at, item.phash,
                        item.dominant,
                        item.duration,
                        // Where this row falls in the default deal. Computed
                        // here so the ORDER BY can be an index scan rather
                        // than a sort of the whole catalogue — see the `deal`
                        // migration. Hashed from the id, so a row lands in the
                        // same place every time the catalogue is rebuilt.
                        deal_of(&item.id),
                    ])
                    .map_err(|e| format!("insert {}: {e}", item.id))?;

                if changed > 0 {
                    added += 1;
                    let text = index_text(item);
                    let _ = index.execute(params![item.id, text]);
                }
            }
        }

        tx.commit().map_err(|e| format!("commit: {e}"))?;
        Ok(added)
    }

    /// Replace a row that has been enriched, keeping it searchable.
    pub fn update(&self, item: &Item) -> Result<(), String> {
        let tags = serde_json::to_string(&item.tags).unwrap_or_else(|_| "[]".into());
        self.conn
            .execute(
                "UPDATE item SET title = ?2, author = ?3, tags = ?4, phash = ?5, dominant = ?6,
                        duration = ?7, w = CASE WHEN ?8 > 0 THEN ?8 ELSE w END,
                        h = CASE WHEN ?9 > 0 THEN ?9 ELSE h END,
                        ratio = CASE WHEN ?8 > 0 AND ?9 > 0 THEN CAST(?8 AS REAL) / ?9 ELSE ratio END
                 WHERE id = ?1",
                params![
                    item.id, item.title, item.author, tags, item.phash, item.dominant,
                    item.duration, item.w, item.h
                ],
            )
            .map_err(|e| format!("update {}: {e}", item.id))?;

        let text = index_text(item);
        let _ = self.conn.execute("DELETE FROM item_fts WHERE id = ?1", params![item.id]);
        let _ = self
            .conn
            .execute("INSERT INTO item_fts (id, text) VALUES (?1, ?2)", params![item.id, text]);
        Ok(())
    }

    /*
     * HISTORY.
     *
     * `kind` is "search", "open" or "export"; `value` is the query or the
     * target; `item` is the row it happened to, when there is one. Repeating
     * something moves it up rather than adding a line.
     */
    pub fn history_add(
        &self,
        kind: &str,
        value: &str,
        item: &str,
        context: &str,
        cap: usize,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let _ = self.conn.execute(
            "DELETE FROM history WHERE kind = ?1 AND value = ?2 AND item = ?3",
            params![kind, value, item],
        );
        self.conn
            .execute(
                "INSERT INTO history (at, kind, value, item, context) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![now, kind, value, item, context],
            )
            .map_err(|e| format!("history: {e}"))?;
        // Trimmed here rather than on a timer: one delete per write keeps the
        // table at its cap without a sweep that has to find the table large.
        let _ = self.conn.execute(
            "DELETE FROM history WHERE rowid NOT IN
               (SELECT rowid FROM history ORDER BY at DESC, rowid DESC LIMIT ?1)",
            params![cap as i64],
        );
        Ok(())
    }

    /// Newest first. `kind` empty means every kind; `needle` filters `value`.
    pub fn history(
        &self,
        kind: &str,
        needle: &str,
        limit: usize,
    ) -> Vec<(i64, String, String, String, String)> {
        let sql = "SELECT at, kind, value, item, context FROM history
                   WHERE (?1 = '' OR kind = ?1) AND (?2 = '' OR value LIKE '%' || ?2 || '%')
                   -- rowid breaks the tie: several entries land in the same
                   -- second, and `at` alone then orders them arbitrarily.
                   ORDER BY at DESC, rowid DESC LIMIT ?3";
        let Ok(mut stmt) = self.conn.prepare(sql) else { return Vec::new() };
        stmt.query_map(params![kind, needle, limit as i64], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// Forget one kind, or everything when `kind` is empty.
    pub fn history_clear(&self, kind: &str) -> usize {
        self.conn
            .execute("DELETE FROM history WHERE (?1 = '' OR kind = ?1)", params![kind])
            .unwrap_or(0)
    }

    /// Every stored crawl cursor: (source, query, page, finished_at).
    ///
    /// Read once at startup; the daemon keeps them in memory afterwards and
    /// writes changes back at the end of each round.
    pub fn cursors(&self) -> Vec<(String, String, u32, i64)> {
        let Ok(mut stmt) = self
            .conn
            .prepare("SELECT source, query, page, finished_at FROM crawl_cursor")
        else {
            return Vec::new();
        };
        stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?.clamp(0, u32::MAX as i64) as u32,
                row.get::<_, i64>(3)?,
            ))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// Write a round's worth of cursors in one transaction — thirty sources a
    /// round, and one statement each would be thirty fsyncs.
    pub fn set_cursors(&self, cursors: &[(String, String, u32, i64)]) -> Result<(), String> {
        if cursors.is_empty() {
            return Ok(());
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.conn.execute_batch("BEGIN").map_err(|e| e.to_string())?;
        for (source, query, page, finished_at) in cursors {
            let written = self.conn.execute(
                "INSERT INTO crawl_cursor (source, query, page, finished_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(source, query) DO UPDATE SET
                   page = excluded.page,
                   finished_at = excluded.finished_at,
                   updated_at = excluded.updated_at",
                params![source, query, *page as i64, finished_at, now],
            );
            if let Err(e) = written {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(format!("cursor {source}/{query}: {e}"));
            }
        }
        self.conn.execute_batch("COMMIT").map_err(|e| e.to_string())
    }

    /// Forget every cursor for a query, so the next scroll starts from page one
    /// — what "search this again from the top" means.
    /*
     * EVERY CRAWLED ROW, GONE — AND NOTHING A PERSON MADE.
     *
     * `item` and its full-text index are rebuilt by browsing, and so are the
     * crawl cursors and the auto-hidden list: they are the daemon's own
     * workings. Boards, collections and history are NOT — they are what
     * somebody chose to keep, and a "start over" that quietly threw those away
     * would be a delete button nobody could trust. Their entries name rows that
     * are now gone, which reads as an empty slot rather than as a lie.
     *
     * VACUUM is the point of the exercise: without it SQLite keeps the pages
     * and the file does not shrink, so "delete the catalogue" would free no
     * disk at all — which on a full disk is the whole reason for pressing it.
     */
    pub fn empty_catalogue(&self) -> Result<u64, String> {
        let before: u64 = self
            .conn
            .query_row("SELECT count(*) FROM item", [], |row| row.get(0))
            .map_err(|e| format!("count: {e}"))?;
        self.conn
            .execute_batch(
                "DELETE FROM item;
                 DELETE FROM item_fts;
                 DELETE FROM hidden;
                 DELETE FROM crawl_cursor;",
            )
            .map_err(|e| format!("empty: {e}"))?;
        // Outside the batch: VACUUM cannot run inside a transaction.
        self.conn.execute_batch("VACUUM").map_err(|e| format!("vacuum: {e}"))?;
        Ok(before)
    }

    pub fn clear_cursors(&self, query: &str) {
        let _ = self.conn.execute("DELETE FROM crawl_cursor WHERE query = ?1", params![query]);
    }

    /// Hide a row for good.
    /// Hide a row, saying WHY.
    ///
    /// `user` means somebody chose this and it must never be undone by a
    /// cleanup. `fetch` means the daemon could not get the picture — a much
    /// weaker claim, and one that used to be indistinguishable from the first.
    /*
     * DELETE THESE ROWS, AND EVERY TRACE THE SCHEMA KEEPS OF THEM.
     *
     * `hide` and this are different promises. Hiding leaves the row and stops
     * answering with it, which is what the adult switch does and why turning it
     * back on costs nothing. This removes it, because "do not show me this" and
     * "do not keep this on my disk" are two different requests and only one of
     * them is satisfied by a filter.
     *
     * Every table that names an item is cleared too. A board or a collection
     * holding an id whose row is gone renders as a permanently empty tile —
     * the failure looks like a broken layout rather than like a deletion, so it
     * gets blamed on the board.
     *
     * In one transaction and in batches: 600k ids is a real delete, and a
     * half-applied one leaves the text index describing rows that no longer
     * exist, which makes every later search return ids that cannot be read.
     */
    /// What is on the disk, per source, with the adult rows COUNTED rather than
    /// filtered — this feeds the delete picker, which exists to remove exactly
    /// the rows every other query is hiding.
    pub fn stored_counts(&self) -> Vec<(String, usize, usize)> {
        let mut out = Vec::new();
        let Ok(mut q) = self.conn.prepare(
            "SELECT source, COUNT(*), SUM(nsfw = 1) FROM item GROUP BY source ORDER BY COUNT(*) DESC",
        ) else {
            return out;
        };
        let Ok(rows) = q.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)? as usize,
                r.get::<_, Option<i64>>(2)?.unwrap_or(0) as usize,
            ))
        }) else {
            return out;
        };
        for row in rows.flatten() {
            out.push(row);
        }
        out
    }

    pub fn purge(&self, ids: &[String]) -> Result<usize, String> {
        if ids.is_empty() {
            return Ok(0);
        }
        let tx = self
            .conn
            .unchecked_transaction()
            .map_err(|e| format!("purge transaction: {e}"))?;
        let mut removed = 0usize;

        /*
         * IN BATCHES, NOT ONE STATEMENT PER ID.
         *
         * The first version ran eight prepared deletes per id. Measured over a
         * real catalogue: 46,327 rows took 198 SECONDS — 4.3 ms a row, with the
         * window frozen for every one of them, and over three quarters of an
         * hour at the size this catalogue reached last week.
         *
         * SQLite's own limit on host parameters is 32,766 by default, so the
         * chunk stays well under it. One statement per chunk per table turns
         * roughly 370,000 statements into about 750.
         */
        const CHUNK: usize = 900;
        // Every table that names an item. A board or a collection holding an id
        // whose row is gone renders as a permanently empty tile — the failure
        // looks like a broken layout rather than like a deletion.
        const TABLES: [(&str, &str); 8] = [
            ("item", "id"),
            ("item_fts", "id"),
            ("hidden", "id"),
            ("collection_item", "item"),
            ("board_item", "item"),
            ("slot", "item"),
            ("slot_history", "item"),
            ("history", "item"),
        ];

        for chunk in ids.chunks(CHUNK) {
            let holders = std::iter::repeat("?").take(chunk.len()).collect::<Vec<_>>().join(",");
            for (table, column) in TABLES {
                let sql = format!("DELETE FROM {table} WHERE {column} IN ({holders})");
                let affected = tx
                    .execute(&sql, rusqlite::params_from_iter(chunk.iter()))
                    .map_err(|e| format!("purge from {table}: {e}"))?;
                // The item table's count is the answer; the rest are tidying,
                // and a row that was in no board legitimately deletes nothing.
                if table == "item" {
                    removed += affected;
                }
            }
        }

        tx.commit().map_err(|e| format!("purge commit: {e}"))?;
        Ok(removed)
    }

    pub fn hide(&self, id: &str, reason: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO hidden (id, at, reason) VALUES (?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET reason = excluded.reason
                   WHERE hidden.reason <> 'user'",
                params![id, now, reason],
            )
            .map_err(|e| format!("hide {id}: {e}"))?;
        self.conn
            .execute("DELETE FROM item WHERE id = ?1", params![id])
            .map_err(|e| format!("remove {id}: {e}"))?;
        let _ = self.conn.execute("DELETE FROM item_fts WHERE id = ?1", params![id]);
        Ok(())
    }

    /// An empty result here must not be read as "nothing is hidden": on a
    /// real query error that is exactly backwards, since it hands
    /// previously-hidden rows back into the catalogue. So the caller gets
    /// the error, not a Vec that looks the same as "no rows".
    pub fn hidden_ids(&self) -> Result<Vec<String>, String> {
        let mut stmt =
            self.conn.prepare("SELECT id FROM hidden").map_err(|e| format!("prepare hidden: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("hidden ids: {e}"))?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| format!("hidden ids: {e}"))
    }

    // ── slots: what is in use where ─────────────────────────────────────────

    /// Record that an item now occupies a target.
    ///
    /// `applied` is false for a plain export — the file exists, whether you
    /// pasted it into Steam is not knowable — and true when quarry put it
    /// somewhere itself, which today means the wallpaper.
    pub fn slot_set(&self, target: &str, item: &str, path: &str, applied: bool) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        // The outgoing occupant goes to history first, so "what did I have
        // before this?" is answerable.
        if let Ok(previous) = self.conn.query_row(
            "SELECT item FROM slot WHERE target = ?1",
            params![target],
            |row| row.get::<_, String>(0),
        ) {
            if previous != item {
                let _ = self.conn.execute(
                    "INSERT INTO slot_history (target, item, at) VALUES (?1, ?2, ?3)",
                    params![target, previous, now],
                );
            }
        }

        self.conn
            .execute(
                "INSERT INTO slot (target, item, path, applied, at) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(target) DO UPDATE SET
                    item = excluded.item, path = excluded.path,
                    applied = excluded.applied, at = excluded.at",
                params![target, item, path, applied as i64, now],
            )
            .map_err(|e| format!("slot {target}: {e}"))?;
        Ok(())
    }

    /// Everything currently in use, newest first.
    pub fn slots(&self) -> Vec<serde_json::Value> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT target, item, path, applied, at FROM slot ORDER BY at DESC",
        ) else {
            return Vec::new();
        };
        stmt.query_map([], |row| {
            Ok(serde_json::json!({
                "target": row.get::<_, String>(0)?,
                "item": row.get::<_, String>(1)?,
                "path": row.get::<_, String>(2)?,
                "applied": row.get::<_, i64>(3)? != 0,
                "at": row.get::<_, i64>(4)?,
            }))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// Which slots one item occupies — what a detail page shows as a badge.
    pub fn slots_of(&self, item: &str) -> Vec<String> {
        let Ok(mut stmt) = self.conn.prepare("SELECT target FROM slot WHERE item = ?1") else {
            return Vec::new();
        };
        stmt.query_map(params![item], |row| row.get::<_, String>(0))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    /// Ids currently in use anywhere, for `used:true`.
    pub fn slot_items(&self) -> Vec<String> {
        let Ok(mut stmt) = self.conn.prepare("SELECT DISTINCT item FROM slot") else {
            return Vec::new();
        };
        stmt.query_map([], |row| row.get::<_, String>(0))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    // ── boards ──────────────────────────────────────────────────────────────
    //
    // A collection is a set; a board is a set WITH A LAYOUT. Everything here
    // is keyed on the quarry item id, so a board survives the catalogue being
    // re-crawled underneath it.

    fn now() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }

    pub fn board_create(&self, name: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT OR IGNORE INTO board (name, created) VALUES (?1, ?2)",
                params![name, Self::now()],
            )
            .map_err(|e| format!("create board {name}: {e}"))?;
        Ok(())
    }

    /// Every board, with how many pictures are on it and where it was left.
    pub fn boards(&self) -> Vec<serde_json::Value> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT b.name, b.created, b.view_x, b.view_y, b.view_z,
                    (SELECT COUNT(*) FROM board_item i WHERE i.board = b.name)
             FROM board b ORDER BY b.name",
        ) else {
            return Vec::new();
        };
        stmt.query_map([], |row| {
            Ok(serde_json::json!({
                "name": row.get::<_, String>(0)?,
                "created": row.get::<_, i64>(1)?,
                "viewX": row.get::<_, f64>(2)?,
                "viewY": row.get::<_, f64>(3)?,
                "viewZ": row.get::<_, f64>(4)?,
                "items": row.get::<_, i64>(5)?,
            }))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// What is on one board, bottom to top. The z order is persisted, so a
    /// board reopens stacked the way it was arranged rather than in whatever
    /// order the rows happen to come back.
    pub fn board_items(&self, board: &str) -> Vec<serde_json::Value> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT item, x, y, w, h, angle, hflip, vflip, z, sharp, container
             FROM board_item WHERE board = ?1 ORDER BY z, added",
        ) else {
            return Vec::new();
        };
        stmt.query_map(params![board], |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "x": row.get::<_, f64>(1)?,
                "y": row.get::<_, f64>(2)?,
                "w": row.get::<_, f64>(3)?,
                "h": row.get::<_, f64>(4)?,
                "angle": row.get::<_, f64>(5)?,
                "hflip": row.get::<_, i64>(6)? != 0,
                "vflip": row.get::<_, i64>(7)? != 0,
                "z": row.get::<_, i64>(8)?,
                "sharp": row.get::<_, i64>(9)? != 0,
                "container": row.get::<_, i64>(10)?,
            }))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// Put a picture on a board, or move one already there.
    ///
    /// One call for both because the board does not care which it is: dragging
    /// something that is already placed and dropping something new are the same
    /// write, and splitting them would only invite the two to disagree.
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
        self.board_create(board)?;
        self.conn
            .execute(
                "INSERT INTO board_item (board, item, x, y, w, h, angle, hflip, vflip, z, sharp, container, added)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT(board, item) DO UPDATE SET
                    x = ?3, y = ?4, w = ?5, h = ?6, angle = ?7,
                    hflip = ?8, vflip = ?9, z = ?10, sharp = ?11, container = ?12",
                params![board, item, x, y, w, h, angle, hflip as i64, vflip as i64, z, sharp as i64, container, Self::now()],
            )
            .map_err(|e| format!("place {item} on {board}: {e}"))?;
        Ok(())
    }

    pub fn board_containers(&self, board: &str) -> Vec<serde_json::Value> {
        let Ok(mut stmt) = self
            .conn
            .prepare("SELECT id, x, y, w, h, label, tint FROM board_container WHERE board = ?1 ORDER BY id")
        else {
            return Vec::new();
        };
        stmt.query_map(params![board], |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, i64>(0)?,
                "x": row.get::<_, f64>(1)?,
                "y": row.get::<_, f64>(2)?,
                "w": row.get::<_, f64>(3)?,
                "h": row.get::<_, f64>(4)?,
                "label": row.get::<_, String>(5)?,
                "tint": row.get::<_, i64>(6)?,
            }))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// Make or move a container. `id` 0 asks for the next free one and the new
    /// id comes back, so the caller never has to guess.
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
        self.board_create(board)?;
        let id = if id > 0 {
            id
        } else {
            self.conn
                .query_row(
                    "SELECT COALESCE(MAX(id), 0) + 1 FROM board_container WHERE board = ?1",
                    params![board],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1)
        };
        self.conn
            .execute(
                "INSERT INTO board_container (board, id, x, y, w, h, label, tint)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(board, id) DO UPDATE SET
                    x = ?3, y = ?4, w = ?5, h = ?6, label = ?7, tint = ?8",
                params![board, id, x, y, w, h, label, tint],
            )
            .map_err(|e| format!("container on {board}: {e}"))?;
        Ok(id)
    }

    /*
     * Remove a container. Its pictures are set loose, NOT deleted.
     *
     * A container is a way of saying these belong together, and changing your
     * mind about that must not cost you the pictures — which is exactly what
     * an ON DELETE CASCADE here would have done.
     */
    pub fn board_container_delete(&self, board: &str, id: i64) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE board_item SET container = 0 WHERE board = ?1 AND container = ?2",
                params![board, id],
            )
            .map_err(|e| format!("free container {id}: {e}"))?;
        self.conn
            .execute(
                "DELETE FROM board_container WHERE board = ?1 AND id = ?2",
                params![board, id],
            )
            .map_err(|e| format!("delete container {id}: {e}"))?;
        Ok(())
    }

    pub fn board_remove(&self, board: &str, item: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM board_item WHERE board = ?1 AND item = ?2",
                params![board, item],
            )
            .map_err(|e| format!("remove {item} from {board}: {e}"))?;
        Ok(())
    }

    /// Where the board was left — the offset and zoom, so it reopens where you
    /// were rather than at the origin.
    pub fn board_view(&self, board: &str, x: f64, y: f64, z: f64) -> Result<(), String> {
        self.board_create(board)?;
        self.conn
            .execute(
                "UPDATE board SET view_x = ?2, view_y = ?3, view_z = ?4 WHERE name = ?1",
                params![board, x, y, z],
            )
            .map_err(|e| format!("view {board}: {e}"))?;
        Ok(())
    }

    /*
     * Rename a board, taking its contents with it.
     *
     * Two statements rather than one because the cascade works the wrong way
     * round for this: renaming the parent row would DELETE every placement
     * before the children could be pointed at the new name. So the new name is
     * made first, the items are moved onto it, and only then does the old row
     * go — by which point the cascade has nothing left to take.
     */
    pub fn board_rename(&self, from: &str, to: &str) -> Result<(), String> {
        if from == to || to.trim().is_empty() {
            return Ok(());
        }
        self.board_create(to)?;
        self.conn
            .execute(
                "UPDATE OR REPLACE board_item SET board = ?2 WHERE board = ?1",
                params![from, to],
            )
            .map_err(|e| format!("rename {from}: {e}"))?;
        self.conn
            .execute(
                "UPDATE OR REPLACE board_container SET board = ?2 WHERE board = ?1",
                params![from, to],
            )
            .map_err(|e| format!("rename containers {from}: {e}"))?;
        // Carry the view across too, or a renamed board reopens at the origin.
        self.conn
            .execute(
                "UPDATE board SET view_x = (SELECT view_x FROM board WHERE name = ?1),
                                  view_y = (SELECT view_y FROM board WHERE name = ?1),
                                  view_z = (SELECT view_z FROM board WHERE name = ?1)
                 WHERE name = ?2",
                params![from, to],
            )
            .map_err(|e| format!("rename view {from}: {e}"))?;
        self.conn
            .execute("DELETE FROM board WHERE name = ?1", params![from])
            .map_err(|e| format!("drop {from}: {e}"))?;
        Ok(())
    }

    /// Delete a board. `board_item` goes with it by ON DELETE CASCADE — which
    /// only fires because `Db::open` turns foreign keys on.
    pub fn board_delete(&self, board: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM board WHERE name = ?1", params![board])
            .map_err(|e| format!("delete board {board}: {e}"))?;
        Ok(())
    }

    // ── collections ─────────────────────────────────────────────────────────

    pub fn collection_create(&self, name: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.conn
            .execute("INSERT OR IGNORE INTO collection (name, created) VALUES (?1, ?2)", params![name, now])
            .map_err(|e| format!("create collection {name}: {e}"))?;
        Ok(())
    }

    /// Add or remove one item. Creating the collection on demand is deliberate:
    /// "put this in Wallpapers" should not require making Wallpapers first.
    pub fn collection_set(&self, name: &str, item: &str, member: bool) -> Result<(), String> {
        if member {
            self.collection_create(name)?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            self.conn
                .execute(
                    "INSERT OR IGNORE INTO collection_item (collection, item, added) VALUES (?1, ?2, ?3)",
                    params![name, item, now],
                )
                .map_err(|e| format!("add to {name}: {e}"))?;
        } else {
            self.conn
                .execute(
                    "DELETE FROM collection_item WHERE collection = ?1 AND item = ?2",
                    params![name, item],
                )
                .map_err(|e| format!("remove from {name}: {e}"))?;
        }
        Ok(())
    }

    /// Every collection with how much is in it.
    pub fn collections(&self) -> Vec<(String, usize)> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT c.name, COUNT(ci.item)
             FROM collection c
             LEFT JOIN collection_item ci ON ci.collection = c.name
             GROUP BY c.name
             ORDER BY c.name",
        ) else {
            return Vec::new();
        };
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as usize)))
            .map(|rows| rows.flatten().map(|(n, c)| (n, c)).collect())
            .unwrap_or_default()
    }

    /// The ids in one collection, most recently added first.
    pub fn collection_members(&self, name: &str) -> Vec<String> {
        let Ok(mut stmt) = self
            .conn
            .prepare("SELECT item FROM collection_item WHERE collection = ?1 ORDER BY added DESC")
        else {
            return Vec::new();
        };
        stmt.query_map(params![name], |row| row.get::<_, String>(0))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    /// Which collections one item belongs to — what a detail page shows.
    pub fn collections_of(&self, item: &str) -> Vec<String> {
        let Ok(mut stmt) = self
            .conn
            .prepare("SELECT collection FROM collection_item WHERE item = ?1 ORDER BY collection")
        else {
            return Vec::new();
        };
        stmt.query_map(params![item], |row| row.get::<_, String>(0))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    pub fn count(&self) -> usize {
        self.conn
            .query_row("SELECT COUNT(*) FROM item", [], |row| row.get::<_, i64>(0))
            .unwrap_or(0) as usize
    }

    /// Rows a query can return, which is what "items" means to a person: a row
    /// you hid is still on disk (that is how it stays hidden through a
    /// re-crawl) but it is not part of your library any more.
    pub fn visible_count(&self) -> usize {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM item WHERE id NOT IN (SELECT id FROM hidden)",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as usize
    }

    /// The catalogue's real size on disk.
    ///
    /// In WAL mode most of a recent crawl is still in `-wal` — reporting only
    /// the main file said 4 KB while half a megabyte of rows sat next to it.
    pub fn size_bytes(&self) -> u64 {
        let main = std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0);
        let wal = std::fs::metadata(format!("{}-wal", self.path.display()))
            .map(|m| m.len())
            .unwrap_or(0);
        main + wal
    }

    /// Fold the write-ahead log back into the database.
    ///
    /// Called when the daemon goes idle so a machine that loses power keeps
    /// what was found, rather than relying on the next write to checkpoint.
    pub fn checkpoint(&self) {
        if let Err(e) = self.conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)") {
            // Silence here would break the promise in the doc comment above:
            // a checkpoint that never lands means a crash can lose more than
            // "the last transaction".
            eprintln!("[quarryd] wal checkpoint failed: {e}");
        }
    }
}

#[cfg(test)]
mod backfill_tests {
    use super::*;
    use crate::scrape::normalize;

    /*
     * Damage that does NOT stop the file opening.
     *
     * The header check catches a catalogue wrecked at page one. This is the
     * other kind, and the kind that actually turned up: a file that opens,
     * answers most queries, and has one tree pointing off the end of itself —
     * on this machine that silently emptied the whole source and kind tally
     * behind the navigation rail while 15,000 rows still showed.
     */
    #[test]
    fn a_locally_damaged_catalogue_is_reported_as_corrupt() {
        use std::io::{Seek, SeekFrom, Write};

        let path = temp_db("localdamage");
        {
            let mut db = Db::open(&path).unwrap();
            // Enough rows to push the b-tree past a single page.
            for n in 0..400 {
                let it = normalize(
                    "danbooru",
                    &n.to_string(),
                    &format!("row {n}"),
                    &format!("https://x/{n}.jpg"),
                    &format!("https://x/{n}t.jpg"),
                    "",
                    8,
                    8,
                    vec!["tag".into()],
                );
                db.insert_many(&[it]).unwrap();
            }
            db.checkpoint();
        }

        // Scribble over an interior page, leaving page one — the part every
        // "is this a database" check reads — perfectly intact.
        let page = 4096u64;
        let mut f = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        f.seek(SeekFrom::Start(page * 3)).unwrap();
        f.write_all(&[0x5a; 2048]).unwrap();
        f.sync_all().unwrap();
        drop(f);

        let err = match Db::open(&path) {
            Ok(_) => panic!("a damaged catalogue must not open as healthy"),
            Err(e) => e,
        };
        assert!(err.starts_with("corrupt:"), "expected a corrupt verdict, got: {err}");

        let _ = std::fs::remove_file(&path);
    }

    fn temp_db(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "quarry-db-{tag}-{}.sqlite",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn typed_words_are_ranked_by_how_well_they_match() {
        let path = temp_db("rank");
        let mut db = Db::open(&path).expect("open");
        let mut rows = Vec::new();
        for (id, title) in [
            ("1", "a cat on a wall"),
            ("2", "cat cat cat"),
            ("3", "a dog"),
            ("4", "cat photograph, printed large, with a long description that dilutes the match"),
        ] {
            let mut item = normalize("s", id, title, "https://x/o.jpg", "https://x/t.jpg", "", 100, 50, vec![]);
            item.kind = "photo".into();
            rows.push(item);
        }
        db.insert_many(&rows).expect("add");

        let ranked = db.rows(&db.compile(&crate::query::parse("cat"))).expect("query");
        let ids: Vec<&str> = ranked.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids.len(), 3, "the dog does not match");
        assert_eq!(ids[0], "s:2", "the strongest match leads, not the newest row");

        // A filter-only query keeps its own order and still runs.
        let plain = db.rows(&db.compile(&crate::query::parse("kind:photo"))).expect("query");
        assert_eq!(plain.len(), 4);

        // Words plus a filter: both the join and the filter's parameters bind.
        let mixed = db.rows(&db.compile(&crate::query::parse("cat kind:photo"))).expect("query");
        assert_eq!(mixed.len(), 3);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn history_keeps_the_newest_and_moves_repeats_up() {
        let path = temp_db("history");
        let db = Db::open(&path).expect("open");
        db.history_add("search", "cats", "", "", 10).unwrap();
        // An opened row records where it was opened from — see the `context`
        // column. Stored verbatim and handed back verbatim; the daemon never
        // reads into it.
        db.history_add("open", "", "danbooru:1", r#"{"lens":"reddit"}"#, 10).unwrap();
        db.history_add("search", "dogs", "", "", 10).unwrap();
        // The same search again is one line, not two, and it comes back first.
        db.history_add("search", "cats", "", "", 10).unwrap();

        let all = db.history("", "", 50);
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].2, "cats", "a repeat moves up rather than duplicating");
        let opened = db.history("open", "", 50);
        assert_eq!(opened.len(), 1);
        assert_eq!(opened[0].4, r#"{"lens":"reddit"}"#, "the place comes back with it");

        let searches = db.history("search", "", 50);
        assert_eq!(searches.len(), 2);
        assert_eq!(db.history("search", "dog", 50).len(), 1, "text narrows it");

        // The cap drops the oldest, whatever kind it is.
        for n in 0..12 {
            db.history_add("search", &format!("q{n}"), "", "", 5).unwrap();
        }
        assert_eq!(db.history("", "", 50).len(), 5);

        assert_eq!(db.history_clear("search"), 5);
        assert!(db.history("", "", 50).is_empty());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn crawl_cursors_survive_a_restart() {
        let path = temp_db("cursors");
        {
            let db = Db::open(&path).expect("open");
            assert!(db.cursors().is_empty());
            db.set_cursors(&[
                ("wallhaven".into(), "cat".into(), 12, 0),
                ("danbooru".into(), "cat".into(), 4_294_967_295, 1_700_000_000),
            ])
            .expect("write");
            // A second write is an update, not a second row.
            db.set_cursors(&[("wallhaven".into(), "cat".into(), 20, 0)]).expect("update");
        }

        // A new process, the way a restart sees it.
        let db = Db::open(&path).expect("reopen");
        let mut stored = db.cursors();
        stored.sort();
        assert_eq!(
            stored,
            vec![
                ("danbooru".to_string(), "cat".to_string(), u32::MAX, 1_700_000_000),
                ("wallhaven".to_string(), "cat".to_string(), 20, 0),
            ]
        );

        db.clear_cursors("cat");
        assert!(db.cursors().is_empty(), "starting a query again forgets where it got to");
        let _ = std::fs::remove_file(&path);
    }

    fn row(sample: &str) -> Item {
        let mut it = normalize("s", "1", "t", "https://x/orig.jpg", "https://x/thumb.jpg", "", 100, 50, vec![]);
        it.sample = sample.to_string();
        it
    }

    // ── the two engines must agree ──────────────────────────────────────

    /// A catalogue with enough variety for the predicates to bite.
    fn varied() -> Vec<Item> {
        let mut rows = Vec::new();
        let specs: [(&str, &str, &str, u32, u32, &str, &str); 6] = [
            ("wallhaven", "wallpaper", "raster", 1920, 1080, "Sunset Over Kyoto", "city,sunset"),
            ("wallhaven", "wallpaper", "raster", 3840, 2160, "Mountain Dawn", "nature"),
            ("danbooru", "avatar", "raster", 512, 512, "kitsune mask", "anime,mask"),
            ("iconify", "icon", "vector", 24, 24, "arrow left", "ui"),
            ("pfps_gg", "avatar", "raster", 184, 184, "sunset girl", "anime,sunset"),
            ("deviantart", "wallpaper", "raster", 2560, 1080, "Ultrawide City", "city"),
        ];
        for (n, (source, kind, family, w, h, title, tags)) in specs.into_iter().enumerate() {
            let tags: Vec<String> = tags.split(',').map(str::to_string).collect();
            let mut it = normalize(
                source,
                &format!("{n}"),
                title,
                &format!("https://x/{n}.jpg"),
                &format!("https://x/{n}-t.jpg"),
                "",
                w,
                h,
                tags,
            );
            it.kind = kind.into();
            it.family = family.into();
            it.bytes = (n as u64 + 1) * 100_000;
            it.animated = n == 2;
            it.added_at = 1_700_000_000 + n as i64;
            rows.push(it);
        }
        rows
    }

    /// What SQL says, and what the Rust matcher says, for the same query.
    fn both_ways(db: &Db, rows: &[Item], q: &str) -> (Vec<String>, Vec<String>) {
        let parsed = crate::query::parse(q);

        let mut from_sql: Vec<String> =
            db.rows(&db.compile(&parsed)).expect(q).into_iter().map(|r| r.id).collect();

        let mut from_rust: Vec<String> = rows
            .iter()
            .filter(|i| crate::query::matches(i, &parsed))
            .map(|i| i.id.clone())
            .collect();

        from_sql.sort();
        from_rust.sort();
        (from_sql, from_rust)
    }

    /// Every predicate that has a column, compared engine to engine.
    ///
    /// This is the test that makes the move to SQL safe to keep making: a
    /// predicate translated wrongly does not error, it answers a slightly
    /// different question, and only a comparison against the original engine
    /// notices.
    #[test]
    fn sql_and_the_matcher_answer_the_same_query() {
        let path = temp_db("agree");
        let mut db = Db::open(&path).unwrap();
        let rows = varied();
        db.insert_many(&rows).unwrap();

        for q in [
            "",
            "kind:wallpaper",
            "kind:avatar,icon",
            "-kind:wallpaper",
            "source:wallhaven",
            "family:vector",
            "vector",
            "-vector",
            "animated",
            "-animated",
            "tag:sunset",
            "tag:city,ui",
            "-tag:anime",
            "w>=1920",
            "w>1920",
            "h<=512",
            "h<512",
            "bytes>200000",
            "ratio:16:9",
            "-ratio:16:9",
            "ratio>=2",
            "added>=1700000003",
            "kind:wallpaper w>=2560",
            "source:danbooru -animated",
            "kind:avatar tag:anime w>=200",
        ] {
            let (sql, rust) = both_ways(&db, &rows, q);
            assert_eq!(sql, rust, "engines disagree on `{q}`");
        }
        let _ = std::fs::remove_file(&path);
    }

    /// Free text is the one place they are allowed to differ, so the difference
    /// is pinned down rather than left to be discovered.
    ///
    /// The matcher looks for a substring anywhere; FTS5 matches from the start
    /// of a word. "sunset" finds the same rows either way — but "unset" finds
    /// them only in Rust, and that is the deliberate trade for an index.
    #[test]
    fn free_text_matches_from_the_start_of_a_word() {
        let path = temp_db("fts");
        let mut db = Db::open(&path).unwrap();
        let rows = varied();
        db.insert_many(&rows).unwrap();

        let (sql, rust) = both_ways(&db, &rows, "sunset");
        assert_eq!(sql, rust, "a whole word must agree");
        assert_eq!(sql.len(), 2, "the Kyoto sunset and the sunset girl");

        let (sql, rust) = both_ways(&db, &rows, "suns");
        assert_eq!(sql, rust, "a word prefix must agree");

        let (sql, rust) = both_ways(&db, &rows, "unset");
        assert!(sql.is_empty(), "mid-word is not indexed");
        assert_eq!(rust.len(), 2, "...and the matcher still finds both");

        let _ = std::fs::remove_file(&path);
    }

    /// sort:random in SQL: one seed, one order; another seed, another order.
    #[test]
    fn random_order_follows_the_seed() {
        let path = temp_db("seeded");
        let mut db = Db::open(&path).unwrap();
        let rows: Vec<_> = (0..60)
            .map(|n| normalize("wallhaven", &n.to_string(), "x", &format!("https://x/{n}.jpg"), "", "", 8, 8, vec![]))
            .collect();
        db.insert_many(&rows).unwrap();
        let order = |q: &str| -> Vec<String> {
            db.rows(&db.compile(&crate::query::parse(q))).unwrap().into_iter().map(|r| r.id).collect()
        };
        assert_eq!(order("sort:random seed:7"), order("sort:random seed:7"));
        assert_ne!(order("sort:random seed:7"), order("sort:random seed:8"));
        // No seed: a fresh shuffle each time, so the first row is not always the same.
        let firsts: std::collections::HashSet<String> = (0..6).map(|_| order("sort:random")[0].clone()).collect();
        assert!(firsts.len() > 1, "six unseeded queries started on the same row");
    }

    /// A search bar receives whatever someone types, and FTS5 has a grammar.
    #[test]
    fn punctuation_in_a_search_does_not_break_the_query() {
        let path = temp_db("ftsquote");
        let mut db = Db::open(&path).unwrap();
        let mut it = normalize("wallhaven", "9", "Cherry Blossom Road", "https://x/9.jpg", "https://x/9t.jpg", "", 8, 8, vec![]);
        it.kind = "wallpaper".into();
        db.insert_many(&[it]).unwrap();

        // None of these may error; the query must simply answer.
        for q in ["cherry", "\"cherry blossom\"", "AND", "NEAR", "OR blossom", "a*b", "c:d", "e-f", "((", "^", "\"\""] {
            let parsed = crate::query::parse(q);
            db.rows(&db.compile(&parsed)).unwrap_or_else(|e| panic!("`{q}` broke the query: {e}"));
        }

        let hits = |q: &str| db.rows(&db.compile(&crate::query::parse(q))).unwrap().len();
        assert_eq!(hits("\"cherry blossom\""), 1, "a phrase matches in order");
        assert_eq!(hits("\"blossom cherry\""), 0, "...and only in order");

        let _ = std::fs::remove_file(&path);
    }

    /// The tag people type is not always the token the tagger wrote.
    #[test]
    fn a_booru_tag_is_indexed_under_its_word_too() {
        let path = temp_db("boorutag");
        let mut db = Db::open(&path).unwrap();

        let mut it = normalize("danbooru", "9", "", "https://x/9.jpg", "https://x/9t.jpg", "", 8, 8, vec!["1girl".into(), "4koma".into()]);
        it.kind = "avatar".into();
        db.insert_many(&[it]).unwrap();

        let found = |q: &str| db.rows(&db.compile(&crate::query::parse(q))).unwrap().len();
        assert_eq!(found("1girl"), 1, "the tag as written still matches");
        assert_eq!(found("girl"), 1, "and so does the word inside it");
        assert_eq!(found("koma"), 1);
        assert_eq!(found("boy"), 0, "without matching everything");

        let _ = std::fs::remove_file(&path);
    }

    /// Opening an older catalogue rebuilds the index rather than leaving it
    /// half-built — the migration is the only thing that can fix rows that
    /// were indexed before `index_text` learned this.
    #[test]
    fn opening_an_older_catalogue_rebuilds_the_index() {
        let path = temp_db("reindex");
        {
            let mut db = Db::open(&path).unwrap();
            let mut it = normalize("danbooru", "9", "", "https://x/9.jpg", "https://x/9t.jpg", "", 8, 8, vec!["1girl".into()]);
            it.kind = "avatar".into();
            db.insert_many(&[it]).unwrap();

            // Put it back the way a v4 catalogue looks: indexed without the
            // extra word, and stamped with the older version.
            db.conn.execute("DELETE FROM item_fts", []).unwrap();
            db.conn
                .execute("INSERT INTO item_fts (id, text) VALUES ('danbooru:9', '1girl')", [])
                .unwrap();
            db.conn.execute_batch("PRAGMA user_version = 4").unwrap();
            assert_eq!(
                db.rows(&db.compile(&crate::query::parse("girl"))).unwrap().len(),
                0,
                "the old index cannot answer this"
            );
        }

        let db = Db::open(&path).unwrap();
        assert_eq!(
            db.rows(&db.compile(&crate::query::parse("girl"))).unwrap().len(),
            1,
            "opening it again must rebuild the index"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// Sorting moved into SQL too, and `ORDER BY` is easy to get backwards.
    #[test]
    fn sorts_order_the_way_they_are_named() {
        let path = temp_db("sorts");
        let mut db = Db::open(&path).unwrap();
        db.insert_many(&varied()).unwrap();

        let ids = |q: &str| -> Vec<String> {
            let parsed = crate::query::parse(q);
            db.rows(&db.compile(&parsed)).unwrap().into_iter().map(|r| r.id).collect()
        };

        let newest = ids("sort:new");
        let oldest_last = ids("sort:new").last().cloned().unwrap();
        assert_ne!(newest[0], oldest_last);

        let large = ids("sort:large");
        assert_eq!(large[0], ids("w>=3840")[0], "the 4K row is the largest");

        let wide = ids("sort:wide");
        assert_eq!(wide[0], ids("ratio>=2")[0], "the ultrawide row is the widest");

        // Random is stable for one seed (a result keeps its seed, so paging does
        // not reshuffle); without `seed:N` each query draws its own.
        assert_eq!(ids("sort:random seed:3"), ids("sort:random seed:3"));

        let _ = std::fs::remove_file(&path);
    }

    /// Hidden rows are excluded by the query itself, not filtered afterwards.
    #[test]
    fn hiding_a_row_removes_it_from_results() {
        let path = temp_db("hidesql");
        let mut db = Db::open(&path).unwrap();
        let rows = varied();
        db.insert_many(&rows).unwrap();

        let before = db.rows(&db.compile(&crate::query::parse(""))).unwrap().len();
        db.hide(&rows[0].id, "user").unwrap();
        let after = db.rows(&db.compile(&crate::query::parse(""))).unwrap().len();
        assert_eq!(after, before - 1);

        let _ = std::fs::remove_file(&path);
    }

    /// Hiding is two different decisions wearing one name, and a cleanup must
    /// only ever undo one of them.
    #[test]
    fn a_deliberate_hide_survives_a_cleanup() {
        let path = temp_db("unhide");
        let mut db = Db::open(&path).unwrap();
        let rows = varied();
        db.insert_many(&rows).unwrap();

        db.hide(&rows[0].id, "user").unwrap();
        db.hide(&rows[1].id, "fetch").unwrap();
        db.hide(&rows[2].id, "fetch").unwrap();
        // A row hidden before the reasons were told apart.
        db.conn
            .execute("UPDATE hidden SET reason = 'legacy' WHERE id = ?1", params![rows[3].id])
            .ok();
        db.hide(&rows[3].id, "fetch").unwrap();
        db.conn
            .execute("UPDATE hidden SET reason = 'legacy' WHERE id = ?1", params![rows[3].id])
            .unwrap();

        assert_eq!(db.unhide("fetch").unwrap(), 2, "the two fetch failures");
        assert_eq!(db.unhide("legacy").unwrap(), 1, "and the old one, separately");

        let left = db.hidden_tally();
        assert_eq!(left, vec![("user".to_string(), 1)], "what a person chose stays: {left:?}");

        // A re-crawl must still be refused for the user's row, and allowed for
        // the others — which is the whole point of forgetting them.
        assert_eq!(db.insert_many(&rows).unwrap(), 3, "the three restored rows come back");

        let _ = std::fs::remove_file(&path);
    }

    /// A fetch failure must never overwrite a deliberate hide.
    #[test]
    fn a_fetch_failure_cannot_downgrade_a_deliberate_hide() {
        let path = temp_db("downgrade");
        let mut db = Db::open(&path).unwrap();
        let rows = varied();
        db.insert_many(&rows).unwrap();

        db.hide(&rows[0].id, "user").unwrap();
        db.hide(&rows[0].id, "fetch").unwrap();
        assert_eq!(db.hidden_tally(), vec![("user".to_string(), 1)]);
        assert_eq!(db.unhide("auto").unwrap(), 0, "a cleanup must not reach it");

        let _ = std::fs::remove_file(&path);
    }

    /// A page is a window into a sorted result, so the records must come back
    /// in the order they were asked for — `IN (...)` does not promise that.
    #[test]
    fn records_come_back_in_the_order_requested() {
        let path = temp_db("order");
        let mut db = Db::open(&path).unwrap();
        let rows = varied();
        db.insert_many(&rows).unwrap();

        let wanted: Vec<String> =
            vec![rows[3].id.clone(), rows[0].id.clone(), rows[5].id.clone()];
        let got: Vec<String> = db.records(&wanted).unwrap().into_iter().map(|i| i.id).collect();
        assert_eq!(got, wanted);

        let _ = std::fs::remove_file(&path);
    }

    /// The one row these tests write, read back the way the daemon reads it.
    fn stored(db: &Db) -> Item {
        db.item_by_id(&row("").id).expect("the row these tests just wrote")
    }

    /// `sample` was added after this catalogue existed, so almost every row has
    /// an empty one. Under plain `INSERT OR IGNORE` a re-crawl could never fill
    /// it in and the feature would reach a rounding error's worth of the library.
    #[test]
    fn a_recrawl_backfills_a_missing_sample() {
        let path = temp_db("backfill");
        let mut db = Db::open(&path).unwrap();
        db.insert_many(&[row("")]).unwrap();
        assert_eq!(stored(&db).sample, "", "starts without one");

        db.insert_many(&[row("https://x/sample.jpg")]).unwrap();
        assert_eq!(
            stored(&db).sample,
            "https://x/sample.jpg",
            "a re-crawl carrying a sample must fill in the empty one"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// The other half: this must stay a NARROW exception to OR IGNORE. A crawl
    /// re-reporting a row it has already seen must not trample enrichment that
    /// only the daemon computes, nor overwrite a sample already stored.
    #[test]
    fn a_recrawl_does_not_trample_what_it_does_not_know() {
        let path = temp_db("notrample");
        let mut db = Db::open(&path).unwrap();

        let mut first = row("https://x/sample-one.jpg");
        first.title = "the real title".into();
        db.insert_many(&[first]).unwrap();

        let mut enriched = stored(&db);
        enriched.phash = "1234abcd".to_string();
        db.update(&enriched).unwrap();

        // A fresh scrape: no phash, a different sample, an empty title.
        let mut again = row("https://x/sample-two.jpg");
        again.title = String::new();
        db.insert_many(&[again]).unwrap();

        let stored = stored(&db);
        assert_eq!(stored.phash, "1234abcd", "enrichment must survive a re-crawl");
        assert_eq!(stored.title, "the real title", "title must survive a re-crawl");
        assert_eq!(
            stored.sample, "https://x/sample-one.jpg",
            "an existing sample must not be replaced"
        );
        let _ = std::fs::remove_file(&path);
    }
}

// ── querying ────────────────────────────────────────────────────────────────

/// One matching row, as cheaply as it can be described.
///
/// A query answers with these rather than with records: an id, the ratio the
/// masonry needs, and the colour the `color:` predicate needs. Three small
/// columns for 137k rows is a few megabytes where the records would be
/// hundreds — the same split the wire protocol makes, made one layer lower.
pub struct Row {
    pub id: String,
    pub ratio: f64,
    pub dominant: String,
    pub phash: String,
    /// Which source it came from — what the default ordering deals out.
    pub source: String,
}

const ROW_COLUMNS: &str = "SELECT id, ratio, dominant, phash, source FROM item";

/*
 * A ROW'S PLACE IN THE DEFAULT DEAL.
 *
 * The catalogue is not shown newest-first — the crawler adds rows constantly,
 * and newest-first meant every launch opened on a wall nobody had seen. The
 * order is a deterministic shuffle instead, and this is the number it shuffles
 * by: FNV-1a over the id, truncated to the same 32-bit range the original
 * `(rowid * 2654435761) % 4294967296` used.
 *
 * From the ID rather than the rowid so it can be written at INSERT, before a
 * rowid exists — and so the same catalogue rebuilt from scratch deals the same
 * way.
 */
fn deal_of(id: &str) -> i64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in id.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    (hash % 4_294_967_296) as i64
}

/// The aspect ratio, however the row happens to record it.
///
/// Older rows have a `ratio` of 0 and only their dimensions, and the Rust
/// matcher has always fallen back to `w/h` for those. SQL has to fall back the
/// same way or `ratio:16:9` would answer differently depending on which engine
/// ran it.
/// One search term, as FTS5 query syntax.
///
/// Quoted, always. What the user typed is data, not query syntax: a term
/// containing `-`, `:`, `*` or a quote is FTS5 grammar unquoted, and a query
/// that fails to parse takes the whole search with it — `AND`, `NEAR`, and a
/// bare `"` are all things people type into a search bar. Quoting also makes
/// `"cherry blossom"` a phrase rather than two words that happen to co-occur,
/// which is what quoting it meant. The trailing `*` keeps it matching as you
/// type, before the last word is finished.
fn fts_term(text: &str) -> String {
    format!("\"{}\"*", text.replace('"', "\"\""))
}

const RATIO: &str = "(CASE WHEN ratio > 0 THEN ratio WHEN h > 0 THEN CAST(w AS REAL) / h ELSE 1.0 END)";

/// The SQL a parsed query compiles to.
pub struct Compiled {
    pub sql: String,
    pub params: Vec<Box<dyn rusqlite::ToSql + Send>>,
}

impl Db {
    /// Compile the parts of a query SQLite can answer.
    ///
    /// Everything that is a column becomes a `WHERE` clause and free text goes
    /// through FTS5. Two predicates stay behind: colour distance (arithmetic
    /// over a hex string) and collection membership (a different table the
    /// catalogue owns), and both are applied by the caller over the rows this
    /// returns — which is why `dominant` comes back with them.
    pub fn compile(&self, query: &crate::query::Query) -> Compiled {
        self.compile_within(query, None)
    }

    /// `compile`, limited to the ids in `within` when given.
    pub fn compile_within(&self, query: &crate::query::Query, within: Option<&[String]>) -> Compiled {
        use crate::query::{Cmp, Term};

        // `item.id`, not `id`: the relevance path joins the text index below,
        // and both tables have that column.
        let mut sql = format!(
            "SELECT item.id, item.ratio, item.dominant, item.phash, item.source FROM item{{FTS}} \
             WHERE item.id NOT IN (SELECT id FROM hidden)"
        );
        let mut params: Vec<Box<dyn rusqlite::ToSql + Send>> = Vec::new();
        let mut text_terms: Vec<String> = Vec::new();
        // First of the WHERE's parameters; only the text join's goes before it.
        if let Some(ids) = within {
            sql.push_str(" AND item.id IN (SELECT value FROM json_each(?))");
            params.push(Box::new(serde_json::to_string(ids).unwrap_or_else(|_| "[]".into())));
        }

        for clause in &query.clauses {
            let not = if clause.negated { "NOT " } else { "" };

            match &clause.term {
                Term::Text(text) => {
                    // Negated text is rarer than it is worth expressing in FTS;
                    // it becomes a LIKE so the meaning is not quietly dropped.
                    if clause.negated {
                        sql.push_str(
                            " AND id NOT IN (SELECT id FROM item_fts WHERE item_fts MATCH ?)",
                        );
                        params.push(Box::new(fts_term(text)));
                    } else {
                        text_terms.push(fts_term(text));
                    }
                }
                Term::Field { key, values } => {
                    let column = match key.as_str() {
                        "kind" => "kind",
                        "source" => "source",
                        "family" => "family",
                        "ext" => "ext",
                        "author" => "author",
                        "license" => "license",
                        "id" => "id",
                        // Tags are a JSON array in one column; `LIKE` over it is
                        // exact enough for a whole-word tag and avoids a second
                        // table for something rarely filtered on alone.
                        "tag" | "tags" => {
                            let mut ors = Vec::new();
                            for value in values {
                                ors.push("tags LIKE ?".to_string());
                                params.push(Box::new(format!("%\"{value}\"%")));
                            }
                            sql.push_str(&format!(" AND {not}({})", ors.join(" OR ")));
                            continue;
                        }
                        _ => continue,
                    };

                    let placeholders = values.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
                    sql.push_str(&format!(" AND {not}(LOWER({column}) IN ({placeholders}))"));
                    for value in values {
                        params.push(Box::new(value.clone()));
                    }
                }
                Term::Number { key, cmp, value } => {
                    let column = match key.as_str() {
                        "w" | "width" => "w",
                        "h" | "height" => "h",
                        "ratio" => RATIO,
                        "bytes" => "bytes",
                        "added" => "added_at",
                        "duration" | "secs" | "length" => "duration",
                        _ => continue,
                    };

                    if matches!(cmp, Cmp::Eq) && column == RATIO {
                        // A ratio never lands exactly; the tolerance the matcher
                        // uses has to survive the move into SQL.
                        sql.push_str(&format!(" AND {not}(ABS({RATIO} - ?) < 0.05)"));
                        params.push(Box::new(*value));
                        continue;
                    }

                    let op = match cmp {
                        Cmp::Eq => "=",
                        Cmp::Ge => ">=",
                        Cmp::Gt => ">",
                        Cmp::Le => "<=",
                        Cmp::Lt => "<",
                    };
                    sql.push_str(&format!(" AND {not}({column} {op} ?)"));
                    params.push(Box::new(*value));
                }
                Term::Flag { key, value } => {
                    let column = match key.as_str() {
                        "animated" => "animated",
                        "nsfw" => "nsfw",
                        "tintable" => "tintable",
                        "vector" => {
                            sql.push_str(&format!(
                                " AND {not}(family = '{}')",
                                if *value { "vector" } else { "raster" }
                            ));
                            continue;
                        }
                        "video" => {
                            sql.push_str(&format!(
                                " AND {not}(family {} 'video')",
                                if *value { "=" } else { "<>" }
                            ));
                            continue;
                        }
                        "moving" => {
                            // What a person means by "moving": a video, or a
                            // GIF, which is a raster that moves.
                            sql.push_str(&format!(
                                " AND {not}({})",
                                if *value {
                                    "(family = 'video' OR animated = 1)"
                                } else {
                                    "(family <> 'video' AND animated = 0)"
                                }
                            ));
                            continue;
                        }
                        _ => continue,
                    };
                    sql.push_str(&format!(" AND {not}({column} = {})", *value as i64));
                }
            }
        }

        /*
         * Typed words are ranked by how well they match, not by what arrived
         * last. Relevance used to mean newest-first, so a search for two words
         * answered with whatever the last crawl happened to add.
         */
        let ranked = !text_terms.is_empty() && query.sort == crate::query::Sort::Relevance;
        if !text_terms.is_empty() {
            // One MATCH for all the words: FTS5 ANDs them, which is what typing
            // two words means.
            if ranked {
                sql = sql.replace(
                    "{FTS}",
                    " JOIN (SELECT id, bm25(item_fts) AS score FROM item_fts WHERE item_fts MATCH ?) m ON m.id = item.id",
                );
                // Bound by position: the join's ? is the first one in the
                // statement, so its value has to lead the list.
                params.insert(0, Box::new(text_terms.join(" ")));
            } else {
                sql.push_str(" AND item.id IN (SELECT id FROM item_fts WHERE item_fts MATCH ?)");
                params.push(Box::new(text_terms.join(" ")));
            }
        }
        sql = sql.replace("{FTS}", "");

        // A seeded permutation: rowid * A + B modulo the prime 2^31 - 1. A large
        // A wraps from the very first rows (mod 2^32 with a small A did not: a
        // small catalogue came back in insertion order), and a prime modulus
        // keeps every key distinct. rowid * A stays well inside i64.
        let mix = |mut z: u64| {
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
            z ^ (z >> 31)
        };
        let h = mix(query.seed);
        // A in the top half of the range, so the key wraps from the second row on.
        let random_order = format!(
            " ORDER BY ((rowid * {}) + {}) % 2147483647",
            1_073_741_823 + (h % 1_073_741_823),
            (h >> 32) % 2_147_483_647
        );
        sql.push_str(match query.sort {
            crate::query::Sort::Newest => " ORDER BY added_at DESC, rowid DESC",
            crate::query::Sort::Largest => " ORDER BY (w * h) DESC",
            crate::query::Sort::Widest => " ORDER BY (CASE WHEN ratio > 0 THEN ratio \
                WHEN h > 0 THEN CAST(w AS REAL) / h ELSE 1.0 END) DESC",
            crate::query::Sort::Title => " ORDER BY LOWER(title)",
            // Reproducible within a session so paging does not reshuffle: the
            // seed is the row id rather than a random per call.
            // A different constant from the default order below, or "Random"
            // and "Relevance" would be the same shuffle.
            crate::query::Sort::Random => &random_order,
            // bm25 is negative and smaller is better; ties go to the newest.
            crate::query::Sort::Relevance if ranked => " ORDER BY m.score, item.added_at DESC",
            // No search text: a fixed per-row order, not newest-first. The
            // crawler adds rows constantly, and newest-first meant every launch
            // opened on a wall of pictures you had never seen. "Newest" is
            // still a sort you can pick.
            // The stored `deal` column, which is exactly this arithmetic
            // written once per row instead of once per query — see the
            // migration that adds it, and its index.
            crate::query::Sort::Relevance => " ORDER BY item.deal",
        });

        Compiled { sql, params }
    }

    pub fn rows(&self, compiled: &Compiled) -> Result<Vec<Row>, String> {
        let mut stmt = self
            .conn
            .prepare(&compiled.sql)
            .map_err(|e| {
                self.note(&e.to_string());
                format!("prepare query: {e}\n{}", compiled.sql)
            })?;

        let params: Vec<&dyn rusqlite::ToSql> =
            compiled.params.iter().map(|p| p.as_ref() as &dyn rusqlite::ToSql).collect();

        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(Row {
                    id: row.get(0)?,
                    ratio: row.get(1)?,
                    dominant: row.get(2)?,
                    phash: row.get(3)?,
                    source: row.get(4)?,
                })
            })
            .map_err(|e| format!("query: {e}"))?;

        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| format!("query rows: {e}"))
    }

    /// Full records for a slice of a result, in the order the ids are given.
    pub fn records(&self, ids: &[String]) -> Result<Vec<Item>, String> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT * FROM item WHERE id IN ({placeholders})"))
            .map_err(|e| format!("prepare records: {e}"))?;

        let params: Vec<&dyn rusqlite::ToSql> =
            ids.iter().map(|id| id as &dyn rusqlite::ToSql).collect();

        let found = stmt
            .query_map(params.as_slice(), Self::row_to_item)
            .map_err(|e| format!("records: {e}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| format!("record rows: {e}"))?;

        // `IN` does not preserve order and the page is a window into a sorted
        // result, so put them back the way they were asked for.
        let mut by_id: std::collections::HashMap<&str, &Item> =
            found.iter().map(|i| (i.id.as_str(), i)).collect();
        // `get`, not `remove`: with the perf multiplier a page asks for the
        // same id several times, and taking it out of the map answered the
        // first copy and dropped the rest.
        Ok(ids.iter().filter_map(|id| by_id.get(id.as_str()).map(|item| (*item).clone())).collect())
    }

    /// Every row that has a perceptual hash — the working set for "more like
    /// this". Three columns, not records: the comparison only needs the hash.
    pub fn hashed_rows(&self) -> Vec<Row> {
        self.rows(&Compiled {
            sql: format!(
                "{ROW_COLUMNS} WHERE phash <> '' AND id NOT IN (SELECT id FROM hidden)"
            ),
            params: Vec::new(),
        })
        .unwrap_or_default()
    }

    /// How many rows mention this tag — what makes a tag distinctive is that
    /// few other pictures carry it. A phrase match on the text index, so
    /// `long_hair` counts "long hair" the way the tokenizer stored it.
    pub fn tag_count(&self, tag: &str) -> usize {
        let phrase = format!("\"{}\"", tag.replace('"', " ").replace('_', " "));
        self.conn
            .query_row("SELECT count(*) FROM item_fts WHERE item_fts MATCH ?1", params![phrase], |row| {
                row.get::<_, i64>(0)
            })
            .map(|n| n.max(0) as usize)
            .unwrap_or(0)
    }

    /// Rows with no hash yet, as (id, thumb, url, source).
    ///
    /// Capped rather than complete: this is a worklist that gets consumed a
    /// batch at a time, so reading the whole backlog to hand back thirty of
    /// them would be work thrown away on every call.
    /*
     * HALF AND HALF, because "whatever comes first" is not a fair share.
     *
     * This took rows in table order, and table order is roughly the order
     * sources were added — so the backlog worked through the older, mostly
     * safe rows and the adult ones waited behind them. Measured on this
     * catalogue: 9.6% of safe rows hashed against 3.2% of adult ones, 8,515
     * hashes against 1,247.
     *
     * That is not a cosmetic imbalance. Find-similar matches on these hashes,
     * so a picture with no hash cannot be found by it — which looks exactly
     * like "find similar refuses to show me adult pictures", a filter nobody
     * wrote. The two halves fill at the same rate now.
     *
     * Each half falls back to the other when it runs dry, so a catalogue that
     * is all one kind still uses the whole batch.
     */
    pub fn unhashed_rows(&self, cap: usize) -> Vec<(String, String, String, String)> {
        let half = cap.div_ceil(2);
        let mut rows = self.unhashed_side(true, half);
        let safe_wanted = cap.saturating_sub(rows.len());
        rows.extend(self.unhashed_side(false, safe_wanted));

        // One side was short: refill from the other rather than returning a
        // half-empty batch, or a catalogue of one kind would hash at half rate.
        if rows.len() < cap {
            let missing = cap - rows.len();
            let have: std::collections::HashSet<String> =
                rows.iter().map(|r| r.0.clone()).collect();
            for row in self.unhashed_side(true, cap) {
                if rows.len() >= cap + missing {
                    break;
                }
                if !have.contains(&row.0) {
                    rows.push(row);
                }
            }
        }
        rows.truncate(cap);
        rows
    }

    fn unhashed_side(&self, nsfw: bool, cap: usize) -> Vec<(String, String, String, String)> {
        if cap == 0 {
            return Vec::new();
        }
        let sql = "SELECT id, thumb, url, source FROM item
                   WHERE phash = '' AND nsfw = ?1 AND id NOT IN (SELECT id FROM hidden)
                   LIMIT ?2";
        let Ok(mut stmt) = self.conn.prepare(sql) else { return Vec::new() };
        stmt.query_map(params![i64::from(nsfw), cap as i64], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// How many rows have a hash, and how many exist.
    pub fn hash_coverage(&self) -> (usize, usize) {
        let hashed: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM item WHERE phash <> ''", [], |r| r.get(0))
            .unwrap_or(0);
        (hashed as usize, self.visible_count())
    }

    /// Which of these ids the catalogue already holds — the dedupe check a
    /// crawl makes, asked of the database instead of a copy of every id.
    pub fn existing_ids(&self, ids: &[String]) -> std::collections::HashSet<String> {
        if ids.is_empty() {
            return Default::default();
        }
        let mut found = std::collections::HashSet::new();
        // Chunked: SQLite's parameter limit is finite and a crawl can hand over
        // more ids than it allows.
        for chunk in ids.chunks(400) {
            let placeholders = chunk.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
            let Ok(mut stmt) = self
                .conn
                .prepare(&format!("SELECT id FROM item WHERE id IN ({placeholders})"))
            else {
                continue;
            };
            let params: Vec<&dyn rusqlite::ToSql> =
                chunk.iter().map(|id| id as &dyn rusqlite::ToSql).collect();
            let got: Vec<String> = match stmt.query_map(params.as_slice(), |r| r.get(0)) {
                Ok(rows) => rows.flatten().collect(),
                Err(_) => continue,
            };
            found.extend(got);
        }
        found
    }

    /// Distinct values of one column, for query completion.
    pub fn distinct(&self, column: &str, cap: usize) -> Vec<String> {
        let sql = format!(
            "SELECT DISTINCT {column} FROM item WHERE {column} <> '' ORDER BY {column} LIMIT {cap}"
        );
        let Ok(mut stmt) = self.conn.prepare(&sql) else { return Vec::new() };
        stmt.query_map([], |row| row.get::<_, String>(0))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    /// Sources with the kinds they carry and how many rows each holds.
    pub fn source_tally(&self) -> Vec<serde_json::Value> {
        let sql = "SELECT source, kind, COUNT(*) FROM item
                   WHERE source <> '' AND id NOT IN (SELECT id FROM hidden)
                   GROUP BY source, kind ORDER BY source";
        let mut stmt = match self.conn.prepare(sql) {
            Ok(stmt) => stmt,
            Err(e) => {
                self.note(&e.to_string());
                return Vec::new();
            }
        };
        let Ok(rows) = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
        }) else {
            return Vec::new();
        };

        let mut by_source: std::collections::BTreeMap<String, (Vec<String>, i64)> =
            Default::default();
        for (source, kind, count) in rows.flatten() {
            let entry = by_source.entry(source).or_insert((Vec::new(), 0));
            if !kind.is_empty() {
                entry.0.push(kind);
            }
            entry.1 += count;
        }
        by_source
            .into_iter()
            .map(|(name, (kinds, items))| {
                // The shelf comes from the adapter, not the catalogue: a source
                // with no rows yet still belongs somewhere, and a filter panel
                // that only groups what has already been crawled would move
                // things around as you use it.
                let category = crate::sources::by_id(&name)
                    .map(|s| s.category())
                    .unwrap_or("art");
                serde_json::json!({
                    "id": name, "label": name, "kinds": kinds,
                    "items": items, "category": category,
                })
            })
            .collect()
    }

    /// Distinct values with counts, straight from SQL.
    pub fn tally_column(&self, column: &str) -> Vec<serde_json::Value> {
        let sql = format!(
            "SELECT {column}, COUNT(*) FROM item
             WHERE {column} <> '' AND id NOT IN (SELECT id FROM hidden)
             GROUP BY {column} ORDER BY COUNT(*) DESC, {column}"
        );
        let mut stmt = match self.conn.prepare(&sql) {
            Ok(stmt) => stmt,
            Err(e) => {
                self.note(&e.to_string());
                return Vec::new();
            }
        };
        stmt.query_map([], |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "items": row.get::<_, i64>(1)?,
            }))
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    pub fn item_by_id(&self, id: &str) -> Option<Item> {
        self.conn
            .query_row("SELECT * FROM item WHERE id = ?1", params![id], Self::row_to_item)
            .optional()
            .ok()
            .flatten()
    }
}

/*
 * The hash backlog decides which pictures find-similar can ever match, so a
 * bias in it is a bias in the feature. It took rows in table order, which gave
 * the catalogue 8,515 safe hashes and 1,247 adult ones and made find-similar
 * look like it was filtering adult results out.
 */
#[cfg(test)]
mod unhashed_share_tests {
    use super::*;

    fn temp_db(tag: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "quarry-db-{tag}-{}.sqlite",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn seeded(name: &str, safe: usize, adult: usize) -> Db {
        let db = Db::open(temp_db(name)).expect("db");
        for i in 0..safe {
            db.conn
                .execute(
                    "INSERT INTO item (id, source, source_id, family, kind, url, phash, nsfw) \
                     VALUES (?1, 's', ?2, 'raster', 'wallpaper', 'u', '', 0)",
                    params![format!("safe:{i}"), format!("{i}")],
                )
                .expect("insert safe");
        }
        for i in 0..adult {
            db.conn
                .execute(
                    "INSERT INTO item (id, source, source_id, family, kind, url, phash, nsfw) \
                     VALUES (?1, 's', ?2, 'raster', 'wallpaper', 'u', '', 1)",
                    params![format!("adult:{i}"), format!("a{i}")],
                )
                .expect("insert adult");
        }
        db
    }

    fn counts(rows: &[(String, String, String, String)]) -> (usize, usize) {
        let adult = rows.iter().filter(|r| r.0.starts_with("adult:")).count();
        (rows.len() - adult, adult)
    }

    /// The measured shape of this catalogue: far more safe rows waiting, so
    /// table order starves the adult ones.
    #[test]
    fn a_lopsided_catalogue_still_hashes_both_sides() {
        let db = seeded("share-lopsided", 500, 500);
        let (safe, adult) = counts(&db.unhashed_rows(20));
        assert!(adult >= 8, "adult rows starved: {safe} safe, {adult} adult");
        assert!(safe >= 8, "safe rows starved: {safe} safe, {adult} adult");
    }

    /// A batch is never returned half empty because one side ran dry.
    #[test]
    fn one_sided_catalogue_still_fills_the_batch() {
        let db = seeded("share-onesided", 40, 0);
        assert_eq!(db.unhashed_rows(20).len(), 20);
    }

    #[test]
    fn nothing_to_hash_returns_nothing() {
        let db = seeded("share-empty", 0, 0);
        assert!(db.unhashed_rows(20).is_empty());
    }
}

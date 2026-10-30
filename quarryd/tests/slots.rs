//! Where a thumbnail is filed on disk is not an implementation detail — it is
//! a contract with everything else that reads that directory. The slot/target
//! feature hands quarryd a source path and a size and trusts the daemon to
//! land the picture exactly where the desktop shell (and quarry's own QML,
//! which computes the same path independently in JS) will look for it. These
//! four helpers in `util.rs` are that whole contract, and none of them had a
//! test before today.
//!
//! util.rs lives inside the `quarryd` binary, not a library crate, so it is
//! pulled in by path the same way tests/sources.rs does.

#[path = "../src/util.rs"]
mod util;

use std::sync::Mutex;
use util::{expand_tilde, file_uri, freedesktop_thumb_path, thumbnail_size_name};

/// `freedesktop_thumb_path` and `expand_tilde` read process-global env vars
/// ($XDG_CACHE_HOME, $HOME). Cargo runs the tests in this binary on several
/// threads at once by default, so two tests setting HOME to different values
/// at the same time would each see the other's value mid-test. Every test
/// that touches an env var takes this lock first and puts the old value back
/// before releasing it, so the tests stay independent of each other and of
/// whatever the ambient shell happens to have set.
static ENV_LOCK: Mutex<()> = Mutex::new(());

fn with_env<F: FnOnce()>(vars: &[(&str, Option<&str>)], f: F) {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let previous: Vec<(&str, Option<String>)> =
        vars.iter().map(|(k, _)| (*k, std::env::var(k).ok())).collect();
    for (k, v) in vars {
        match v {
            Some(val) => std::env::set_var(k, val),
            None => std::env::remove_var(k),
        }
    }
    f();
    for (k, v) in previous {
        match v {
            Some(val) => std::env::set_var(k, val),
            None => std::env::remove_var(k),
        }
    }
}

// ── file_uri: must match JS encodeURIComponent, per path segment ───────────

#[test]
fn file_uri_needs_no_escaping_for_a_plain_ascii_path() {
    // The common case, and worth pinning on its own: nothing here falls
    // outside the unreserved set, so this should come out a byte-for-byte
    // copy with the scheme glued on, not a run through the escaper.
    assert_eq!(
        file_uri("/home/user/wallpapers/sunset-01.jpg"),
        "file:///home/user/wallpapers/sunset-01.jpg"
    );
}

#[test]
fn file_uri_escapes_a_space() {
    // The single most common reason a real wallpaper path needs escaping at
    // all: "My Pictures" style directory names from a synced/exported drive.
    assert_eq!(
        file_uri("/home/user/My Pictures/cat.png"),
        "file:///home/user/My%20Pictures/cat.png"
    );
}

#[test]
fn file_uri_escapes_non_ascii_by_utf8_byte_not_by_codepoint() {
    // "ü" (U+00FC) is two UTF-8 bytes (0xC3, 0xBC). JS's encodeURIComponent
    // percent-escapes each UTF-8 byte, not the Unicode codepoint — a rewrite
    // that tried to escape "one %XX per character" would produce a different
    // (and wrong) sequence here, and the hash the desktop computes from its
    // own JS would stop matching this one silently.
    assert_eq!(file_uri("/home/user/Bücher.png"), "file:///home/user/B%C3%BCcher.png");
    // CJK: three UTF-8 bytes per character (0xE6 0x97 0xA5, 0xE6 0x9C 0xAC,
    // 0xE8 0xAA 0x9E) — exercises the same byte-wise rule with a wider glyph.
    assert_eq!(
        file_uri("/home/user/日本語.png"),
        "file:///home/user/%E6%97%A5%E6%9C%AC%E8%AA%9E.png"
    );
}

#[test]
fn file_uri_escapes_ampersand_hash_and_plus() {
    // These three are the ones people actually type or that scrapers hand
    // back in a filename, and each means something different if left raw in
    // a URI (query separator, fragment separator, encoded space) — leaving
    // any one of them unescaped would make a URI that means a different file.
    assert_eq!(file_uri("/home/user/a&b#c+d.png"), "file:///home/user/a%26b%23c%2Bd.png");
}

#[test]
fn file_uri_leaves_an_apostrophe_unescaped() {
    // The trap: apostrophe is IN the unreserved set JS's encodeURIComponent
    // leaves alone (A-Z a-z 0-9 - _ . ! ~ * ' ( )), so a naive "escape
    // anything that isn't alphanumeric" implementation would wrongly turn
    // this into %27 and disagree with the desktop's own hash.
    assert_eq!(file_uri("/home/user/user's photo.png"), "file:///home/user/user's%20photo.png");
}

#[test]
fn file_uri_known_answer_md5() {
    // KNOWN ANSWER, computed independently of this crate two ways —
    // `hashlib.md5(...)` in Python and `printf '%s' <uri> | md5sum` — not
    // derived from freedesktop_thumb_path itself:
    //
    //   md5("file:///home/user/Pictures/cat.png")
    //     = a207e3439201940791c9f88e505b8f2c
    //
    // This pins the exact bytes that get hashed. A self-consistency test
    // (hash twice, compare) would pass even if file_uri or the hashing both
    // changed together; this one only passes if the URI text is still
    // exactly what the freedesktop spec — and the desktop's own JS — expect.
    let uri = file_uri("/home/user/Pictures/cat.png");
    assert_eq!(uri, "file:///home/user/Pictures/cat.png");

    let mut hasher = <md5::Md5 as md5::Digest>::new();
    md5::Digest::update(&mut hasher, uri.as_bytes());
    let hex: String = md5::Digest::finalize(hasher).iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(hex, "a207e3439201940791c9f88e505b8f2c");
}

// ── thumbnail_size_name: the boundaries are the whole function ─────────────

#[test]
fn thumbnail_size_name_boundaries_128_256_512() {
    // These are the spec's actual bucket edges (normal/large/x-large/
    // xx-large). An off-by-one on any of the three puts a thumbnail one
    // pixel over a boundary in the wrong directory — nothing errors, the
    // picture just never turns up where a reader with the exact same size
    // looks for it.
    assert_eq!(thumbnail_size_name(128), "normal");
    assert_eq!(thumbnail_size_name(129), "large");
    assert_eq!(thumbnail_size_name(256), "large");
    assert_eq!(thumbnail_size_name(257), "x-large");
    assert_eq!(thumbnail_size_name(512), "x-large");
    assert_eq!(thumbnail_size_name(513), "xx-large");
    // 0 is a degenerate size a caller could pass by accident; it must still
    // land somewhere sane rather than panicking on the match.
    assert_eq!(thumbnail_size_name(0), "normal");
}

// ── freedesktop_thumb_path: stable, lowercase hex, honours $XDG_CACHE_HOME ─

#[test]
fn freedesktop_thumb_path_hash_is_stable_lowercase_hex() {
    /*
     * TAKES THE LOCK EVEN THOUGH IT SETS NOTHING.
     *
     * This test was flaky — roughly one run in five — because
     * `freedesktop_thumb_path` READS $XDG_CACHE_HOME, and the tests that set it
     * run on other threads of the same binary. Two calls a line apart could
     * straddle another test's set/restore and come back with different prefixes,
     * so "the same input hashes the same" failed for a reason that had nothing
     * to do with hashing.
     *
     * The lock belongs to anything that touches the environment, reads
     * included. `with_env` with an empty list takes it and changes nothing.
     */
    with_env(&[], || {
    let a = freedesktop_thumb_path("/home/user/wallpapers/dune.jpg", 256);
    let b = freedesktop_thumb_path("/home/user/wallpapers/dune.jpg", 256);
    assert_eq!(a, b, "same source + size must hash to the same name on every run");

    let hex = a.rsplit('/').next().unwrap().trim_end_matches(".png");
    assert_eq!(hex.len(), 32, "an MD5 hex digest is always 32 chars: {hex}");
    // Uppercase hex would still be a valid digest but a different STRING, and
    // the shell compares filenames verbatim, not case-insensitively.
    assert!(
        hex.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
        "must be lowercase hex — readers compare the filename verbatim: {hex}"
    );
    });
}

#[test]
fn freedesktop_thumb_path_honours_xdg_cache_home() {
    with_env(&[("XDG_CACHE_HOME", Some("/custom/cache/dir"))], || {
        let path = freedesktop_thumb_path("/home/user/a.png", 64);
        assert!(
            path.starts_with("/custom/cache/dir/thumbnails/normal/"),
            "XDG_CACHE_HOME must win over the ~/.cache default: {path}"
        );
    });
}

#[test]
fn freedesktop_thumb_path_falls_back_to_home_cache_without_xdg_cache_home() {
    // Most desktops never set XDG_CACHE_HOME, so this fallback is the path
    // that actually runs for almost every user.
    with_env(&[("XDG_CACHE_HOME", None), ("HOME", Some("/home/testuser"))], || {
        let path = freedesktop_thumb_path("/home/user/a.png", 64);
        assert!(
            path.starts_with("/home/testuser/.cache/thumbnails/normal/"),
            "{path}"
        );
    });
}

#[test]
fn freedesktop_thumb_path_full_path_matches_the_known_answer() {
    // Ties the known-answer MD5 above to the full on-disk path quarryd
    // actually writes, under a fixed size bucket so the directory name is
    // pinned too.
    with_env(&[("XDG_CACHE_HOME", Some("/tmp/quarry-test-cache"))], || {
        let path = freedesktop_thumb_path("/home/user/Pictures/cat.png", 128);
        assert_eq!(
            path,
            "/tmp/quarry-test-cache/thumbnails/normal/a207e3439201940791c9f88e505b8f2c.png"
        );
    });
}

// ── expand_tilde: only a LEADING "~/" expands ───────────────────────────────

#[test]
fn expand_tilde_cases() {
    with_env(&[("HOME", Some("/home/testuser"))], || {
        assert_eq!(expand_tilde("~/x"), "/home/testuser/x");
        assert_eq!(
            expand_tilde("~/Pictures/wallpaper.png"),
            "/home/testuser/Pictures/wallpaper.png"
        );
        // Bare "~" has no trailing slash to strip. It is left alone rather
        // than guessed at — a directory literally named "~" is rare but
        // real, and there is nothing after it to say the user meant $HOME.
        assert_eq!(expand_tilde("~"), "~");
        assert_eq!(expand_tilde("/absolute/path"), "/absolute/path");
        assert_eq!(expand_tilde("relative/path"), "relative/path");
        // Only a LEADING "~/" is a home reference. One that shows up mid-path
        // is somebody's real directory named "~" and must survive untouched —
        // expanding it would silently rewrite a path to a file that doesn't
        // exist at the rewritten location.
        assert_eq!(expand_tilde("/data/~/backup"), "/data/~/backup");
    });
}

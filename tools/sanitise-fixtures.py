#!/usr/bin/env python3
"""Replace real people, handles and content ids in test fixtures with synthetic ones.

WHY THIS EXISTS
---------------
The fixtures under quarryd/tests/fixtures/ are captures of live pages, and a live
page is full of other people: DeviantArt usernames, danbooru artist handles,
uploader ids, avatar URLs with a name in the path, md5s that identify one real
picture. None of that is needed to pin a parser — the parser cares about the
SHAPE of the document — and all of it ends up in the repository for good.

So every such value is swapped for an invented one of the same shape. Same
length class, same character set, same position in the document, so the parsers
and their assertions behave identically and only the identities change.

WHAT IT WILL NOT TOUCH
----------------------
Any string that appears verbatim anywhere in the test sources. Those are the
values the assertions pin, and a fixture that no longer contains them is a red
suite rather than a sanitised one. The check is a plain substring test against
the concatenated test files — deliberately not a Rust literal parser, because
the obvious regex for that mis-pairs quotes and silently under-protects.

USAGE
-----
    tools/sanitise-fixtures.py --check     # report what is still real, change nothing
    tools/sanitise-fixtures.py             # rewrite the fixtures in place

Run `cargo test` afterwards. A failure means something asserted was missed by
the protection check; the value it names should be added to KEEP below.
"""

import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "quarryd" / "tests" / "fixtures"
TEST_SOURCES = [ROOT / "quarryd" / "tests" / "sources.rs"] + sorted(
    (ROOT / "quarryd" / "src").rglob("*.rs")
)

# Values that must survive even though the substring check might not see them
# (a test that builds one by concatenation, say). None needed so far.
KEEP: set[str] = set()

# Invented word stock. Deliberately nothing that reads as a real handle.
SYLLABLES = [
    "aur", "bel", "cin", "dov", "eth", "fen", "gil", "hol", "iri", "jor",
    "kel", "lum", "mar", "nys", "orl", "pil", "quar", "rin", "sel", "tov",
    "umb", "vel", "wren", "xan", "yol", "zar",
]
SURNAMES = [
    "Marsk", "Quill", "Vane", "Ashby", "Crane", "Dorne", "Elder", "Frost",
    "Grove", "Hale", "Ivory", "Kembel", "Lowry", "Mira", "Norden", "Oakes",
]
GIVEN = [
    "Aveline", "Bramwell", "Cordis", "Delwyn", "Esker", "Fenna", "Goring",
    "Halcy", "Irwen", "Jessamy", "Kestrel", "Lorne", "Marrow", "Nesta",
]


def _seed(value: str) -> int:
    return int(hashlib.sha256(value.encode("utf-8")).hexdigest()[:12], 16)


def fake_handle(value: str) -> str:
    """A username-shaped replacement, stable for a given input."""
    n = _seed(value)
    word = SYLLABLES[n % len(SYLLABLES)] + SYLLABLES[(n // 31) % len(SYLLABLES)]
    # Keep a trailing digit run if the original had one — some parsers and some
    # assertions care that a handle can end in digits.
    tail = re.search(r"\d+$", value)
    if tail:
        word += str(n % (10 ** len(tail.group())))
    return word


def fake_name(value: str) -> str:
    """A person-shaped replacement: two capitalised words."""
    n = _seed(value)
    return f"{GIVEN[n % len(GIVEN)]} {SURNAMES[(n // 17) % len(SURNAMES)]}"


def fake_hex(value: str, length: int) -> str:
    return hashlib.sha256(("fixture:" + value).encode()).hexdigest()[:length]


def fake_digits(value: str, length: int) -> str:
    n = _seed(value)
    return str(n % (10 ** length)).rjust(length, "1")[:length]


class Sanitiser:
    def __init__(self) -> None:
        blob = []
        for path in TEST_SOURCES:
            try:
                blob.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
        self.tests = "\n".join(blob)
        self.mapping: dict[str, str] = {}
        self.skipped: set[str] = set()

    def protected(self, value: str) -> bool:
        """Asserted somewhere, so it has to stay exactly as it is."""
        return value in KEEP or value in self.tests

    def rename(self, value: str, maker) -> str:
        if self.protected(value):
            self.skipped.add(value)
            return value
        if value not in self.mapping:
            self.mapping[value] = maker(value)
        return self.mapping[value]


def collect(text: str, patterns: list[str]) -> set[str]:
    found: set[str] = set()
    for pattern in patterns:
        for m in re.finditer(pattern, text):
            found.add(m.group(1))
    return found


# Each rule: (filename glob, [capture patterns], value maker).
# The capture group is the part that gets replaced, everywhere it appears in
# that file — a username is in the credit, the link and the avatar path, and
# leaving any one of them is leaving the name in the repository.
RULES = [
    # DeviantArt: the author of every item, in all four places it is written.
    ("deviantart*.rss", [
        r"<media:credit[^>]*role=\"author\"[^>]*>([^<]+)</media:credit>",
        r"<dc:creator[^>]*>([^<]+)</dc:creator>",
        r"deviantart\.com/([A-Za-z0-9_-]+)/art/",
        r"a\.deviantart\.net/avatars/[a-z0-9]/[a-z0-9]/([A-Za-z0-9_-]+)\.",
    ], fake_handle),
    # danbooru: the artist, and the uploader behind the post.
    ("danbooru.json", [
        r'"tag_string_artist":\s*"([^"]+)"',
    ], fake_handle),
    # AniList: character names are the whole payload.
    ("anilist-characters.json", [
        r'"full":\s*"([^"]+)"',
        r'"native":\s*"([^"]+)"',
    ], fake_name),
    # pfps.gg: the numeric uploader on a picture's page.
    ("pfps-gg*.html", [
        r"Pfp by (\d{6,})",
        r"Banner by (\d{6,})",
    ], lambda v: fake_digits(v, len(v))),
]

# Content hashes: they identify one real picture on a real host. Same length,
# same alphabet, so every URL built from them still parses.
HASH_RULES = [
    ("danbooru.json", r"\b([0-9a-f]{32})\b", 32),
    ("iqdb*.html", r"\b([0-9a-f]{32})\b", 32),
    ("wallhaven.json", r"\b([0-9a-f]{32})\b", 32),
]


def run(check_only: bool) -> int:
    if not FIXTURES.is_dir():
        print(f"no fixtures at {FIXTURES}", file=sys.stderr)
        return 2

    san = Sanitiser()
    touched = 0
    total = 0

    for path in sorted(FIXTURES.iterdir()):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        original = text
        changes = 0

        for glob, patterns, maker in RULES:
            if not path.match(glob):
                continue
            for value in sorted(collect(text, patterns), key=len, reverse=True):
                new = san.rename(value, maker)
                if new == value:
                    continue
                # EVERY CASE, not just the one the structured field used.
                #
                # A handle is written one way in <dc:creator>, lowercased in an
                # avatar path, and shouted in the middle of a description where
                # the artist signs their own work — "ART BY UDZILO". Replacing
                # only the exact spelling left the name in the file in the one
                # place nothing parses and nobody greps.
                pattern = re.compile(re.escape(value), re.IGNORECASE)
                changes += len(pattern.findall(text))
                text = pattern.sub(lambda m: new.upper() if m.group().isupper()
                                   else (new.capitalize() if m.group()[:1].isupper() else new),
                                   text)

        for glob, pattern, length in HASH_RULES:
            if not path.match(glob):
                continue
            for value in sorted(collect(text, [pattern]), key=len, reverse=True):
                new = san.rename(value, lambda v, n=length: fake_hex(v, n))
                if new == value:
                    continue
                changes += text.count(value)
                text = text.replace(value, new)

        total += changes
        if text != original:
            touched += 1
            if not check_only:
                path.write_text(text, encoding="utf-8")
            print(f"  {path.name}: {changes} replacements")

    verb = "would replace" if check_only else "replaced"
    print(f"\n{verb} {total} values across {touched} fixtures")
    print(f"distinct identities renamed: {len(san.mapping)}")
    if san.skipped:
        print(f"left alone because a test asserts them: {len(san.skipped)}")
        for value in sorted(san.skipped)[:12]:
            print(f"    {value}")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="report what would change, write nothing")
    sys.exit(run(ap.parse_args().check))

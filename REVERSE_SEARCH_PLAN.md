# Finding the same picture somewhere else

Three tiers, in cost order. Each is useful alone; each degrades to the one
below it rather than failing.

## Tier 1 — local, built

Perceptual hash over your own catalogue. No network, no third party, answers in
the time it takes to xor 28,000 integers. `similar` sets the result index the
way `query` does, so paging, ratios, masonry and dedupe all work unchanged.

Live now. Its only limit is coverage: hashes are computed when a thumbnail is
made, so `hashed` climbs as you browse (1,253 of 28,498 at the time of writing).
A backfill fixes that and is the single highest-value thing left.

## Tier 2 — providers with an API

**SauceNAO** and **IQDB** answer "where else does this image exist" over plain
HTTP with documented parameters and a rate limit you can respect. They belong in
quarryd as ordinary sources: fetch, parse JSON, return rows. No new machinery —
the HTTP cache and retry logic already exist. The source TRAIT does not fit —
`Source::build_url` takes a parsed text query and `SourceQuery` has nowhere to
put a picture — so these are plain functions called directly by the `reverse`
method. `SOURCE_TRAIT_PROPOSAL.md` weighs whether that should change.

Do these before Yandex. They cover most of the need and cannot break in the way
tier 3 breaks.

## Tier 3 — Yandex, and why it needs a browser

Yandex has **no API**. Reverse image search is an HTML page, JS-driven, behind
anti-bot heuristics that read the TLS fingerprint, the header order and the
cookie jar. `reqwest` cannot pass for a browser; scraping it works for a while
and then silently returns nothing, which is the worst failure a source can have.

**tela is the only thing here that can actually load it**: a Rust core with Qt
WebEngine underneath, already bridged through cxx-qt. It is a real engine with a
real cookie jar and a real JS runtime.

### The shape

Do NOT put a browser engine in the daemon. quarryd stays what it is — no Qt, no
Chromium, no window. Instead tela grows a small, boring IPC surface:

    tela: "load this URL / submit this image, run the page, hand back the DOM"
    quarryd: "here is an image, give me the result links"

quarryd asks; tela answers in a hidden tab. Same shape as the socket protocol
quarry already speaks, so there is no new transport to design. If tela is not
running, tier 3 is simply unavailable and tiers 1 and 2 still answer.

### The cookie problem is not incidental

You already hit cookie trouble in tela-zen, and this is the feature where that
bites hardest: Yandex's reverse search depends on a session, and a broken or
absent cookie jar is exactly what turns a working scraper into one that returns
an empty page and no error. **Whatever is wrong with cookies has to be fixed
before tier 3 is worth building** — otherwise you get a source that fails
silently and intermittently, which costs more to own than it is worth.

That is also the honest argument for the tier order: tiers 1 and 2 have no such
dependency.

## Google Lens

Same category as Yandex — no public API for this, engine-backed or not at all.
Everything above applies unchanged; it is one more page for tela to load once
that path exists.

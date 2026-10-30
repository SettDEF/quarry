# Fitting reverse search into the source abstraction

`saucenao.rs` and `iqdb.rs` are plain functions — `build_url`/`parse`,
`build_request`/`parse` — called directly from the `"reverse"` arm in
`main.rs`, instead of `Source` impls registered in `sources::all()`. Their own
header comments already say why, and say it correctly. This is the design
decision those comments deferred: is the gap worth closing, with what shape,
and at what cost.

## 1. The mismatch, precisely

`Source` (`quarryd/src/sources/mod.rs`) is four required methods:

```rust
pub trait Source {
    fn id(&self) -> &'static str;
    fn capabilities(&self) -> Capabilities;
    fn build_url(&self, query: &SourceQuery) -> String;
    fn parse(&self, body: &str) -> Result<Vec<Item>, String>;
    fn body(&self, query: &SourceQuery) -> Option<serde_json::Value> { None }
    fn has_more(&self, body: &str) -> bool { true }
}
```

Every method that takes input takes a `SourceQuery`, and `SourceQuery` is
built exactly one way: `pushdown(&Query, Capabilities)` walks a *parsed text
query* — `Query { clauses: Vec<Clause>, color, sort, .. }`, itself produced by
`query::parse(&str)` — and splits it into what a source can push down and what
stays local. Every field on `SourceQuery` is text-query shaped: `text: Vec<String>`,
`tags: Vec<String>`, `min_w`/`min_h`, `ratio: Option<f64>`, `allow_nsfw`,
`sort: Sort`, `color: Option<String>`, `kind: String`, `page: u32`. There is no
field that could hold "the bytes of an image" or even "a URL to one" without
lying about what it means — every other field on that struct is a filter
*predicate*, and an image is not a predicate, it's the subject.

`build_url` cannot be reached at all without first having a `SourceQuery`, and
`pushdown` cannot produce one from anything but a `Query`, and `Query` cannot
be produced from anything but `query::parse`'s grammar — `term`, `key:value`,
`key>=n`, `-flag`, all typed text. There is no path from "here is an `Item`
with a `.url`" to a `SourceQuery` anywhere in this chain. That is the mismatch:
it is not that `SourceQuery` is *missing a field*, it is that the whole call
chain above `build_url` is text-query shaped from `query::parse` down, and
reverse search has no text query to parse in the first place — it starts from
an already-decided `image_url: &str`, taken from `main.rs`'s `"reverse"` arm
straight off a catalog `Item`.

The output side doesn't fit either, and this matters as much as the input
side. `Source::parse` returns `Result<Vec<Item>, String>` — the catalogue's
own record shape, ready for `catalog.add()`. `saucenao::parse` returns
`Result<SauceResponse, String>` where `SauceResponse` carries
`similarity: f64`, `index_name: String`, `short_remaining`/`long_remaining`
quota counters — none of which exists on `Item`, and `short_remaining` in
particular is not a fact about a *result*, it's a fact about the *account*
making the request, with nowhere on `Item` to live even in principle.
`iqdb::parse` returns `SearchResult::Matches(Vec<Match>) |
SearchResult::NoMatches(String)` — an enum, because "zero rows because
nothing matched" and "zero rows because the page didn't parse" are different
facts iqdb's own page distinguishes and `Vec<Item>` cannot. Forcing either
into `Vec<Item>` loses information the daemon currently keeps and the `reverse`
response currently sends over the wire (`PROTOCOL.md` has no `reverse` method
documented at all yet — it's real, wired, and used, but off-book).

Concretely, three call sites in `main.rs`'s `"reverse"` arm do work no
`Source` impl is asked to do and no generic `search`-style dispatcher performs
for them: reading `item.url` off a catalog row instead of running
`query::parse`, choosing `fetch_text` vs `post_form` per provider (not `body()`'s
GET-vs-POST-JSON switch — a third HTTP shape), and shaping a bespoke JSON
response per provider inline rather than through `parse() -> Vec<Item>` +
`catalog.add()`.

## 2. Two designs, and their real cost

### Design A — a sibling trait, `ReverseSource`

```rust
pub trait ReverseSource {
    fn id(&self) -> &'static str;
    fn capabilities(&self) -> ReverseCapabilities; // e.g. { by_url: bool, needs_key: bool }
    fn build_request(&self, image_url: &str) -> ReverseRequest; // url + optional form fields
    fn parse(&self, body: &str) -> Result<Vec<ReverseMatch>, String>;
}
```

`ReverseMatch` is a new type shaped like the union of `saucenao::Match` and
`iqdb::Match` — `similarity`, `source_url`, `thumbnail`, plus a
`serde_json::Value` bag or per-provider optional fields (`index_name`,
`rating`) for what doesn't generalize. `SauceResponse`'s quota counters ride
alongside as `Option<ReverseQuota>`, not squeezed into `ReverseMatch` itself.

**Cost.** `saucenao.rs` and `iqdb.rs` each grow a struct (`Saucenao`, `Iqdb`)
implementing four small methods that mostly re-export what's already there —
`build_request` wraps `build_url`/`build_request`, `parse` wraps `parse` and
maps `Match`/`SearchResult` into `ReverseMatch`. Neither file's actual
HTTP-shape or HTML-parsing logic changes; this is a wrapper layer. `mod.rs`
gains `reverse_all() -> Vec<Box<dyn ReverseSource + Send + Sync>>` alongside
`all()`, and `main.rs`'s `"reverse"` arm becomes a dispatch over that list
instead of a `match provider { "saucenao" => .., "iqdb" => .. }`. Zero
existing `Source` impls change — `Wallhaven`, `Danbooru`, every `declarative.rs`
manifest, all untouched, because `Source` itself doesn't move. `declarative.rs`
is unaffected in every sense: TOML manifests describe text-searchable
catalogues (a `map:` for JSON/RSS fields), and nothing about reverse image
lookup is expressible in that manifest shape anyway — SauceNAO and IQDB stay
native code under this design exactly as they are today, this only adds a
second native-only trait beside `Source`.

What it doesn't buy: `pushdown()`, `Capabilities`, and `SourceQuery` are not
reused at all — `ReverseCapabilities` is a parallel, near-empty concept
invented to fill the slot `Capabilities` fills for `Source`, and there are
only ever two `ReverseSource` impls, so a whole second trait plus a second
`_all()` registry function is machinery built for a membership of two. `doctor`
and `sources` protocol methods would need their own reverse-specific loop
(`reverse_all()` instead of `all()`) to cover these — an addition, not a reuse
of the existing one, because the two traits don't share a supertype.

### Design B — an enum-shaped query, threaded through `pushdown`

```rust
pub enum QueryInput {
    Text(Query),
    Image { url: String },
}
```

`pushdown` becomes `fn pushdown(input: &QueryInput, caps: Capabilities) ->
(SourceQuery, Query)`, and `SourceQuery` grows `pub image: Option<String>`.
`Source::build_url` reads `query.image` when present and ignores the text
fields (all empty for an image input, so no dual-purpose ambiguity there, just
an unused struct field on that call). `Capabilities` grows `reverse: bool` so
`pushdown` — or the dispatcher calling it — can route only capable sources.

**Cost.** This is the expensive one, and not just administratively. Every
existing `Source::build_url` implementation pattern-matches or reads fields
off `SourceQuery` assuming they came from `pushdown(Query, ..)` — `Wallhaven`
reads `query.text`/`query.tags`/`query.color` and joins them into `q=`;
`Danbooru` does the same into a tag string; every `declarative.rs` manifest
substitutes `{query}`/`{tags}` from those same fields. None of them is wrong
today because `pushdown` only ever produces a `SourceQuery` from real text.
Under this design that invariant is gone: `build_url` can now be called with a
`SourceQuery` that came from `QueryInput::Image`, where `text`/`tags` are
empty and `image` is set — and *nothing stops it*. `Wallhaven::build_url`
would silently build `https://wallhaven.cc/api/v1/search?purity=100&sorting=date_added&page=1`
(a valid, working, wrong URL — a browse of newest wallpapers, not an error)
for a source that never claimed `capabilities().reverse`, because the trait
has no way to refuse a call it's handed. The two things that make this safe —
"only route image input to a source that opted in" and "never call `build_url`
with an image on a source that didn't" — live entirely in the dispatcher's
discipline in `main.rs`, not in the type system, which is exactly the kind of
implicit contract this whole exercise exists to get rid of.

It also does not shrink `SourceQuery` for the sources that don't do reverse
search — `Option<String>` on a struct nine other fields are read from
unconditionally means every `Source` impl's `build_url` — all six native ones,
plus the declarative template substitution — carries a field it must remember
to *not* read, forever, as a matter of convention rather than something the
compiler enforces. And the residue-matching half of `pushdown` (the `Query`
returned alongside `SourceQuery`, applied by `query::matches` against
`Vec<Item>`) has no meaning for an image match at all — `ReverseMatch`/`Match`
isn't an `Item`, so the second return value of `pushdown` would need to become
`Option<Query>` or the reverse path would need to route around calling
`pushdown` for the residue half regardless, which is most of the function
providing nothing.

`declarative.rs` is affected here in a way it isn't in Design A: its
`Caps { text, tags, min_size, ratio, nsfw, sort }` struct maps 1:1 onto
`Capabilities`'s text-search fields today. Adding `Capabilities::reverse`
means either every manifest silently defaults to `reverse: false` (fine, but
now `Capabilities` has a field no `.toml` can ever set, which is a live
asymmetry someone has to notice and document) or the manifest format grows a
`reverse = true` knob for a feature no declarative source could ever
implement (`build_url` from a template string cannot describe "POST this
image URL to a multipart-shaped endpoint and parse an HTML page with
`scraper` selectors" — that is exactly the native-code escape hatch
`declarative.rs`'s own header comment names boojums like `pfps_gg`/`AniList`
for). Either way, a manifest author now reads a capability flag that can never
apply to them.

## 3. Recommendation

**Design A — a sibling `ReverseSource` trait — with the codebase's status quo
kept for `declarative.rs` and no change to `Source`, `Capabilities`, `pushdown`,
or `SourceQuery` at all.**

Design B fails on its own terms: it makes `build_url` partial (some
`SourceQuery` shapes are meaningless to some sources) without the compiler
knowing which, which is a strictly worse type-safety story than today's "these
two files openly say they don't implement the trait." A trait method that can
be called with input it silently mishandles is the bug this whole proposal
exists to prevent, not fix. It also spends real cost — a new enum threaded
through every `build_url` call site, a new `Capabilities` field every
non-reverse source must remember not to be tripped by, a `pushdown` return
shape that stops meaning what it means for text — to serve exactly two
adapters, forever, since Yandex/Google-Lens (`REVERSE_SEARCH_PLAN.md`'s tier
3) go through tela's IPC surface, not `reqwest`, and can never be a
`build_url(&SourceQuery) -> String` in the first place.

Design A costs a small, additive wrapper layer around code that already works,
touches zero existing `Source` impls, and gives reverse search exactly the two
things it's currently missing that are worth having: a registry
(`reverse_all()`) so `doctor` and `sources` can enumerate and health-check
`saucenao`/`iqdb` the way they do every text source today, and a single
dispatch point in `main.rs` instead of a hand-written `match provider {
"saucenao" => .., "iqdb" => .. }` that a third reverse provider (tela-backed
Yandex, eventually) would otherwise be added to by copy-pasting the block
above it. Neither of those needs `pushdown`, `Capabilities`, or `SourceQuery`
to be touched, because those three exist to solve a problem — "how much of an
open-ended text query can this endpoint's own filters answer" — that a
reverse lookup, which has exactly one input and no filter language, does not
have.

## 4. The honest case for doing nothing

The status quo — plain functions, called directly from `main.rs`'s `"reverse"`
arm — is not merely tolerable, it may be *correct*, and the case for it is
stronger than "it works today":

- **There are two of them, ever, in the near term.** `REVERSE_SEARCH_PLAN.md`
  is explicit that tier 3 (Yandex, Google Lens) goes through tela's IPC, not
  through `quarryd`'s own `reqwest`-based `Http` — those never become
  `build_url(&SourceQuery) -> String` under any design, A included, because
  there is no URL to build; the request is "load this page in a real
  browser." So the ceiling for *either* proposed trait's membership is two
  real Rust impls, permanently. A trait is a promise of a shape more than two
  things will eventually share; abstracting for a fixed population of two is
  spending design cost that never gets to amortize past the two payers who
  already paid it by hand.

- **They already share the machinery that actually matters.** `RateLimiter`,
  `Http::fetch_text`/`post_form` (retry/backoff/User-Agent/per-host pacing),
  and the `ScrapeError` taxonomy are not gated behind `Source` — they're free
  functions and a struct any caller reaches, and `main.rs`'s `"reverse"` arm
  already calls `self.http.fetch_text`/`post_form` exactly like `"search"`
  does. The thing genuinely missing is *registration* (`doctor`, `sources`,
  a generic dispatch), which is real but small, and Design A's whole value
  proposition is delivering just that without touching anything else — which
  is itself evidence that the size of the actual gap is smaller than "sits
  outside the abstraction every other source uses" makes it sound.

- **`REVERSE_SEARCH_PLAN.md` already says the opposite of what the header
  comments say, and that disagreement is worth resolving before code moves.**
  The plan's tier 2 section states flatly: "They belong in quarryd as ordinary
  sources... No new machinery — the source trait already fits." The header
  comments in `saucenao.rs`/`iqdb.rs` argue the trait does *not* fit, in
  detail, and this document sides with the header comments — but the plan
  document is still sitting there saying the opposite, unedited. Whichever
  way this proposal lands, `REVERSE_SEARCH_PLAN.md`'s tier 2 paragraph needs a
  line changed to match, or the next person to read it will re-open a
  question this file just answered.

- **The two-function shape is not a compromise; it's arguably more honest
  than a trait would be.** `Source::parse -> Vec<Item>` promises "these rows
  are catalogue-shaped and ready to store"; `saucenao::parse -> SauceResponse`
  promises "these are *matches for a specific query image*, with a quota
  attached" — a materially different kind of answer that a shared `parse`
  signature would have to either widen (an `Item` with fields that don't
  mean anything for a catalogue row) or wrap (which is Design A, restated).
  Nothing about the plain-function shape is accidental; it is what the
  header comments describe, and they describe it accurately.

If the trait question doesn't get revisited, that is a legitimate outcome:
build the third reverse provider (tela/Yandex) the same way, as a plain
function pair called from a `match` in `main.rs`, and reassess only once that
`match` has three or four arms and the copy-paste tax is visible in the diff
rather than argued in the abstract. Design A is the answer if and when a
registry is actually wanted (mainly: `doctor` coverage for a broken
`SAUCENAO_API_KEY` or IQDB markup drift, which today fails silently until
someone runs a reverse search by hand) — it is not something the plain
functions are currently *costing* the daemon in a way that shows up as a bug.

## 5. Migration sketch (if Design A is taken)

Order chosen so `cargo build` stays green after every step — nothing is ever
half-referenced.

1. **Add the types, nothing calls them yet.** In `sources/mod.rs`: 
   `ReverseCapabilities`, `ReverseRequest` (endpoint + method + optional form
   fields, mirroring what `saucenao::build_url` and `iqdb::build_request`
   already return in different shapes), `ReverseMatch`, `ReverseQuota`, and
   the `ReverseSource` trait itself. Compiles trivially — new dead code,
   `#![allow(dead_code)]` already covers the module.

2. **Wrap, don't rewrite.** Add `pub struct Saucenao;` to `saucenao.rs` and
   `pub struct Iqdb { pub service: Service }` to `iqdb.rs`, each implementing
   `ReverseSource` by calling the existing `build_url`/`build_request`/`parse`
   free functions and mapping their return types into `ReverseMatch`/
   `ReverseQuota`. The free functions themselves are untouched — they're now
   private implementation detail of the wrapper, or stay `pub` if the
   `#[cfg(test)]` fixtures below them are worth keeping addressed directly
   (they are; leave them `pub`). Compiles: two new impls of a trait nothing
   requires yet.

3. **Add `reverse_all()` beside `all()`** in `sources/mod.rs`, returning
   `vec![Box::new(saucenao::Saucenao), Box::new(iqdb::Iqdb { service: Service::All })]`
   (the 3D variant can be a second registry entry, `iqdb-3d`, or stay a
   request-time parameter as it is today — either is a `main.rs`-only
   decision, not a trait one). Compiles: an unused function, same as step 1.

4. **Repoint `main.rs`'s `"reverse"` arm** from the `match provider { "saucenao"
   => .., "iqdb" => .. }` block to `reverse_all().iter().find(|s| s.id() ==
   provider)` + the trait's three methods, deleting the per-provider inline
   HTTP-shape logic (the `fetch_text`-vs-`post_form` choice moves into each
   `ReverseSource::build_request`'s returned shape, read generically once by
   the dispatcher). This is the one step that changes existing behavior, so
   it's last, and it's a pure refactor — the wire response for `"reverse"`
   should be byte-identical, checked against the existing `saucenao.rs`/
   `iqdb.rs` test fixtures plus a manual `reverse` request against both
   providers before merging.

5. **Wire `doctor` and `sources` to include `reverse_all()`,** tagged
   distinctly from `all()`'s rows (a `"reverse": true` field, or a separate
   `"reverseSources"` array) since `doctor`'s probe today assumes a
   `Query::default()`-shaped browse request works for every source, which is
   meaningless for something that only ever answers a specific image — the
   probe for a `ReverseSource` has to be "is the endpoint reachable and the
   key valid," not "does a browse return rows," and that's a different
   `doctor` code path, worth its own small `match` arm rather than folding
   into the existing loop.

6. **Document `reverse` in `PROTOCOL.md`.** It has been a real, used method
   since before this proposal; writing it down is overdue independently of
   whether `ReverseSource` lands, and doing it in the same change makes the
   new `ReverseMatch`/`ReverseQuota` wire shape (if the response JSON changes
   at all — it shouldn't, per step 4) the version that gets written up.

Each step leaves `cargo test` green: steps 1–3 add unreferenced code, step 4
is the only behavior change and is covered by the existing `saucenao`/`iqdb`
fixture tests, step 5 adds a new report field additively (PROTOCOL.md's rule
that "an unknown field in `p`/response is ignored" already covers a client
that hasn't been updated to read it yet).

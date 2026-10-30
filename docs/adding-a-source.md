# Adding a source

A source is a file, not code. Drop a TOML manifest in

```
~/.config/quarry/sources/<anything>.toml
```

restart the daemon (`systemctl --user restart quarryd`), and it is in the
catalogue — including anywhere quarry is the backend, such as the wallpaper
picker in the `ii` shell — searchable, pageable, filterable, with its rows in the same shape as
every other source. Most of the 156 shipped sources are exactly this; only the
awkward ones are Rust (Reddit's OAuth, pfps.gg's HTML, AniList's GraphQL), and
both kinds implement the same trait so nothing downstream can tell them apart.

A manifest whose `id` matches a shipped one **replaces** it, so you can fix a
source that has changed its API without editing the install.

## The smallest thing that works

```toml
id = "catapi"
label = "The Cat API"
category = "photography"

[request]
url = "https://api.thecatapi.com/v1/images/search?limit={limit}"
format = "json"
limit = 40

[map]
id = "id"
url = "url"
width = "width"
height = "height"
page_url = "url"        # no page of its own; the file is the thing
```

`[request].url` is a template. `{query}`, `{tags}`, `{page}`, `{page0}`,
`{offset}`, `{limit}`, `{minw}`, `{minh}`, `{author}`, `{sort}` and
`{page_value}` are substituted. Anything else is left alone, so a typo shows up
in the URL rather than silently vanishing.

`[map]` says which field of the response is which. Paths walk into nested
objects with dots. `id` and `url` are the two that make a row a row; everything
else is optional and stays empty when the key is absent. Nested fields use a
dotted path — `file.url`, `preview.url`, as e621 and its relatives publish them.

## Checking it

```sh
quarry-proto doctor                 # installed with the package
tools/proto.sh doctor               # or from a checkout
```

Fetches every source's first page, parses it, and reports `status`, how many
rows `parsed`, and the URL it used. A source that answers 200 and parses 0 rows
is reported as failing — which is usually a wrong path in `[map]`, not a broken
site. Then:

```sh
quarry-proto query '{"text":"cat","sources":["catapi"]}' items '{"queryId":1,"limit":3}'
```

Both frames go down one connection on purpose: `queryId` refers to the daemon's
current result, so a query and the fetch that follows have to share a session.

## The three formats

`format = "json"` is the default. `[request].root` names the array to walk;
omit it when the document itself is one.

`format = "rss"` reads RSS, RDF and Atom, including the Yahoo media extensions
(`media:content`, `media:thumbnail`, `media:rating`, `media:credit`). Nothing
else to configure — the fields are fixed.

`format = "html"` needs an `[html]` block: a `row` selector, and a field per
thing to pull out of it.

```toml
[request]
url = "https://www.erome.com/search?q={query}&page={page}"
format = "html"
space = "+"

[html]
row = "div.album"
base = "https://www.erome.com"        # what relative URLs resolve against
next = "a.next"                       # presence means "there is another page"

[html.fields]
# The id lives in the element's own id attribute: "album-22707242".
id    = { attr = "id", re = "album-(\\d+)" }
page  = { sel = "a.album-link", attr = "href" }
thumb = { sel = "img.album-thumbnail", attr = "src" }
title = { sel = "img.album-thumbnail", attr = "alt" }

[map]
id = "id"
url = "thumb"
page_url = "page"
```

A field takes `sel` (a CSS selector inside the row; empty means the row itself),
`attr` (empty means the element's text), `re` (keep only what it matches, or
capture group 1 if there is one), `all = true` for every match as a list rather
than the first, and `abs` to force URL resolution on or off.

## Paging, which is where sources break

**Something in the URL must advance.** A URL with no `{page}`, `{page0}`,
`{offset}` or `{page_value}` crawls its first page for ever, and every "next
page" is identical to the last. This is checked by the test suite for the
shipped manifests, and it is the single most common mistake.

Some sources are not paged by number at all. Peapix publishes the Bing
wallpaper of the day per market: seven rows a feed, `page` ignored. That is not
one list with pages, it is fourteen small lists — so list them and let
`{page_value}` cycle through:

```toml
url = "https://peapix.com/bing/feed?country={page_value}"
page_values = ["us", "jp", "de", "gb", "fr", "cn", "in", "es", "it", "br", "ca", "au", "nz", "row"]
```

The list's length is how many pages the source has — fourteen, above. Where a
source really does answer everything at once, a single-element list says so, and
the token can ride in the URL fragment, which is never sent:
`...&n=8&mkt=en-US#page={page_value}` with `page_values = ["1"]`. `page_values` and
`{page_value}` go together; one without the other is either decoration or a
URL that never changes.

**A source that answers nothing to an empty query needs `browse_term`.** Three
hand-written adapters hit this before it was a field: with no search term the
site answers 400, or zero rows, and it reads as broken rather than unsearched.

## Capabilities are claims about the site, not wishes

```toml
[capabilities]
text = true
tags = true
nsfw = false
sort = false
```

This block means "the site's API can filter on this", and it is load-bearing in
a way that is easy to get backwards. When a source claims a capability, the
query planner pushes that predicate into the request **and drops it from the
local residue**. So claiming one the site cannot actually do does not degrade
the filter — it removes it from everywhere, and `-nsfw` becomes a silent no-op
instead of a visible gap.

Leave a capability `false` and the clause stays local, where the matcher applies
it against the row. Same answer, honestly obtained, at the cost of fetching
rows that get discarded.

Three capabilities are only true if you also supply the words:

- `nsfw` needs **both** `sfw_tag` and `nsfw_tag` in `[request]` — `rating:g` and
  `-rating:g` on Danbooru, `safe` / `-safe` on Philomena. A source that can only
  say one half would answer `nsfw` with its usual mixture and nothing would
  filter it afterwards.
- `video` comes from the presence of `video_tag` — `video` on Danbooru,
  `type:webm` on e621.
- `sort` needs a `[request].sort` table mapping quarry's sort names (`new`,
  `large`, …) plus `default` to the site's own words. A value may carry extra
  parameters after an `&` for sites where an ordering is really two parameters.
- `author` needs `{author}` in the URL, or `author_tag` for a board where the
  creator is a tag (`user:{author}`).

## Marking adult content

`adult = true` at the top level means **everything this source returns** is
adult. It is a fact about the source, not a capability: `capabilities.nsfw` says
"this site can filter by rating", which is a different question from "what comes
back should be marked". Without it the rows arrive unmarked and `-nsfw` keeps
every one of them.

A board that mixes both — yande.re, AIBooru — is neither, and needs a per-row
answer:

```toml
[map]
rating = "rating"
nsfw_ratings = ["questionable", "explicit"]
```

Compared case-insensitively, because mspabooru answers both `safe` and `Safe`.
An absent rating marks nothing: a guess either way would be quarry deciding
rather than the site.

## Credentials

```toml
[auth]
vars = ["GELBOORU_USER_ID", "GELBOORU_API_KEY"]
query = "&user_id={GELBOORU_USER_ID}&api_key={GELBOORU_API_KEY}"
hint = "https://gelbooru.com/index.php?page=account&s=options — API Access Credentials tab"
```

Every variable must be set or the source does not load at all, and an empty
variable counts as unset — a leftover `export FOO=` from a half-finished setup
should read as "not done", not as a real value. `hint` is folded into the
startup log when one is missing, so the fix is a click rather than a search.

## Smaller things that have each cost an afternoon

- **`space`** is what a space becomes in a substituted value. `+` by default; a
  site whose search is a path segment needs `%20`, because Shimmie answers 404
  to a literal plus.
- **`joiner`** glues terms together, a space on nearly every booru. Philomena is
  the exception that makes it a key: a tag there may *contain* a space, so
  `wallpaper safe` is one tag nobody has and returns nothing, while
  `wallpaper,safe` returns ten thousand rows.
- **`ext`** in `[map]` is for URLs that carry no extension. Shimmie serves
  images from an extensionless path, and without this every video there read as
  a still picture.
- **Duration** has three spellings — `duration` (seconds), `duration_ms`, and
  `duration_clock` for the `15:10` form the tube sites publish. Use exactly
  one: a length in the wrong unit turns a three-minute song into fifty hours,
  and `"15:10".parse::<f64>()` reads as fifteen seconds.
- **`tag_resolver`** looks typed words up as the site's real tags before
  searching (`danbooru`, `gelbooru`, `moebooru`, `e621`, `philomena`,
  `eshuushuu`).
- **`user_agent`** should stay empty. `"browser"` spells out a browser string,
  and any other value is sent literally — but only for hosts measured to answer
  403 to the honest one, never assumed. `grep -l user_agent sources/` then lists
  every exception in one command.
- **`[[sections]]`** surfaces the site's own categories in the filter panel.
  `label` is what is shown, `q` is the query it runs and defaults to the label,
  which is right for a category: its name *is* the search.

## Contributing one back

Shipped manifests live in `sources/`. The test suite loads every one and checks
that its URL is https, that `[map]` has `id` and `url`, that paging advances,
that an adult source says so, and that a credentialed source explains where to
get the credentials. Run it with:

```sh
cargo test --test sources the_shipped_manifests_are_coherent
```

Probe the source live before opening a pull request, and say in a comment at the
top of the file when you did. Several manifests carry exactly that line, and it
is the difference between a source that works and one that used to.

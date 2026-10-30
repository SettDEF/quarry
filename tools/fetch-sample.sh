#!/usr/bin/env bash
# Build fixtures/sample.json — real items from live sources, in the Item shape
# of ITEM.md. Temporary: the Rust indexer replaces this from Phase 6.
#
#   tools/fetch-sample.sh > fixtures/sample.json
set -euo pipefail
UA="Mozilla/5.0 (X11; Linux x86_64) quarry/0.1 (personal use)"
get() { curl -sL -m 25 -A "$UA" "$1"; }
now=$(date +%s)

{
# ── wallhaven: wallpapers, raster ────────────────────────────────────────────
get "https://wallhaven.cc/api/v1/search?q=landscape&categories=100&purity=100&sorting=toplist" |
  jq -c --argjson now "$now" '.data[:24][] | {
    id: ("wallhaven:" + .id), source: "wallhaven", source_id: .id,
    family: "raster", kind: "wallpaper", title: (.id), slug: ("wallhaven-" + .id),
    url: .path, thumb: .thumbs.small, page_url: .url,
    ext: (.file_type | sub("image/"; "")),
    w: .dimension_x, h: .dimension_y,
    ratio: (.dimension_x / .dimension_y), bytes: .file_size,
    animated: false, tintable: false, nsfw: (.purity != "sfw"),
    author: "", license: "", tags: [.category],
    added_at: $now, phash: "", dominant: (.colors[0] // "")
  }'

# ── pfps.gg: avatars, raster (HTML scrape — no JSON API) ──────────────────────
get "https://pfps.gg/?sort=featured" |
  grep -oE 'https://cdn\.pfps\.gg/pfps/[0-9]+-[0-9]+-[a-z0-9-]+\.(png|jpeg|jpg|gif)' |
  sort -u | head -40 |
  jq -R -c --argjson now "$now" '
    . as $u
    | ($u | capture("pfps/(?<id>[0-9]+)-[0-9]+-(?<slug>[a-z0-9-]+)\\.(?<ext>[a-z]+)$")) as $m
    | { id: ("pfps.gg:" + $m.id), source: "pfps.gg", source_id: $m.id,
        family: "raster", kind: "avatar",
        title: ($m.slug | gsub("-"; " ")), slug: $m.slug,
        url: $u, thumb: $u, page_url: "https://pfps.gg/",
        ext: $m.ext, w: 400, h: 400, ratio: 1.0, bytes: 0,
        animated: ($m.ext == "gif"), tintable: false, nsfw: false,
        author: "", license: "", tags: ["pfp"],
        added_at: $now, phash: "", dominant: "" }'

# ── danbooru: raster, real tags ───────────────────────────────────────────────
get "https://danbooru.donmai.us/posts.json?tags=rating:general&limit=20" |
  jq -c --argjson now "$now" '.[] | select(.file_url != null and .image_width > 0) | {
    id: ("danbooru:" + (.id | tostring)), source: "danbooru", source_id: (.id | tostring),
    family: "raster", kind: (if (.image_width / .image_height) > 1.4 then "wallpaper" else "avatar" end),
    title: (.tag_string_character // ""), slug: ("danbooru-" + (.id | tostring)),
    url: .file_url, thumb: (.preview_file_url // .file_url), page_url: ("https://danbooru.donmai.us/posts/" + (.id | tostring)),
    ext: .file_ext, w: .image_width, h: .image_height,
    ratio: (.image_width / .image_height), bytes: (.file_size // 0),
    animated: (.file_ext == "gif"), tintable: false, nsfw: (.rating != "g"),
    author: (.tag_string_artist // ""), license: "",
    tags: (.tag_string_general // "" | split(" ") | .[:8]),
    added_at: $now, phash: "", dominant: ""
  }'

# ── Met Museum: raster, public domain (one request per object) ───────────────
# NOTE: Art Institute of Chicago was the first pick — its metadata API is 200 but
# its IIIF image host answers 403 from here even with the AIC-User-Agent header,
# so its images are daemon-fetch-only and cannot be remote thumbs in the view.
for oid in $(get "https://collectionapi.metmuseum.org/public/collection/v1/search?q=painting&hasImages=true" | jq -r '.objectIDs[:12][]'); do
  get "https://collectionapi.metmuseum.org/public/collection/v1/objects/$oid" |
    jq -c --argjson now "$now" 'select(.primaryImageSmall != null and .primaryImageSmall != "") | {
      id: ("met:" + (.objectID | tostring)), source: "met", source_id: (.objectID | tostring),
      family: "raster", kind: "wallpaper", title: .title,
      slug: ("met-" + (.objectID | tostring)),
      url: (if .primaryImage != "" then .primaryImage else .primaryImageSmall end),
      thumb: .primaryImageSmall,
      page_url: .objectURL, ext: "jpg",
      w: 843, h: 1000, ratio: 0.843, bytes: 0,
      animated: false, tintable: false, nsfw: false,
      author: (.artistDisplayName // ""), license: (.rightsAndReproduction // "public domain"),
      tags: [(.department // "art")],
      added_at: $now, phash: "", dominant: ""
    }'
done

# ── Iconify: vectors, tintable ───────────────────────────────────────────────
for prefix in mdi ph tabler; do
  get "https://api.iconify.design/collection?prefix=$prefix" |
    jq -c --arg p "$prefix" --argjson now "$now" '
      ((.uncategorized // []) + ([.categories // {} | .[] | .[]] | flatten))[:12][] |
      { id: ("iconify:" + $p + ":" + .), source: "iconify", source_id: ($p + ":" + .),
        family: "vector", kind: "icon", title: ., slug: ($p + "-" + .),
        url: ("https://api.iconify.design/" + $p + "/" + . + ".svg"),
        thumb: ("https://api.iconify.design/" + $p + "/" + . + ".svg?height=128"),
        page_url: ("https://icon-sets.iconify.design/" + $p + "/" + . + "/"),
        ext: "svg", w: 24, h: 24, ratio: 1.0, bytes: 0,
        animated: false, tintable: true, nsfw: false,
        author: $p, license: "open source", tags: ["icon", $p],
        added_at: $now, phash: "", dominant: "" }'
done

# ── Poly Haven: 3D models and HDRIs ──────────────────────────────────────────
get "https://api.polyhaven.com/assets?t=models" |
  jq -c --argjson now "$now" 'to_entries[:16][] | {
    id: ("polyhaven:" + .key), source: "polyhaven", source_id: .key,
    family: "model", kind: "cover", title: .value.name, slug: .key,
    url: ("https://api.polyhaven.com/files/" + .key),
    thumb: ("https://cdn.polyhaven.com/asset_img/thumbs/" + .key + ".png?width=256&height=256"),
    page_url: ("https://polyhaven.com/a/" + .key),
    ext: "gltf", w: 256, h: 256, ratio: 1.0, bytes: 0,
    animated: false, tintable: false, nsfw: false,
    author: "Poly Haven", license: "CC0",
    tags: (.value.tags // [])[:6],
    added_at: $now, phash: "", dominant: ""
  }'
} | jq -s -c '{ version: 1, generated: now | floor, items: . }'

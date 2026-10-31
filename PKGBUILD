# Maintainer: SettDEF
#
# Builds the working tree, so there is nothing to download:
#
#   makepkg -f                        # produces quarry-*.pkg.tar.zst
#   sudo pacman -U quarry-*.pkg.tar.zst
#
# or in one step:  tools/install.sh
#
# arch=x86_64 because the daemon and the board are compiled; the main UI is
# pure QML and is copied.

pkgname=quarry
pkgver=0.1.0.r20261026.2341
pkgrel=1
pkgdesc="Picture query engine — search many sources and export for any image slot"
arch=('x86_64')
url="https://github.com/SettDEF/quarry"
license=('MIT')

depends=(
    # The browser window a lens opens for what an API cannot answer.
    'qt6-webengine'
    'quickshell'          # the UI is a quickshell config, run by path
    'qt6-declarative'     # QtQuick, Controls, Layouts
    'qt6-5compat'         # Qt5Compat.GraphicalEffects — OpacityMask for ripples
    'qt6-svg'             # renders the app icon and any SVG the daemon does not
    'qt6-websockets'      # QtWebSockets: services/Dispatch.qml (and the morse lens); without it
                          # the window does not open ("module QtWebSockets is not installed")
    'qt6-quick3d'         # QtQuick3D + AssetUtils: the 3D model view (modules/gallery/ModelView.qml);
                          # DetailView loads it, so without it the window does not open either
    'bash'
    # quarry-proto speaks the unix socket with it.
    'socat'
    'hicolor-icon-theme'
    # OpenSSL, for one source and one reason: Reddit's edge fingerprints the
    # TLS handshake and refuses rustls before it reads the request. Everything
    # else still speaks rustls and carries its own roots.
    'openssl'
    # Poster frames and durations for video rows.
    'ffmpeg'
    # The board is a native window: OpenGL, and Wayland with an X11 fallback.
    'libglvnd'
    'libxkbcommon'
    'wayland'
)

makedepends=('rust' 'cmake')

# rustls' crypto backend (`ring`) compiles C alongside Rust, and Arch's default
# `-flto=auto` in CFLAGS makes the C objects unlinkable against the Rust ones:
# the build dies with a wall of `undefined symbol: ring_core_*`. Disabling LTO
# for this package is the standard fix and costs nothing measurable here.
#
# '!debug' because a separate quarry-debug package is a trap here: makepkg
# writes it *after* the real one, so anything picking "the newest .pkg.tar.zst"
# installs debug symbols and no application. There is no call for split debug
# symbols on a personal build.
options=('!lto' '!debug')

optdepends=(
    # The in-app browser (modules/gallery/BrowserView.qml). Optional, not a
    # hard dependency: it is a 150 MB install for one view, and quarry says so
    # and hands the page to your own browser when it is missing. Qt WebEngine
    # additionally needs the host quickshell to pass its argument list through
    # — 0.3.1 does not (see BrowserView.qml), so this is dormant there.
    'ttf-material-symbols-variable-git: the icon font — without it every icon is a blank box'
    'ttf-readex-pro: reading font'
    'otf-space-grotesk: display font'
    'ttf-jetbrains-mono-nerd: monospace font for the numbers'
    'tinct: live Material You palette the app follows'
    'wl-clipboard: paste pictures onto the board, copy them and picked colours out'
    'xdg-user-dirs: board exports land in your own Pictures folder'
    'python-pillow: quarry term, the catalogue in a terminal'
    'mpv: quarry term plays video and audio'
)

source=()
sha256sums=()

# makepkg copies nothing with an empty source array, so reference the checkout.
# $startdir is the directory holding this PKGBUILD.

prepare() {
    cd "$startdir/quarryd"
    # Vendor-free but reproducible: lock the dependency versions that were
    # tested, rather than resolving fresh at package time.
    cargo fetch --locked --target "$CARCH-unknown-linux-gnu"
    cd "$startdir/board"
    cargo fetch --locked --target "$CARCH-unknown-linux-gnu"
}


#
# THE VERSION IS THE NEWEST SOURCE FILE'S TIMESTAMP.
#
# Every build was pkgver-pkgrel with both hardcoded, so pacman could not tell
# two of them apart: `-Syu` never saw an upgrade and the repo index held one
# entry however many times it was rebuilt. Taken from the source mtime rather
# than from `date`, so the version moves when the CODE moves and rebuilding
# untouched sources gives the same version back — which is what makes an index
# mean anything.
#
pkgver() {
    cd "$startdir"
    local newest
    # EVERYTHING THAT SHIPS, not just the parts someone remembered.
    #
    # `optional-lenses` and `scripts` were missing, so changing a lens or a
    # script built a package whose version said nothing had changed — the same
    # version string over different contents. That is indistinguishable from
    # "the fix is installed and does nothing", which this project has now spent
    # several rounds chasing from the other end (see StaleBar.qml).
    newest=$(find quarryd/src modules services sources scripts optional-lenses extensions tools shell.qml PKGBUILD \
        -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
    printf '0.1.0.r%s' "$(date -u -d "@${newest:-0}" +%Y%m%d.%H%M)"
}

build() {
    cd "$startdir/quarryd"
    export RUSTUP_TOOLCHAIN=stable
    # PERSISTENT TARGET DIR. This was "$srcdir/target", and makepkg wipes and
    # recreates $srcdir every run — so cargo never saw a previous build and
    # recompiled every crate, every install, for a one-line QML change. Kept
    # outside the build dir it is a normal incremental build: only what changed.
    # Override with QUARRY_TARGET_DIR if you want a throwaway one.
    export CARGO_TARGET_DIR="${QUARRY_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets}"
    cargo build --frozen --release
    cd "$startdir/board"
    cargo build --frozen --release

    # ── the browser window ───────────────────────────────────────────────────
    #
    # A separate Qt program, and it has to be: quickshell hands Qt an empty
    # argument list, and Qt WebEngine ABORTS the process when there is none —
    # so a web view can never live inside the app's own. See browser/main.cpp.
    cmake -S "$startdir/browser" -B "${QUARRY_BROWSER_BUILD:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/browser-build}" \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "${QUARRY_BROWSER_BUILD:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/browser-build}"
}

check() {
    cd "$startdir/quarryd"
    export RUSTUP_TOOLCHAIN=stable
    # PERSISTENT TARGET DIR. This was "$srcdir/target", and makepkg wipes and
    # recreates $srcdir every run — so cargo never saw a previous build and
    # recompiled every crate, every install, for a one-line QML change. Kept
    # outside the build dir it is a normal incremental build: only what changed.
    # Override with QUARRY_TARGET_DIR if you want a throwaway one.
    export CARGO_TARGET_DIR="${QUARRY_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets}"
    # The parser tests are offline by design, so this is safe in a clean chroot.
    cargo test --frozen --release

    # THE QML SIDE HAS NO COMPILER, so the wiring is checked here instead.
    #
    # QML resolves names at runtime: a call to a method that does not exist
    # raises a TypeError inside whatever handler it is in, aborts the rest of
    # that handler, and prints where nobody is looking. `Catalog.refresh()` did
    # exactly that for an unknown number of releases — turning the adult switch
    # off told the daemon and never re-queried, so the wall went on showing what
    # had just been switched off, with nothing logged and every test green.
    #
    # `--strict` fails on a call that cannot resolve, or on a signal nobody
    # listens to that is not in tools/lint-qml.baseline.
    cd "$startdir"
    ./tools/lint-qml.sh --strict
}

package() {
    cd "$startdir"

    # ── the daemon ───────────────────────────────────────────────────────────
    # Read the binary from wherever build() actually put it. This was hardcoded
    # to "$srcdir/target", which silently tied the install path to the build dir
    # — moving CARGO_TARGET_DIR out of $srcdir (so cargo stops recompiling every
    # crate on every install) broke packaging until this followed it.
    _target="${QUARRY_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets}"
    install -Dm755 "$_target/release/quarryd" "$pkgdir/usr/bin/quarryd"
    # The board, native. /usr/bin/quarry-board is the launcher that makes sure
    # the daemon is up; this is what it runs.
    install -Dm755 "$_target/release/quarry-board" "$pkgdir/usr/lib/quarry/quarry-board"
    # The browser window, and the QML it draws.
    _browser="${QUARRY_BROWSER_BUILD:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/browser-build}"
    install -Dm755 "$_browser/quarry-browser" "$pkgdir/usr/bin/quarry-browser"
    install -Dm644 browser/Browser.qml "$pkgdir/usr/share/quarry/browser/Browser.qml"
    install -Dm644 browser/Theme.qml "$pkgdir/usr/share/quarry/browser/Theme.qml"
    #
    # TELA'S CHROME, COPIED AT PACKAGE TIME.
    #
    # In a checkout `browser/tela-chrome` is a SYMLINK into the tela
    # checkout, so editing tela changes quarry's browser with no copy to
    # drift. A package cannot ship a symlink to somebody else's source tree,
    # so the files are resolved and copied here — `cp -L` rather than `cp`,
    # or the package would contain a dangling link and the window would fail
    # to load with "Type TabStrip unavailable".
    #
    install -dm755 "$pkgdir/usr/share/quarry/browser/tela-chrome"
    cp -L browser/tela-chrome/*.qml "$pkgdir/usr/share/quarry/browser/tela-chrome/"

    # ── the UI, as a quickshell config run by path ────────────────────────────
    install -dm755 "$pkgdir/usr/share/quarry/qml"
    install -Dm644 shell.qml "$pkgdir/usr/share/quarry/qml/shell.qml"
    # board.qml is no longer shipped: the board is a native window now (board/),
    # because a see-through QML window picked up the compositor's layer blur
    # and QML gave no control over the window it was drawing in.
    cp -r modules services "$pkgdir/usr/share/quarry/qml/"
    # The example scripts, beside the QML that copies them into a person's own
    # folder (Settings → Scripts). Shipped read-only on purpose: what you edit
    # is your copy, and an example that could be edited in place would be an
    # example that a package update silently reverts.
    install -dm755 "$pkgdir/usr/share/quarry/qml/scripts"
    install -Dm644 scripts/*.js "$pkgdir/usr/share/quarry/qml/scripts/"
    install -Dm644 SCRIPTS.md "$pkgdir/usr/share/doc/quarry/SCRIPTS.md"

    # ── the declarative sources ──────────────────────────────────────────────
    #
    # NINETEEN OF THE TWENTY-NINE SOURCES LIVE IN THESE FILES, and the package
    # was shipping none of them: an installed quarry had only the hand-written
    # Rust adapters and silently lacked every booru, every museum and Openverse.
    # The daemon has always looked here — `Declarative::directories()` tries
    # `<exe>/../share/quarry/sources` first — so this was a packaging omission
    # and not a missing feature, which is exactly why nothing ever failed
    # loudly enough to notice.
    install -dm755 "$pkgdir/usr/share/quarry/sources"
    cp -r sources/. "$pkgdir/usr/share/quarry/sources/"

    # ── the shipped extensions ───────────────────────────────────────────────
    #
    # Resolved by `Extensions.builtinDir`, which is `../extensions` relative to
    # services/ — so under qml/, not beside it. Newly load-bearing: the Steam
    # profile mockup is an extension now, so without this the in-context layout
    # loses a pane and says "no mockup packs are on" on a fresh install.
    install -dm755 "$pkgdir/usr/share/quarry/qml/extensions"
    cp -r extensions/. "$pkgdir/usr/share/quarry/qml/extensions/"

    # cp -r keeps the checkout's write bits; normalise so the package is
    # reproducible regardless of umask.
    find "$pkgdir/usr/share/quarry" -type d -exec chmod 755 {} +
    find "$pkgdir/usr/share/quarry" -type f -exec chmod 644 {} +

    # The fixture ships too: it is the offline fallback when no daemon is up.
    install -Dm644 fixtures/sample.json "$pkgdir/usr/share/quarry/fixtures/sample.json"

    # ── entry points ─────────────────────────────────────────────────────────
    install -Dm755 packaging/quarry.sh "$pkgdir/usr/bin/quarry"
    # A folder of wallpapers, for anything that wants one. Same four arguments
    # and the same two lines of output as the Reddit fetcher it replaces, so a
    # shell that can page through one source can page through all of quarry's.
    install -Dm755 tools/quarry-fetch.sh "$pkgdir/usr/bin/quarry-fetch"
    # `quarry term`: the catalogue drawn in a terminal.
    install -Dm755 tools/quarry-term "$pkgdir/usr/lib/quarry/quarry-term"
    install -Dm644 packaging/quarry.desktop "$pkgdir/usr/share/applications/quarry.desktop"
    install -Dm755 packaging/quarry-board.sh "$pkgdir/usr/bin/quarry-board"
    install -Dm644 packaging/quarry-board.desktop \
        "$pkgdir/usr/share/applications/quarry-board.desktop"
    install -Dm644 packaging/quarryd.service \
        "$pkgdir/usr/lib/systemd/user/quarryd.service"

    # ── icon ─────────────────────────────────────────────────────────────────
    install -Dm644 packaging/quarry.svg \
        "$pkgdir/usr/share/icons/hicolor/scalable/apps/quarry.svg"
    # the board's: the same blocks with a dot in the middle (packaging/quarry-board.vectorcraft)
    install -Dm644 packaging/quarry-board.svg \
        "$pkgdir/usr/share/icons/hicolor/scalable/apps/quarry-board.svg"
    if command -v rsvg-convert >/dev/null 2>&1; then
        for size in 16 22 24 32 48 64 128 256; do
            install -dm755 "$pkgdir/usr/share/icons/hicolor/${size}x${size}/apps"
            for icon in quarry quarry-board; do
                rsvg-convert -w "$size" -h "$size" "packaging/$icon.svg" \
                    -o "$pkgdir/usr/share/icons/hicolor/${size}x${size}/apps/$icon.png"
                chmod 644 "$pkgdir/usr/share/icons/hicolor/${size}x${size}/apps/$icon.png"
            done
        done
    fi

    # ── docs: the protocol is the contract, so it ships ───────────────────────
    install -Dm644 docs/adding-a-source.md \
        "$pkgdir/usr/share/doc/quarry/adding-a-source.md"
    # The one tool a user needs to test a source they wrote themselves: without
    # it `doctor` is only reachable from a checkout, and the manifest system
    # might as well not exist for anyone who installed the package.
    install -Dm755 tools/proto.sh "$pkgdir/usr/bin/quarry-proto"
    install -Dm644 PROTOCOL.md "$pkgdir/usr/share/doc/quarry/PROTOCOL.md"
    install -Dm644 ITEM.md "$pkgdir/usr/share/doc/quarry/ITEM.md"
    install -Dm644 PLAN.md "$pkgdir/usr/share/doc/quarry/PLAN.md"
}

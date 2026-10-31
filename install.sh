#!/usr/bin/env bash
#
# quarry installer.
#
#   curl -fsSL https://raw.githubusercontent.com/SettDEF/quarry/main/install.sh | bash
#
# …or, to pass options through the pipe (note the `-s --`):
#
#   curl -fsSL https://raw.githubusercontent.com/SettDEF/quarry/main/install.sh \
#     | bash -s -- --yes --no-enable
#
# Run from inside a checkout it builds that checkout instead of cloning.
#
# Safe to re-run: the clone is updated and pacman replaces the installed copy,
# so nothing is left behind in /usr the way `make install` leaves things.
set -euo pipefail

REPO_URL="https://github.com/SettDEF/quarry"
BRANCH="main"
SRC_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/quarry-src"

ASSUME_YES=0
SKIP_DEPS=0
DO_ENABLE=1

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; R=$'\033[0m'
else
  B=''; DIM=''; RED=''; GREEN=''; R=''
fi

step() { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
info() { printf '    %s\n' "$*"; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$R"; }
die()  { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

# Piped into bash, stdin IS the script, so a prompt must read the terminal
# directly — and must check it can be OPENED, not merely that it exists.
have_tty() { exec 3</dev/tty 2>/dev/null && exec 3<&-; }

ask() {
  local prompt="$1" default="$2" reply
  if [ "$ASSUME_YES" = 1 ] || ! have_tty; then
    printf '    %s %s(%s)%s\n' "$prompt" "$DIM" "$default" "$R"
    [ "$default" = y ]
    return
  fi
  read -r -p "    $prompt [$( [ "$default" = y ] && echo 'Y/n' || echo 'y/N' )] " reply </dev/tty
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --yes            Take every default; never prompt.
  --dir PATH       Where to clone and build (default: ~/.local/share/quarry-src).
  --branch NAME    Branch to clone (default: main).
  --no-deps        Do not install dependencies with pacman.
  --no-enable      Do not enable quarryd at login.
  -h, --help       This.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1 ;;
    --dir)      [ $# -ge 2 ] || die "--dir needs a path"; SRC_DIR="$2"; shift ;;
    --branch)   [ $# -ge 2 ] || die "--branch needs a name"; BRANCH="$2"; shift ;;
    --no-deps)  SKIP_DEPS=1 ;;
    --no-enable) DO_ENABLE=0 ;;
    --enable)   die "unknown option: --enable (the daemon is enabled by default; --no-enable skips it)" ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[ "$(id -u)" != 0 ] || die "do not run this as root — makepkg refuses to build as root, and it calls sudo itself where it needs to."
command -v pacman >/dev/null 2>&1 || die "this installer builds an Arch package and needs pacman."
command -v sudo >/dev/null 2>&1 || die "sudo is needed to install the package."
curl -fsS --head --max-time 10 https://github.com >/dev/null 2>&1 \
  || die "no route to github.com — check the network first."

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/PKGBUILD" ]; then
  SRC_DIR="$SELF_DIR"; CLONE=0
  step "Building the checkout at $SRC_DIR"
else
  CLONE=1
fi

# `cargo` as a package name resolves to rustup, which installs with NO toolchain
# selected — the build then dies on "no default toolchain" with nothing pointing
# at the cause. Ask for `rust` and it cannot happen.
DEPS=(
  git base-devel rust cmake
  quickshell qt6-declarative qt6-5compat qt6-svg qt6-websockets qt6-quick3d qt6-webengine
  openssl ffmpeg libglvnd libxkbcommon wayland hicolor-icon-theme
)

if [ "$SKIP_DEPS" = 1 ]; then
  step "Skipping dependencies (--no-deps)"
else
  step "Dependencies"
  missing=()
  for p in "${DEPS[@]}"; do pacman -T "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -eq 0 ]; then
    info "already satisfied"
  else
    info "installing: ${missing[*]}"
    sudo -v
    # quickshell is not in the official repos; use an AUR helper when there is one.
    helper=""
    for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { helper="$h"; break; }; done
    if [ -n "$helper" ]; then
      "$helper" -S --needed --noconfirm "${missing[@]}"
    else
      sudo pacman -S --needed --noconfirm "${missing[@]}" \
        || die "some of these are in the AUR (quickshell). Install an AUR helper (paru or yay) and re-run."
    fi
  fi
fi

if ! cargo --version >/dev/null 2>&1; then
  if command -v rustup >/dev/null 2>&1; then
    step "Rust toolchain"
    info "rustup has no default toolchain; installing stable"
    rustup default stable
  else
    die "cargo is not usable and rustup is not installed."
  fi
fi

if [ "$CLONE" = 1 ]; then
  if [ -d "$SRC_DIR/.git" ]; then
    step "Updating $SRC_DIR"
    git -C "$SRC_DIR" fetch --quiet origin "$BRANCH"
    if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
      note "local changes present — leaving them alone, building what is there"
    else
      git -C "$SRC_DIR" checkout --quiet "$BRANCH"
      git -C "$SRC_DIR" merge --quiet --ff-only "origin/$BRANCH"
      info "at $(git -C "$SRC_DIR" rev-parse --short HEAD)"
    fi
  else
    step "Cloning into $SRC_DIR"
    [ ! -e "$SRC_DIR" ] || die "$SRC_DIR exists and is not a git checkout. Move it, or pass --dir."
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
    info "at $(git -C "$SRC_DIR" rev-parse --short HEAD)"
  fi
fi

step "Building the package"
note "the daemon and the board are compiled; the first build takes a while"
cd "$SRC_DIR"
# A stale package from a previous build would be picked up by the glob below.
rm -f quarry-*.pkg.tar.zst
makepkg -fsi --noconfirm

step "Verifying"
pacman -Q quarry >/dev/null 2>&1 || die "pacman does not report quarry as installed — the build reported success but installed nothing."
command -v quarryd >/dev/null 2>&1 || die "quarry is installed but quarryd is not on PATH."
info "$(pacman -Q quarry)"
info "daemon: $(command -v quarryd)"

# The shell reaches quarryd over a unix socket, so an installed binary nothing
# starts leaves every client on its fallback path, looking like a broken install.
if [ "$DO_ENABLE" = 1 ] && ask "Start quarryd now and at login?" y; then
  step "Enabling quarryd"
  systemctl --user daemon-reload
  systemctl --user enable --now quarryd.service
  sleep 1
  if systemctl --user is-active --quiet quarryd.service; then
    info "running: $(systemctl --user show -p MainPID --value quarryd.service)"
  else
    note "quarryd did not stay up; see: systemctl --user status quarryd"
  fi
fi

printf '\n%squarry is installed.%s  Source: %s\n' "$GREEN" "$R" "$SRC_DIR"
printf '    Re-run this script to update.\n\n'

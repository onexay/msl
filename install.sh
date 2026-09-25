#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# msl installer: Modern Subsystem for Linux.
#
#   sh install.sh [options]
#   curl -fsSL <url>/install.sh | sh          (prompts are read from the terminal)
#
# Options:
#   --prefix <dir>     install location (default: ~/.local; /usr/local uses sudo)
#   --version <x.y.z>  release to install (default: the latest)
#   --from <tarball>   install a local msl-<version>-macos-arm64.tar.gz instead of downloading
#   --yes, -y          accept the defaults; don't prompt
#   --no-path          don't add the prefix to PATH
#   --no-ide           don't set up the MSL extension in VS Code, VSCodium or Cursor
#   --help
#
# Environment: MSL_REPO (default onexay/msl), GITHUB_TOKEN (for a private repo
# when the GitHub CLI isn't logged in), MSL_PREFIX, MSL_VERSION.
set -eu

REPO=${MSL_REPO:-onexay/msl}
# Release signing key (SECURITY.md); checksums signed with it are verified when gpg is installed.
RELEASE_KEY=E8803CF7DBA78BCB3F0B8F1D43E89DC44167036A
PREFIX=${MSL_PREFIX:-}
VERSION=${MSL_VERSION:-}
FROM=
YES=0
EDIT_PATH=1
SETUP_IDE=1

if [ -t 1 ]; then B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[31m'); G=$(printf '\033[32m'); N=$(printf '\033[0m'); else B='' D='' R='' G='' N=''; fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() { sed -n '2,/^[^#]/{/^#/p;}' "$0" | grep -v SPDX | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case $1 in
    --prefix)  [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION=${2#v}; shift ;;
    --from)    [ $# -ge 2 ] || die "--from needs a file"; FROM=$2; shift ;;
    --yes|-y)  YES=1 ;;
    --no-path) EDIT_PATH=0 ;;
    --no-ide)  SETUP_IDE=0 ;;
    --help|-h) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# Prompts read from the terminal, so `curl … | sh` is still interactive.
TTY=/dev/tty
if [ "$YES" = 0 ] && ! { : < "$TTY"; } 2>/dev/null; then YES=1; fi

# ask <question> <default>: prints the answer (the default with --yes).
ask() {
  if [ "$YES" = 1 ]; then printf '%s' "$2"; return; fi
  printf '%s %s[%s]%s ' "$1" "$D" "$2" "$N" > "$TTY"
  read -r a < "$TTY" || a=
  printf '%s' "${a:-$2}"
}
# confirm <question> <y|n>: succeeds on yes.
confirm() {
  a=$(ask "$1 (y/n)" "$2")
  case $a in [Yy]*) return 0 ;; *) return 1 ;; esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say ""
say "${B}Modern Subsystem for Linux${N}: installer"
say ""

# --- System checks -----------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "msl runs on macOS only."
[ "$(uname -m)" = arm64 ] || die "msl needs a Mac with Apple silicon."
MACOS=$(sw_vers -productVersion)
[ "${MACOS%%.*}" -ge 26 ] 2>/dev/null || die "msl needs macOS 26 or later (this Mac has $MACOS)."
ok "Apple silicon, macOS $MACOS"

# --- Where ------------------------------------------------------------------
EXISTING=$(command -v msl 2>/dev/null || true)
if [ -z "$PREFIX" ]; then
  DEFAULT=$HOME/.local
  if [ -n "$EXISTING" ] && [ -e "$(dirname "$EXISTING")/../libexec/msl/msld" ]; then
    DEFAULT=$(cd "$(dirname "$EXISTING")/.." && pwd)
    say "Found msl $("$EXISTING" --version 2>/dev/null | sed -n 's/^MSL version: //p') in $DEFAULT."
  fi
  if [ "$YES" = 0 ]; then
    say ""
    say "Install location:"
    say "  ${B}~/.local${N}    (bin/msl in ~/.local/bin; no sudo; 'msl --update' works without sudo)"
    say "  ${B}/usr/local${N}  (for all users; needs sudo)"
    say "  or any other directory"
  fi
  PREFIX=$(ask "Install to" "$DEFAULT")
fi
# shellcheck disable=SC2088 # expanding a literal ~ the user typed
case $PREFIX in "~"|"~/"*) PREFIX=$HOME${PREFIX#\~} ;; esac
case $PREFIX in /*) ;; *) PREFIX=$(pwd)/$PREFIX ;; esac

SUDO=
mkdir -p "$PREFIX" 2>/dev/null || true
if [ ! -w "$PREFIX" ] || { [ -e "$PREFIX/bin" ] && [ ! -w "$PREFIX/bin" ]; }; then
  SUDO=sudo
  say "Writing to $PREFIX needs administrator rights (sudo)."
fi

# --- What -------------------------------------------------------------------
# GitHub API access: the GitHub CLI if it's logged in, else curl (+ GITHUB_TOKEN).
use_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }
api() {  # api <path>: JSON on stdout
  if use_gh; then gh api "$1"
  else
    set -- -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
    [ -n "${GITHUB_TOKEN:-}" ] && set -- -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
    curl "$@"
  fi
}
# JSON queries with macOS's own JavaScript (no jq/python needed).
js() { osascript -l JavaScript -e "function run(a){const d=JSON.parse(a[0]);return ($1)}" "$2"; }

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || die "no such file: $FROM"
  TARBALL=$FROM
  VERSION=$(basename "$FROM" | sed -n 's/^msl-\(.*\)-macos-arm64\.tar\.gz$/\1/p')
  [ -n "$VERSION" ] || die "expected a file named msl-<version>-macos-arm64.tar.gz"
  if [ -f "$FROM.sha256" ]; then (cd "$(dirname "$FROM")" && shasum -a 256 -c "$(basename "$FROM").sha256" >/dev/null) || die "checksum mismatch for $FROM"; fi
  ok "Using $FROM (msl $VERSION)"
else
  step "Looking up releases of $REPO"
  RELEASES=$(api "repos/$REPO/releases?per_page=100") \
    || die "could not read releases from github.com/$REPO. For a private repo, run 'gh auth login' or set GITHUB_TOKEN."
  if [ -z "$VERSION" ]; then
    VERSION=$(js 'd.filter(r=>!r.draft&&!r.prerelease&&/^v\d/.test(r.tag_name)).map(r=>r.tag_name.slice(1)).sort((x,y)=>{const p=s=>s.split(/[.-]/).map(Number);const a=p(x),b=p(y);for(let i=0;i<3;i++){if(a[i]!==b[i])return b[i]-a[i]}return 0})[0]||""' "$RELEASES")
    [ -n "$VERSION" ] || die "github.com/$REPO has no msl release (v<version>) yet."
  fi
  NAME=msl-$VERSION-macos-arm64.tar.gz
  REL=$(js "JSON.stringify(d.find(r=>r.tag_name==='v$VERSION')||null)" "$RELEASES")
  [ "$REL" != null ] || die "release v$VERSION not found in github.com/$REPO"
  TAR_ID=$(js "(d.assets.find(x=>x.name==='$NAME')||{}).id||''" "$REL")
  SUM_ID=$(js "(d.assets.find(x=>x.name==='$NAME.sha256')||{}).id||''" "$REL")
  SIG_ID=$(js "(d.assets.find(x=>x.name==='$NAME.sha256.asc')||{}).id||''" "$REL")
  [ -n "$TAR_ID" ] || die "release v$VERSION has no $NAME"
  step "Downloading msl $VERSION"
  fetch() {  # fetch <asset id> <file>
    if use_gh; then gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$1" > "$2"
    else
      set -- -fL# -o "$2" -H "Accept: application/octet-stream" "https://api.github.com/repos/$REPO/releases/assets/$1"
      [ -n "${GITHUB_TOKEN:-}" ] && set -- -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
      curl "$@"
    fi
  }
  TARBALL=$TMP/$NAME
  fetch "$TAR_ID" "$TARBALL" || die "download failed"
  if [ -n "$SUM_ID" ]; then
    fetch "$SUM_ID" "$TARBALL.sha256" || die "checksum download failed"
    (cd "$TMP" && shasum -a 256 -c "$NAME.sha256" >/dev/null) || die "checksum mismatch: the download is corrupt"
    ok "Downloaded and verified (SHA-256)"
    if [ -n "$SIG_ID" ] && command -v gpg >/dev/null 2>&1; then
      fetch "$SIG_ID" "$TARBALL.sha256.asc" || die "signature download failed"
      export GNUPGHOME="$TMP/gnupg"; mkdir -m 700 "$GNUPGHOME"
      curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/$RELEASE_KEY" | gpg --batch --quiet --import 2>/dev/null \
        || die "could not fetch the release signing key $RELEASE_KEY"
      gpg --batch --status-fd 1 --verify "$TARBALL.sha256.asc" "$TARBALL.sha256" 2>/dev/null | grep "VALIDSIG" | grep -q "$RELEASE_KEY" \
        || die "the release signature is invalid"
      ok "Signature verified (release key ${RELEASE_KEY#????????????????????????})"
    elif [ -n "$SIG_ID" ]; then
      say "note: install gpg to also verify the release signature"
    fi
  else
    say "note: release v$VERSION has no $NAME.sha256; not verified"
  fi
fi

# --- Confirm ------------------------------------------------------------------
say ""
say "  version  ${B}$VERSION${N}"
say "  prefix   ${B}$PREFIX${N}  (bin/msl, libexec/msl, share/msl)"
[ -n "$SUDO" ] && say "  sudo     yes"
say ""
confirm "Install?" y || { say "Cancelled."; exit 1; }

# --- Install ------------------------------------------------------------------
tar -xzf "$TARBALL" -C "$TMP"
SRC=$TMP/msl-$VERSION
[ -x "$SRC/bin/msl" ] && [ -x "$SRC/libexec/msl/msld" ] || die "the archive doesn't look like an msl release"

# A running msld from this prefix must stop so the new one starts next time;
# that ends running distributions, so ask first.
RUNNING=0
if pgrep -f "^$PREFIX/libexec/msl/msld" >/dev/null 2>&1; then
  RUNNING=1
  confirm "msl is running. Stop it now? Running distributions will be terminated." y \
    || die "Cancelled; run 'msl --shutdown' and try again."
  step "Stopping msl"
  "$PREFIX/bin/msl" --shutdown >/dev/null 2>&1 || true
fi

step "Installing to $PREFIX"
$SUDO mkdir -p "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/share/doc"
# Each tree is staged next to its destination and swapped in with a rename,
# so a failure never leaves a half-installed msl.
for p in libexec/msl share/msl share/doc/msl; do
  $SUDO rm -rf "$PREFIX/$p.new"
  $SUDO cp -R "$SRC/$p" "$PREFIX/$p.new"
  $SUDO rm -rf "$PREFIX/$p"
  $SUDO mv "$PREFIX/$p.new" "$PREFIX/$p"
done
$SUDO cp "$SRC/bin/msl" "$PREFIX/bin/msl.new"
$SUDO mv -f "$PREFIX/bin/msl.new" "$PREFIX/bin/msl"
# Downloads carry the quarantine flag; the binaries are verified above.
$SUDO xattr -dr com.apple.quarantine "$PREFIX/bin/msl" "$PREFIX/libexec/msl" 2>/dev/null || true
# Like 'msl --update': after the swap, the old msld sees its executable was
# replaced and exits on the next shutdown request.
[ "$RUNNING" = 1 ] && { "$PREFIX/bin/msl" --shutdown >/dev/null 2>&1 || true; }
"$PREFIX/bin/msl" --version >/dev/null 2>&1 || die "the installed msl doesn't run"
ok "Installed msl $VERSION"

# --- PATH ---------------------------------------------------------------------
BIN=$PREFIX/bin
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    if [ "$EDIT_PATH" = 1 ]; then
      case ${SHELL##*/} in
        zsh)  RC=$HOME/.zshrc ;;
        bash) RC=$HOME/.bash_profile ;;
        fish) RC=$HOME/.config/fish/config.fish ;;
        *)    RC=$HOME/.profile ;;
      esac
      SHOW_BIN=$(printf '%s' "$BIN" | sed "s|^$HOME|\$HOME|")
      if [ "${SHELL##*/}" = fish ]; then LINE="fish_add_path \"$SHOW_BIN\""; else LINE="export PATH=\"$SHOW_BIN:\$PATH\""; fi
      if grep -qsF "$LINE" "$RC"; then
        :
      elif confirm "Add $SHOW_BIN to PATH in ${RC#$HOME/}?" y; then
        mkdir -p "$(dirname "$RC")"
        printf '\n# msl\n%s\n' "$LINE" >> "$RC"
        ok "Added to ${RC#$HOME/}; open a new terminal (or run: $LINE)"
      else
        say "Add $BIN to your PATH to run 'msl' directly."
      fi
    else
      say "Add $BIN to your PATH to run 'msl' directly."
    fi
    ;;
esac

# --- IDEs --------------------------------------------------------------------
# The MSL extension opens folders in distros (like VS Code's WSL extension).
# msl --manage-ide installs it and enables its proposed API in argv.json.
if [ "$SETUP_IDE" = 1 ]; then
  IDES=
  for pair in "Visual Studio Code:.vscode" "Visual Studio Code - Insiders:.vscode-insiders" "VSCodium:.vscode-oss" "Cursor:.cursor"; do
    name=${pair%%:*} dir=${pair#*:}
    if [ -d "/Applications/$name.app" ] || [ -d "$HOME/Applications/$name.app" ] || [ -d "$HOME/$dir" ]; then
      IDES="${IDES:+$IDES, }$name"
    fi
  done
  if [ -n "$IDES" ] && confirm "Set up the MSL extension in $IDES?" y; then
    "$BIN/msl" --manage-ide --ide all --install || say "You can try again later with: msl --manage-ide"
  fi
fi

# --- First distro ------------------------------------------------------------
MSL=$BIN/msl
if "$MSL" -l -q >/dev/null 2>&1; then HAS=1; else HAS=0; fi
if [ "$YES" = 0 ] && [ "$HAS" = 0 ]; then
  say ""
  if confirm "Install a Linux distribution now?" y; then
    "$MSL" --list --online || true
    D=$(ask "Distribution" "Ubuntu")
    "$MSL" --install "$D" < "$TTY" || say "You can try again later with: msl --install <Distro>"
  fi
fi

say ""
say "${B}Done.${N} Next:"
[ "$HAS" = 0 ] && say "  msl --list --online      distributions you can install"
[ "$HAS" = 0 ] && say "  msl --install Ubuntu     install one"
say "  msl                      open a shell in your default distribution"
say "  msl --help               everything else (the same arguments as wsl.exe)"
say "  msl --update             update msl later; msl --uninstall removes it"

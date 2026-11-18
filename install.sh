#!/bin/sh
# Strata installer.
#
#   curl -fsSL https://raw.githubusercontent.com/gabalexander/strata/main/install.sh | sh
#
# Options (pass them after `sh -s --`):
#   --source      build from source instead of downloading the latest release
#   --app PATH    install an already built Strata.app (used by `make install`)
#   --no-open     don't launch Strata afterwards
#   --uninstall   remove the app, the CLI link and the agent skill (keeps ~/.strata)
set -eu

REPO="gabalexander/strata"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Strata.app"
BIN_DIR="$HOME/.local/bin"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf 'strata install: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Install Strata:  curl -fsSL https://raw.githubusercontent.com/gabalexander/strata/main/install.sh | sh
Options (after `sh -s --`):
  --source      build from source instead of downloading the latest release
  --app PATH    install an already built Strata.app (used by `make install`)
  --no-open     don't launch Strata afterwards
  --uninstall   remove the app, the CLI link and the agent skill (keeps ~/.strata)
USAGE
}

mode=release
app=""
open_app=1
while [ $# -gt 0 ]; do
  case "$1" in
    --source) mode=source ;;
    --app) [ $# -ge 2 ] || die "--app needs a path"; mode=local; app="$2"; shift ;;
    --no-open) open_app=0 ;;
    --uninstall) mode=uninstall ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
  shift
done

[ "$(uname -s)" = Darwin ] || die "Strata is a macOS app."
version=$(sw_vers -productVersion)
[ "${version%%.*}" -ge 26 ] || die "Strata needs macOS 26 or later; this Mac runs $version."

# Quit only the copy we're about to replace, never a dev build running elsewhere.
quit_installed() {
  if pkill -f "$DEST/Contents/MacOS/Strata" 2>/dev/null; then sleep 1; fi
}

skill_dirs() { printf '%s\n' "$HOME/.claude/skills/strata" "$HOME/.agents/skills/strata"; }

if [ "$mode" = uninstall ]; then
  quit_installed
  rm -rf "$DEST"
  if [ -L "$BIN_DIR/strata" ]; then rm -f "$BIN_DIR/strata"; fi
  skill_dirs | while IFS= read -r d; do rm -rf "$d"; done
  say "Removed Strata. Your notes and simulators in ~/.strata are untouched."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$mode" = release ] && [ "$(uname -m)" != arm64 ]; then
  say "Prebuilt releases are Apple Silicon only; building from source."
  mode=source
fi

if [ "$mode" = release ]; then
  say "Downloading the latest Strata release"
  if curl -fsSL "https://github.com/$REPO/releases/latest/download/Strata-macos-arm64.zip" -o "$work/Strata.zip"; then
    ditto -x -k "$work/Strata.zip" "$work/release"
    app="$work/release/Strata.app"
  else
    say "No release to download; building from source instead."
    mode=source
  fi
fi

if [ "$mode" = source ]; then
  command -v swift >/dev/null 2>&1 || die "building needs the Swift toolchain: run 'xcode-select --install', then try again."
  command -v git >/dev/null 2>&1 || die "building needs git."
  say "Cloning $REPO"
  git clone --quiet --depth 1 "https://github.com/$REPO.git" "$work/src" || die "git clone failed"
  say "Building Strata (a few minutes the first time)"
  (cd "$work/src" && ./scripts/build-app.sh >"$work/build.log" 2>&1) \
    || { tail -20 "$work/build.log" >&2; die "the build failed (log above)"; }
  app="$work/src/build/Strata.app"
fi

[ -x "$app/Contents/MacOS/Strata" ] || die "no Strata.app at $app"

say "Installing to $DEST"
mkdir -p "$DEST_DIR" "$BIN_DIR" "$HOME/.strata/sims" "$HOME/.strata/vault"
rm -rf "$DEST.new"
ditto "$app" "$DEST.new"
xattr -dr com.apple.quarantine "$DEST.new" 2>/dev/null || true
quit_installed
# Replace by rename: copying over a signed binary in place gets it killed on Apple Silicon.
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
ln -sf "$DEST/Contents/Resources/bin/strata" "$BIN_DIR/strata"
if [ -d "$DEST/Contents/Resources/Skill" ]; then
  skill_dirs | while IFS= read -r d; do
    mkdir -p "$d"
    cp -R "$DEST/Contents/Resources/Skill/." "$d/"
  done
fi

if [ "$open_app" = 1 ]; then open "$DEST"; fi

say "Strata is installed"
echo "    Show or hide it:  ctrl+option+s, or the stacked-layers icon in the menu bar"
echo "    Command line:     strata --help"
echo "    Your data:        ~/.strata (sims/, vault/, config.yaml)"
echo "    Agent skill:      ask Claude Code or Codex to \"use the strata skill to map ~/path/to/repo\""
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "    Note: add $BIN_DIR to your PATH to use the strata command." ;;
esac

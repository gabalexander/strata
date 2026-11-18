#!/bin/sh
# Installs build/Strata.app into ~/Applications, the CLI into ~/.local/bin and the agent skill.
# Writes the new bundle beside the old one and renames it into place (never cp over a signed binary).
set -eu
cd "$(dirname "$0")/.."
DEST="$HOME/Applications/Strata.app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$DEST.new"
cp -R build/Strata.app "$DEST.new"
pkill -x Strata 2>/dev/null || true
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
ln -sf "$DEST/Contents/Resources/bin/strata" "$HOME/.local/bin/strata"
if [ -d skill ]; then
  mkdir -p "$HOME/.claude/skills/strata"
  cp -R skill/. "$HOME/.claude/skills/strata/"
fi
mkdir -p "$HOME/.strata/sims" "$HOME/.strata/vault"
open "$DEST"
echo "installed $DEST"

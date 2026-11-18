#!/bin/sh
set -eu

label=com.gabalexander.strata.app
agents="$HOME/Library/LaunchAgents"
plist="$agents/$label.plist"
app="$HOME/Applications/Strata.app"

case "${1:-}" in
  enable)
    if [ ! -d "$app" ]; then
      echo "Install Strata in ~/Applications before enabling login launch." >&2
      exit 1
    fi
    mkdir -p "$agents"
    staging="$(mktemp -d "$agents/.strata-login.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    temp="$staging/$label.plist"
    /usr/bin/plutil -create xml1 "$temp"
    /usr/bin/plutil -insert Label -string "$label" "$temp"
    /usr/bin/plutil -insert ProgramArguments -json '["/usr/bin/open","-g"]' "$temp"
    /usr/bin/plutil -insert ProgramArguments.2 -string "$app" "$temp"
    /usr/bin/plutil -insert ProgramArguments.3 -string "--args" "$temp"
    /usr/bin/plutil -insert ProgramArguments.4 -string "--hidden" "$temp"
    /usr/bin/plutil -insert RunAtLoad -bool YES "$temp"
    /usr/bin/plutil -lint "$temp" >/dev/null
    mv -f "$temp" "$plist"
    echo "Strata will start at your next login."
    ;;
  disable)
    job="gui/$(id -u)/$label"
    if launchctl print "$job" >/dev/null 2>&1; then
      launchctl bootout "$job"
    fi
    rm -f "$plist"
    echo "Removed Strata from login."
    ;;
  *)
    echo "Usage: $0 enable|disable" >&2
    exit 2
    ;;
esac

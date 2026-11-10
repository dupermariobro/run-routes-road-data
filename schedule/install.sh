#!/usr/bin/env bash
# Install (or reinstall) the yearly road-data refresh LaunchAgent for this checkout.
#   schedule/install.sh            install / update
#   schedule/install.sh --remove   uninstall
set -euo pipefail
LABEL="com.apollo.run-routes.road-data-refresh"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$TARGET"
  echo "Removed $LABEL"
  exit 0
fi
sed -e "s#__REPO_DIR__#$REPO_DIR#g" -e "s#__HOME__#$HOME#g" \
  "$REPO_DIR/schedule/$LABEL.plist.template" > "$TARGET"
plutil -lint "$TARGET" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$TARGET"
echo "Installed $LABEL (yearly, 10 November 03:30)"

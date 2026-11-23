#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app="${CODEX_SCHEDULER_APP:-$HOME/Library/Application Support/CodexScheduler/runtime/CodexScheduler.app}"

if [[ $(uname -s) != Darwin ]]; then
    printf 'Codex Scheduler requires macOS 14 or later.\n' >&2
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    printf 'Install the Xcode Command Line Tools with xcode-select --install, then run this script again.\n' >&2
    exit 1
fi

SCHEDULER_APP_OUTPUT="$app" /bin/bash "$root/scripts/build-app.sh"
/usr/bin/open -n -a "$app" --args authorize

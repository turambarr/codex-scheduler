#!/bin/bash
# LaunchServices starts the signed app with its own Calendar and Reminders permissions.
# The private FIFOs preserve the standard input/output connection expected by Codex.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app="${CODEX_SCHEDULER_APP:-$root/dist/CodexScheduler.app}"
if [[ -z "${CODEX_SCHEDULER_APP:-}" && ! -x "$app/Contents/MacOS/CodexScheduler" ]]; then
    app="$HOME/Library/Application Support/CodexScheduler/runtime/CodexScheduler.app"
fi
if [[ ! -x "$app/Contents/MacOS/CodexScheduler" ]]; then
    printf 'Codex Scheduler app is missing at %s\n' "$app" >&2
    printf 'Install the local app using the setup instructions at https://github.com/turambarr/codex-scheduler.\n' >&2
    exit 1
fi

umask 077
channel=$(mktemp -d "${TMPDIR:-/private/tmp}/codex-scheduler-mcp.XXXXXXXX")
request="$channel/input"
response="$channel/output"
diagnostics="$channel/diagnostics"
input_pid=
output_pid=
open_pid=

cleanup() {
    if [[ -n "$input_pid" ]]; then kill "$input_pid" 2>/dev/null || true; fi
    if [[ -n "$output_pid" ]]; then kill "$output_pid" 2>/dev/null || true; fi
    if [[ -n "$open_pid" ]]; then kill "$open_pid" 2>/dev/null || true; fi
    /bin/rm -f "$request" "$response" "$diagnostics"
    /bin/rmdir "$channel" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkfifo "$request" "$response"
exec 9<&0
/usr/bin/perl "$root/scripts/normalize-mcp-initialize.pl" <&9 >"$request" &
input_pid=$!
exec 9<&-
/bin/cat <"$response" &
output_pid=$!

environment=()
if [[ -n "${CODEX_SCHEDULER_STORE:-}" ]]; then
    environment+=(--env "CODEX_SCHEDULER_STORE=$CODEX_SCHEDULER_STORE")
fi
if [[ -n "${CODEX_SCHEDULER_TIME_ZONE:-}" ]]; then
    environment+=(--env "CODEX_SCHEDULER_TIME_ZONE=$CODEX_SCHEDULER_TIME_ZONE")
fi

open_arguments=(-n -g -W -a "$app" --stdin "$request" --stdout "$response" --stderr "$diagnostics")
if (( ${#environment[@]} > 0 )); then open_arguments+=("${environment[@]}"); fi
/usr/bin/open "${open_arguments[@]}" --args mcp &
open_pid=$!
code=0
wait "$open_pid" || code=$?
open_pid=
if [[ -s "$diagnostics" ]]; then /bin/cat "$diagnostics" >&2; fi
if (( code == 0 )); then
    # Allow the relay to flush bytes already written by the app.
    for attempt in {1..40}; do
        if ! kill -0 "$output_pid" 2>/dev/null; then break; fi
        sleep 0.05
    done
fi
exit "$code"

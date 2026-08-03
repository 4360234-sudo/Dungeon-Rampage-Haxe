#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
default_binary="$project_root/bin/gc-diagnostics/linux/bin/Dungeon Rampage Haxe"

usage() {
  cat <<EOF
Usage: $0 [output_directory] [-- game_arguments...]

Environment:
  DRH_PROFILE_BINARY   Executable to launch (default: $default_binary)
  DRH_PROFILE_INTERVAL /proc sampling interval in seconds (default: 1)

While the game is running, type a short marker and press Enter to record an
event (for example: "dungeon start", "floor 3", or "first severe stutter").
Close the game normally to preserve HXCPP_GC_SUMMARY.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

output_dir=""
if [[ $# -gt 0 && "$1" != "--" ]]; then
  output_dir="$1"
  shift
fi
if [[ "${1:-}" == "--" ]]; then
  shift
fi
game_arguments=("$@")

if [[ -z "$output_dir" ]]; then
  output_dir="$project_root/profiling/gc-$(date +%Y%m%d_%H%M%S)"
elif [[ "$output_dir" != /* ]]; then
  output_dir="$project_root/$output_dir"
fi

profile_binary="${DRH_PROFILE_BINARY:-$default_binary}"
sample_interval="${DRH_PROFILE_INTERVAL:-1}"

if [[ ! -x "$profile_binary" ]]; then
  echo "Diagnostic executable not found or not executable: $profile_binary" >&2
  exit 1
fi

mkdir -p "$output_dir"
game_log="$output_dir/game.log"
memory_csv="$output_dir/memory.csv"
events_csv="$output_dir/events.csv"
session_file="$output_dir/session.txt"
session_start_epoch="$(date +%s.%N)"

{
  printf 'format_version=1\n'
  printf 'started_at=%s\n' "$(date --iso-8601=ns)"
  printf 'started_epoch=%s\n' "$session_start_epoch"
  printf 'hostname=%s\n' "$(hostname)"
  printf 'kernel=%s\n' "$(uname -srmo)"
  printf 'binary=%s\n' "$profile_binary"
  printf 'binary_sha256=%s\n' "$(sha256sum "$profile_binary" | awk '{print $1}')"
  printf 'sample_interval_sec=%s\n' "$sample_interval"
  printf 'command='
  printf '%q ' "$profile_binary" "${game_arguments[@]}"
  printf '\n'
  lspci 2>/dev/null | awk 'BEGIN { IGNORECASE=1 } /VGA|3D controller|Display controller/ { print "gpu=" $0 }'
} > "$session_file"

printf 'timestamp_epoch,elapsed_sec,label\n' > "$events_csv"

monitor_pid=""
game_pid=""

cleanup() {
  if [[ -n "$monitor_pid" ]] && kill -0 "$monitor_pid" 2>/dev/null; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Profiling output: $output_dir"
echo "Launching: $profile_binary"
echo "Game output is being recorded in: $game_log"

STEAM_APP_ID="${STEAM_APP_ID:-3053950}" \
  "$profile_binary" "${game_arguments[@]}" > "$game_log" 2>&1 &
game_pid=$!
printf 'pid=%s\n' "$game_pid" >> "$session_file"

"$script_dir/profiling/profile_native_memory.sh" "$game_pid" "$memory_csv" "$sample_interval" "$session_start_epoch" &
monitor_pid=$!

record_marker() {
  local label="$1"
  local marker_epoch marker_elapsed marker_display escaped_label
  marker_epoch="$(date +%s.%N)"
  marker_elapsed="$(LC_ALL=C awk -v now="$marker_epoch" -v start="$session_start_epoch" 'BEGIN { printf "%.6f", now-start }')"
  marker_display="$(LC_ALL=C awk -v elapsed="$marker_elapsed" 'BEGIN { printf "%.1f", elapsed }')"
  escaped_label="${label//\"/\"\"}"
  printf '%s,%s,"%s"\n' "$marker_epoch" "$marker_elapsed" "$escaped_label" >> "$events_csv"
  printf '[marker %ss] %s\n' "$marker_display" "$label"
}

game_is_running() {
  local process_state
  if ! kill -0 "$game_pid" 2>/dev/null; then
    return 1
  fi
  process_state="$(awk '{ sub(/^.*\\) /, ""); print $1 }' "/proc/$game_pid/stat" 2>/dev/null || true)"
  [[ "$process_state" != "Z" && -n "$process_state" ]]
}

if [[ -t 0 ]]; then
  echo "Type markers here during the run, then press Enter. Close the game normally when finished."
  while game_is_running; do
    if IFS= read -r -t 1 marker && [[ -n "$marker" ]]; then
      record_marker "$marker"
    fi
  done
fi

set +e
wait "$game_pid"
game_status=$?
set -e

cleanup
monitor_pid=""

{
  printf 'finished_at=%s\n' "$(date --iso-8601=ns)"
  printf 'exit_status=%s\n' "$game_status"
} >> "$session_file"

python3 "$script_dir/analyze_gc_session.py" "$output_dir" || true

echo
echo "Session complete: $output_dir"
echo "Send back the whole directory (or at least game.log, memory.csv, events.csv and analysis.md)."
exit "$game_status"

#!/usr/bin/env bash
# Git workflow around an ax4 conversion: converted/ + edits/ pair, then import to master.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP_PATH="edits/conversion/stamp"
CONVERT_CMD="$SCRIPT_DIR/convert.cmd"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

  start --buildid ID --reasons REASONS [--date YYYY-MM-DD] [--skip-convert]
        [--] [convert options]
                    Create converted/DATE-bID-reasons, run convert, commit stamp
  rebase            Replay edits/latest onto the current converted/ branch
  replay [sha...]   Cherry-pick commits onto the current converted/ branch
                    (default: converted/latest..edits/latest)
  continue          Resume rebase or cherry-pick after resolving conflicts
  abort             Abort rebase or cherry-pick
  import            Copy src/, src-steam/, and stamp from edits/latest onto master

Reasons: dr, jpexs, ax4 (any subset; stored as dr > jpexs > ax4).
Convert flags after -- go to convert.cmd.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

cd "$ROOT"
command -v git >/dev/null 2>&1 || die "git is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

STATE="$(git rev-parse --git-path drh-refresh-suffix)"

in_rebase() {
  [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]
}

in_cherry_pick() {
  [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]]
}

require_no_sequencer() {
  if in_rebase || in_cherry_pick; then
    die "rebase or cherry-pick in progress (use continue or abort)"
  fi
}

git_has_ref() {
  git rev-parse --verify --quiet "$1" >/dev/null
}

save_suffix() {
  printf '%s\n' "$1" > "$STATE"
}

read_suffix() {
  [[ -f "$STATE" ]] || die "no in-progress conversion (run start first)"
  cat "$STATE"
}

normalize_reasons() {
  local has_dr=0 has_jpexs=0 has_ax4=0 part
  local IFS=+
  # shellcheck disable=SC2086
  set -- $1
  for part in "$@"; do
    case "$part" in
      dr) has_dr=1 ;;
      jpexs) has_jpexs=1 ;;
      ax4) has_ax4=1 ;;
      "") ;;
      *) die "unknown reason '$part' (expected dr, jpexs, ax4)" ;;
    esac
  done
  local out=()
  [[ "$has_dr" -eq 1 ]] && out+=(dr)
  [[ "$has_jpexs" -eq 1 ]] && out+=(jpexs)
  [[ "$has_ax4" -eq 1 ]] && out+=(ax4)
  [[ "${#out[@]}" -gt 0 ]] || die "need at least one reason (dr, jpexs, ax4)"
  local IFS=+
  echo "${out[*]}"
}

sibling_head() {
  local dir="$ROOT/../$1"
  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    git -C "$dir" rev-parse HEAD 2>/dev/null || true
  fi
}

write_stamp() {
  local suffix="$1" date="$2" buildid="$3" reasons="$4"
  mkdir -p "$(dirname "$ROOT/$STAMP_PATH")"
  cat > "$ROOT/$STAMP_PATH" <<EOF
branch=$suffix
date=$date
buildid=$buildid
reasons=$reasons
jpexs=$(sibling_head jpexs-decompiler)
ax4=$(sibling_head ax4)
EOF
}

converted_suffix() {
  local branch
  branch="$(git branch --show-current)"
  [[ "$branch" == converted/* && "$branch" != converted/latest ]] ||
    die "current branch must be converted/<date>-b<id>-<reasons> (on ${branch:-detached})"
  echo "${branch#converted/}"
}

point_latest() {
  local suffix="$1"
  git branch -f "converted/latest" "converted/$suffix"
  git branch -f "edits/latest" "edits/$suffix"
  rm -f "$STATE"
  echo "converted/latest and edits/latest -> $suffix"
}

cmd_start() {
  local buildid="" reasons="" date="" skip_convert=0
  local convert_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --buildid) buildid="$2"; shift 2 ;;
      --reasons) reasons="$2"; shift 2 ;;
      --date) date="$2"; shift 2 ;;
      --skip-convert) skip_convert=1; shift ;;
      --) shift; convert_args+=("$@"); break ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n "$buildid" ]] || die "start requires --buildid"
  [[ "$buildid" =~ ^[0-9]+$ ]] || die "buildid must be numeric"
  [[ -n "$reasons" ]] || die "start requires --reasons"
  reasons="$(normalize_reasons "$reasons")"
  [[ -n "$date" ]] || date="$(date +%F)"
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date must be YYYY-MM-DD"

  require_no_sequencer

  local suffix="${date}-b${buildid}-${reasons}"
  local branch="converted/$suffix"
  git_has_ref "refs/heads/$branch" && die "branch already exists: $branch"

  if git_has_ref refs/heads/converted/latest; then
    git checkout converted/latest
  fi
  git checkout -b "$branch"
  save_suffix "$suffix"

  if [[ "$skip_convert" -eq 0 ]]; then
    "$CONVERT_CMD" "${convert_args[@]+"${convert_args[@]}"}"
  fi

  write_stamp "$suffix" "$date" "$buildid" "$reasons"
  git add -- src src-steam "$STAMP_PATH"
  git commit -m "$(cat <<EOF
Convert ${date} b${buildid} (${reasons})

BuildID: ${buildid}
reasons: ${reasons}
jpexs: $(sibling_head jpexs-decompiler)
ax4:   $(sibling_head ax4)
EOF
)"

  echo "created $branch"
  if git_has_ref refs/heads/edits/latest; then
    echo "next: $(basename "$0") rebase"
  else
    git branch "edits/$suffix"
    point_latest "$suffix"
    echo "first pair: add stack commits on edits/$suffix, then $(basename "$0") import"
  fi
}

cmd_rebase() {
  require_no_sequencer
  local suffix
  suffix="$(converted_suffix)"
  save_suffix "$suffix"
  git_has_ref refs/heads/edits/latest || die "no edits/latest"
  git_has_ref refs/heads/converted/latest || die "no converted/latest"

  git rebase --onto "converted/$suffix" converted/latest edits/latest
  git branch -f "edits/$suffix"
  point_latest "$suffix"
}

cmd_replay() {
  require_no_sequencer
  local suffix shas=()
  suffix="$(converted_suffix)"
  save_suffix "$suffix"
  if [[ $# -eq 0 ]]; then
    git_has_ref refs/heads/edits/latest || die "no edits/latest and no commit list"
    git_has_ref refs/heads/converted/latest || die "no converted/latest"
    mapfile -t shas < <(git rev-list --reverse converted/latest..edits/latest)
    [[ "${#shas[@]}" -gt 0 ]] || die "edits/latest has no commits beyond converted/latest"
  else
    shas=("$@")
  fi

  git checkout -B "edits/$suffix" "converted/$suffix"
  local sha
  for sha in "${shas[@]}"; do
    git cherry-pick "$sha"
  done
  point_latest "$suffix"
}

cmd_continue() {
  local suffix
  suffix="$(read_suffix)"
  if in_rebase; then
    git rebase --continue
    git branch -f "edits/$suffix"
    point_latest "$suffix"
    return
  fi
  if in_cherry_pick; then
    git cherry-pick --continue
    if in_cherry_pick; then
      echo "cherry-pick continues; resolve the next commit then $(basename "$0") continue"
      return
    fi
    git branch -f "edits/$suffix"
    point_latest "$suffix"
    return
  fi
  die "no rebase or cherry-pick in progress"
}

cmd_abort() {
  if in_rebase; then
    git rebase --abort
    echo "rebase aborted"
    return
  fi
  if in_cherry_pick; then
    git cherry-pick --abort
    echo "cherry-pick aborted"
    return
  fi
  die "no rebase or cherry-pick in progress"
}

cmd_import() {
  require_no_sequencer
  git_has_ref refs/heads/edits/latest || die "no edits/latest"
  local current source
  current="$(git branch --show-current)"
  [[ "$current" == master ]] || git checkout master
  source="$(git rev-parse --abbrev-ref edits/latest)"
  git checkout edits/latest -- src src-steam "$STAMP_PATH"
  git commit -m "Refresh src from ${source}"
}

[[ $# -gt 0 ]] || { usage >&2; exit 1; }
cmd="$1"
shift
case "$cmd" in
  start) cmd_start "$@" ;;
  rebase) cmd_rebase "$@" ;;
  replay) cmd_replay "$@" ;;
  continue) cmd_continue "$@" ;;
  abort) cmd_abort "$@" ;;
  import) cmd_import "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac

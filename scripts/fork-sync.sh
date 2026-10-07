#!/usr/bin/env bash
# Sync the weebo-si forks with upstream and rebuild their develop branch, as described in forks.yaml.
#
# Usage: fork-sync.sh <status|sync|fetch|develop|update> [fork...]
#   status   show what each step would change, push nothing
#   sync     fast-forward the `sync` branches of each fork to upstream
#   fetch    copy the `fetch` outside branches into each fork
#   develop  rebuild the develop branch from base, then merge the `merge` branches into it
#   update   sync, fetch then develop
#
# Env: CONFIG (default: forks.yaml), PUSH=true to push, FORK_SYNC_DIR (clone cache),
#      SIGN=false to not sign the merge commits (default: follow commit.gpgsign).
set -euo pipefail

CONFIG=${CONFIG:-forks.yaml}
PUSH=${PUSH:-false}
SIGN=${SIGN:-}
WORKDIR=${FORK_SYNC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/weebo-fork-sync}
CMD=${1:-status}
shift || true

# Use gh as credential helper, so pushes work without `gh auth setup-git`
git() { command git -c credential.helper= -c credential.helper='!gh auth git-credential' "$@"; }

cfg() { yq -r "$1" "$CONFIG"; }
# One compact JSON document per line, for lists of branch references
cfgj() { yq -o json -I 0 "$1" "$CONFIG"; }
# Fork value with fallback on defaults: fval <fork> <path>
fval() { yq -r ".forks[\"$1\"]$2 // .defaults$2 // \"\"" "$CONFIG"; }

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*" >&2; FAILED=1; }

# Resolve a branch reference (string or {remote, branch}) to "<remote> <branch>"
ref_parts() {
  local json=$1
  if [[ $(yq -r 'type' <<<"$json") == "!!str" ]]; then
    echo "origin $(yq -r '.' <<<"$json")"
  else
    echo "$(yq -r '.remote' <<<"$json") $(yq -r '.branch' <<<"$json")"
  fi
}

ref_exists() { command git rev-parse -q --verify "$1^{commit}" >/dev/null; }
short() { command git rev-parse --short "$1"; }

# Push refspecs collected for the current fork, all at once and only if no step failed
PUSHES=()
push_all() {
  local fork=$1
  if ((${#PUSHES[@]} == 0)); then say "nothing to push"; return; fi
  if ((FAILED)); then warn "$fork: errors above, nothing pushed"; return; fi
  if [[ $PUSH != true ]]; then say "dry run, would push: ${PUSHES[*]}"; return; fi
  git push --atomic origin "${PUSHES[@]}"
}

prepare_repo() {
  local fork=$1 org upstream_org upstream dir
  org=$(fval "$fork" .org)
  upstream_org=$(fval "$fork" .upstreamOrg)
  upstream=$(cfg ".forks[\"$fork\"].upstream // \"$upstream_org/$fork\"")
  dir="$WORKDIR/$fork"

  if [[ ! -d $dir/.git ]]; then
    mkdir -p "$WORKDIR"
    git clone -q --no-checkout --filter=blob:none "https://github.com/$org/$fork.git" "$dir"
  fi
  cd "$dir"
  command git remote set-url origin "https://github.com/$org/$fork.git"
  set_remote upstream "https://github.com/$upstream.git"
  while IFS=$'\t' read -r name url; do
    if [[ -n $name ]]; then set_remote "$name" "$url"; fi
  done < <(cfg ".forks[\"$fork\"].remotes // {} | to_entries | .[] | [.key, .value] | @tsv")

  # Clean state, in case a previous run stopped in the middle of a merge
  command git merge --abort 2>/dev/null || true
  command git reset -q --hard 2>/dev/null || true

  local remotes
  remotes=$(command git remote)
  for r in $remotes; do
    git fetch -q --prune --no-tags "$r" "+refs/heads/*:refs/remotes/$r/*" || warn "fetch $r failed"
  done
}

set_remote() {
  if command git remote get-url "$1" >/dev/null 2>&1; then
    command git remote set-url "$1" "$2"
  else
    command git remote add "$1" "$2"
  fi
}

# Fast-forward origin/<to> to <src>, or create it. force=true allows a non fast-forward update.
ff_update() {
  local src=$1 to=$2 force=$3 label=$4
  local dst="origin/$to"
  if ! ref_exists "$src"; then warn "$label: $src not found"; return; fi
  if ! ref_exists "$dst"; then
    say "$label: create $to at $(short "$src")"
    PUSHES+=("$(command git rev-parse "$src"):refs/heads/$to")
  elif [[ $(command git rev-parse "$src") == $(command git rev-parse "$dst") ]]; then
    say "$label: $to up to date"
  elif command git merge-base --is-ancestor "$dst" "$src"; then
    say "$label: $to +$(command git rev-list --count "$dst..$src") commits ($(short "$dst")..$(short "$src"))"
    PUSHES+=("$(command git rev-parse "$src"):refs/heads/$to")
  elif [[ $force == true ]]; then
    say "$label: $to diverged, force update to $(short "$src")"
    PUSHES+=("+$(command git rev-parse "$src"):refs/heads/$to")
  else
    warn "$label: $to diverged from $src ($(command git rev-list --count "$src..$dst") own commits), skipped"
  fi
}

step_sync() {
  local fork=$1 branch
  while read -r branch; do
    if [[ -n $branch ]]; then ff_update "upstream/$branch" "$branch" false sync; fi
  done < <(cfg "(.forks[\"$fork\"].sync // .defaults.sync // [])[]")
}

step_fetch() {
  local fork=$1 entry remote branch to force
  while read -r entry; do
    if [[ -z $entry ]]; then continue; fi
    read -r remote branch < <(ref_parts "$(yq -o json -I 0 '.from' <<<"$entry")")
    to=$(yq -r ".to // \"$branch\"" <<<"$entry")
    force=$(yq -r '.force // false' <<<"$entry")
    ff_update "$remote/$branch" "$to" "$force" fetch
  done < <(cfgj "(.forks[\"$fork\"].fetch // [])[]")
}

step_develop() {
  local fork=$1 enabled branch base remote src ref
  # Not `//`: yq treats false as missing
  enabled=$(cfg "[.forks[\"$fork\"].develop.enabled, .defaults.develop.enabled, true] | map(select(. != null)) | .[0]")
  if [[ $enabled != true ]]; then say "develop: disabled"; return; fi
  branch=$(fval "$fork" .develop.branch)
  base=$(fval "$fork" .develop.base)

  # Merge on top of what sync/fetch will push, so a dry run shows the real result
  local -A pending=()
  local p sha
  for p in "${PUSHES[@]}"; do
    sha=${p%%:*}
    pending[${p#*:refs/heads/}]=${sha#+}
  done
  resolve() { # remote branch -> commit
    if [[ $1 == origin && -n ${pending[$2]:-} ]]; then echo "${pending[$2]}"; else echo "$1/$2"; fi
  }

  # develop is rebuilt from base on every run: the merge entries are the only thing it adds
  local start
  start=$(resolve origin "$base")
  if ! ref_exists "$start"; then warn "develop: $base not found"; return; fi
  command git checkout -q --detach "$start"

  local refs=()
  while read -r ref; do if [[ -n $ref ]]; then refs+=("$ref"); fi; done \
    < <(cfgj "(.forks[\"$fork\"].develop.merge // [])[]")

  local merged=("$start")
  for ref in "${refs[@]}"; do
    read -r remote src < <(ref_parts "$ref")
    local commit name
    commit=$(resolve "$remote" "$src")
    name=$([[ $remote == origin ]] && echo "$src" || echo "$remote/$src")
    if ! ref_exists "$commit"; then warn "develop: $name not found"; return; fi
    merged+=("$commit")
    if command git merge-base --is-ancestor "$commit" HEAD; then
      say "develop: $name already merged"
      continue
    fi
    local n
    n=$(command git rev-list --count "HEAD..$commit")
    local sign=() out conflicts
    if [[ $SIGN == false ]]; then sign=(-c commit.gpgsign=false); fi
    if out=$(command git "${sign[@]}" merge -q --no-ff --no-edit -m "chore: merge $name into $branch" "$commit" 2>&1); then
      say "develop: merge $name (+$n commits)"
    else
      conflicts=$(command git diff --name-only --diff-filter=U | tr '\n' ' ')
      if [[ -n $conflicts ]]; then
        warn "develop: conflict merging $name into $branch: $conflicts"
      else
        warn "develop: merging $name failed: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
      fi
      command git merge --abort 2>/dev/null || true
      return
    fi
  done

  local dst="origin/$branch"
  if ! ref_exists "$dst"; then
    say "develop: create $branch at $(short HEAD)"
    PUSHES+=("$(command git rev-parse HEAD):refs/heads/$branch")
    return
  fi
  # Up to date when the current develop has the same content and holds nothing but base, the
  # merge entries and merge commits: then don't rewrite it (no new sha, no image rebuild)
  local m same=true
  for m in "${merged[@]}"; do
    command git merge-base --is-ancestor "$m" "$dst" || same=false
  done
  if [[ $same == true && $(command git rev-parse "HEAD^{tree}") == $(command git rev-parse "$dst^{tree}") &&
        -z $(command git rev-list --no-merges "$dst" --not "${merged[@]}") ]]; then
    say "develop: $branch up to date"
  else
    # Commits made on develop directly would be lost by the rebuild: refuse, they belong in a branch.
    # A commit rewritten by a rebase of a merge entry (same author, date and subject) is not lost,
    # nor is an upstream commit (e.g. when base moves from main to a release branch).
    local lost fmt='%an %at %s'
    lost=$(LC_ALL=C comm -23 \
      <(command git log --no-merges --format="$fmt" "$dst" --not "${merged[@]}" --remotes=upstream | LC_ALL=C sort -u) \
      <(command git log --no-merges --format="$fmt" HEAD | LC_ALL=C sort -u) | grep -c . || true)
    if ((lost > 0)); then
      warn "develop: $branch has $lost commits not in $base or the merge entries, move them to a branch first"
      return
    fi
    say "develop: rebuild $branch from $base ($(short "$dst") -> $(short HEAD), force push)"
    PUSHES+=("+$(command git rev-parse HEAD):refs/heads/$branch")
  fi
}

main() {
  command -v yq >/dev/null || { echo "yq is missing: run 'mise install'" >&2; exit 1; }
  [[ -f $CONFIG ]] || { echo "$CONFIG not found" >&2; exit 1; }
  CONFIG=$(realpath "$CONFIG")
  case $CMD in status|sync|fetch|develop|update) ;; *) sed -n '2,12p' "$0"; exit 1 ;; esac
  [[ $CMD == status ]] && PUSH=false

  local forks=("$@") rc=0
  if ((${#forks[@]} == 0)); then
    mapfile -t forks < <(cfg '.forks | to_entries | .[] | select(.value.enabled != false) | .key')
  fi

  for fork in "${forks[@]}"; do
    echo "▶ $fork"
    FAILED=0
    PUSHES=()
    # set -e is ignored in a subshell tested with ||, so check the status by hand
    set +e
    ( set -e
      prepare_repo "$fork"
      case $CMD in
        sync)    step_sync "$fork" ;;
        fetch)   step_fetch "$fork" ;;
        develop) step_develop "$fork" ;;
        status|update) step_sync "$fork"; step_fetch "$fork"; step_develop "$fork" ;;
      esac
      push_all "$fork"
      exit "$FAILED"
    )
    (($? == 0)) || rc=1
    set -e
  done
  exit "$rc"
}

main "$@"

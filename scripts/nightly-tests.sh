#!/bin/zsh
# Full test suite against the committed tip of main, in a private worktree so
# uncommitted agent work and the main .build are never touched. Run daily by
# launchd (scripts/install-nightly-tests.sh); safe to run by hand.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${CONTEXTDESK_NIGHTLY_BRANCH:-main}"
WORK="$HOME/Library/Caches/ContextDesk/nightly-tests/worktree"
LOGS="$HOME/Library/Logs/ContextDesk/nightly-tests"
mkdir -p "$LOGS" "${WORK:h}"
stamp=$(date +%Y-%m-%d_%H%M)
log="$LOGS/$stamp.log"

{
  if [[ ! -d "$WORK/.git" && ! -f "$WORK/.git" ]]; then
    git -C "$REPO" worktree prune
    git -C "$REPO" worktree add --detach "$WORK" "$BRANCH"
  fi
  git -C "$WORK" checkout --detach --force "$BRANCH" && git -C "$WORK" clean -fdq -e .build
} >"$log" 2>&1
commit=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "Nightly full suite: $BRANCH @ $commit, $(date)" >>"$log"

start=$SECONDS
(cd "$WORK" && zsh scripts/test.sh --verbose) >>"$log" 2>&1
code=$?
summary=$(grep -E 'Test run with|FAILED|error:' "$log" | tail -1)
[[ $code == 0 ]] && result=passed || result=failed
echo "$result $commit $(date +%Y-%m-%dT%H:%M:%S) $((SECONDS - start))s ${summary}" >"$LOGS/latest-status"
ln -sf "$log" "$LOGS/latest.log"
# Keep two weeks of logs.
ls -1t "$LOGS"/*.log(N) | tail -n +15 | xargs rm -f 2>/dev/null

if [[ $code != 0 ]]; then
  osascript -e "display notification \"$commit: ${summary//\"/}\" with title \"Context Desk: nightly tests failed\"" >/dev/null 2>&1
fi
exit $code

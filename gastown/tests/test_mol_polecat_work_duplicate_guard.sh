#!/usr/bin/env bash
set -euo pipefail

# Executed coverage for the duplicate-work guard (step 1b) in mol-polecat-work.
#
# The guard refuses to re-implement a bead whose work already shipped
# (gc.work_outcome=shipped, or a canonical pr_url with an OPEN pull request),
# and must still let a bead that was deliberately rejected back for rework
# (non-empty rejection_reason) resume on its same open PR. The block is LIFTED
# out of the formula and executed, not transcribed.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

BIN="$tmp/bin"
GUARD="$tmp/guard.sh"
GCLOG="$tmp/gc-invocations.log"
: >"$GCLOG"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null || fail "jq is required (the recipe under test uses it)"

lift_block() {
    local sentinel="$1" dest="$2"
    awk -v want="$sentinel" '
        /^[[:space:]]*```bash[[:space:]]*$/ { inblk = 1; body = ""; next }
        inblk && /^[[:space:]]*```[[:space:]]*$/ {
            inblk = 0
            if (index(body, want)) { printf "%s", body; found = 1 }
            body = ""
            next
        }
        inblk { body = body $0 "\n"; next }
        END { exit(found ? 0 : 1) }
    ' "$FORMULA" | sed 's/{{escalation_target}}/mayor/g; s/{{binding_prefix}}//g' >"$dest" ||
        fail "no fenced bash block in $FORMULA contains: $sentinel"
    [ -s "$dest" ] || fail "lifted an empty block for: $sentinel"
    bash -n "$dest" || fail "lifted block does not parse: $sentinel"
}

lift_block 'DUPLICATE-WORK GUARD' "$GUARD"

mkdir -p "$BIN"
cat >"$BIN/gc" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "gc $*" >>"${GC_LOG:-/dev/null}"
case "gc $*" in
    *"gc bd show"*) cat "${GC_BD_JSON:-/dev/null}" ;;
    *) exit 0 ;;
esac
SH
cat >"$BIN/gh" <<'SH'
#!/usr/bin/env sh
# Only `gh pr view <url> --json state -q .state` is exercised.
if [ -n "${GH_PR_STATE:-}" ]; then
    printf '%s\n' "$GH_PR_STATE"
    exit 0
fi
exit 1
SH
chmod +x "$BIN/gc" "$BIN/gh"

export PATH="$BIN:$PATH"
export GC_LOG="$GCLOG"
export GC_BD_JSON="$tmp/bead.json"
export WORK_BEAD_ID=TESTBEAD

PR_URL="https://github.com/example/repo/pull/1"

# run_guard <metadata-json> <gh-pr-state> -- execute the lifted guard against a
# bead carrying that metadata. gc invocations land in $GCLOG.
run_guard() {
    printf '[{"id":"TESTBEAD","metadata":%s}]' "$1" >"$GC_BD_JSON"
    : >"$GCLOG"
    (
        export GH_PR_STATE="$2"
        set +e
        . "$GUARD"
    ) >/dev/null 2>&1
}

refused() { grep -q 'halt_reason=duplicate_work_refused' "$GCLOG"; }
resumed() { grep -q -- '--unset-metadata handoff_stage' "$GCLOG"; }

test_rejected_bead_with_open_pr_resumes() {
    run_guard "{\"pr_url\":\"$PR_URL\",\"rejection_reason\":\"rebase conflict\"}" OPEN
    ! refused || fail "a rejected bead with an open PR must resume, not be refused"
    resumed || fail "a rejected bead must pass the guard and reach the handoff-marker clear"
}

test_rejected_shipped_bead_resumes() {
    # A rejected handoff keeps gc.work_outcome=shipped; rejection is the
    # explicit, deliberate rework signal and wins.
    run_guard "{\"gc.work_outcome\":\"shipped\",\"pr_url\":\"$PR_URL\",\"rejection_reason\":\"tests failed\"}" OPEN
    ! refused || fail "a rejected shipped bead must resume, not be refused"
    resumed || fail "a rejected shipped bead must reach the handoff-marker clear"
}

test_rejected_bead_resumes_when_pr_state_unverifiable() {
    run_guard "{\"pr_url\":\"$PR_URL\",\"rejection_reason\":\"rebase conflict\"}" ""
    ! refused || fail "rework must not depend on a PR state lookup"
    resumed || fail "rejected rework must reach the handoff-marker clear"
}

test_shipped_bead_without_rejection_is_refused() {
    run_guard '{"gc.work_outcome":"shipped"}' ""
    refused || fail "gc.work_outcome=shipped without rejection_reason must be refused"
    ! resumed || fail "a refused bead must not reach the handoff-marker clear"
    grep -q 'gc workflow delete-source TESTBEAD --apply' "$GCLOG" ||
        fail "refusal must tear down the duplicate workflow"
}

test_open_pr_without_rejection_is_refused() {
    run_guard "{\"pr_url\":\"$PR_URL\"}" OPEN
    refused || fail "an OPEN pr_url without rejection_reason must be refused"
    ! resumed || fail "a refused bead must not reach the handoff-marker clear"
}

test_open_pr_with_empty_rejection_is_refused() {
    run_guard "{\"pr_url\":\"$PR_URL\",\"rejection_reason\":\"\"}" OPEN
    refused || fail "an empty rejection_reason must not exempt an open-PR bead"
}

test_unverifiable_pr_without_rejection_is_refused() {
    run_guard "{\"pr_url\":\"$PR_URL\"}" ""
    refused || fail "an unverifiable PR state without rejection_reason must fail closed"
}

test_merged_pr_without_rejection_proceeds() {
    run_guard "{\"pr_url\":\"$PR_URL\"}" MERGED
    ! refused || fail "a MERGED pr_url must allow follow-up work"
    resumed || fail "a MERGED pr_url must reach the handoff-marker clear"
}

test_second_live_workflow_after_rework_started_is_refused() {
    # Step 3 unsets rejection_reason when the rework attempt resumes the branch.
    # A second workflow arriving afterwards sees an open PR with no rejection
    # reason and must be refused.
    run_guard "{\"pr_url\":\"$PR_URL\"}" OPEN
    refused || fail "a second live workflow on an in-rework bead must be refused"
}

test_rejected_bead_with_open_pr_resumes
test_rejected_shipped_bead_resumes
test_rejected_bead_resumes_when_pr_state_unverifiable
test_shipped_bead_without_rejection_is_refused
test_open_pr_without_rejection_is_refused
test_open_pr_with_empty_rejection_is_refused
test_unverifiable_pr_without_rejection_is_refused
test_merged_pr_without_rejection_proceeds
test_second_live_workflow_after_rework_started_is_refused

echo "mol-polecat-work duplicate-work guard tests passed"

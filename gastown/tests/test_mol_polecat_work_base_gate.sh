#!/usr/bin/env bash
set -euo pipefail

# Executed coverage for the base-resolution gate in mol-polecat-work
# workspace-setup.
#
# The gate decides, from `refs/heads/<base>` vs `refs/remotes/origin/<base>`,
# whether a polecat may branch. Its old shape halted on a single one-directional
# ancestry probe against refs fetched minutes earlier by an unchecked prune
# fetch: in a shared-ref clone (every polecat, the refinery, the witness and
# the launcher share one refs database) a fetch that loses a ref-lock race
# leaves the remote-tracking base stale while the local base is current, and a
# mergeable bead halted as "diverged" (a production rig bead halted three
# times on refs that matched again minutes later). The halt also rerouted the bead while
# leaving a stale submit marker behind, so the witness handed halted work back
# to the refinery.
#
# The block is LIFTED out of the formula and executed, not transcribed. A
# transcription drifts silently from the recipe that actually runs.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

BIN="$tmp/bin"
GATE="$tmp/base-gate.sh"
GCLOG="$tmp/gc-invocations.log"
: >"$GCLOG"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null || fail "jq is required (the recipe under test uses it)"

# lift_block <sentinel> <dest> -- extract the fenced ```bash block containing
# <sentinel>, then neutralize the formula's template placeholders so the shell
# can execute it: {{base_branch}} becomes `main`, {{binding_prefix}} and
# ${GC_RIG:+...} resolve through the environment. `<worktree-path>` style
# placeholders do not appear in this block.
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
    ' "$FORMULA" | sed 's/{{base_branch}}/main/g; s/{{binding_prefix}}//g' >"$dest" ||
        fail "no fenced bash block in $FORMULA contains: $sentinel"
    [ -s "$dest" ] || fail "lifted an empty block for: $sentinel"
    bash -n "$dest" || fail "lifted block does not parse: $sentinel"
}

lift_block 'pin_base_ref() {' "$GATE"

write_gc_stub() {
    mkdir -p "$BIN"
    cat >"$BIN/gc" <<'SH'
#!/usr/bin/env sh
# Match on the reconstructed command line: the repo's bare-`bd` lint only
# accepts beads literals that read as `gc bd ...`. Every invocation is
# appended to $GCLOG so assertions can read exactly what the recipe wrote.
printf '%s\n' "gc $*" >>"${GC_LOG:-/dev/null}"
invocation="gc $*"
case "$invocation" in
    *"gc bd show"*) cat "${GC_BD_JSON:-/dev/null}" ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$BIN/gc"
}

write_gc_stub
export PATH="$BIN:$PATH"
export GC_LOG="$GCLOG"
export WORK_BEAD_ID=TESTBEAD

# The bead record the recipe reads back for the stale-halt clear. Tests
# override GC_BD_JSON contents as needed.
export GC_BD_JSON="$tmp/bead.json"
printf '[{"id":"TESTBEAD","metadata":{}}]' >"$GC_BD_JSON"

# new_fixture <name> -- a clone whose local main and origin/main both sit at
# the baseline commit.
new_fixture() {
    local name="$1"
    FIXTURE="$tmp/fix-$name"
    ORIGIN_BARE="$tmp/fix-$name.git"
    git init -q --bare -b main "$ORIGIN_BARE"
    git init -q -b main "$FIXTURE"
    git -C "$FIXTURE" config user.name "Polecat Base Gate Test"
    git -C "$FIXTURE" config user.email "polecat@example.invalid"
    git -C "$FIXTURE" remote add origin "$ORIGIN_BARE"
    printf 'baseline\n' >"$FIXTURE/README.md"
    git -C "$FIXTURE" add -A
    git -C "$FIXTURE" commit -q -m baseline
    git -C "$FIXTURE" push -q origin main
    git -C "$FIXTURE" fetch -q origin
}

# commit_on <repo> <file> -- one commit on the current branch of <repo>.
commit_on() {
    printf 'work %s\n' "$(date +%s)-$RANDOM" >"$1/$2"
    git -C "$1" add -A
    git -C "$1" commit -q -m "$2"
}

# run_gate -- execute the lifted block inside the fixture. Prints the recipe's
# exit status on stdout (the block's STOP arms `exit 1` from inside the
# sourced file, so the subshell's own status is the recipe's status); gc
# invocations land in $GCLOG (re-created per run).
run_gate() {
    : >"$GCLOG"
    local rc=0
    (
        cd "$FIXTURE"
        set +e
        . "$GATE"
    ) >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

halted() { grep -q 'halt_reason=base_branch_diverged' "$GCLOG"; }
pooled() { grep -q -- '--status=open --assignee=' "$GCLOG"; }
cleared_marker() { grep -q -- '--unset-metadata handoff_stage' "$GCLOG"; }
routed_to_pool() { grep -q 'gc.routed_to=.*polecat' "$GCLOG"; }
mailed_witness() { grep -q 'gc mail send' "$GCLOG"; }
drained() { grep -q 'gc runtime drain-ack' "$GCLOG"; }

test_equal_refs_branch_from_remote() {
    new_fixture equal
    [ "$(run_gate)" = "0" ] || fail "equal refs must not stop the recipe"
    ! halted || fail "equal refs must not halt"
    grep -q 'base_ref=refs/remotes/origin/main' "$GCLOG" ||
        fail "equal refs must record the remote base ref"
}

test_local_ahead_of_origin_is_not_divergence() {
    # The measured false-halt shape: local main advanced (a concurrent pull or
    # an upstream sync between merge and push) while the remote-tracking ref
    # lags. The old one-directional probe halted here; the fixed gate must
    # treat origin/main as a valid fork point and branch from it.
    new_fixture ahead
    commit_on "$FIXTURE" local-only.txt          # local main ahead, unpushed
    [ "$(run_gate)" = "0" ] || fail "a local base merely ahead of origin must not stop the recipe"
    ! halted || fail "local-ahead is a fast-forward, not divergence -- must not halt"
    ! drained || fail "local-ahead must not drain-ack"
}

test_origin_ahead_of_local_is_not_divergence() {
    new_fixture origin-ahead
    commit_on "$FIXTURE" remote-only.txt
    git -C "$FIXTURE" push -q origin main
    git -C "$FIXTURE" reset -q --hard HEAD~1      # local main behind origin
    [ "$(run_gate)" = "0" ] || fail "a local base behind origin must not stop the recipe"
    ! halted || fail "origin-ahead is a fast-forward, not divergence -- must not halt"
}

test_mutual_divergence_halts_into_the_pool() {
    new_fixture diverged
    commit_on "$FIXTURE" local-side.txt
    git -C "$FIXTURE" push -q origin main:main
    git -C "$FIXTURE" reset -q --hard HEAD~1
    commit_on "$FIXTURE" other-side.txt           # local and origin now disagree
    git -C "$FIXTURE" fetch -q origin
    [ "$(run_gate)" = "1" ] || fail "mutual divergence must stop the recipe"
    halted || fail "mutual divergence must stamp halt_reason=base_branch_diverged"
    pooled || fail "the halt must return the bead to the pool (status=open, assignee empty)"
    cleared_marker || fail "the halt must clear handoff_stage so the witness cannot hand halted work to the refinery"
    routed_to_pool || fail "the halt must route the bead to the polecat pool"
    ! grep -q 'refinery' "$GCLOG" || fail "the halt must never assign the bead to the refinery"
    mailed_witness || fail "the halt must mail the witness"
    drained || fail "the halt must drain-ack on the way out"
}

test_failed_pin_fails_closed_without_halting() {
    # A fetch failure must never feed a stale remote ref into the ancestry
    # probe: the old gate halted off exactly that pair. Fail closed = stop,
    # drain, and write NO halt metadata (the bead stays as it was for the next
    # attempt).
    new_fixture unreachable
    git -C "$FIXTURE" remote set-url origin "$tmp/does-not-exist.git"
    [ "$(run_gate)" = "1" ] || fail "a failed base pin must stop the recipe"
    ! halted || fail "a failed base pin must not stamp a halt (that is a false halt by construction)"
    ! pooled || fail "a failed base pin must not reroute the bead"
    drained || fail "a failed base pin must still drain-ack"
}

test_missing_base_halts_into_the_pool() {
    new_fixture missing
    git -C "$FIXTURE" checkout -q --detach
    git -C "$FIXTURE" branch -q -D main
    git -C "$ORIGIN_BARE" update-ref -d refs/heads/main
    git -C "$FIXTURE" update-ref -d refs/remotes/origin/main
    [ "$(run_gate)" = "1" ] || fail "a base missing everywhere must stop the recipe"
    grep -q 'halt_reason=base_branch_missing' "$GCLOG" ||
        fail "a missing base must stamp halt_reason=base_branch_missing"
    pooled || fail "the missing-base halt must return the bead to the pool"
    cleared_marker || fail "the missing-base halt must clear handoff_stage"
    routed_to_pool || fail "the missing-base halt must route to the polecat pool"
}

test_resolved_base_clears_a_stale_halt_marker() {
    # Nothing ever cleared halt_reason, so a base halt from an earlier attempt
    # used to ride along on the next submit -- producing exactly the metadata
    # pair the production loop showed (halt_reason=base_branch_diverged next to
    # handoff_stage=target_recorded on a refinery-bound bead).
    new_fixture recovered
    printf '[{"id":"TESTBEAD","metadata":{"halt_reason":"base_branch_diverged"}}]' >"$GC_BD_JSON"
    [ "$(run_gate)" = "0" ] || fail "a resolved base must not stop the recipe"
    grep -q -- '--unset-metadata halt_reason' "$GCLOG" ||
        fail "a resolved base must clear the stale base halt_reason from an earlier attempt"
}

test_equal_refs_branch_from_remote
test_local_ahead_of_origin_is_not_divergence
test_origin_ahead_of_local_is_not_divergence
test_mutual_divergence_halts_into_the_pool
test_failed_pin_fails_closed_without_halting
test_missing_base_halts_into_the_pool
test_resolved_base_clears_a_stale_halt_marker

echo "mol-polecat-work base gate tests passed"

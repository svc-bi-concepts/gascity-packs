#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

parse_toml() {
    python3 - "$@" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
}

test_dog_assets_are_pack_local() {
    [[ -f "$GASTOWN/agents/dog/agent.toml" ]] || fail "missing dog agent config"
    [[ -f "$GASTOWN/agents/dog/prompt.template.md" ]] || fail "missing dog prompt"
    [[ -f "$GASTOWN/formulas/mol-shutdown-dance.toml" ]] || fail "missing shutdown dance formula"
    parse_toml "$GASTOWN/agents/dog/agent.toml" "$GASTOWN/formulas/mol-shutdown-dance.toml"
    grep -F 'wake_mode = "fresh"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own wake_mode"
    grep -F 'work_dir = ".gc/agents/dogs/{{.AgentBase}}"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own work_dir"
    ! grep -F 'fallback = true' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "gastown dog should be authoritative over fallback dog providers"
    ! grep -A3 -F '[[patches.agent]]' "$GASTOWN/pack.toml" | grep -F 'name = "dog"' >/dev/null ||
        fail "dog should not be split between pack-local agent and same-name patch"
    [[ ! -e "$GASTOWN/agents/dog/overlay/.gitkeep" ]] ||
        fail "dog overlay placeholder should not be present without an overlay contract"
}

test_retired_dog_formulas_are_not_reintroduced() {
    [[ ! -e "$GASTOWN/formulas/mol-dog-jsonl.toml" ]] || fail "mol-dog-jsonl formula should remain retired"
    [[ ! -e "$GASTOWN/formulas/mol-dog-reaper.toml" ]] || fail "mol-dog-reaper formula should remain retired"
    ! grep -R --exclude='test_gastown_pack_assets.sh' "mol-dog-jsonl\\|mol-dog-reaper" "$GASTOWN" >/dev/null ||
        fail "gastown pack should not advertise retired dog formulas"
}

test_shutdown_dance_contracts_are_executable() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"

    ! grep -F '[vars.warrant_id]' "$formula" >/dev/null ||
        fail "warrant_id should be the claimed work bead, not a required formula var"
    grep -F 'gc bd show "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should inspect the claimed warrant bead"
    grep -F 'gc bd close "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should close the claimed warrant bead"
    ! grep -F '<wisp-id>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw wisp placeholders"
    ! grep -F '<work-bead>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw work bead placeholders"
    ! grep -F 'gc mail send {{requester}}/' "$formula" >/dev/null ||
        fail "routine dog requester reporting must use nudge, not mail"
    grep -F 'requester_endpoint="${requester%/}/"' "$formula" >/dev/null ||
        fail "shutdown dance should normalize requester endpoints"
    grep -F 'gc session nudge "$requester_endpoint" "DOG_DONE:' "$formula" >/dev/null ||
        fail "shutdown dance should notify requester with DOG_DONE nudges"
    ! grep -F 'gc session peek "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for peeks"
    ! grep -F 'gc session kill "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for kills"
    grep -F 'Verify the warrant bead exists and is not closed' "$formula" >/dev/null ||
        fail "receive step should verify the warrant is not closed rather than demanding open"
    grep -F 'Both `open` and `in_progress` are valid warrant states' "$formula" >/dev/null ||
        fail "receive step should explicitly accept open and in_progress warrant states"
    ! grep -F 'exists and is open' "$formula" >/dev/null ||
        fail "receive step must not regress to an open-only warrant instruction; claimed warrants are in_progress"
}

test_shutdown_dance_lifecycle_and_audit_contracts() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"
    local prompt="$GASTOWN/agents/dog/prompt.template.md"

    ! grep -Fi 'burn' "$formula" >/dev/null ||
        fail "early-exit paths should drain-ack and exit, not burn a wisp that was never poured"
    [[ "$(grep -c 'gc runtime drain-ack' "$formula")" -ge 8 ]] ||
        fail "every early-exit path and the epitaph should end with gc runtime drain-ack"
    local malformed_branches malformed_closes malformed_drains
    malformed_branches="$(grep -c 'is missing target or reason' "$formula" || true)"
    malformed_closes="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc bd close "$GC_BEAD_ID"' || true)"
    malformed_drains="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc runtime drain-ack' || true)"
    [[ "$malformed_branches" -ge 1 ]] ||
        fail "shutdown dance should validate warrant target/reason metadata"
    [[ "$malformed_closes" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must close the claimed warrant before exiting"
    [[ "$malformed_drains" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must drain-ack before exiting, not leak the claimed warrant"
    grep -F 'MALFORMED_WARRANT' "$formula" >/dev/null ||
        fail "malformed warrants should close with a malformed-warrant audit reason"
    ! grep -E '^\[vars' "$formula" >/dev/null ||
        fail "warrant values come from bead metadata; the formula should not declare pour vars"
    grep -F 'EXECUTE_FAILED: kill did not take effect' "$formula" >/dev/null ||
        fail "kill failures should close the warrant as EXECUTE_FAILED, not Executed"
    grep -F 'DOG_DONE: $target - EXECUTE_FAILED (escalated)' "$formula" >/dev/null ||
        fail "kill failures should notify the requester with EXECUTE_FAILED, not EXECUTED"
    grep -F 'gone or shows fresh startup output' "$formula" >/dev/null ||
        fail "execute verification should treat gone-or-freshly-restarted as kill success"
    ! grep -F '{{requester}}' "$prompt" >/dev/null ||
        fail "dog prompt should use the normalized requester endpoint, not raw requester templates"
    ! grep -F 'nudge deacon/' "$prompt" >/dev/null ||
        fail "dog prompt should notify the warrant's requester, not a hardcoded deacon endpoint"
    grep -F 'gc session nudge "$requester_endpoint"' "$prompt" >/dev/null ||
        fail "dog prompt DOG_DONE guidance should use the normalized requester endpoint"
}

test_composition_is_documented() {
    # The retired maintenance pack is gone: the runtime composes the builtin
    # core pack via explicit city.toml includes, and gastown owns the only
    # mol-shutdown-dance. The docs must describe that model, not the old
    # fallback/ordering workarounds.
    grep -F 'builtin core pack' "$GASTOWN/README.md" >/dev/null ||
        fail "README should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not reference the retired maintenance pack import"
    ! grep -Fi 'implicit maintenance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not describe implicit maintenance injection"
    grep -F 'gc formula show mol-shutdown-dance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should document how to verify the effective shutdown-dance formula"
    grep -F 'builtin core' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should not reference the retired maintenance pack import"
}

test_refinery_direct_merge_is_worktree_safe_and_fail_closed() {
    local formula direct_block
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"

    direct_block=$(python3 - "$formula" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
print(text[start:end])
PY
)

    [[ "$direct_block" == *'git worktree add --detach "$MERGE_WT" "origin/$TARGET"'* ]] ||
        fail "direct refinery merge must use a detached target worktree"
    [[ "$direct_block" == *'+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}'* ]] ||
        fail "direct refinery merge refspecs must brace TARGET for zsh-safe expansion"
    [[ "$direct_block" == *'git -C "$MERGE_WT" push origin "HEAD:$TARGET"'* ]] ||
        fail "direct refinery merge must push the verified merge worktree HEAD"
    [[ "$direct_block" == *'[ "$MERGED_SHA" != "$REMOTE" ]'* ]] ||
        fail "direct refinery merge must compare merged SHA to origin target"
    [[ "$direct_block" == *'STOP. Do not mutate bead state.'* ]] ||
        fail "direct refinery merge must fail closed before metadata writes"
    ! printf '%s\n' "$direct_block" | grep -E '^[[:space:]]*git checkout \$TARGET([[:space:]]|$)' >/dev/null ||
        fail "direct refinery merge must not checkout target branch in the active worktree"

    python3 - "$formula" <<'PY' || fail "direct refinery merge must verify origin before setting merged metadata"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
block = text[start:end]
verify = block.index('[ "$MERGED_SHA" != "$REMOTE" ]')
metadata = block.index('--set-metadata merge_result=merged')
if verify >= metadata:
    raise SystemExit(1)
PY
}

test_refinery_closes_attached_polecat_workflows_on_terminal_handoff() {
    local formula direct_block mr_block prompt
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"
    prompt="$GASTOWN/agents/refinery/prompt.template.md"

    grep -F 'close_polecat_workflow_for_handoff()' "$formula" >/dev/null ||
        fail "refinery should define a terminal handoff cleanup helper"
    grep -F 'bd show "$handoff_work" --refs --json' "$formula" >/dev/null ||
        fail "refinery cleanup should discover synthetic tracking convoys from work bead refs"
    grep -F 'gc.input_convoy_id=$input_convoy' "$formula" >/dev/null ||
        fail "refinery cleanup should find graph.v2 roots by input convoy"
    grep -F 'gc.root_bead_id=$workflow_root' "$formula" >/dev/null ||
        fail "refinery cleanup should close workflow steps before the root"
    grep -F 'mol-polecat-work' "$formula" >/dev/null ||
        fail "refinery cleanup should be scoped to mol-polecat-work roots"

    direct_block=$(python3 - "$formula" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
print(text[start:end])
PY
)
    mr_block=$(python3 - "$formula" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "mr"')
end = text.index('**If MERGE_STRATEGY = "local"')
print(text[start:end])
PY
)

    [[ "$direct_block" == *'close_polecat_workflow_for_handoff "$WORK" "Refinery direct handoff merged to $TARGET at $MERGED_SHORT"'* ]] ||
        fail "direct handoff should close attached polecat workflows after closing the work bead"
    [[ "$mr_block" == *'close_polecat_workflow_for_handoff "$WORK" "Refinery PR handoff ready: $PR_URL"'* ]] ||
        fail "PR handoff should close attached polecat workflows after closing the work bead"
    grep -F 'still-live `mol-polecat-work` graph.v2 workflow' "$prompt" >/dev/null ||
        fail "refinery prompt should document terminal cleanup of attached polecat workflows"
}

test_polecat_exits_cleanly_when_work_is_already_shipped() {
    local formula prompt
    formula="$GASTOWN/formulas/mol-polecat-work.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"

    grep -F 'WORK_OUTCOME=$(printf' "$formula" >/dev/null ||
        fail "polecat should inspect work outcome before creating/reusing a worktree"
    grep -F 'gc.work_outcome' "$formula" >/dev/null ||
        fail "polecat should specifically recognize gc.work_outcome=shipped"
    grep -F 'Work bead $WORK_BEAD_ID already shipped; closing stale polecat workflow step' "$formula" >/dev/null ||
        fail "polecat should close stale workflow steps when work is already shipped"
    grep -F 'Work bead $WORK_BEAD_ID already shipped; closing stale polecat workflow root' "$formula" >/dev/null ||
        fail "polecat should close its stale workflow root when work is already shipped"
    grep -F 'gc runtime drain-ack' "$formula" >/dev/null ||
        fail "polecat already-shipped path should drain cleanly"
    grep -F 'already closed with' "$prompt" >/dev/null ||
        fail "polecat prompt should document the already-shipped clean exit"
}

test_polecat_enforces_ownership_and_host_safety() {
    local formula prompt witness gate tmp
    formula="$GASTOWN/formulas/mol-polecat-work.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"
    witness="$GASTOWN/agents/witness/prompt.template.md"

    parse_toml "$formula"
    # load-context, workspace-setup, self-review, submit-and-exit each carry the gate.
    [[ $(grep -c '# BEGIN ownership-gate' "$formula") -eq 4 ]] ||
        fail "ownership gate should be in load-context, workspace-setup, self-review and submit-and-exit"
    grep -F 'id = "load-context"' "$formula" >/dev/null ||
        fail "polecat formula should override load-context with the ownership gate"
    grep -F 'Mail can describe work but never grants it' "$formula" >/dev/null ||
        fail "load-context should not treat mail as authority to resume"
    grep -F 'One Polecat Per Bead' "$prompt" >/dev/null ||
        fail "polecat prompt should document ownership re-checks"
    grep -F 'Host Safety' "$prompt" >/dev/null ||
        fail "polecat prompt should have a Host Safety section"
    grep -F 'Host Safety' "$witness" >/dev/null ||
        fail "witness prompt should have a Host Safety section"
    grep -F 'brew services' "$prompt" >/dev/null ||
        fail "host safety should forbid package/service manager commands"

    # Simulate the gate with a stub gc against varied bead states.
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    python3 - "$formula" "$tmp" <<'PY'
import sys, tomllib
data = tomllib.load(open(sys.argv[1], "rb"))
for step in data["steps"]:
    body = step["description"]
    if "# BEGIN ownership-gate" not in body:
        continue
    start = body.index("# BEGIN ownership-gate")
    end = body.index("# END ownership-gate")
    open(f"{sys.argv[2]}/gate-{step['id']}.sh", "w").write(
        body[start:end].replace("{{convoy_id}}", "cv-1"))
PY
    cat >"$tmp/gc" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "convoy status") echo '{"children":[{"id":"wb-1"}]}' ;;
    "bd show") cat "$STUB_WORK" ;;
    "bd list")
        case "$*" in
            *gc.kind=workflow*) cat "$STUB_ROOTS" ;;
            *gc.root_bead_id=*) cat "$STUB_STEPS" ;;
        esac ;;
    "runtime drain-ack") echo drained >>"$STUB_LOG" ;;
esac
STUB
    chmod +x "$tmp/gc"

    # gate step work-assignee work-status work-outcome roots-json steps-json
    run_gate() {
        printf '[{"assignee":"%s","status":"%s","metadata":{"gc.work_outcome":"%s"}}]' \
            "$2" "$3" "$4" >"$tmp/work.json"
        printf '%s' "$5" >"$tmp/roots.json"
        printf '%s' "$6" >"$tmp/steps.json"
        : >"$tmp/log"
        env -i PATH="$tmp:$PATH" BEADS_ACTOR=rig/gastown.me GC_AGENT=rig/gastown.me \
            STUB_WORK="$tmp/work.json" STUB_ROOTS="$tmp/roots.json" \
            STUB_STEPS="$tmp/steps.json" STUB_LOG="$tmp/log" \
            bash "$tmp/gate-$1.sh" >/dev/null 2>&1
    }
    local open_root='[{"id":"r1","metadata":{"gc.formula_name":"mol-polecat-work"}}]'
    local step_me='[{"assignee":"rig/gastown.me","metadata":{"gc.step_id":"mol-polecat-work.workspace-setup"}}]'
    local step_other='[{"assignee":"rig/gastown.other","metadata":{"gc.step_id":"mol-polecat-work.workspace-setup"}}]'
    local step_none='[{"assignee":"","metadata":{"gc.step_id":"mol-polecat-work.workspace-setup"}}]'

    # Live shape: work bead unassigned, current step assigned to this session -> pass.
    run_gate workspace-setup "" open "" "$open_root" "$step_me" ||
        fail "gate should pass: work bead unassigned, current step assigned to this session"
    # Missing optional fields are not a mismatch.
    run_gate workspace-setup "" open "" "$open_root" "$step_none" ||
        fail "gate should pass when the current step is not yet assigned"
    run_gate workspace-setup "" open "" "$open_root" '[]' ||
        fail "gate should pass when the step bead cannot be found"
    run_gate load-context "rig/gastown.me" in_progress "" "$open_root" "$step_me" ||
        fail "gate should pass when the work bead is assigned to this session"
    # Genuine mismatches stop and drain.
    if run_gate workspace-setup "" open "" "$open_root" "$step_other"; then
        fail "gate should stop when the current step is assigned to another polecat"
    fi
    grep -F drained "$tmp/log" >/dev/null || fail "gate should drain-ack when ownership is lost"
    if run_gate workspace-setup "" open "" '[]' "$step_me"; then
        fail "gate should stop when the workflow root is closed"
    fi
    if run_gate workspace-setup "rig/gastown.other" open "" "$open_root" "$step_me"; then
        fail "gate should stop when the work bead is assigned to a different polecat"
    fi
    if run_gate self-review "" closed "shipped" "$open_root" "$step_me"; then
        fail "gate should stop self-review on a shipped work bead"
    fi
    if run_gate load-context "" closed "" "$open_root" "$step_me"; then
        fail "gate should stop on a closed work bead that was not shipped"
    fi
    # load-context and workspace-setup let a shipped bead through to the stale-workflow cleanup.
    run_gate workspace-setup "" closed "shipped" '[]' "$step_me" ||
        fail "workspace-setup gate should defer shipped beads to stale-workflow cleanup"
}

test_dog_assets_are_pack_local
test_retired_dog_formulas_are_not_reintroduced
test_shutdown_dance_contracts_are_executable
test_shutdown_dance_lifecycle_and_audit_contracts
test_composition_is_documented
test_refinery_direct_merge_is_worktree_safe_and_fail_closed
test_refinery_closes_attached_polecat_workflows_on_terminal_handoff
test_polecat_exits_cleanly_when_work_is_already_shipped

test_polecat_enforces_ownership_and_host_safety

echo "gastown pack asset tests passed"

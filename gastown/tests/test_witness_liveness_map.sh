#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"
FIXTURES="$GASTOWN/tests/fixtures/witness-liveness"
FORMULA="$GASTOWN/formulas/mol-witness-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null || fail "jq is required"

# Extract the LIVENESS_MAP jq assignment from the recover-orphaned-beads step
# description. The test executes the recipe's real command line (flags and
# program), so a schema regression in either half fails here. Raw-text
# extraction (no tomllib) so the test runs on any python3.
MAP_CMD=$(python3 - "$FORMULA" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
# "$(" is spelled indirectly: a literal dollar-paren inside a heredoc body
# nested in command substitution trips the macOS bash 3.2 parser.
marker = "LIVENESS_MAP=" + "$" + "(jq -n"
if text.count(marker) != 1:
    raise SystemExit("expected exactly one LIVENESS_MAP jq assignment")
start = text.index(marker)
q1 = text.index("'", start)
q2 = text.index("'", q1 + 1)
cmd = text[start : q2 + 2]
if not cmd.endswith("')"):
    raise SystemExit("unexpected LIVENESS_MAP command shape")
print(cmd)
PY
) || fail "could not extract LIVENESS_MAP command from formula"

# Run the extracted command against fixture blobs.
# Sets MAP_RC (jq exit status) and MAP_JSON (map contents, may be empty).
run_map() {
    local runner out
    runner=$(mktemp)
    {
        printf '%s\n' "$MAP_CMD"
        printf '%s\n' 'rc=$?'
        printf '%s\n' 'printf "RC=%s\n" "$rc"'
        printf '%s\n' 'printf "%s" "$LIVENESS_MAP"'
    } >"$runner"
    out=$(SESSIONS_FILE="$1" SESSION_BEADS_FILE="$2" bash "$runner" 2>/dev/null) || true
    MAP_RC="${out%%$'\n'*}"
    MAP_RC="${MAP_RC#RC=}"
    MAP_JSON="${out#*$'\n'}"
    rm -f "$runner"
}

resolve() {
    printf '%s' "$MAP_JSON" | jq -r --arg a "$1" '.[$a] // "absent"'
}

test_map_resolves_every_assignee_form() {
    run_map "$FIXTURES/session_list.json" "$FIXTURES/session_beads.json"

    [[ "$MAP_RC" == "0" ]] ||
        fail "liveness map build failed against clean fixtures (jq exit $MAP_RC)"
    [[ -n "$MAP_JSON" ]] ||
        fail "liveness map came out empty against clean fixtures"

    local count
    count=$(printf '%s' "$MAP_JSON" | jq -r 'length')
    [[ "$count" -ge 8 ]] ||
        fail "liveness map too thin: $count keys (expected id/session_name/alias/template per session plus bead identity)"

    # Session id form: gp-wisp-xxxx
    [[ "$(resolve "gp-wisp-aa11bb22")" == "active" ]] ||
        fail "session id form gp-wisp-xxxx did not resolve to active"
    # Session name form: gc__<role>-gp-wisp-xxxx
    [[ "$(resolve "gc__implementation-worker-gp-wisp-aa11bb22")" == "active" ]] ||
        fail "session name form gc__<role>-gp-wisp-xxxx did not resolve to active"
    # Alias form
    [[ "$(resolve "recruiter-hub/gastown.polecat-1")" == "closed" ]] ||
        fail "alias form did not resolve (stopped session must derive closed)"
    # Template route form (no alias on the session)
    [[ "$(resolve "recruiter-hub/gc.implementation-worker")" == "active" ]] ||
        fail "template route form did not resolve to active"
    # Session-bead configured_named_identity (no session side entry needed)
    [[ "$(resolve "recruiter-hub/gastown.witness")" == "active" ]] ||
        fail "configured_named_identity form did not resolve to active"
    # Terminal state derived from state=closed
    [[ "$(resolve "gp-wisp-99aa00bb")" == "closed" ]] ||
        fail "state=closed session must map to closed"
    # Unknown assignees stay absent
    [[ "$(resolve "gp-wisp-does-not-exist")" == "absent" ]] ||
        fail "unknown assignee must resolve to absent"
}

test_map_survives_malformed_session_bead_blobs() {
    # A malformed session-bead blob must never zero the map: the sessions side
    # still populates identifier keys, so orphan recovery stays armed instead
    # of failing safe every cycle (the empty-map incident).
    local variant
    for variant in object_wrapper banner string_metadata; do
        run_map "$FIXTURES/session_list.json" "$FIXTURES/session_beads_${variant}.json"
        [[ "$MAP_RC" == "0" ]] ||
            fail "liveness map build crashed on $variant bead blob (jq exit $MAP_RC)"
        [[ "$(resolve "gp-wisp-aa11bb22")" == "active" ]] ||
            fail "liveness map lost session identities on $variant bead blob"
    done
}

test_recipe_uses_current_schema_only() {
    local program
    program=$(printf '%s\n' "$MAP_CMD")
    ! grep -qF '$s.name' <<<"$program" ||
        fail "recipe still keys on removed session field \$s.name"
    ! grep -qF '$s.agent_name' <<<"$program" ||
        fail "recipe still keys on removed session field \$s.agent_name"
    ! grep -qF '$s.closed' <<<"$program" ||
        fail "recipe still reads removed session field \$s.closed (derive closed from state)"
    grep -qF '$s.template' <<<"$program" ||
        fail "recipe must key on \$s.template (route-form assignees)"
    grep -qF '"stopped"' <<<"$program" ||
        fail "recipe must derive closed from state closed/stopped"
    grep -qF 'configured_named_identity' <<<"$program" ||
        fail "recipe must merge session-bead configured_named_identity"
}

test_empty_map_fail_safe_is_kept() {
    grep -qF 'FAIL-SAFE: empty liveness map' "$FORMULA" ||
        fail "empty-map fail-safe echo must stay"
    grep -qF 'MAP_COUNT' "$FORMULA" ||
        fail "fail-safe must still gate on MAP_COUNT"
    grep -qF 'orphan-recovery disabled' "$FORMULA" ||
        fail "fail-safe must still escalate to the mayor"
}

test_map_resolves_every_assignee_form
test_map_survives_malformed_session_bead_blobs
test_recipe_uses_current_schema_only
test_empty_map_fail_safe_is_kept

echo "witness liveness map tests passed"

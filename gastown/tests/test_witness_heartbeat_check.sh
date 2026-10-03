#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/witness-heartbeat-check.sh"
COMMAND="$ROOT/gastown/commands/witness-heartbeat-check/run.sh"
FORMULA="$ROOT/gastown/formulas/mol-deacon-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
# Only `gc session list --state=all --json` is exercised here.
case "$*" in
    *"session"*"list"*"--json"*) cat "$GC_SESSIONS_JSON" ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_check <sessions-json-literal> [env assignments...] — prints the TSV rows,
# sets RC to the exit code. stderr is captured separately so row assertions stay
# clean.
run_check() {
    local payload="$1"
    shift
    printf '%s' "$payload" >"$SESSIONS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env GC_CITY="$CITY" GC_SESSIONS_JSON="$SESSIONS" PATH="$BIN:$PATH" ${1+"$@"} \
        bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# epoch -> RFC3339 UTC. GNU `date -d` first, BSD `date -r` second: the suite
# must run green on the macOS fleet, not only on Linux CI.
fmt_epoch_utc() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# epoch -> the local-offset form gc emits (e.g. 2026-10-02T19:12:05+02:00),
# pinned to a +02:00 offset: the instant rendered in UTC+2 plus the offset
# suffix names the same instant.
fmt_epoch_plus0200() {
    local base
    base=$(date -u -d "@$(( $1 + 7200 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
        || date -u -r "$(( $1 + 7200 ))" +%Y-%m-%dT%H:%M:%S)
    printf '%s+02:00' "$base"
}

ts_ago() {
    fmt_epoch_utc "$(( $(date -u +%s) - $1 ))"
}

ts_ago_plus0200() {
    fmt_epoch_plus0200 "$(( $(date -u +%s) - $1 ))"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
SESSIONS="$tmp/sessions.json"
ERRFILE="$tmp/stderr.txt"
mkdir -p "$CITY"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

FRESH=$(ts_ago 45)
STALE=$(ts_ago 72000)   # 20h — inside the 14h-63h band this check exists for

test_fresh_heartbeat_is_not_flagged() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$FRESH")"
    [ "$RC" -eq 0 ] || fail "a fresh witness must exit 0, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	asleep	' ||
        fail "a fresh witness should report the fresh verdict, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stalled' &&
        fail "a fresh witness must never be reported stalled"
    return 0
}

test_stale_heartbeat_is_stalled() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$STALE")"
    [ "$RC" -eq 1 ] || fail "a stalled witness must exit 1, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	alpha	alpha/witness	asleep	7[0-9][0-9][0-9][0-9]	' ||
        fail "a 20h-silent witness should report stalled with its age, got: $OUT"
}

test_zero_time_sentinel_is_no_heartbeat_not_stalled() {
    run_check '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"0001-01-01T00:00:00Z"}]}'
    printf '%s' "$OUT" | grep -q '^no-heartbeat	alpha	alpha/witness	asleep	-	-$' ||
        fail "the Go zero-time sentinel should report no-heartbeat, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stalled' &&
        fail "the zero-time sentinel must never be parsed as an ancient heartbeat"
    [ "$RC" -eq 1 ] || fail "an unmeasurable heartbeat is a finding (exit 1), got $RC"
    return 0
}

test_malformed_timestamp_is_no_heartbeat_not_stalled() {
    run_check '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"active","running":true,"last_active":"not-a-timestamp"}]}'
    printf '%s' "$OUT" | grep -q '^no-heartbeat	alpha	alpha/witness	active	-	-$' ||
        fail "an unparseable timestamp should report no-heartbeat, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stalled' &&
        fail "an unparseable timestamp must not be reported stalled"
    [ "$RC" -eq 1 ] || fail "an unparseable heartbeat is a finding (exit 1), got $RC"
    return 0
}

test_offset_timestamp_parses() {
    # gc emits local-offset stamps such as 2026-10-02T19:12:05+02:00; BSD
    # `date -f %z` cannot parse the colon inside the offset, so the script
    # normalizes +02:00 -> +0200 before parsing. A parse failure would read
    # as a false no-heartbeat finding on the macOS fleet.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"active","running":true,"last_active":"%s"}]}' "$(ts_ago_plus0200 45)")"
    [ "$RC" -eq 0 ] || fail "an offset-fresh witness must exit 0, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	active	[0-9][0-9]	' ||
        fail "a +02:00 offset timestamp should parse as fresh, got: $OUT"
    printf '%s' "$OUT" | grep -q 'no-heartbeat' &&
        fail "an offset timestamp must never read as no-heartbeat"
    return 0
}

test_newer_of_the_two_stamps_wins() {
    # Stale last_active + fresh self-nudge = healthy. This is the pairing that
    # makes the check usable on an asleep witness at all.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s","last_nudge_delivered_at":"%s"}]}' "$STALE" "$FRESH")"
    [ "$RC" -eq 0 ] || fail "a fresh self-nudge should keep the witness fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q "^fresh	alpha	alpha/witness	asleep	[0-9]*	$FRESH\$" ||
        fail "the newer of last_active/last_nudge_delivered_at should win, got: $OUT"

    # ...and the reverse ordering must give the same answer.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s","last_nudge_delivered_at":"%s"}]}' "$FRESH" "$STALE")"
    [ "$RC" -eq 0 ] || fail "stamp order must not change the verdict, got $RC ($OUT)"
}

test_fractional_seconds_parse() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "${FRESH%Z}.123456789Z")"
    [ "$RC" -eq 0 ] || fail "a fractional-second timestamp should parse as fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	' ||
        fail "a fractional-second timestamp should report fresh, got: $OUT"
}

test_future_heartbeat_is_clock_skew_not_stale() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$(fmt_epoch_utc "$(( $(date -u +%s) + 3600 ))")")"
    [ "$RC" -eq 0 ] || fail "a future heartbeat is skew, not staleness, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	asleep	0	' ||
        fail "a future heartbeat should clamp to age 0, got: $OUT"
}

test_threshold_is_configurable() {
    local ninety_one_min
    ninety_one_min=$(ts_ago 5460)
    # Inside the 90m default...
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$(ts_ago 3600)")"
    [ "$RC" -eq 0 ] || fail "a 1h-old heartbeat is inside the 90m default, got $RC ($OUT)"
    # ...outside it.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$ninety_one_min")"
    [ "$RC" -eq 1 ] || fail "a 91m-old heartbeat should breach the 90m default, got $RC ($OUT)"
    # ...and a tighter window flags what the default tolerates.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$(ts_ago 3600)")" \
        GASTOWN_WITNESS_STALE_MIN=15
    [ "$RC" -eq 1 ] || fail "GASTOWN_WITNESS_STALE_MIN=15 should flag a 1h-old heartbeat, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'window 15m' ||
        fail "the summary should report the configured window, got: $ERR"
}

test_bad_threshold_fails_loudly() {
    run_check '{"_cache_age_s":0,"sessions":[]}' GASTOWN_WITNESS_STALE_MIN=abc
    [ "$RC" -eq 2 ] || fail "a non-numeric window must exit 2, got $RC"
    run_check '{"_cache_age_s":0,"sessions":[]}' GASTOWN_WITNESS_STALE_MIN=0
    [ "$RC" -eq 2 ] || fail "a zero window must exit 2, got $RC"
}

test_controller_owned_states_are_skipped() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[
      {"id":"s1","alias":"a/witness","session_name":"gastown__witness-s1","template":"a/gastown.witness","state":"creating","running":false,"last_active":"%s"},
      {"id":"s2","alias":"b/witness","session_name":"gastown__witness-s2","template":"b/gastown.witness","state":"start-pending","running":false,"last_active":"%s"},
      {"id":"s3","alias":"c/witness","session_name":"gastown__witness-s3","template":"c/gastown.witness","state":"draining","running":false,"last_active":"%s"},
      {"id":"s4","alias":"d/witness","session_name":"gastown__witness-s4","template":"d/gastown.witness","state":"suspended","running":false,"last_active":"%s"},
      {"id":"s5","alias":"e/witness","session_name":"gastown__witness-s5","template":"e/gastown.witness","state":"drained","running":false,"last_active":"%s"}
    ]}' "$STALE" "$STALE" "$STALE" "$STALE" "$STALE")"
    [ "$RC" -eq 0 ] || fail "controller/operator-owned states must not be flagged, got $RC ($OUT)"
    [ -z "$OUT" ] || fail "controller/operator-owned states should emit no rows, got: $OUT"
    printf '%s' "$ERR" | grep -q "no patrolling 'witness' session among 5" ||
        fail "the summary should say nothing was checked, got: $ERR"
}

test_terminal_states_are_excluded_by_state() {
    # The current schema (gc-3tn8g) has no `closed` field. A terminal session
    # with a stale heartbeat must be excluded by `state` (closed / stopped),
    # never read as a stalled patrol loop — and never even counted as checked.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[
      {"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"stopped","running":false,"last_active":"%s"},
      {"id":"s2","alias":"beta/witness","session_name":"gastown__witness-s2","template":"beta/gastown.witness","state":"closed","running":false,"last_active":"%s"},
      {"id":"s3","alias":"gamma/witness","session_name":"gastown__witness-s3","template":"gamma/gastown.witness","state":"active","running":true,"last_active":"%s"}
    ]}' "$STALE" "$STALE" "$FRESH")"
    [ "$RC" -eq 0 ] || fail "terminal sessions must not be flagged, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -qE '^(stalled|no-heartbeat)' &&
        fail "terminal sessions must not produce findings, got: $OUT"
    [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] ||
        fail "only the live witness should yield a row, got: $OUT"
    printf '%s' "$OUT" | grep -q '^fresh	gamma	gamma/witness	active	' ||
        fail "the live witness should report fresh, got: $OUT"
    printf '%s' "$ERR" | grep -q "checked 1 'witness' session" ||
        fail "terminal sessions must not be counted as checked, got: $ERR"
    return 0
}

test_legacy_closed_flag_still_honored() {
    # Pre-drift rosters that still carry the boolean `closed` field keep their
    # old meaning: a closed session is excluded even from a patrolling state.
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","template":"gastown.witness","state":"asleep","last_active":"%s","closed":true}]}' "$STALE")"
    [ "$RC" -eq 0 ] || fail "a legacy closed=true session must be excluded, got $RC ($OUT)"
    [ -z "$OUT" ] || fail "a legacy closed=true session should emit no row, got: $OUT"
    return 0
}

test_non_witness_sessions_are_ignored() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[
      {"id":"s1","alias":"","session_name":"gastown__deacon-s1","template":"gastown.deacon","state":"asleep","running":false,"last_active":"%s"},
      {"id":"s2","alias":"a/refinery","session_name":"gastown__refinery-s2","template":"a/gastown.refinery","state":"asleep","running":false,"last_active":"%s"},
      {"id":"s3","alias":"a/witnessing-tool","session_name":"gastown__witnessing-tool-s3","template":"a/gastown.witnessing-tool","state":"asleep","running":false,"last_active":"%s"},
      {"id":"s4","alias":"a/witness","session_name":"gastown__witness-s4","template":"a/gastown.witness","state":"asleep","running":false,"last_active":"%s"}
    ]}' "$STALE" "$STALE" "$STALE" "$FRESH")"
    [ "$RC" -eq 0 ] || fail "only witness sessions should be checked, got $RC ($OUT)"
    [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] ||
        fail "exactly one row (the witness) expected, got: $OUT"
    printf '%s' "$OUT" | grep -q 'a/witness	asleep' ||
        fail "the witness row should be the one reported, got: $OUT"
    printf '%s' "$OUT" | grep -q 'witnessing-tool' &&
        fail "a bare substring match must not pull in unrelated session names"
    return 0
}

test_binding_prefixed_template_matches() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","state":"asleep","running":false,"template":"gastown.witness","last_active":"%s"}]}' "$STALE")"
    [ "$RC" -eq 1 ] || fail "a binding-prefixed template should still match, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	-	s1	asleep	' ||
        fail "a session with no alias/session_name should fall back to its id, got: $OUT"
}

test_rig_column_derived_from_route_prefix() {
    # The current schema has no `rig` field; the rig column falls back to the
    # alias/template route prefix, and reports "-" when neither carries one.
    run_check "$(printf '{"_cache_age_s":0,"sessions":[
      {"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"},
      {"id":"s2","alias":"","session_name":"gastown__witness-s2","template":"gastown.witness","state":"asleep","running":false,"last_active":"%s"}
    ]}' "$FRESH" "$FRESH")"
    [ "$RC" -eq 0 ] || fail "route-prefix rig derivation must not fail, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	asleep	' ||
        fail "the rig column should come from the alias route prefix, got: $OUT"
    printf '%s' "$OUT" | grep -q '^fresh	-	gastown__witness-s2	asleep	' ||
        fail "a route-less session should report rig '-' and its session_name, got: $OUT"
    return 0
}

test_role_override() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"a/scout","session_name":"gastown__scout-s1","template":"a/gastown.scout","state":"asleep","running":false,"last_active":"%s"}]}' "$STALE")" \
        GASTOWN_WITNESS_ROLE=scout
    [ "$RC" -eq 1 ] || fail "GASTOWN_WITNESS_ROLE should retarget the check, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	a	a/scout	' ||
        fail "the overridden role should be checked, got: $OUT"
}

test_legacy_top_level_array_is_tolerated() {
    # The pre-schema-1.1.1 roster shape (bare top-level array, `name`/`rig`/
    # `closed` fields) still parses and keeps its old meaning.
    run_check "$(printf '[{"id":"s1","name":"alpha/witness","rig":"alpha","template":"gastown.witness","state":"asleep","last_active":"%s","closed":false}]' "$STALE")"
    [ "$RC" -eq 1 ] || fail "the legacy top-level array shape should still parse, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	alpha	alpha/witness	' ||
        fail "the legacy array shape should yield the same verdict, got: $OUT"
}

test_missing_last_active_field_fails_loud() {
    # Schema drift must never read as health: nothing was measured, so say so
    # instead of quietly reporting every witness fresh.
    run_check '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false}]}'
    [ "$RC" -eq 2 ] || fail "a roster with no last_active field must exit 2, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^schema-drift	alpha	alpha/witness	asleep	-	-$' ||
        fail "the drifted session should be named, got: $OUT"
    printf '%s' "$ERR" | grep -q 'NOT measured' ||
        fail "the drift message should say freshness was not measured, got: $ERR"
}

test_unreadable_roster_fails_loud() {
    mkdir -p "$tmp/badbin"
    printf '#!/usr/bin/env sh\nexit 1\n' >"$tmp/badbin/gc"
    chmod +x "$tmp/badbin/gc"
    set +e
    OUT=$(GC_CITY="$CITY" PATH="$tmp/badbin:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a failing 'gc session list' must exit 2, got $RC"
    grep -q 'NOT measured' "$ERRFILE" ||
        fail "a failing roster read should say freshness was not measured"
}

test_missing_city_fails_loud() {
    set +e
    OUT=$(cd "$tmp" && GC_CITY="$tmp/nope" PATH="$BIN:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a missing city must exit 2, got $RC"
    grep -q 'no city.toml found' "$ERRFILE" || fail "expected the city-resolution error"
}

test_multiple_rigs_report_every_witness() {
    run_check "$(printf '{"_cache_age_s":0,"sessions":[
      {"id":"s1","alias":"a/witness","session_name":"gastown__witness-s1","template":"a/gastown.witness","state":"asleep","running":false,"last_active":"%s"},
      {"id":"s2","alias":"b/witness","session_name":"gastown__witness-s2","template":"b/gastown.witness","state":"active","running":true,"last_active":"%s"},
      {"id":"s3","alias":"c/witness","session_name":"gastown__witness-s3","template":"c/gastown.witness","state":"asleep","running":false,"last_active":"0001-01-01T00:00:00Z"}
    ]}' "$FRESH" "$STALE")"
    [ "$RC" -eq 1 ] || fail "a mixed roster with findings must exit 1, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	a	a/witness	' || fail "rig a should be fresh: $OUT"
    printf '%s' "$OUT" | grep -q '^stalled	b	b/witness	active	' || fail "rig b should be stalled: $OUT"
    printf '%s' "$OUT" | grep -q '^no-heartbeat	c	c/witness	' || fail "rig c should be no-heartbeat: $OUT"
    printf '%s' "$ERR" | grep -q "checked 3 'witness' session(s), 1 stalled (window 90m)" ||
        fail "the summary should count what was checked, got: $ERR"
}

test_uses_no_bash4_only_constructs() {
    ! grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^|\$\{[A-Za-z_]+,,|&>>|\[\[ -v ' "$SCRIPT" >/dev/null ||
        fail "the check must stay bash 3.2 compatible (the fleet includes macOS)"
}

test_formula_dispatches_via_pack_command_without_agent_pack_env() {
    grep -Fqx 'GASTOWN_WITNESS_STALE_MIN={{witness_stale_min}} gc gastown witness-heartbeat-check' "$FORMULA" ||
        fail "health-scan must invoke the heartbeat check through the gastown command namespace"
    ! grep -Fq 'GC_PACK_DIR' "$FORMULA" ||
        fail "agent formulas must not assume managed sessions receive GC_PACK_DIR"
    [ -x "$COMMAND" ] ||
        fail "the witness-heartbeat-check pack command must be executable"

    local dispatch_bin="$tmp/dispatch-bin"
    mkdir -p "$dispatch_bin"
    cat >"$dispatch_bin/gc" <<'SH'
#!/usr/bin/env sh
case "$*" in
    "gastown witness-heartbeat-check")
        if [ -n "${GC_PACK_DIR:-}" ]; then
            echo "agent unexpectedly inherited GC_PACK_DIR" >&2
            exit 90
        fi
        GC_PACK_DIR="$GC_TEST_PACK_DIR"
        export GC_PACK_DIR
        exec "$GC_PACK_DIR/commands/witness-heartbeat-check/run.sh"
        ;;
    "session list --state=all --json")
        cat "$GC_SESSIONS_JSON"
        ;;
    *)
        echo "unexpected gc invocation: $*" >&2
        exit 91
        ;;
esac
SH
    chmod +x "$dispatch_bin/gc"

    printf '{"_cache_age_s":0,"sessions":[{"id":"s1","alias":"alpha/witness","session_name":"gastown__witness-s1","template":"alpha/gastown.witness","state":"asleep","running":false,"last_active":"%s"}]}' "$FRESH" >"$SESSIONS"
    set +e
    OUT=$(env -u GC_PACK_DIR GC_CITY="$CITY" GC_TEST_PACK_DIR="$ROOT/gastown" \
        GC_SESSIONS_JSON="$SESSIONS" PATH="$dispatch_bin:$PATH" \
        GASTOWN_WITNESS_STALE_MIN=90 gc gastown witness-heartbeat-check 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")

    [ "$RC" -eq 0 ] ||
        fail "pack-command dispatch without agent GC_PACK_DIR must succeed, got $RC ($ERR)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	asleep	' ||
        fail "pack-command dispatch should reach the heartbeat implementation, got: $OUT"
}

test_fresh_heartbeat_is_not_flagged
test_stale_heartbeat_is_stalled
test_zero_time_sentinel_is_no_heartbeat_not_stalled
test_malformed_timestamp_is_no_heartbeat_not_stalled
test_offset_timestamp_parses
test_newer_of_the_two_stamps_wins
test_fractional_seconds_parse
test_future_heartbeat_is_clock_skew_not_stale
test_threshold_is_configurable
test_bad_threshold_fails_loudly
test_controller_owned_states_are_skipped
test_terminal_states_are_excluded_by_state
test_legacy_closed_flag_still_honored
test_non_witness_sessions_are_ignored
test_binding_prefixed_template_matches
test_rig_column_derived_from_route_prefix
test_role_override
test_legacy_top_level_array_is_tolerated
test_missing_last_active_field_fails_loud
test_unreadable_roster_fails_loud
test_missing_city_fails_loud
test_multiple_rigs_report_every_witness
test_uses_no_bash4_only_constructs
test_formula_dispatches_via_pack_command_without_agent_pack_env

echo "witness heartbeat check tests passed"

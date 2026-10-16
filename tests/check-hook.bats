#!/usr/bin/env bats
# The first boot hook firstboot.d/40lnpp-check (decision 0059, point 6):
# the role, the database and the table of the check page, and one row for
# this host, on a writable server only. Every command that would touch the
# system (systemctl, pg_isready, runuser) is a PATH stub that records its
# arguments and its standard input. Nothing here needs root or a database.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/40lnpp-check"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin"
    ln -s "$(cd "$ROOT/overlay/usr/lib/inithooks" && pwd)" "$scratch/inithooks"

    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export CALLS="$scratch/calls"
    export SQL="$scratch/sql"
    export PGSQL_SLEEP=:
    export RECOVERY=f
    printf 'INITHOOKS_PATH=%s\n' "$scratch/inithooks" > "$INITHOOKS_DEFAULT"

    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    stub pg_isready 'echo "pg_isready $*" >> "$CALLS"'
    stub hostname 'echo "lnpp-1"'
    # runuser -u postgres -- psql ...: the recovery question is answered
    # from RECOVERY; the statements on standard input are recorded
    stub runuser 'echo "runuser $*" >> "$CALLS"
case "$*" in
  *pg_is_in_recovery*) echo "$RECOVERY" ;;
  *) cat >> "$SQL" ;;
esac'
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

@test "a writable server gets the role, the database, the table and the row" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -qx "systemctl start postgresql.service" "$CALLS"
    grep -q "runuser -u postgres -- psql" "$CALLS"
    grep -q 'CREATE ROLE "keel-check" LOGIN' "$SQL"
    grep -q 'CREATE DATABASE keel_check' "$SQL"
    grep -q 'CREATE TABLE IF NOT EXISTS boot' "$SQL"
    grep -q "INSERT INTO boot (host) VALUES (:'host') ON CONFLICT (host) DO NOTHING" "$SQL"
    grep -q -- "--set=host=lnpp-1" "$CALLS"
    [[ "$output" == *"the check page reads keel_check as keel-check"* ]]
}

@test "the role has no password and only reads" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    run ! grep -qi 'PASSWORD' "$SQL"
    grep -q 'GRANT SELECT ON boot TO "keel-check"' "$SQL"
    grep -q 'GRANT CONNECT ON DATABASE keel_check TO "keel-check"' "$SQL"
    grep -q 'REVOKE ALL ON DATABASE keel_check FROM PUBLIC' "$SQL"
    run ! grep -qE 'GRANT (INSERT|UPDATE|DELETE|ALL)' "$SQL"
}

@test "a second run creates nothing twice: each CREATE is guarded" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keel-check')" "$SQL"
    grep -q "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keel_check')" "$SQL"
    grep -q '\\gexec' "$SQL"
}

@test "a standby writes nothing and says so" {
    RECOVERY=t
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -e "$SQL" ]
    [[ "$output" == *"is a standby (in recovery): it writes nothing"* ]]
}

@test "an answer that is not t or f fails the hook" {
    RECOVERY=maybe
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pg_is_in_recovery() answered 'maybe'"* ]]
    [ ! -e "$SQL" ]
}

@test "a server that never answers fails the hook" {
    stub pg_isready 'exit 2'
    export PGSQL_WAIT_TRIES=2
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"postgresql did not answer after 2 tries"* ]]
}

@test "a failed statement fails the hook" {
    stub runuser 'case "$*" in *pg_is_in_recovery*) echo f ;; *) exit 3 ;; esac'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the statements of the check page failed"* ]]
}

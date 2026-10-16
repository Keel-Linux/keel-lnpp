#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/lib/postgresql.sh, the logic
# behind the first boot hook 36pgsqlverify (decision 0004). Every function
# is pure: nothing here needs a database, root or a network.

bats_require_minimum_version 1.5.0

setup() {
    load ../overlay/usr/lib/inithooks/lib/postgresql.sh
}

@test "first_value: the first value that is set and is not DEFAULT" {
    [ "$(pgsql_first_value "" DEFAULT keeper other)" = keeper ]
    [ "$(pgsql_first_value default keeper)" = keeper ]
    [ "$(pgsql_first_value Default keeper)" = keeper ]
    [ "$(pgsql_first_value first second)" = first ]
    run ! pgsql_first_value "" DEFAULT ""
    run ! pgsql_first_value
}

@test "role: the cluster superuser, or the one APP_DB_USER names" {
    [ "$(pgsql_role)" = postgres ]
    [ "$(pgsql_role "")" = postgres ]
    [ "$(pgsql_role DEFAULT)" = postgres ]
    [ "$(pgsql_role lappuser)" = lappuser ]
    PGSQL_ROLE=dba
    [ "$(pgsql_role)" = dba ]
}

@test "role: a name that would need quoting is refused" {
    run ! pgsql_role "rm -rf /"
    run ! pgsql_role '"postgres"'
    run ! pgsql_role "9lives"
    run ! pgsql_role "a b"
    run ! pgsql_role "pg;sql"
}

@test "is_role_name: what this layer will verify" {
    pgsql_is_role_name postgres
    pgsql_is_role_name _pg
    pgsql_is_role_name lapp-user
    pgsql_is_role_name a1
    run ! pgsql_is_role_name ""
    run ! pgsql_is_role_name "1a"
    run ! pgsql_is_role_name "a%"
}

@test "missing_values: DB_PASS only when the description declared none" {
    [ -z "$(pgsql_missing_values s3cret)" ]
    [ "$(pgsql_missing_values "")" = DB_PASS ]
    [ "$(pgsql_missing_values)" = DB_PASS ]
}

@test "verify_argv: the psql call that proves the password, without it" {
    output=$(pgsql_verify_argv postgres ::1 5432 postgres)
    [ "$output" = $'--username=postgres\n--host=::1\n--port=5432\n--dbname=postgres\n--no-password\n--tuples-only\n--no-align\n--quiet\n--command=SELECT 1' ]
    [[ $output != *s3cret* ]]
    [[ $output == *"--no-password"* ]]
}

@test "verify_argv: a role, a host, a positive port and a database are needed" {
    run ! pgsql_verify_argv "" ::1 5432 postgres
    run ! pgsql_verify_argv "a b" ::1 5432 postgres
    run ! pgsql_verify_argv postgres "" 5432 postgres
    run ! pgsql_verify_argv postgres ::1 "" postgres
    run ! pgsql_verify_argv postgres ::1 0 postgres
    run ! pgsql_verify_argv postgres ::1 54o2 postgres
    run ! pgsql_verify_argv postgres ::1 5432 ""
}

@test "probe_verdict: the answer the query asks for, whitespace aside" {
    pgsql_probe_verdict 1
    pgsql_probe_verdict $'\n 1 \n'
    run ! pgsql_probe_verdict 0
    run ! pgsql_probe_verdict ""
    run ! pgsql_probe_verdict
    run ! pgsql_probe_verdict "psql: error: connection to server failed"
}

@test "wait_ready: returns as soon as the command succeeds" {
    PGSQL_SLEEP=:
    attempts=0
    probe() { attempts=$((attempts + 1)); [ "$attempts" -ge 3 ]; }
    pgsql_wait_ready probe 10
    [ "$attempts" -eq 3 ]
}

@test "wait_ready: gives up after the last try" {
    PGSQL_SLEEP=:
    never() { return 1; }
    run ! pgsql_wait_ready never 4
}

@test "masked: a length, never the password" {
    [ "$(pgsql_masked s3cret)" = "(6 characters)" ]
    [ "$(pgsql_masked "")" = "(none)" ]
    [ "$(pgsql_masked)" = "(none)" ]
    [[ "$(pgsql_masked s3cret)" != *s3cret* ]]
}

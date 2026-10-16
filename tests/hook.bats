#!/usr/bin/env bats
# The first boot hook firstboot.d/36pgsqlverify (decision 0004): every path
# it takes runs for real against scratch directories, and every command
# that would touch the system (systemctl, pg_isready, psql) is a PATH stub
# that records its arguments. Nothing here needs root, a database or a
# network.
#
# What these tests are about is the half of the password defect that is
# this layer's: common's 35pgsqlpass already reads DB_PASS and sets the
# role, and nothing said whether the database would accept it. keel diff
# never compares secrets, on either side, so on an appliance whose whole
# purpose is the database a password that did not arrive would have been
# silent.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/36pgsqlverify"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin" "$scratch/inithooks/bin"
    # the library is the real file, not a copy: kcov measures the one the
    # layer ships, and a copy per test would be measured as its own
    # uncovered file
    ln -s "$(cd "$ROOT/overlay/usr/lib/inithooks/lib" && pwd)" "$scratch/inithooks/lib"

    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"
    export PGSQL_SLEEP=:

    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$scratch/inithooks
DEF

    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    stub pg_isready 'echo "pg_isready $*" >> "$CALLS"'
    # the client the hook proves the password with: it answers the probe
    # only for the password the description declared, the way a server does
    stub psql 'echo "psql $* PGPASSWORD=$PGPASSWORD" >> "$CALLS"
if [ "$PGPASSWORD" = "s3cret-from-the-description" ]; then echo 1; else
echo "psql: error: connection failed: password authentication failed" >&2; exit 2; fi'
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

DECLARED_PASS=s3cret-from-the-description

# write_conf [EXTRA_LINE...]: the conf a declared description renders to
write_conf() {
    printf 'export DB_PASS=%s\n' "$DECLARED_PASS" > "$INITHOOKS_CONF"
    printf '%s\n' "$@" >> "$INITHOOKS_CONF"
}

@test "the declared password is proved against the database" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- "psql --username=postgres --host=::1 --port=5432 --dbname=postgres" "$CALLS"
    grep -q -- "PGPASSWORD=$DECLARED_PASS" "$CALLS"
    [[ "$output" == *"set from DB_PASS (${#DECLARED_PASS} characters)"* ]]
    [[ "$output" == *"verified on [::1]:5432"* ]]
    [[ "$output" != *"$DECLARED_PASS"* ]]
}

@test "a password the database refuses fails the hook" {
    write_conf
    DECLARED_PASS=not-the-one-the-server-has
    write_conf
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot authenticate on [::1]:5432 with the declared password"* ]]
}

@test "a server that answers something else fails the hook" {
    write_conf
    stub psql 'echo "surprise"'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"answered 'surprise', not '1'"* ]]
}

@test "nothing declared: the hook names the field, and never prompts" {
    printf 'export HOSTNAME=db\n' > "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS in $INITHOOKS_CONF"* ]]
    [[ "$output" == *"declare secrets.db_password in the instance description"* ]]
    [ ! -f "$CALLS" ]
}

@test "no conf at all is the same failure" {
    rm -f "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS"* ]]
}

@test "PGSQL_PASS in the conf is not a password: it is a build time variable" {
    printf 'export PGSQL_PASS=from-the-build\n' > "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS"* ]]
    [ ! -f "$CALLS" ] || ! grep -q "from-the-build" "$CALLS"
}

@test "APP_DB_USER names the role the password belongs to" {
    write_conf "export APP_DB_USER=lappuser"
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- "psql --username=lappuser" "$CALLS"
}

@test "a role name this layer will not verify fails before anything runs" {
    write_conf "export APP_DB_USER='rm -rf /'"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a role name this layer will verify"* ]]
    [ ! -f "$CALLS" ]
}

@test "the cluster is started and waited for on the address it checks" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CALLS")" = "systemctl start postgresql.service" ]
    [ "$(sed -n 2p "$CALLS")" = "pg_isready --quiet --host=::1 --port=5432" ]
}

@test "a cluster that never answers fails before the client runs" {
    write_conf
    stub pg_isready 'exit 1'
    export PGSQL_WAIT_TRIES=2
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"postgresql did not answer on [::1]:5432 after 2 tries"* ]]
    ! grep -q psql "$CALLS"
}

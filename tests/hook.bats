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
    mkdir -p "$scratch/bin" "$scratch/inithooks/bin" "$scratch/inithooks/lib"
    # the library is the real file, not a copy: kcov measures the one the
    # layer ships, and a copy per test would be measured as its own
    # uncovered file
    ln -s "$(cd "$ROOT/overlay/usr/lib/inithooks/lib" && pwd)/postgresql.sh" \
        "$scratch/inithooks/lib/postgresql.sh"
    # lib/console.sh is inithooks' (35pgsqlpass of common sources it too).
    # This stand-in has its two functions: INITHOOKS_UNATTENDED says
    # whether anybody can answer the console, and a deferred question is
    # one line in the log and in the record of keel-init.
    cat > "$scratch/inithooks/lib/console.sh" <<'CON'
console_unattended() { [[ "${INITHOOKS_UNATTENDED:-no}" != "no" ]]; }
console_deferred() { echo "INFO: [$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2" >&2; echo "$1" >> "$DEFERRED"; }
CON

    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"
    export DEFERRED="$scratch/deferred"
    export PGSQL_SLEEP=:
    # a console with an operator at it, unless a test says otherwise
    export INITHOOKS_UNATTENDED=no

    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$scratch/inithooks
DEF

    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    stub pg_isready 'echo "pg_isready $*" >> "$CALLS"'
    # the catalogue, read as postgres by peer: ROLPASSWORD is what
    # pg_authid holds for the role (t: a password, f: none)
    export ROLPASSWORD=t
    stub runuser 'echo "runuser $* $(cat)" >> "$CALLS"; echo "$ROLPASSWORD"'
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

@test "nothing declared on a headless first boot: the question is left to keel-init, and nothing fails" {
    # an LXC: tty1 is a terminal nobody is attached to, and 35pgsqlpass
    # asked nothing (BR1 and BR2, 2026-11-06: "fatal [36pgsqlverify]: no
    # DB_PASS" in the inithooks log of every fresh container)
    printf 'export HOSTNAME=db\n' > "$INITHOOKS_CONF"
    export INITHOOKS_UNATTENDED="the console has no size, nobody is attached to it"
    run "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[36pgsqlverify] not asked, nobody can answer"* ]]
    [[ "$output" == *"keel-init asks it"* ]]
    [[ "$output" != *fatal* ]]
    [ "$(cat "$DEFERRED")" = 36pgsqlverify ]
    [ ! -f "$CALLS" ]
}

@test "nothing declared at a console (keel-init): the password set on the screen is in the catalogue" {
    # under keel-init the inithooks conf is empty: 35pgsqlpass asked the
    # password on the console and set it, and DB_PASS is nowhere
    : > "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"PostgreSQL role 'postgres' has a password, set on the console (35pgsqlpass)"* ]]
    [[ "$output" != *fatal* ]]
    [ "$(head -1 "$CALLS")" = "systemctl start postgresql.service" ]
    grep -q -- "runuser -u postgres -- psql .*--set=role=postgres" "$CALLS"
    grep -q "rolpassword IS NOT NULL FROM pg_authid WHERE rolname = :'role'" "$CALLS"
    run ! grep -q "PGPASSWORD" "$CALLS"
    [ ! -f "$DEFERRED" ]
}

@test "nothing declared at a console, and the role still has no password: the hook fails and names the field" {
    rm -f "$INITHOOKS_CONF"
    export ROLPASSWORD=f
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"fatal [36pgsqlverify]: no DB_PASS in $INITHOOKS_CONF, and the 'postgres' role has no password"* ]]
    [[ "$output" == *"declare secrets.db_password in the instance description, or run keel-init"* ]]
}

@test "nothing declared at a console, and a cluster that never answers: the hook fails" {
    : > "$INITHOOKS_CONF"
    stub pg_isready 'exit 1'
    export PGSQL_WAIT_TRIES=2
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"postgresql did not answer on [::1]:5432 after 2 tries"* ]]
    run ! grep -q runuser "$CALLS"
}

@test "nothing declared at a console, and the catalogue cannot be read: the hook fails" {
    : > "$INITHOOKS_CONF"
    stub runuser 'echo "psql: error: connection to server failed" >&2; exit 2'
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"the 'postgres' role has no password"* ]]
}

@test "PGSQL_PASS in the conf is not a password: it is a build time variable" {
    printf 'export PGSQL_PASS=from-the-build\n' > "$INITHOOKS_CONF"
    export ROLPASSWORD=f
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS"* ]]
    run ! grep -q "from-the-build" "$CALLS"
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

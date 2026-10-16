#!/bin/bash
# Logic behind firstboot.d/36pgsqlverify (decision 0004: logic apart from
# effect). Meant to be sourced. Every function reads its inputs from its
# arguments, prints its result on stdout and returns non-zero instead of
# exiting, so the hook decides what is fatal and a test can exercise every
# branch without a database, a network or root.

# The role common's conf/pgsql and firstboot.d/35pgsqlpass configure.
PGSQL_ROLE="${PGSQL_ROLE:-postgres}"
# Where the verification connects. IPv6 first; the cluster listens on the
# loopback of both families and nowhere else.
PGSQL_VERIFY_HOST="${PGSQL_VERIFY_HOST:-::1}"
PGSQL_PORT="${PGSQL_PORT:-5432}"
PGSQL_DATABASE="${PGSQL_DATABASE:-postgres}"
PGSQL_SERVICE="${PGSQL_SERVICE:-postgresql}"
PGSQL_WAIT_TRIES="${PGSQL_WAIT_TRIES:-30}"
PGSQL_PROBE_QUERY="${PGSQL_PROBE_QUERY:-SELECT 1}"
PGSQL_PROBE_ANSWER="${PGSQL_PROBE_ANSWER:-1}"
# What a role name may be here. PostgreSQL allows far more, but a name
# that needs quoting is a name this layer will not verify.
PGSQL_ROLE_RE='^[A-Za-z_][A-Za-z0-9_-]*$'

# pgsql_first_value VALUE...: the first argument that is set and is not the
# inithooks placeholder DEFAULT; fails when there is none.
pgsql_first_value() {
    local value
    for value in "$@"; do
        if [[ -n "$value" && "${value^^}" != "DEFAULT" ]]; then
            echo "$value"
            return 0
        fi
    done
    return 1
}

# pgsql_role [APP_DB_USER]: the role the declared password belongs to.
# app.options.db_user of the instance description renders to APP_DB_USER,
# so an appliance above this layer can name its own role.
pgsql_role() {
    local name
    name=$(pgsql_first_value "${1-}" "$PGSQL_ROLE")
    pgsql_is_role_name "$name" || return 1
    echo "$name"
}

# pgsql_is_role_name NAME: true for a name this layer will verify
pgsql_is_role_name() {
    [[ -n "${1-}" ]] && [[ $1 =~ $PGSQL_ROLE_RE ]]
}

# pgsql_missing_values PASS: the names of the values the description did
# not carry. Empty output is the headless case the boot test proves.
pgsql_missing_values() {
    [[ -n "${1-}" ]] || echo DB_PASS
    return 0
}

# pgsql_verify_argv ROLE HOST PORT DATABASE: the psql call that proves the
# password, one argument per line. The password is not among them: it goes
# to psql through PGPASSWORD, so it never appears in the process list.
pgsql_verify_argv() {
    local role=$1 host=$2 port=$3 database=$4
    pgsql_is_role_name "$role" || return 1
    [[ -n "$host" ]] || return 1
    [[ $port =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -n "$database" ]] || return 1
    printf '%s\n' "--username=$role" "--host=$host" "--port=$port" \
        "--dbname=$database" --no-password --tuples-only --no-align \
        --quiet "--command=$PGSQL_PROBE_QUERY"
}

# pgsql_probe_verdict OUTPUT: what psql printed. The whole point of this
# layer is that a declared password reaches the database, so the answer is
# the verdict.
pgsql_probe_verdict() {
    local answer
    answer=$(printf '%s' "${1-}" | tr -d '[:space:]')
    [[ $answer == "$PGSQL_PROBE_ANSWER" ]]
}

# pgsql_wait_ready COMMAND TRIES: run COMMAND until it succeeds, once a
# second, up to TRIES times. COMMAND is given so a test can pass its own.
pgsql_wait_ready() {
    local command=$1 tries=$2 attempt=1
    while [ "$attempt" -le "$tries" ]; do
        if $command >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        ${PGSQL_SLEEP:-sleep} 1
    done
    return 1
}

# pgsql_masked PASS: what the log may show of a password
pgsql_masked() {
    if [[ -z "${1-}" ]]; then
        echo "(none)"
    else
        echo "(${#1} characters)"
    fi
}

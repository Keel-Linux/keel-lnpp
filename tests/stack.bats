#!/usr/bin/env bats
# The stack on a machine (decision 0059): PostgreSQL, the first boot hook
# of the check page, gunicorn started by its systemd socket, and Nginx
# with a stand-in of keel-web's default site that includes
# /etc/nginx/keel-default.d/ as keel-web 0.3.0 does. It runs as root on a
# disposable trixie machine booted with systemd, with nginx, postgresql,
# gunicorn and python3-psycopg installed, only where
# KEEL_LNPP_STACK_TEST=1. setup_file installs the files of the overlay.
# With KEEL_SRC naming a checkout of keel, keel validates the manifest and
# the two example specs against a tree of the chain's manifests.
#
# What this does not prove is the image: the boot test of the published
# layer and the evidence of the real platform do (tests/README.md).

bats_require_minimum_version 1.5.0

setup_file() {
    if [ "${KEEL_LNPP_STACK_TEST:-}" != 1 ]; then
        skip "this suite installs units and writes to PostgreSQL: set KEEL_LNPP_STACK_TEST=1 on a disposable machine"
    fi
    if [ "$(id -u)" -ne 0 ] || [ ! -d /run/systemd/system ]; then
        echo "refusing to run: needs root and systemd running" >&2
        return 1
    fi
    local repo overlay
    repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    overlay="$repo/overlay"
    install -D -m 0644 "$overlay/usr/lib/systemd/system/keel-lnpp-check.socket" \
        /usr/lib/systemd/system/keel-lnpp-check.socket
    install -D -m 0644 "$overlay/usr/lib/systemd/system/keel-lnpp-check.service" \
        /usr/lib/systemd/system/keel-lnpp-check.service
    install -D -m 0644 "$overlay/usr/share/keel-lnpp/app/keel_check.py" \
        /usr/share/keel-lnpp/app/keel_check.py
    install -D -m 0644 "$overlay/etc/nginx/keel-default.d/50-keel-lnpp.conf" \
        /etc/nginx/keel-default.d/50-keel-lnpp.conf
    install -D -m 0644 "$overlay/usr/lib/inithooks/lib/postgresql.sh" \
        /usr/lib/inithooks/lib/postgresql.sh
    install -D -m 0755 "$overlay/usr/lib/inithooks/firstboot.d/40lnpp-check" \
        /usr/lib/inithooks/firstboot.d/40lnpp-check
    printf 'INITHOOKS_PATH=/usr/lib/inithooks\n' > /etc/default/inithooks
    # what conf.d/main does for the page
    getent passwd keel-check >/dev/null || adduser --system --group --no-create-home \
        --home /nonexistent --shell /usr/sbin/nologin keel-check
    # the stand-in of keel-web's default site: its include line, nothing else
    rm -f /etc/nginx/sites-enabled/default
    cat > /etc/nginx/sites-enabled/stand-in <<'SITE'
server {
	listen [::]:80 default_server;
	listen 80 default_server;
	server_name _;
	include /etc/nginx/keel-default.d/*.conf;
	location / {
		return 404;
	}
}
SITE
    systemctl daemon-reload
    systemctl stop keel-lnpp-check.service keel-lnpp-check.socket 2>/dev/null || true
    systemctl enable --now keel-lnpp-check.socket
    nginx -t
    systemctl reload-or-restart nginx.service
}

page() {
    curl -s "http://[::1]$1"
}

code() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

@test "the socket listens and gunicorn is not started yet" {
    systemctl is-active keel-lnpp-check.socket
    [ -S /run/keel-lnpp/check.sock ]
    [ "$(stat -c %U:%G:%a /run/keel-lnpp/check.sock)" = www-data:www-data:660 ]
    run systemctl is-active keel-lnpp-check.service
    [ "$output" = inactive ]
}

@test "the first boot hook makes the database of the page, and a second run changes nothing" {
    run /usr/lib/inithooks/firstboot.d/40lnpp-check
    [ "$status" -eq 0 ]
    [[ "$output" == *"the check page reads keel_check as keel-check"* ]]
    run /usr/lib/inithooks/firstboot.d/40lnpp-check
    [ "$status" -eq 0 ]
    run runuser -u postgres -- psql -tAq -d keel_check -c "SELECT count(*) FROM boot"
    [ "$output" = 1 ]
}

@test "the role of the page has no password and cannot write" {
    run runuser -u postgres -- psql -tAq -d postgres \
        -c "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'keel-check'"
    [ "$output" = t ]
    run runuser -u keel-check -- psql -tAq -d keel_check -c "INSERT INTO boot (host) VALUES ('x')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]
    run runuser -u keel-check -- psql -tAq -d keel_check -c "CREATE TABLE t (a int)"
    [ "$status" -ne 0 ]
}

@test "the page shows Python, PostgreSQL, a writable server and the row of this host" {
    run page /keel-check/
    [[ "$output" == *"Keel LNPP: the stack works"* ]]
    [[ "$output" == *"<td>Python 3.13"* ]]
    [[ "$output" == *"<td>PostgreSQL 17"* ]]
    [[ "$output" == *"<td>writable"* ]]
    [[ "$output" == *"<td>$(hostname)</td><td>"* ]]
    [[ "$output" == *"<td>keel-check</td>"* ]]
}

@test "the socket started gunicorn, as keel-check, with no TCP port" {
    systemctl is-active keel-lnpp-check.service
    [ "$(systemctl show -p User --value keel-lnpp-check.service)" = keel-check ]
    pid="$(systemctl show -p MainPID --value keel-lnpp-check.service)"
    [ "$(ps -o user= -p "$pid")" = keel-check ]
    [[ "$(ps -o args= -p "$pid")" == *gunicorn* ]]
    run bash -c "ss -Hltnp | grep -c gunicorn"
    [ "$output" = 0 ]
}

@test "/keel-check redirects to /keel-check/" {
    [ "$(code "http://[::1]/keel-check")" = 301 ]
}

@test "only GET and HEAD reach the page" {
    [ "$(code -X POST "http://[::1]/keel-check/")" = 403 ]
    [ "$(code -I "http://[::1]/keel-check/")" = 200 ]
}

@test "a database that does not answer is a 503, and the page comes back with it" {
    # the cluster's own unit: the umbrella postgresql.service can be
    # active while the cluster is down, and the other way round
    cluster="$(systemctl list-units --plain --no-legend 'postgresql@*.service' | awk '{print $1; exit}')"
    [ -n "$cluster" ]
    systemctl stop "$cluster"
    run pg_isready -q
    [ "$status" -ne 0 ]
    run code "http://[::1]/keel-check/"
    echo "code with the cluster stopped: $output"
    [ "$output" = 503 ]
    systemctl start "$cluster"
    for _ in $(seq 30); do
        pg_isready -q && break
        sleep 1
    done
    [ "$(code "http://[::1]/keel-check/")" = 200 ]
}

# keel's schema check of the manifest and the specs, against a tree of the
# chain's manifests: core.yaml and web.yaml, the eight overlays, and the
# files they name, made empty and owned by root, as keel requires
manifest_tree() {
    local tree=$1
    mkdir -p "$tree/usr/share/keel/appliances" "$tree/usr/share/keel/overlays"
    cp "$KEEL_MANIFESTS"/core.yaml "$KEEL_MANIFESTS"/web.yaml "$tree/usr/share/keel/appliances/"
    cp "$KEEL_MANIFESTS"/overlays/*.yaml "$tree/usr/share/keel/overlays/"
    cp "$BATS_TEST_DIRNAME/../overlay/usr/share/keel/appliances/lnpp.yaml" \
        "$tree/usr/share/keel/appliances/"
    python3 - "$tree" <<'PY'
import glob, os, sys, yaml
root = sys.argv[1]
for f in glob.glob(root + "/usr/share/keel/*/*.yaml"):
    m = yaml.safe_load(open(f))
    paths = []
    for p in m.get("processes") or []:
        unit = p["unit"]
        if "@" in unit:
            pre, _, rest = unit.partition("@")
            unit = pre + "@." + rest.rpartition(".")[2]
        paths.append("/usr/lib/systemd/system/" + unit)
    hooks = m.get("hooks") or {}
    paths += hooks.get("first_boot") or []
    state = hooks.get("state")
    if state:
        paths.append(state["path"] if isinstance(state, dict) else state)
    for p in paths:
        q = root + p
        os.makedirs(os.path.dirname(q), exist_ok=True)
        if not os.path.exists(q):
            with open(q, "w") as out:
                out.write("#!/bin/sh\n")
            os.chmod(q, 0o755)
PY
}

@test "keel validates the lnpp manifest and resolves its chain" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC names no keel checkout"
    tree="$BATS_TEST_TMPDIR/tree"
    manifest_tree "$tree"
    run env PYTHONPATH="$KEEL_SRC" python3 -m keel manifest validate --root "$tree" lnpp
    echo "$output"
    [ "$status" -eq 0 ]
    run env PYTHONPATH="$KEEL_SRC" python3 -m keel manifest show lnpp --resolved --root "$tree"
    [ "$status" -eq 0 ]
    [[ "$output" == *postgresql* ]]
    [[ "$output" == *nginx* ]]
}

@test "keel validates the standalone and the pair example specs" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC names no keel checkout"
    tree="$BATS_TEST_TMPDIR/tree2"
    manifest_tree "$tree"
    for spec in instance.example.yaml instance.pair.example.yaml; do
        run env PYTHONPATH="$KEEL_SRC" python3 -m keel spec validate \
            --spec "$BATS_TEST_DIRNAME/../keel/$spec" --no-secret-files --root "$tree"
        echo "$output"
        [ "$status" -eq 0 ]
    done
}

#!/usr/bin/env bats
# The files of the stack that the overlay ships (decision 0059): the
# appliance manifest, the units of the check page and its Nginx route.
# keel's own schema check of the manifest runs as root in the stack job
# (tests/stack.bats); these checks keep the files from drifting, with no
# dependency beyond grep.

bats_require_minimum_version 1.5.0

OVERLAY=overlay
MANIFEST=$OVERLAY/usr/share/keel/appliances/lnpp.yaml
SOCKET=$OVERLAY/usr/lib/systemd/system/keel-lnpp-check.socket
SERVICE=$OVERLAY/usr/lib/systemd/system/keel-lnpp-check.service
ROUTE=$OVERLAY/etc/nginx/keel-default.d/50-keel-lnpp.conf

@test "manifest: lnpp, version 1, an appliance on web" {
    grep -qx "manifest_version: 1" "$MANIFEST"
    grep -qx "kind: appliance" "$MANIFEST"
    grep -qx "name: lnpp" "$MANIFEST"
    grep -qx "base: web" "$MANIFEST"
}

@test "manifest: PostgreSQL on 5432, a mesh port, with its pgsql check" {
    grep -q "unit: postgresql.service" "$MANIFEST"
    grep -q "listen: \[{port: 5432, protocol: tcp, expose: mesh}\]" "$MANIFEST"
    grep -q "protocol: pgsql" "$MANIFEST"
}

@test "manifest: the check page is a process with no TCP port" {
    grep -q "unit: keel-lnpp-check.service" "$MANIFEST"
    run grep -cE "^[^#]*port: " "$MANIFEST"
    [ "$output" = 2 ]
}

@test "manifest: the shared database secret" {
    grep -q "name: db_password" "$MANIFEST"
    grep -q "shared: true" "$MANIFEST"
}

@test "manifest: no overlay of its own, so the chain is Core's and Web's" {
    run ! grep -q "^overlays:" "$MANIFEST"
}

@test "manifest: no tabs, no CRLF" {
    run ! grep -q $'[\t\r]' "$MANIFEST"
}

@test "the image ships no other appliance manifest, so lnpp is the one on top" {
    run ls "$OVERLAY/usr/share/keel/appliances"
    [ "$output" = lnpp.yaml ]
}

@test "socket: a unix socket for www-data, no TCP port" {
    grep -qx "ListenStream=/run/keel-lnpp/check.sock" "$SOCKET"
    grep -qx "SocketUser=www-data" "$SOCKET"
    grep -qx "SocketMode=0660" "$SOCKET"
    grep -qx "WantedBy=sockets.target" "$SOCKET"
}

@test "service: gunicorn from Debian as keel-check, given the socket by systemd" {
    grep -qx "Type=notify" "$SERVICE"
    grep -qx "User=keel-check" "$SERVICE"
    grep -qx "Requires=keel-lnpp-check.socket" "$SERVICE"
    grep -q "^ExecStart=/usr/bin/gunicorn .*--chdir /usr/share/keel-lnpp/app .*keel_check:application$" "$SERVICE"
    run ! grep -q -- "--bind" "$SERVICE"
}

@test "service: no write access, unix sockets only, no privileges" {
    grep -qx "ProtectSystem=strict" "$SERVICE"
    grep -qx "ProtectHome=yes" "$SERVICE"
    grep -qx "PrivateTmp=yes" "$SERVICE"
    grep -qx "NoNewPrivileges=yes" "$SERVICE"
    grep -qx "RestrictAddressFamilies=AF_UNIX" "$SERVICE"
    grep -qx "CapabilityBoundingSet=" "$SERVICE"
    run ! grep -q "^ReadWritePaths=" "$SERVICE"
}

@test "route: /keel-check/ goes to the socket the socket unit holds" {
    socket_path="$(sed -n 's/^ListenStream=//p' "$SOCKET")"
    grep -q "proxy_pass http://unix:$socket_path;" "$ROUTE"
    grep -q "location ^~ /keel-check/ {" "$ROUTE"
    grep -q "return 301 /keel-check/;" "$ROUTE"
}

@test "route: only GET and HEAD reach the page" {
    grep -q "limit_except GET {" "$ROUTE"
}

@test "the usage screen lists the site and the check page over HTTPS" {
    grep -qE '^Web: +https://\[\$ipaddr6\]$' "$OVERLAY/etc/confconsole/services.txt"
    grep -qE '^Check: +https://\[\$ipaddr6\]/keel-check/$' "$OVERLAY/etc/confconsole/services.txt"
    run ! grep -q "12320" "$OVERLAY/etc/confconsole/services.txt"
}

@test "the check application has no password and no secret" {
    run ! grep -rniE "password=|passwd|secret" "$OVERLAY/usr/share/keel-lnpp"
}

# keel_as_root ARGS...: keel from KEEL_SRC as root: keel refuses a hook
# file that root does not own, and the scratch root is the test's own, so a
# test that is not root runs it in a user namespace where it is root
keel_as_root() {
    local wrap=()
    [ "$(id -u)" = 0 ] || wrap=(unshare -r)
    "${wrap[@]}" env PYTHONPATH="$KEEL_SRC" python3 -m keel "$@"
}

@test "manifest: keel resolves it along web and core (KEEL_SRC and KEEL_MANIFEST_SOURCES)" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run tests/lib/manifest-root.sh "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    run keel_as_root manifest validate --root "$BATS_TEST_TMPDIR/root" lnpp
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "manifest: the example specs hold against it, with no warning" {
    # keel 0.23.83 takes a spec that names no appliance with no check of
    # the manifests, and the example then named an option no manifest
    # declares: keel-postgresql's example, the same text, was refused by a
    # first boot that named the appliance (BR1 and BR2, 2026-11-06)
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run tests/lib/manifest-root.sh "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    for spec in keel/instance.example.yaml keel/instance.pair.example.yaml; do
        run keel_as_root spec validate --spec "$spec" --no-secret-files --root "$BATS_TEST_TMPDIR/root"
        echo "$spec: $output"
        [ "$status" -eq 0 ]
        [[ "$output" != *Warning* ]]
    done
}

@test "manifest: every example names the lnpp appliance, its mode and the nine overlays of Core and Web" {
    for spec in keel/instance.example.yaml keel/instance.pair.example.yaml; do
        python3 - "$spec" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["appliance"]["name"] == "lnpp", "appliance.name"
assert d["installation"]["mode"] in ("simple", "cloud_simple"), "installation.mode"
assert sorted(d["overlays"]) == ["anubis", "coraza", "crowdsec", "etcd", "installer", "nginx", "syncthing", "vip", "wireguard"], d["overlays"]
assert "options" not in (d.get("app") or {}), "app.options: the manifest declares none"
assert d["secrets"]["db_password"], "secrets.db_password"
PY
    done
}

@test "manifest: the commissioning contract's instance is the example's shape" {
    python3 - keel/instance.example.yaml tests/commission.yaml <<'PY'
import sys, yaml
example = yaml.safe_load(open(sys.argv[1]))
instance = yaml.safe_load(open(sys.argv[2]))["instance"]
for key in ("version", "network", "tls", "appliance", "installation", "overlays", "hub", "first_login_wizard"):
    assert instance[key] == example[key], key
assert sorted(instance["secrets"]) == sorted(example["secrets"]), "secrets"
assert "instance" not in instance, "the machine keeps the name pct create gave it"
PY
}

@test "manifest: the spec of the boot test names no appliance: the host of the test validates it, and has no manifest of lnpp" {
    # the boot test refused it: "appliance.name: lnpp is not an installed
    # appliance under /usr/share/keel" (CI of this repository, 2026-11-06)
    run ! grep -qE '^(appliance|installation|overlays):' tests/instance.yaml
    run ! grep -q 'db_user' tests/instance.yaml
}

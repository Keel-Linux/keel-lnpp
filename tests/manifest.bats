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

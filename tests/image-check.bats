#!/usr/bin/env bats
# Unit tests of conf.d/zz-check, the check that fails the build of the
# lnpp layer when the image is not what decision 0059 says. It runs against
# a scratch tree named by KEEL_CONF_ROOT: a good tree first, then each
# defect alone.

bats_require_minimum_version 1.5.0

setup() {
    CHECK="$BATS_TEST_DIRNAME/../conf.d/zz-check"
    T="$BATS_TEST_TMPDIR/root"
    export KEEL_CONF_ROOT="$T"
    mkdir -p "$T/etc/systemd/system/sockets.target.wants" \
        "$T/usr/lib/systemd/system" "$T/etc/nginx/keel-default.d" \
        "$T/usr/share/keel/appliances" "$T/usr/bin" \
        "$T/usr/lib/python3/dist-packages/psycopg" "$T/usr/share/keel-lnpp/app"
    cp "$BATS_TEST_DIRNAME/../overlay/usr/lib/systemd/system/keel-lnpp-check."* \
        "$T/usr/lib/systemd/system/"
    cp "$BATS_TEST_DIRNAME/../overlay/etc/nginx/keel-default.d/50-keel-lnpp.conf" \
        "$T/etc/nginx/keel-default.d/"
    ln -s /usr/lib/systemd/system/keel-lnpp-check.socket \
        "$T/etc/systemd/system/sockets.target.wants/keel-lnpp-check.socket"
    for name in core web lnpp; do : > "$T/usr/share/keel/appliances/$name.yaml"; done
    : > "$T/usr/bin/gunicorn"
    cp "$BATS_TEST_DIRNAME/../overlay/usr/share/keel-lnpp/app/keel_check.py" "$T/usr/share/keel-lnpp/app/"
    mkdir -p "$T/usr/lib/systemd/system-preset"
    cp "$BATS_TEST_DIRNAME/../overlay/usr/lib/systemd/system-preset/20-keel-lnpp.preset" \
        "$T/usr/lib/systemd/system-preset/"
    printf 'root:x:0:0:root:/root:/bin/bash\nkeel-check:x:998:998::/nonexistent:/usr/sbin/nologin\n' > "$T/etc/passwd"
}

@test "a good tree passes" {
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Apache in the image fails the build" {
    mkdir -p "$T/usr/sbin" && : > "$T/usr/sbin/apache2"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Apache is in the image"* ]]
}

@test "an apache2 unit fails the build too" {
    : > "$T/usr/lib/systemd/system/apache2.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Apache is in the image"* ]]
}

@test "the socket not enabled fails the build" {
    rm "$T/etc/systemd/system/sockets.target.wants/keel-lnpp-check.socket"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-lnpp-check.socket is not enabled"* ]]
}

@test "the service enabled on its own fails the build: the socket starts it" {
    mkdir -p "$T/etc/systemd/system/multi-user.target.wants"
    ln -s /usr/lib/systemd/system/keel-lnpp-check.service \
        "$T/etc/systemd/system/multi-user.target.wants/keel-lnpp-check.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-lnpp-check.service is enabled"* ]]
}

@test "a route that does not reach the socket fails the build" {
    sed -i 's|unix:/run/keel-lnpp/check.sock|unix:/run/other.sock|' \
        "$T/etc/nginx/keel-default.d/50-keel-lnpp.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not proxy to /run/keel-lnpp/check.sock"* ]]
}

@test "no route fails the build" {
    rm "$T/etc/nginx/keel-default.d/50-keel-lnpp.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not proxy to /run/keel-lnpp/check.sock"* ]]
}

@test "a second top manifest fails the build: keel inspect could not name the appliance" {
    : > "$T/usr/share/keel/appliances/postgresql.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"postgresql.yaml is in the image"* ]]
}

@test "no lnpp manifest fails the build" {
    rm "$T/usr/share/keel/appliances/lnpp.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lnpp.yaml is not in the image"* ]]
}

@test "the user of the page with a shell, or missing, fails the build" {
    sed -i 's|/usr/sbin/nologin|/bin/bash|' "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-check is not a system user with no shell and no home"* ]]
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-check is not a system user"* ]]
}

@test "no gunicorn or no psycopg fails the build" {
    rm "$T/usr/bin/gunicorn"
    rmdir "$T/usr/lib/python3/dist-packages/psycopg"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/usr/bin/gunicorn is not in the image"* ]]
    [[ "$output" == *"psycopg is not in the image"* ]]
}

@test "no check application fails the build" {
    rm "$T/usr/share/keel-lnpp/app/keel_check.py"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel_check.py is not in the image"* ]]
}

@test "every problem is reported, not only the first" {
    rm "$T/usr/bin/gunicorn" "$T/usr/share/keel/appliances/lnpp.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [ "$(grep -c FATAL <<< "$output")" -eq 2 ]
}

@test "WAL archival that a first boot would enable fails the build (keel#201)" {
    rm "$T/usr/lib/systemd/system-preset/20-keel-lnpp.preset"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pg_receivewal@.service"* ]]
}

@test "WAL archival enabled in the image fails the build" {
    mkdir -p "$T/etc/systemd/system/postgresql@17-main.service.wants"
    ln -s /usr/lib/systemd/system/pg_receivewal@.service \
        "$T/etc/systemd/system/postgresql@17-main.service.wants/pg_receivewal@17-main.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pg_receivewal"* ]]
}

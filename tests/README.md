# Tests

What a test means for a layer recipe is written in `COVERAGE.md`: the
recipe builds, the result boots in an LXC container, its first boot
completes headless from an instance spec, the database accepts the
password that the spec declared, the check page answers over HTTPS, and
the machine matches the spec.

## Layout

- `boot-test.sh`, `lib/boot-test-lib.sh`, `boot-test.bats`: the boot test
  of keel-postgresql, with the host named `lnpp` and one more step: the
  check page at `https://[<address>]/keel-check/` must show Python,
  PostgreSQL, a writable server and the row of the host
  (`bt_check_page_verdict`). `test-appliance.yml` of `keel-linux/.github`
  runs it against the layers that the mirror publishes.
- `postgresql.bats`, `hook.bats`: the library and the hook
  `36pgsqlverify`, copied from keel-postgresql with the files they test.
- `check-hook.bats`: the hook `40lnpp-check`, run for real with
  `systemctl`, `pg_isready`, `runuser` and `hostname` as stubs. It checks
  the statements, that the role has no password and only reads, that each
  `CREATE` is guarded, and that a standby writes nothing.
- `image-check.bats`: `conf.d/zz-check` against a scratch tree named by
  `KEEL_CONF_ROOT`: a good tree, then each defect alone.
- `manifest.bats`: the manifest, the two units, the Nginx route and the
  usage screen, with grep.
- `apt-files.bats`, `project-packages.bats`: the project packages come
  from the Keel archive, as in keel-postgresql.
- `python/`: the check page under pytest, with a fake connection.
- `stack.bats`: the stack on a booted trixie machine, as root, only where
  `KEEL_LNPP_STACK_TEST=1`. It installs the files of the overlay, puts a
  stand-in of keel-web's default site with its include line in place, runs
  `40lnpp-check` twice, and reads the page through Nginx and the socket.
  It checks that gunicorn started from the socket as `keel-check` with no
  TCP port, that the role cannot write, the redirect, that only GET and
  HEAD reach the page, and the 503 when PostgreSQL stops. With `KEEL_SRC`
  (a keel checkout) and `KEEL_MANIFESTS` (core.yaml, web.yaml and
  `overlays/*.yaml`), keel validates the manifest and the two example
  specs. The job `stack` runs it.
- `coverage.sh`: the bats suite under kcov; it fails when a measured file
  is below `COVERAGE_THRESHOLD` (default 100).

## Run them

No root, no network:

    bats tests/
    COVERAGE_THRESHOLD=100 tests/coverage.sh
    python3 -m pytest -q tests/python

## The layer on a built image

The boot test runs against the published layer only. What a branch does
on a machine is proven on an image built from it: the core layer, the web
layer, then `bt-layer lnpp --parent web`, booted with a spec in a simple
installation. On the container:

    keel manifest validate
    keel manifest show lnpp --resolved
    systemctl is-active keel-lnpp-check.socket
    curl -sk https://[<address>]/keel-check/
    keel diff

The handbook keeps the evidence of each such run (decision 0053).

# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe).

## Measured 2026-11-06

| File | Test | Coverage | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/postgresql.sh | tests/postgresql.bats (13 tests) | 100 percent (45/45), kcov | copied from keel-postgresql with its tests |
| overlay/usr/lib/inithooks/firstboot.d/36pgsqlverify | tests/hook.bats (15 tests) | 100 percent (25/25), kcov | copied from keel-postgresql with its tests: a declared password, a headless boot that defers, a console that set it |
| keel/*.yaml, tests/instance.yaml, tests/commission.yaml | tests/manifest.bats | keel's own validator | with KEEL_SRC and KEEL_MANIFEST_SOURCES: the specs hold along web and core, with no warning |
| overlay/usr/lib/inithooks/firstboot.d/40lnpp-check | tests/check-hook.bats (7 tests) | 100 percent (15/15), kcov | the database of the check page; a standby writes nothing |
| conf.d/zz-check | tests/image-check.bats (13 tests) | 100 percent (35/35), kcov | every defect alone, and all reported |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (47 tests) | 100 percent (163/163), kcov | with the verdict of the check page |
| bin/keel-project-packages | tests/project-packages.bats (6 tests) | 100 percent (32/32), kcov | |
| overlay/usr/share/keel-lnpp/app/keel_check.py | tests/python (13 tests) | 100 percent of lines and branches, coverage.py | a fake connection; no psycopg needed |
| The stack on a machine | tests/stack.bats (10 tests) | integration | the job `stack`: PostgreSQL, gunicorn from its socket, Nginx, keel's schema check |
| conf.d/main | the build | integration only | build time script |
| tests/boot-test.sh | itself | integration only | the thin main of the boot test |

`tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow
sets to 100, the measured number. It is only ever raised (decision 0006).

    $ COVERAGE_THRESHOLD=100 tests/coverage.sh
    kcov line coverage (threshold 100 percent):
     100.00  32/32  keel-project-packages
     100.00  35/35  zz-check
     100.00  25/25  36pgsqlverify
     100.00  45/45  postgresql.sh
     100.00  15/15  40lnpp-check
     100.00  163/163  boot-test-lib.sh

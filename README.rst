Keel LNPP: nginx, PostgreSQL and Python
=======================================

The LNPP stack of Keel Linux (handbook decision 0059): Nginx, PostgreSQL 17
and Python 3 with gunicorn, a layer on the web layer::

    bt-layer lnpp --parent web

What the layers below carry
---------------------------

- Keel Core: Webmin, SSH, the WireGuard mesh, CrowdSec, the VIP overlay.
- Keel Web: Nginx, Coraza with the OWASP Core Rule Set, Anubis, and the
  default site over HTTP and HTTPS with the certificate of the machine.

What this layer adds
--------------------

- PostgreSQL 17 from Debian 13. It listens on ``::1`` and ``127.0.0.1``
  only. The ``postgres`` role has no password in the image:
  ``secrets.db_password`` of the instance spec sets it at the first boot,
  and ``firstboot.d/36pgsqlverify`` proves it.
- Python 3, ``gunicorn`` and ``python3-psycopg`` from Debian 13. Nothing
  is installed with pip.
- The check page at ``https://<address>/keel-check/``. It proves each
  layer: Nginx reached Python, and Python read from PostgreSQL. It shows
  the versions, the role of the server and the rows that the first boot
  writes. It only reads.
- The appliance manifest ``/usr/share/keel/appliances/lnpp.yaml``
  (``base: web``). A spec names ``appliance.name: lnpp``.

The check page
--------------

- ``keel-lnpp-check.socket`` holds ``/run/keel-lnpp/check.sock`` for
  ``www-data``. systemd starts ``keel-lnpp-check.service``, gunicorn, at
  the first request. No TCP port opens.
- The service runs as ``keel-check``, a system user with no shell and no
  home. It cannot write to the disk.
- PostgreSQL authenticates ``keel-check`` by peer on the local socket.
  The role has no password and has ``SELECT`` on one table only.
- ``firstboot.d/40lnpp-check`` makes the role, the database
  ``keel_check``, its table and one row for the host. A standby writes
  nothing: it gets the rows of the primary with the base backup.
- Nginx reaches the socket through
  ``/etc/nginx/keel-default.d/50-keel-lnpp.conf``, which keel-web 0.3.0
  includes in its default site and behind Anubis.

A replicated pair
-----------------

The pair of decisions 0049 and 0054 comes from the spec:
``appliance.vip`` and ``database.server`` with ``engine: postgresql``.
``keel/instance.pair.example.yaml`` is the spec of node A, and
``keel/instance.example.yaml`` is a standalone node. On a pair, the check
page of the standby shows "read-only" and the row of the primary.

Tests
-----

``tests/README.md`` lists the suites and how to run them, and
``COVERAGE.md`` the measured coverage.

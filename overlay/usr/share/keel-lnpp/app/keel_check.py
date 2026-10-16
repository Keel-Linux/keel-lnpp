"""The check page of Keel LNPP (handbook decision 0059, point 6).

A WSGI application with no framework. gunicorn serves it on the unix
socket of keel-lnpp-check.socket, and Nginx proxies /keel-check/ to it
(/etc/nginx/keel-default.d/50-keel-lnpp.conf).

It proves each layer of the stack: Nginx reached Python, and Python read
from PostgreSQL. It shows the version of Python and of the server, the
role of the server (writable, or read-only on a standby), the host name,
and the rows of the table that the first boot writes
(firstboot.d/40lnpp-check). On a pair, the row on the standby comes from
the primary, so the page also proves the replication.

The page only reads. It connects as the operating system user of the
service, keel-check, over the local socket of the server, and PostgreSQL
authenticates it by peer: no password exists for it. The role has SELECT
on the one table, and nothing else.
"""
import html
import socket
import sys

CONNINFO = "dbname=keel_check"
CONNECT_TIMEOUT = 5
SERVER_QUERY = "SELECT version(), pg_is_in_recovery(), current_user"
BOOT_QUERY = "SELECT host, written_at::text FROM boot ORDER BY written_at, host"
PATHS = ("/", "/keel-check/")
UNAVAILABLE = "The database does not answer.\n"

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Keel LNPP check</title>
<style>
body {{ font-family: sans-serif; margin: 2rem auto; max-width: 48rem; padding: 0 1rem; color: #1b2733; background: #fff; }}
h1 {{ font-size: 1.5rem; }}
table {{ border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; }}
th, td {{ text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid #d5dde5; }}
th {{ width: 12rem; }}
</style>
</head>
<body>
<h1>Keel LNPP: the stack works</h1>
<p>Nginx passed this request to Python, and Python read these values from PostgreSQL.</p>
<table>
<tr><th>Host</th><td>{host}</td></tr>
<tr><th>Python</th><td>Python {python}</td></tr>
<tr><th>PostgreSQL</th><td>{server}</td></tr>
<tr><th>Role of the server</th><td>{role}</td></tr>
<tr><th>Database user</th><td>{user}</td></tr>
</table>
<h2>Rows that a first boot wrote</h2>
{rows}
</body>
</html>
"""


def _connect():
    """psycopg on the local socket of the server, as the user of the
    service"""
    import psycopg
    return psycopg.connect(CONNINFO, connect_timeout=CONNECT_TIMEOUT)


def _read(connection):
    with connection.cursor() as cursor:
        cursor.execute(SERVER_QUERY)
        server, recovery, user = cursor.fetchone()
        cursor.execute(BOOT_QUERY)
        rows = cursor.fetchall()
    return server, recovery, user, rows


def _values(connect):
    """What the page shows, read on a connection that is always closed"""
    connection = connect()
    try:
        return _read(connection)
    finally:
        connection.close()


def _rows_html(rows):
    if not rows:
        return "<p>No row: the first boot of the primary did not write one yet.</p>"
    cells = "".join(
        f"<tr><td>{html.escape(str(host))}</td><td>{html.escape(str(at))}</td></tr>"
        for host, at in rows)
    return f"<table>\n<tr><th>Host</th><th>Written at</th></tr>\n{cells}\n</table>"


def _page(server, recovery, user, rows):
    role = ("read-only (a standby, in recovery)" if recovery
            else "writable (a primary, or a standalone server)")
    return PAGE.format(
        host=html.escape(socket.gethostname()),
        python=html.escape(sys.version.split()[0]),
        server=html.escape(str(server)),
        role=role,
        user=html.escape(str(user)),
        rows=_rows_html(rows))


def make_app(connect=None):
    """The WSGI application, with CONNECT as its connection (a test gives
    a fake one)"""
    connect = connect or _connect

    def app(environ, start_response):
        method = environ.get("REQUEST_METHOD", "GET")
        if method not in ("GET", "HEAD"):
            start_response("405 Method Not Allowed", [
                ("Content-Type", "text/plain; charset=utf-8"),
                ("Allow", "GET, HEAD")])
            return [b"Only GET and HEAD.\n"]
        if environ.get("PATH_INFO", "/") not in PATHS:
            start_response("404 Not Found", [
                ("Content-Type", "text/plain; charset=utf-8")])
            return [b"Not found.\n"]
        try:
            values = _values(connect)
        except Exception as error:  # every failure is the same answer
            environ["wsgi.errors"].write(f"keel-lnpp-check: {error}\n")
            start_response("503 Service Unavailable", [
                ("Content-Type", "text/plain; charset=utf-8")])
            return [UNAVAILABLE.encode()]
        body = _page(*values).encode()
        start_response("200 OK", [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Length", str(len(body))),
            ("Cache-Control", "no-store")])
        return [b""] if method == "HEAD" else [body]

    return app


application = make_app()

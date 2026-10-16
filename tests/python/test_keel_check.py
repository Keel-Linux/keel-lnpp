"""Unit tests of the check application of keel-lnpp (decision 0059, point 6).

Every database answer comes from a fake connection, so the tests need no
PostgreSQL and no psycopg. The default connection is tested with a fake
psycopg module in sys.modules.
"""
import io
import sys
import types

import keel_check


class FakeCursor:
    def __init__(self, answers):
        self.answers = answers
        self.queries = []
        self.result = None

    def execute(self, query):
        self.queries.append(query)
        self.result = self.answers[query]

    def fetchone(self):
        return self.result[0]

    def fetchall(self):
        return self.result

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeConnection:
    def __init__(self, answers):
        self.cursor_ = FakeCursor(answers)
        self.closed = False

    def cursor(self):
        return self.cursor_

    def close(self):
        self.closed = True


def answers(recovery=False, rows=None):
    if rows is None:
        rows = [("lnpp", "2026-10-16 07:00:00+00")]
    return {
        keel_check.SERVER_QUERY: [("PostgreSQL 17.6 (Debian 17.6-0+deb13u1)", recovery, "keel-check")],
        keel_check.BOOT_QUERY: rows,
    }


def call(app, method="GET", path="/keel-check/"):
    seen = {}

    def start_response(status, headers):
        seen["status"] = status
        seen["headers"] = dict(headers)

    environ = {"REQUEST_METHOD": method, "PATH_INFO": path,
               "wsgi.errors": io.StringIO()}
    body = b"".join(app(environ, start_response))
    return seen["status"], seen["headers"], body.decode(), environ["wsgi.errors"].getvalue()


def app_with(recovery=False, rows=None):
    connection = FakeConnection(answers(recovery, rows))
    return keel_check.make_app(lambda: connection), connection


def test_get_shows_python_postgresql_role_host_and_the_boot_row():
    app, connection = app_with()
    status, headers, body, _ = call(app)
    assert status == "200 OK"
    assert headers["Content-Type"] == "text/html; charset=utf-8"
    assert "Python " + sys.version.split()[0] in body
    assert "PostgreSQL 17.6 (Debian 17.6-0+deb13u1)" in body
    assert "writable" in body
    assert "lnpp" in body and "2026-10-16 07:00:00+00" in body
    assert connection.closed


def test_a_standby_is_shown_read_only():
    app, _ = app_with(recovery=True)
    _, _, body, _ = call(app)
    assert "read-only" in body
    assert "writable" not in body


def test_the_page_only_reads():
    app, connection = app_with()
    call(app)
    for query in connection.cursor_.queries:
        assert query.lstrip().upper().startswith("SELECT")


def test_values_are_html_escaped():
    app, _ = app_with(rows=[("<script>x</script>", "t&t")])
    _, _, body, _ = call(app)
    assert "<script>x</script>" not in body
    assert "&lt;script&gt;x&lt;/script&gt;" in body
    assert "t&amp;t" in body


def test_no_boot_row_is_said():
    app, _ = app_with(rows=[])
    _, _, body, _ = call(app)
    assert "No row" in body


def test_head_has_the_headers_and_no_body():
    app, _ = app_with()
    status, headers, body, _ = call(app, method="HEAD")
    assert status == "200 OK"
    assert headers["Content-Type"] == "text/html; charset=utf-8"
    assert body == ""


def test_other_methods_are_refused():
    app, connection = app_with()
    status, headers, _, _ = call(app, method="POST")
    assert status == "405 Method Not Allowed"
    assert headers["Allow"] == "GET, HEAD"
    assert connection.cursor_.queries == []


def test_other_paths_are_not_found():
    app, connection = app_with()
    status, _, _, _ = call(app, path="/keel-check/../etc")
    assert status == "404 Not Found"
    assert connection.cursor_.queries == []


def test_the_root_path_is_the_page_too():
    app, _ = app_with()
    status, _, _, _ = call(app, path="/")
    assert status == "200 OK"


def test_a_database_that_does_not_answer_is_503_in_one_line():
    def refuse():
        raise OSError("connection to server on socket failed: secret detail")

    status, headers, body, errors = call(keel_check.make_app(refuse))
    assert status == "503 Service Unavailable"
    assert headers["Content-Type"] == "text/plain; charset=utf-8"
    assert body == "The database does not answer.\n"
    assert "secret detail" not in body
    assert "secret detail" in errors


def test_a_query_that_fails_is_503_and_the_connection_closed():
    connection = FakeConnection({})
    status, _, body, _ = call(keel_check.make_app(lambda: connection))
    assert status == "503 Service Unavailable"
    assert body == "The database does not answer.\n"
    assert connection.closed


def test_the_default_connection_is_psycopg_on_the_local_socket(monkeypatch):
    calls = []
    fake = types.ModuleType("psycopg")

    def connect(conninfo, **options):
        calls.append((conninfo, options))
        return FakeConnection(answers())

    fake.connect = connect
    monkeypatch.setitem(sys.modules, "psycopg", fake)
    status, _, _, _ = call(keel_check.make_app())
    assert status == "200 OK"
    assert calls == [("dbname=keel_check", {"connect_timeout": 5})]


def test_the_module_has_a_wsgi_application():
    assert callable(keel_check.application)

# keel-lnpp: Nginx, PostgreSQL and Python with gunicorn, the LNPP stack of
# Keel (handbook decision 0059), built as a layer on the web layer:
#
#     bt-layer lnpp --parent web
#
# Nginx, Coraza, Anubis and the default site come from the web layer. This
# layer adds PostgreSQL 17 (standalone by default, the pair of decision
# 0054 by the spec), Python 3 with gunicorn and psycopg from Debian 13, and
# the check page at /keel-check/, which proves that Nginx reaches Python
# and Python reads from PostgreSQL. mk/turnkey/pgsql.mk brings the conf
# script and the overlay that carries bin/pgsqlconf.py and
# firstboot.d/35pgsqlpass; the rest of the database half is copied from
# keel-postgresql (decision 0059, point 3).

include $(FAB_PATH)/common/mk/turnkey/pgsql.mk

# After pgsql.mk, so a file of this overlay wins over the shared one.
COMMON_OVERLAYS += $(CURDIR)/overlay

# Webmin comes from core and answers on 12321; Nginx serves 80 and 443.
# 5432 stays shut: it listens on loopback, and on a pair on the mesh only.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12321

include $(FAB_PATH)/common/mk/turnkey.mk

# The project's own packages (inithooks, confconsole, keel) come from the
# Keel archive, archive.keellinux.org, like every other Keel package: the
# parent layer carries its source and the 990 pin (common's
# overlays/turnkey.d/keel-apt, Keel-Linux/common#30), and a build with
# KEEL_APT_TRACK=testing reads trixie-testing as well (common#32). There is
# no build time archive any more. The build host's staging distribution held
# versions far older than the archive's, and pinned at 1001 it would have
# downgraded the layer to them.
#
# conf.d/main upgrades the three and then proves, with bin/keel-project-
# packages, that each is installed at apt's candidate and that the candidate
# is the Keel archive's, in the suite of the track. The check runs inside the
# tree while its apt lists are still there, so it is copied in before the
# conf scripts run and conf.d/main removes it again.
KEEL_BUILD_TOOLS ?= /usr/local/lib/keel-build
define _keel_root.patched/pre

	install -D -m 755 $(CURDIR)/bin/keel-project-packages $O/root.patched$(KEEL_BUILD_TOOLS)/keel-project-packages;
endef
root.patched/pre += $(_keel_root.patched/pre)

#!/bin/sh
# The service user has to exist before the package manager unpacks
# /var/lib/kividb with this owner, so it is created here and not in postinstall.
set -e

if ! getent group kividb >/dev/null; then
    groupadd --system kividb
fi

if ! getent passwd kividb >/dev/null; then
    # /usr/sbin/nologin is where Debian and RHEL both keep it (RHEL's /sbin is
    # a symlink). adduser(8) is Debian-only, so this uses useradd(8).
    useradd --system --gid kividb --home-dir /var/lib/kividb \
            --no-create-home --shell /usr/sbin/nologin --comment "KiviDB" kividb
fi

exit 0

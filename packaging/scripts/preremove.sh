#!/bin/sh
# Stop the unit only when the package is going away, never on upgrade.
set -e

case "$1" in
    0|remove|purge)
        if [ -d /run/systemd/system ]; then
            systemctl stop kividb.service >/dev/null 2>&1 || true
            systemctl disable kividb.service >/dev/null 2>&1 || true
        fi
        ;;
esac

# The kividb user and /var/lib/kividb survive a removal: the data is not the
# package's to delete.
exit 0

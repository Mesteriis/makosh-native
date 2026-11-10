#!/bin/sh
set -eu
# Copy protected host input to private tmpfs, then drop root before accepting clients.
umask 077
cp /run/makosh-pgbouncer-users.txt /tmp/makosh-pgbouncer-users.txt
chown postgres:postgres /tmp/makosh-pgbouncer-users.txt
exec pgbouncer -u postgres /etc/makosh-pgbouncer.ini

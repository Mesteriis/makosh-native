# Reuse the reviewed Debian/PostgreSQL base; install the signed Debian package
# from the Debian snapshot archive at the base image's own snapshot time, so the
# build does not depend on the live archive still carrying this revision.
# The live Debian and PGDG sources are removed for the build and stay removed:
# this image never installs anything else.
FROM pgvector/pgvector:0.8.7-pg18-trixie@sha256:5895949dfcdf308eb0cd31c950c93c14895c77f33fbedfecf1fa511ab1d4bcd2
RUN set -eu; \
    rm -f /etc/apt/sources.list.d/*; \
    printf '%s\n' 'Types: deb' \
        'URIs: http://snapshot.debian.org/archive/debian/20261027T000000Z/' \
        'Suites: trixie' 'Components: main' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
        > /etc/apt/sources.list.d/makosh-snapshot.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get -o Acquire::Check-Valid-Until=false install --no-install-recommends -y pgbouncer=1.24.1-1+deb13u2; \
    rm -rf /var/lib/apt/lists/*
COPY pgbouncer.ini /etc/makosh-pgbouncer.ini
COPY entrypoint.sh /usr/local/bin/makosh-pgbouncer
ENTRYPOINT ["/bin/sh", "/usr/local/bin/makosh-pgbouncer"]

# Reuse the reviewed Debian/PostgreSQL base; install the signed Debian package.
FROM pgvector/pgvector:0.8.7-pg18-trixie@sha256:5895949dfcdf308eb0cd31c950c93c14895c77f33fbedfecf1fa511ab1d4bcd2
RUN apt-get update && apt-get install --no-install-recommends -y pgbouncer=1.24.1-1+deb13u2
COPY pgbouncer.ini /etc/makosh-pgbouncer.ini
COPY entrypoint.sh /usr/local/bin/makosh-pgbouncer
ENTRYPOINT ["/bin/sh", "/usr/local/bin/makosh-pgbouncer"]

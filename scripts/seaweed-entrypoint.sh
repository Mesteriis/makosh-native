#!/bin/sh
set -eu
# Host secrets remain 0600. Copy into tmpfs before dropping to the image's UID.
umask 077
cp /run/makosh-s3-identities.json /tmp/makosh-s3-identities.json
chown 1000:1000 /tmp/makosh-s3-identities.json /data
exec su-exec 1000:1000 weed mini -dir=/data -ip=127.0.0.1 -ip.bind=0.0.0.0 \
  -s3.config=/tmp/makosh-s3-identities.json -bucket=makosh-files \
  -s3.autoCreateBucket=false -s3.allowDeleteBucketNotEmpty=false -s3.iam.readOnly=true \
  -master.telemetry=false -webdav=false -admin.ui=false

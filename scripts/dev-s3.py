#!/usr/bin/env python3
"""Initialize and probe this project's local S3. No credential or response-body logging."""
import base64
from datetime import datetime, timezone
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("s3_config", ROOT / "scripts/configure-dev-s3.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(method, key="", query="", body=b"", admin=False, anonymous=False, invalid=False, extra=None):
    # Deliberately fixed to the owned loopback dev service; never a general URL relay.
    values = config.private_read(ROOT / ".local/s3-settings.json")
    access = values["adminAccessKey" if admin else "appAccessKey"]
    secret = values["adminSecretKey" if admin else "appSecretKey"]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    day = stamp[:8]
    path = "/makosh-files" + ("/" + key if key else "")
    digest = hashlib.sha256(body).hexdigest()
    headers = {"host": "127.0.0.1:55440", "x-amz-content-sha256": digest, "x-amz-date": stamp, **(extra or {})}
    if body:
        headers["content-md5"] = base64.b64encode(hashlib.md5(body).digest()).decode()
    names = ";".join(sorted(headers))
    canonical = "\n".join([method, path, query, "".join(k + ":" + headers[k] + "\n" for k in sorted(headers)), names, digest])
    scope = day + "/us-east-1/s3/aws4_request"
    signing = ("AWS4" + secret).encode()
    for part in (day, "us-east-1", "s3", "aws4_request"):
        signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(signing, ("AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + hashlib.sha256(canonical.encode()).hexdigest()).encode(), hashlib.sha256).hexdigest()
    if not anonymous:
        headers["Authorization"] = f"AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={names}, Signature={('0' * 64) if invalid else signature}"
    url = "http://127.0.0.1:55440" + path + ("?" + query if query else "")
    req = urllib.request.Request(url, data=body if method in ("PUT", "POST") else None, headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=15) as response:
            return response.status, response.headers, response.read(2 * 1024 * 1024)
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read(2 * 1024 * 1024)


def require(value):
    if not value:
        raise ValueError("S3 acceptance check failed")


def initialize():
    # mini opens S3 before its bucket initializer finishes. Wait for the bucket,
    # not merely a listening socket/master health, without retrying mutations.
    for attempt in range(21):
        try:
            code, _, body = request("GET", query="versioning=", admin=True)
        except urllib.error.URLError:
            code, body = 503, b""
        if code not in (404,503) or attempt == 20:
            break
        time.sleep(0.5)
    require(code == 200)
    if b">Enabled<" not in body:
        code, _, _ = request("PUT", query="versioning=", body=b'<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>', admin=True)
        require(code == 200)
    policy = {"Version": "2012-10-17", "Statement": [{"Sid": "RetainMakoshFiles", "Effect": "Deny", "Principal": "*", "Action": ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket", "s3:PutLifecycleConfiguration", "s3:PutBucketVersioning"], "Resource": ["arn:aws:s3:::makosh-files", "arn:aws:s3:::makosh-files/*"]}]}
    require(request("PUT", query="policy=", body=json.dumps(policy).encode(), admin=True)[0] == 204)
    require(request("HEAD", anonymous=True)[0] == 403)
    require(request("HEAD", invalid=True)[0] == 403)
    print("S3 bucket ready: versioning enabled, deletion/lifecycle/version suspension denied, anonymous access denied.")


def probe():
    marker = ROOT / ".local/s3-persistence-probe.json"
    payload = b"Makosh synthetic S3 persistence probe v1\n"
    digest = hashlib.sha256(payload).hexdigest()
    if marker.exists():
        key = config.private_read(marker)["key"]
        require(isinstance(key, str) and key.startswith("synthetic-probes/") and len(key) == 53)
    else:
        key = "synthetic-probes/" + str(uuid.uuid4())
        require(request("PUT", key=key, body=payload, extra={"if-none-match": "*", "x-amz-meta-sha256": digest})[0] == 200)
        config.private_write(marker, {"key": key})
    code, headers, data = request("GET", key=key)
    require(code == 200 and data == payload and headers.get("x-amz-meta-sha256") == digest)
    require(request("DELETE", key=key)[0] == 403)
    require(request("GET", key=key, anonymous=True)[0] == 403)
    require(request("PUT", query="lifecycle=", body=b"<LifecycleConfiguration/>", admin=True)[0] == 403)
    require(request("PUT", query="versioning=", body=b"<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>", admin=True)[0] == 403)
    require(request("GET", key=key)[2] == payload)
    print("S3 synthetic PUT/GET integrity and persistence probe passed; delete/anonymous/lifecycle/version suspension denied.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["init"]:
            initialize()
        elif sys.argv[1:] == ["probe"]:
            probe()
        else:
            raise ValueError("Usage")
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
        raise SystemExit("Local S3 operation failed. Configuration and response details are not logged.") from None

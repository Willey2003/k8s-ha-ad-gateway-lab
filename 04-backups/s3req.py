#!/usr/bin/env python3
"""Minimal signed S3 request (AWS SigV4, path-style), stdlib only.

  s3req.py METHOD URL [FILE]
Credentials come from ROOT_ACCESS_KEY_ID / ROOT_SECRET_ACCESS_KEY (or AWS_* equivalents).
Prints the HTTP status and body; exits non-zero on HTTP >= 300.
"""
import datetime, hashlib, hmac, os, sys, urllib.parse, urllib.request, urllib.error

def env(*names):
    for n in names:
        if os.environ.get(n):
            return os.environ[n]
    sys.exit(f"missing credentials: set {names[0]}")

method, url = sys.argv[1].upper(), sys.argv[2]
body = open(sys.argv[3], "rb").read() if len(sys.argv) > 3 else b""
access = env("ROOT_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID")
secret = env("ROOT_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY")
region, service = os.environ.get("S3_REGION", "us-east-1"), "s3"

u = urllib.parse.urlsplit(url)
now = datetime.datetime.now(datetime.timezone.utc)
amzdate, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(body).hexdigest()
headers = {"host": u.netloc, "x-amz-content-sha256": payload_hash, "x-amz-date": amzdate}

canonical_query = "&".join(sorted(
    f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(v, safe='~')}"
    for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
signed = ";".join(sorted(headers))
canonical = "\n".join([method, urllib.parse.quote(u.path or "/", safe="/~"), canonical_query,
                       "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload_hash])
scope = f"{datestamp}/{region}/{service}/aws4_request"
to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, hashlib.sha256(canonical.encode()).hexdigest()])

key = ("AWS4" + secret).encode()
for part in (datestamp, region, service, "aws4_request"):
    key = hmac.new(key, part.encode(), hashlib.sha256).digest()
signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
headers["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
                            f"SignedHeaders={signed}, Signature={signature}")

req = urllib.request.Request(url, data=body if method in ("PUT", "POST") else None,
                             method=method, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(r.status); sys.stdout.write(r.read().decode(errors="replace"))
except urllib.error.HTTPError as e:
    print(e.code); sys.stdout.write(e.read().decode(errors="replace")); sys.exit(1)

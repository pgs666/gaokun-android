#!/usr/bin/env python3
"""Upload release artifacts to a Cloudflare R2 bucket (S3 API, SigV4).

Standard library only -- no boto3, no requests, no awscli. This runs on a bare
Debian build machine as-is, which is the point: the artifacts are 2.4 GiB and
uploading them cloud-to-cloud from the build host is far faster than pulling
them down to a laptop first and pushing them back up.

Credentials come from the environment, never from arguments or a file in the
repo:

    R2_ENDPOINT             https://<account-id>.r2.cloudflarestorage.com
    R2_ACCESS_KEY_ID
    R2_SECRET_ACCESS_KEY

Only the S3 keys are needed. Do NOT put a Cloudflare account API token on a
build machine to do this -- an account token can rewrite DNS and delete
buckets, while these keys can only touch object storage.

    r2-upload.py <bucket> <local-file> <key> [content-type]
    r2-upload.py --delete <bucket> <key>

Notes
  * Signs with x-amz-content-sha256: UNSIGNED-PAYLOAD. R2 accepts that over
    HTTPS and it avoids reading a multi-GB file twice (once to hash, once to
    send).
  * Single PUT, no multipart. R2's single-object PUT limit is 5 GiB, and the
    largest thing here is ~1.3 GiB.
  * Retries on transient TLS/connection failures, which this project sees
    regularly against both Cloudflare and Azure.
"""

import datetime
import hashlib
import hmac
import os
import sys
import time
import urllib.error
import urllib.request

UNSIGNED = 'UNSIGNED-PAYLOAD'
REGION = 'auto'
SERVICE = 's3'


def _sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()


def _auth_headers(method, host, canon_uri, extra):
    ak = os.environ['R2_ACCESS_KEY_ID']
    sk = os.environ['R2_SECRET_ACCESS_KEY']

    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime('%Y%m%dT%H%M%SZ')
    datestamp = now.strftime('%Y%m%d')

    headers = {'host': host, 'x-amz-content-sha256': UNSIGNED, 'x-amz-date': amzdate}
    headers.update(extra)

    signed = ';'.join(sorted(headers))
    canon_headers = ''.join('%s:%s\n' % (k, headers[k]) for k in sorted(headers))
    canon_req = '%s\n%s\n\n%s\n%s\n%s' % (
        method, canon_uri, canon_headers, signed, UNSIGNED)

    scope = '%s/%s/%s/aws4_request' % (datestamp, REGION, SERVICE)
    to_sign = 'AWS4-HMAC-SHA256\n%s\n%s\n%s' % (
        amzdate, scope, hashlib.sha256(canon_req.encode()).hexdigest())

    k = _sign(('AWS4' + sk).encode(), datestamp)
    for part in (REGION, SERVICE, 'aws4_request'):
        k = _sign(k, part)
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()

    headers['Authorization'] = (
        'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s'
        % (ak, scope, signed, sig))
    return headers


def _send(method, canon_uri, extra, body=None, attempts=4):
    ep = os.environ['R2_ENDPOINT'].rstrip('/')
    host = ep.split('://', 1)[1]
    last = None
    for attempt in range(attempts):
        # Re-sign every attempt: SigV4 signatures expire, and a retry minutes
        # after the first try would be rejected as skewed rather than retried.
        headers = _auth_headers(method, host, canon_uri, extra)
        try:
            req = urllib.request.Request(
                ep + canon_uri, data=body() if body else None,
                headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=3600) as resp:
                return resp.status, ''
        except urllib.error.HTTPError as e:
            # A 4xx will not fix itself; fail immediately with the server's
            # explanation rather than retrying three more times.
            return e.code, e.read()[:500].decode('utf-8', 'replace')
        except Exception as e:                      # TLS EOF, reset, timeout
            last = e
            if attempt < attempts - 1:
                time.sleep(5 * (attempt + 1))
    raise last


def put(bucket, path, key, ctype):
    size = os.path.getsize(path)
    code, msg = _send(
        'PUT', '/%s/%s' % (bucket, key),
        {'content-length': str(size), 'content-type': ctype},
        body=lambda: open(path, 'rb'))
    ok = code in (200, 201)
    print('  %-56s %8.1f MiB  HTTP %s%s'
          % (key, size / 1048576.0, code, '' if ok else '  ' + msg))
    return ok


def delete(bucket, key):
    code, msg = _send('DELETE', '/%s/%s' % (bucket, key), {})
    ok = code in (200, 204)
    print('  deleted %-48s HTTP %s%s' % (key, code, '' if ok else '  ' + msg))
    return ok


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    if args[0] == '--delete':
        sys.exit(0 if delete(args[1], args[2]) else 1)
    bucket, path, key = args[0], args[1], args[2]
    ctype = args[3] if len(args) > 3 else 'application/octet-stream'
    sys.exit(0 if put(bucket, path, key, ctype) else 1)


if __name__ == '__main__':
    main()

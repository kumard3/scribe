#!/usr/bin/env python3
"""App Store Connect API call. Usage: asc.py GET /v1/builds?limit=5 [json-body]"""
import json, os, sys, time, urllib.request
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
import base64

KEY_ID = os.environ.get("ASC_KEY_ID", "2S4W5QQ4T6")
ISSUER = os.environ.get("ASC_ISSUER_ID", "fc850c72-bbab-45db-adf4-d9278ca710ee")
KEY = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")

def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=")

def token():
    key = serialization.load_pem_private_key(open(KEY, "rb").read(), password=None)
    head = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": ISSUER, "iat": int(time.time()),
                           "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"}).encode())
    msg = head + b"." + body
    r, s = decode_dss_signature(key.sign(msg, ec.ECDSA(hashes.SHA256())))
    return (msg + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()

method, path = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 else None
req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=data, method=method,
                             headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(req).read().decode() or "(empty)")
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}", e.read().decode()); sys.exit(1)

"""Point Cloudflare DNS-only A records at this network's public IPv4.

Config (env): ZONE, RECORDS (JSON list of names), TTL, TOKEN_FILE.
Idempotent: creates a missing record, updates a wrong one, else does nothing.
"""

import ipaddress
import json
import os
import sys
import urllib.parse
import urllib.request

API = os.environ.get("CF_API", "https://api.cloudflare.com/client/v4")
TRACE = os.environ.get("TRACE_URL", "https://cloudflare.com/cdn-cgi/trace")


def http(method, url, token=None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()


def cf(method, path, token, body=None):
    res = json.loads(http(method, API + path, token, body))
    if not res.get("success"):
        raise RuntimeError(f"{method} {path}: {res.get('errors')}")
    return res


def public_ip():
    for line in http("GET", TRACE).splitlines():
        if line.startswith("ip="):
            return str(ipaddress.IPv4Address(line[3:].strip()))
    raise RuntimeError("no ip= in trace")


def a_records(zone_id, token):
    out, page = [], 1
    while True:
        q = urllib.parse.urlencode({"type": "A", "per_page": 100, "page": page})
        res = cf("GET", f"/zones/{zone_id}/dns_records?{q}", token)
        out += res["result"]
        if page >= res["result_info"]["total_pages"]:
            return out
        page += 1


def plan(existing, names, ip, ttl):
    """[(method, record id or None, body)] that make each name one A record at ip, DNS-only."""
    ops = []
    for name in names:
        want = {"type": "A", "name": name, "content": ip, "ttl": ttl, "proxied": False}
        have = [r for r in existing if r["name"] == name]
        if len(have) > 1:
            raise RuntimeError(f"{name}: {len(have)} A records, expected at most 1")
        if not have:
            ops.append(("POST", None, want))
        elif any(have[0].get(k) != want[k] for k in ("content", "ttl", "proxied")):
            ops.append(("PATCH", have[0]["id"], want))
    return ops


def main():
    zone = os.environ["ZONE"]
    names = json.loads(os.environ["RECORDS"])
    ttl = int(os.environ.get("TTL", "300"))
    with open(os.environ["TOKEN_FILE"]) as f:
        token = f.read().strip()
    ip = public_ip()
    zones = cf("GET", "/zones?" + urllib.parse.urlencode({"name": zone}), token)["result"]
    if len(zones) != 1:
        raise RuntimeError(f"zone {zone}: {len(zones)} matches")
    zid = zones[0]["id"]
    ops = plan(a_records(zid, token), names, ip, ttl)
    for method, rid, body in ops:
        path = f"/zones/{zid}/dns_records" + (f"/{rid}" if rid else "")
        cf(method, path, token, body)
        print(f"{method} {body['name']} -> {ip}")
    if not ops:
        print(f"unchanged: {', '.join(names)} -> {ip}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # one line in the Job's log, non-zero exit
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

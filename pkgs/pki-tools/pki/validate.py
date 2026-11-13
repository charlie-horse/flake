import os
import re
from datetime import timedelta

from . import certs, kube, sopsfile

CAS = ("k8s", "etcd", "front-proxy")
EXPIRY = timedelta(days=14)


def load_cas(tree: str) -> dict:
    out = {}
    for name in (*CAS, "root", "workload"):
        p = os.path.join(tree, "cluster", "pki", f"{name}-ca.pem")
        if os.path.exists(p):
            out[name] = certs.load_chain(open(p, "rb").read())[0]
    missing = [c for c in CAS if c not in out]
    if missing:
        raise SystemExit(f"pki-export: error: no cluster/pki/{missing[0]}-ca.pem on main")
    return out


def leaf_errors(l: kube.Leaf, exp: dict, cas: dict, nodes: list[str], now) -> list[str]:
    if not re.fullmatch(rf"[a-z0-9-]+-{l.node}", l.name):
        return [f"name must be <component>-{l.node}"]
    if l.name not in exp:
        return ["not an expected leaf"]
    if l.type != "kubernetes.io/tls":
        return [f"type {l.type!r}, want kubernetes.io/tls"]
    if not l.crt or not l.key:
        return ["tls.crt or tls.key is empty"]
    try:
        chain = certs.load_chain(l.crt)
        if not certs.key_matches(chain[0], l.key):
            return ["tls.key does not match tls.crt"]
    except ValueError as e:
        return [f"unreadable tls.crt/tls.key: {e}"]
    s = certs.summarize(chain[0])
    ca = exp[l.name]["ca"]
    errs = [] if s.not_after > now else ["certificate has expired"]
    errs += ["the leaf is a CA"] if s.is_ca else []
    errs += [f"label {kube.CA_LABEL}={l.ca_label}, want {ca}"] if l.ca_label and l.ca_label != ca else []
    others = {f"cluster/pki/{n}-ca.pem": c for n, c in cas.items() if n != ca}
    errs += certs.chain_errors(chain, cas[ca], others)
    want = certs.summarize(cas[ca]).sha256
    errs += [f"chain cert {i} is not cluster/pki/{ca}-ca.pem"
             for i, c in enumerate(chain[1:], 1) if certs.summarize(c).sha256 != want]
    return errs + certs.ownership_errors(l.name, l.node, s, nodes)


def expiring_on_main(tree: str, now) -> list[str]:
    out, d = [], os.path.join(tree, "secrets", "pki")
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        for k, pem in sopsfile.certs(os.path.join(d, f)).items():
            for c in certs.load_chain(pem):
                s = certs.summarize(c)
                if certs.expiring(s, now, EXPIRY):
                    out.append(f"secrets/pki/{f} {k}: {c.subject.rfc4514_string()}, not after {s.not_after}")
    return out


def fingerprints(files: dict[str, bytes]) -> dict[str, str]:
    return {k: certs.summarize(certs.load_chain(v)[0]).sha256 for k, v in files.items() if not sopsfile.is_key(k)}

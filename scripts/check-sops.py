"""Pre-commit check: sops files are fully encrypted, to their .sops.yaml recipients.

Reads the staged (index) version of every file under secrets/ and k8s/secrets/
and of .sops.yaml. Run by the devenv git hook `sops-files`; by hand:
`python3 scripts/check-sops.py` (needs PyYAML).
"""

import re
import subprocess
import sys

import yaml

ENC = re.compile(r"^ENC\[[A-Z0-9_]+,data:.*\]$", re.S)
CERT = re.compile(
    r"-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+?-----END CERTIFICATE-----"
)
OTHER_KEYS = ("pgp", "kms", "gcp_kms", "azure_kv", "hc_vault")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def staged(path):
    return git("show", f":{path}").decode()


def mode_of(f):
    if re.fullmatch(r"secrets/pki/[^/]+\.yaml", f):
        return "pki"
    if re.fullmatch(r"secrets/[^/]+\.yaml", f):
        return "strict"
    if f.startswith("secrets/"):
        return "bad"
    if re.fullmatch(r"k8s/secrets/[^/]+/[^/]+\.sops\.yaml", f):
        return "k8s"
    if f.startswith("k8s/secrets/"):
        return "badk8s"
    return None


def certs_only(v):
    return isinstance(v, str) and CERT.search(v) and CERT.sub("", v).strip() == ""


def encryption_errors(mode, raw):
    bad = []
    for i, line in enumerate(raw.splitlines(), 1):
        t = line.strip()
        if t.startswith("#") and not t.startswith("#ENC["):
            bad.append(f"line {i}: plaintext comment")
    try:
        docs = list(yaml.safe_load_all(raw))
    except yaml.YAMLError:
        docs = None
    if not docs or len(docs) != 1 or not isinstance(docs[0], dict):
        return ["not a single YAML mapping (sops-encrypted?)"]
    doc = docs[0]
    meta = doc.get("sops")
    if not isinstance(meta, dict) or not ENC.match(str(meta.get("mac", ""))):
        bad.append("no sops block with mac: ENC[...]")
    elif not any(meta.get(k) for k in ("age",) + OTHER_KEYS):
        bad.append("sops block has no recipients")
    clear = ("apiVersion", "kind", "metadata", "type") if mode == "k8s" else ()
    allowed = clear + ("data", "stringData", "sops")  # = checkSecret in k8s/render.nix
    if mode == "k8s":
        bad += [f"top-level key {k} not allowed" for k in doc if k not in allowed]

    def walk(v, path):
        if isinstance(v, dict):
            for k, x in v.items():
                walk(x, path + [str(k)])
        elif isinstance(v, list):
            for j, x in enumerate(v):
                walk(x, path + [str(j)])
        elif v is not None and not (isinstance(v, str) and ENC.match(v)):
            bad.append("unencrypted value at " + ".".join(path))

    for k, v in doc.items():
        if k == "sops" or k in clear or (mode == "k8s" and k not in allowed):
            continue
        if mode == "pki" and str(k).endswith(".pem") and not str(k).endswith("-key.pem") and certs_only(v):
            continue
        walk(v, [str(k)])
    return bad


def ages(v):
    if not v:
        return set()
    if isinstance(v, str):
        v = v.split(",")
    return {a.strip() for a in v if a.strip()}


def recipient_errors(f, raw, cfg, names):
    rule = next(
        (r for r in cfg.get("creation_rules") or [] if re.search(r.get("path_regex", ""), f)),
        None,
    )
    if rule is None:
        return ["no creation rule in .sops.yaml matches it"]
    meta = (yaml.safe_load(raw) or {}).get("sops") or {}
    want = ages(rule.get("age"))
    for g in rule.get("key_groups") or []:
        want |= ages(g.get("age"))
    entries = list(meta.get("age") or [])
    for g in meta.get("key_groups") or []:
        entries += g.get("age") or []
    have = {e["recipient"].strip() for e in entries}
    if rule.get("encrypted_regex") != meta.get("encrypted_regex"):
        return ["encrypted_regex differs from its .sops.yaml rule; re-create it with sops"]
    label = lambda r: f"{names[r]} ({r})" if r in names else r  # noqa: E731
    bad = [f"missing recipient {label(r)}" for r in sorted(want - have)]
    bad += [f"extra recipient {label(r)}" for r in sorted(have - want)]
    bad += [f"unexpected {k} keys" for k in OTHER_KEYS if meta.get(k)]
    if bad:
        bad.append(f"run `sops updatekeys {f}`")
    return bad


def main():
    files = [
        f
        for f in git("ls-files", "-z", "--cached", "--", "secrets", "k8s/secrets").decode().split("\0")
        if f
    ]
    raw_cfg = staged(".sops.yaml")
    cfg = yaml.safe_load(raw_cfg)
    names = {k: n for n, k in re.findall(r"&(\S+)\s+(age1[0-9a-z]+)", raw_cfg)}
    status = 0
    for f in sorted(files):
        mode = mode_of(f)
        if mode is None:
            continue
        if mode in ("bad", "badk8s"):
            errs = ["only sops-encrypted secrets/<name>.yaml, secrets/pki/<node>.yaml and"
                    " k8s/secrets/<namespace>/<name>.sops.yaml files belong here"]
        else:
            raw = staged(f)
            errs = encryption_errors(mode, raw) or recipient_errors(f, raw, cfg, names)
        for e in errs:
            print(f"{f}: {e}", file=sys.stderr)
            status = 1
    sys.exit(status)


if __name__ == "__main__":
    main()

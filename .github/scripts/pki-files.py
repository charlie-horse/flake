#!/usr/bin/env python3
"""Check the exported host PKI files secrets/pki/<node>.yaml (checks.yml,
job pki-files; docs/ci.md, "pki-files"; docs/pki-migration-plan.md, P4).

Each file is a flat sops map written by the cert-manager export job:
`<stem>.pem` is a plaintext cert (leaf + its intermediate), `<stem>-key.pem`
its sops-encrypted key (encrypted_regex -key\\.pem$). For every file:

  - the node (file name) is a node of cluster/definition.nix;
  - every key is `<stem>.pem` or `<stem>-key.pem`, and both exist per stem;
  - every `-key.pem` value is sops-encrypted (ENC[...]), every `.pem` value
    holds only CERTIFICATE blocks;
  - the leaf (first cert) is issued by its component's intermediate
    (cluster/pki/{k8s,etcd,front-proxy}-ca.pem), verifies against ONLY that
    intermediate with `openssl verify -partial_chain`, is not a CA, is not
    the root, and does not verify against the root or the workload CA; any
    further cert in the value is exactly that intermediate;
  - the cert belongs to the node: the stem ends in -<node>, kubelet certs
    have CN system:node:<node>, etcd peer/server certs CN <node>, DNS SANs
    (if any) name the node, and no CN or SAN names or addresses another
    node;
  - no cert in the value expires within 14 days.

Needs python3 with PyYAML and openssl. Never decrypts anything. Exits 0
with a message when there are no files yet. Only file, key and reasons are
printed, never a key value.

usage: pki-files.py [--pki-dir DIR] [--definition FILE] [FILE ...]
       (default files: secrets/pki/*.yaml)
"""

import argparse
import glob
import ipaddress
import os
import re
import subprocess
import sys
import tempfile

import yaml

MIN_VALID_SECONDS = 14 * 24 * 3600

# Leaf component -> intermediate (pkgs/cluster-pki/cluster-pki.sh, SPECS).
COMPONENT_CA = {
    "etcd-peer": "etcd",
    "etcd-server": "etcd",
    "etcd-client-apiserver": "etcd",
    "apiserver": "k8s",
    "apiserver-kubelet-client": "k8s",
    "front-proxy-client": "front-proxy",
    "controller-manager": "k8s",
    "scheduler": "k8s",
    "admin": "k8s",
    "addon-manager": "k8s",
    "kubelet": "k8s",
    "kube-proxy": "k8s",
    "flannel": "k8s",
}
CA_FILES = {
    "k8s": "k8s-ca.pem",
    "etcd": "etcd-ca.pem",
    "front-proxy": "front-proxy-ca.pem",
}
ENC = re.compile(r"^ENC\[[A-Z0-9_]+,data:.*\]$", re.S)
PEM_CERT = re.compile(
    r"-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+?-----END CERTIFICATE-----"
)


def openssl(args, data=None):
    p = subprocess.run(
        ["openssl"] + args,
        input=data,
        capture_output=True,
        text=True,
    )
    return p.returncode, p.stdout, p.stderr


def parse_definition(path):
    """Node names, IPs and domain from cluster/definition.nix (pure data,
    nixfmt-formatted, so a line parser is enough). Fails loudly."""
    domain, nodes, cur, in_nodes = None, {}, None, False
    for line in open(path):
        m = re.match(r'^  domain = "([^"]+)";', line)
        if m:
            domain = m.group(1)
        if re.match(r"^  nodes = \{", line):
            in_nodes = True
            continue
        if in_nodes:
            if re.match(r"^  \};", line):
                break
            m = re.match(r"^    ([A-Za-z0-9_-]+) = \{", line)
            if m:
                cur = m.group(1)
                nodes[cur] = set()
                continue
            m = re.match(r'^      (lanIP|tailnetIP) = "([^"]+)";', line)
            if m and cur:
                nodes[cur].add(m.group(2))
    if not domain or not nodes or not all(nodes.values()):
        sys.exit(f"{path}: could not parse domain/nodes/IPs (format changed?)")
    return domain, nodes


def cert_info(pem):
    """Subject CN, issuer DN, subject DN, DNS and IP SANs, isCA."""
    rc, out, err = openssl(
        [
            "x509",
            "-noout",
            "-nameopt",
            "RFC2253",
            "-subject",
            "-issuer",
            "-ext",
            "subjectAltName,basicConstraints",
        ],
        pem,
    )
    if rc != 0:
        return None
    info = {"subject": "", "issuer": "", "dns": [], "ip": [], "ca": False}
    for line in out.splitlines():
        if line.startswith("subject="):
            info["subject"] = line[len("subject=") :].strip()
        elif line.startswith("issuer="):
            info["issuer"] = line[len("issuer=") :].strip()
        elif "DNS:" in line or "IP Address:" in line:
            for part in line.split(","):
                part = part.strip()
                if part.startswith("DNS:"):
                    info["dns"].append(part[4:])
                elif part.startswith("IP Address:"):
                    info["ip"].append(part[len("IP Address:") :])
        elif "CA:TRUE" in line:
            info["ca"] = True
    m = re.search(r"(?:^|,)CN=((?:[^,\\]|\\.)*)", info["subject"])
    info["cn"] = m.group(1).replace("\\", "") if m else ""
    return info


def der(pem):
    p = subprocess.run(
        ["openssl", "x509", "-outform", "DER"],
        input=pem.encode(),
        capture_output=True,
    )
    return p.stdout if p.returncode == 0 else None


def check_file(path, pki_dir, domain, nodes, tmp):
    errs = []
    node = os.path.basename(path)[: -len(".yaml")]
    if node not in nodes:
        return [f"{node} is not a node of the cluster definition"]
    others = {n: ips for n, ips in nodes.items() if n != node}
    other_names = set(others) | {f"{n}.{domain}" for n in others}
    other_ips = {ipaddress.ip_address(ip) for ips in others.values() for ip in ips}

    try:
        doc = yaml.safe_load(open(path))
    except yaml.YAMLError as e:
        return [f"not valid YAML: {e.__class__.__name__}"]
    if not isinstance(doc, dict):
        return ["not a YAML mapping"]
    meta = doc.get("sops")
    if not isinstance(meta, dict):
        errs.append("no sops metadata")
    elif meta.get("encrypted_regex") != r"-key\.pem$":
        errs.append(
            "sops encrypted_regex is not -key\\.pem$ (use the .sops.yaml rule)"
        )

    stems_cert, stems_key = set(), set()
    for k, v in doc.items():
        if k == "sops":
            continue
        k = str(k)
        if k.endswith("-key.pem"):
            stems_key.add(k[: -len("-key.pem")])
            if not (isinstance(v, str) and ENC.match(v)):
                errs.append(f"{k}: private key is not sops-encrypted (ENC[...])")
        elif k.endswith(".pem"):
            stems_cert.add(k[: -len(".pem")])
        else:
            errs.append(f"{k}: unexpected key (only <stem>.pem, <stem>-key.pem)")
    for s in sorted(stems_cert - stems_key):
        errs.append(f"{s}.pem: no {s}-key.pem")
    for s in sorted(stems_key - stems_cert):
        errs.append(f"{s}-key.pem: no {s}.pem")

    cas = {}
    for name, f in CA_FILES.items():
        p = os.path.join(pki_dir, f)
        pem = open(p).read()
        cas[name] = {"path": p, "info": cert_info(pem), "der": der(pem)}
    root = os.path.join(pki_dir, "root-ca.pem")
    root_info = cert_info(open(root).read())
    root_der = der(open(root).read())
    forbidden = [root, os.path.join(pki_dir, "workload-ca.pem")]

    for stem in sorted(stems_cert):
        k = f"{stem}.pem"
        v = doc[k]
        if not isinstance(v, str) or ENC.match(v):
            errs.append(f"{k}: certificate must be plaintext PEM")
            continue
        blocks = PEM_CERT.findall(v)
        rest = PEM_CERT.sub("", v).strip()
        if not blocks or rest:
            errs.append(f"{k}: must hold only CERTIFICATE PEM blocks")
            continue
        if not stem.endswith(f"-{node}"):
            errs.append(f"{k}: stem does not end in -{node}")
            continue
        comp = stem[: -len(node) - 1]
        ca = COMPONENT_CA.get(comp)
        if ca is None:
            errs.append(f"{k}: unknown component {comp}")
            continue
        leaf = blocks[0]
        info = cert_info(leaf)
        if info is None:
            errs.append(f"{k}: leaf does not parse")
            continue
        leaf_path = os.path.join(tmp, f"{node}-{stem}.pem")
        with open(leaf_path, "w") as fh:
            fh.write(leaf + "\n")

        # Issuer and chain.
        if der(leaf) == root_der or info["subject"] == root_info["subject"]:
            errs.append(f"{k}: is the root CA")
            continue
        if info["ca"]:
            errs.append(f"{k}: leaf has CA:TRUE")
        issuer_ca = next(
            (n for n, c in cas.items() if c["info"]["subject"] == info["issuer"]),
            None,
        )
        if issuer_ca is None:
            errs.append(f"{k}: issuer {info['issuer']} is none of the intermediates")
        elif issuer_ca != ca:
            errs.append(f"{k}: issued by the {issuer_ca} CA, expected the {ca} CA")
        want = cas[issuer_ca or ca]
        rc, _, err = openssl(
            [
                "verify",
                "-partial_chain",
                "-x509_strict",
                "-CAfile",
                want["path"],
                leaf_path,
            ]
        )
        if rc != 0:
            errs.append(
                f"{k}: does not verify against {os.path.basename(want['path'])}"
            )
        for bad in forbidden:
            rc, _, _ = openssl(
                ["verify", "-partial_chain", "-CAfile", bad, leaf_path]
            )
            if rc == 0:
                errs.append(f"{k}: verifies against {os.path.basename(bad)}")
        for i, extra in enumerate(blocks[1:], 1):
            d = der(extra)
            if d == root_der:
                errs.append(f"{k}: chain cert {i} is the root CA")
            elif d != cas[ca]["der"]:
                errs.append(f"{k}: chain cert {i} is not {CA_FILES[ca]}")

        # Ownership.
        cn = info["cn"]
        if comp == "kubelet" and cn != f"system:node:{node}":
            errs.append(f"{k}: CN {cn!r}, expected 'system:node:{node}'")
        if comp in ("etcd-peer", "etcd-server") and cn != node:
            errs.append(f"{k}: CN {cn!r}, expected {node!r}")
        cn_node = cn[len("system:node:") :] if cn.startswith("system:node:") else cn
        if cn_node in others:
            errs.append(f"{k}: CN {cn!r} names node {cn_node}")
        for d in info["dns"]:
            if d in other_names:
                errs.append(f"{k}: SAN DNS:{d} belongs to another node")
        if info["dns"] and node not in info["dns"]:
            errs.append(f"{k}: SANs do not include {node}")
        for ip in info["ip"]:
            try:
                if ipaddress.ip_address(ip) in other_ips:
                    errs.append(f"{k}: SAN IP:{ip} belongs to another node")
            except ValueError:
                errs.append(f"{k}: unparsable SAN IP {ip!r}")

        # Expiry (leaf and chain).
        for i, b in enumerate(blocks):
            rc, _, _ = openssl(
                ["x509", "-noout", "-checkend", str(MIN_VALID_SECONDS)], b
            )
            if rc != 0:
                what = "leaf" if i == 0 else f"chain cert {i}"
                errs.append(f"{k}: {what} expires within 14 days")
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pki-dir", default="cluster/pki")
    ap.add_argument("--definition", default="cluster/definition.nix")
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()
    files = a.files or sorted(glob.glob("secrets/pki/*.yaml"))
    if not files:
        print("no secrets/pki/*.yaml files yet; nothing to check")
        return 0
    domain, nodes = parse_definition(a.definition)
    status = 0
    with tempfile.TemporaryDirectory() as tmp:
        for f in files:
            errs = check_file(f, a.pki_dir, domain, nodes, tmp)
            if errs:
                status = 1
                for e in errs:
                    print(f"::error file={f}::{e}")
            else:
                print(f"ok  {f}")
    return status


if __name__ == "__main__":
    sys.exit(main())

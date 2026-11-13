import base64
import glob
import json
import os
import subprocess
from dataclasses import dataclass

import yaml

NODE_LABEL = "pki.neurosis/node"
CA_LABEL = "pki.neurosis/ca"


@dataclass
class Leaf:
    name: str
    node: str
    ca_label: str
    type: str
    crt: bytes
    key: bytes


def _flatten(objs):
    for o in objs:
        if not o:
            continue
        if o.get("kind") == "List":
            yield from o.get("items", [])
        else:
            yield o


def from_dir(path: str) -> list[dict]:
    files = sorted(glob.glob(os.path.join(path, "*.yaml")) + glob.glob(os.path.join(path, "*.yml")))
    if not files:
        raise SystemExit(f"pki-export: error: no *.yaml files in {path}")
    objs = []
    for f in files:
        with open(f) as fh:
            objs += list(yaml.safe_load_all(fh))
    return list(_flatten(objs))


def from_cluster(namespace: str, names: list[str]) -> list[dict]:
    out = subprocess.run(
        ["kubectl", "get", "secrets", "-n", namespace, "--ignore-not-found", "-o", "json", *names],
        check=True,
        capture_output=True,
    ).stdout
    dec = json.JSONDecoder()
    text, objs, i = out.decode(), [], 0
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        obj, i = dec.raw_decode(text, i)
        objs.append(obj)
    return list(_flatten(objs))


def _b64(s: str | None) -> bytes:
    try:
        return base64.b64decode(s or "", validate=True)
    except ValueError:
        return b""


def leaves(objs: list[dict], namespace: str) -> list[Leaf]:
    out = []
    for o in objs:
        meta = o.get("metadata", {})
        labels = meta.get("labels") or {}
        if o.get("kind") != "Secret" or meta.get("namespace", namespace) != namespace:
            continue
        if not labels.get(NODE_LABEL):
            continue
        data = o.get("data") or {}
        out.append(
            Leaf(
                name=meta["name"],
                node=labels[NODE_LABEL],
                ca_label=labels.get(CA_LABEL, ""),
                type=o.get("type", ""),
                crt=_b64(data.get("tls.crt")),
                key=_b64(data.get("tls.key")),
            )
        )
    return sorted(out, key=lambda l: l.name)

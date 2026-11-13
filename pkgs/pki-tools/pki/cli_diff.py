"""Compare one node's cluster-pki leaves (A) with its cert-manager set (B)."""

import argparse
import sys
from pathlib import Path

import yaml
from cryptography import x509

from .certs import load_chain, summarize

USAGE = """\
usage: pki-diff [--node NODE] A B
  A  cluster-pki leaves: a directory of <stem>.pem (r440's PKI dir, or
     /var/lib/kubernetes/secrets on a node)
  B  cert-manager set: secrets/pki/<node>.yaml (plaintext certs; nothing is
     decrypted) or a directory like A
  --node  only stems ending in -NODE (default for a B file: its basename)
Prints OK / DIFF <field> / MISSING-IN-A / MISSING-IN-B per stem, INFO for a
chain difference, and a summary. Exit 1 on any DIFF or MISSING."""
SET_FIELDS = ("subject", "san", "ku", "eku")
DAY = 86400


class InputError(Exception):
    pass


def _leaf(name: str, pem: bytes, node: str | None) -> tuple[str, list[x509.Certificate]] | None:
    if not name.endswith(".pem") or name.endswith("-key.pem"):
        return None
    stem = name.removesuffix(".pem")
    if node and not stem.endswith(f"-{node}"):
        return None
    try:
        chain = load_chain(pem)
    except ValueError:
        return None
    return None if summarize(chain[0]).is_ca else (stem, chain)


def load_set(src: Path, node: str | None) -> dict[str, list[x509.Certificate]]:
    if src.is_dir():
        items = ((p.name, p.read_bytes()) for p in sorted(src.glob("*.pem")) if p.is_file())
    elif src.is_file():
        data = yaml.safe_load(src.read_text())
        if not isinstance(data, dict):
            raise InputError(f"{src}: not a YAML map (export file expected)")
        items = []
        for k, v in data.items():
            if isinstance(k, str) and k.endswith(".pem") and not k.endswith("-key.pem"):
                if str(v).startswith("ENC["):
                    raise InputError(f"{src}: '{k}' is encrypted; certs must be plaintext")
                items.append((k, str(v).encode()))
    else:
        raise InputError(f"not a directory or file: '{src}'")
    return dict(leaf for name, pem in items if (leaf := _leaf(name, pem, node)))


def fields(cert: x509.Certificate) -> dict[str, frozenset[str] | str]:
    s = summarize(cert)
    try:
        bc = cert.extensions.get_extension_for_class(x509.BasicConstraints).value
        basic = "CA:TRUE" if bc.ca else "CA:FALSE"
    except x509.ExtensionNotFound:
        basic = "absent"
    return {
        "subject": frozenset(f"{k}={v}" for k, v in s.subject),
        "san": frozenset({f"DNS:{d}" for d in s.dns} | {f"IP:{i}" for i in s.ips}),
        "ku": s.key_usage,
        "eku": s.ext_key_usage,
        "bc": basic,
        "key": s.key,
        "issuer": f"{s.issuer} keyid={s.aki or 'none'}",
    }


def chain_kind(chain: list[x509.Certificate]) -> str:
    return {1: "leaf", 2: "leaf+intermediate"}.get(len(chain), f"leaf+{len(chain) - 1}-certs")


def lifetime(cert: x509.Certificate) -> float:
    return (cert.not_valid_after_utc - cert.not_valid_before_utc).total_seconds()


def compare(stem: str, a: list[x509.Certificate], b: list[x509.Certificate]) -> list[str]:
    fa, fb = fields(a[0]), fields(b[0])
    lines = []
    for f in fa:
        va, vb = fa[f], fb[f]
        if va == vb:
            continue
        if f in SET_FIELDS:
            va, vb = ",".join(sorted(va - vb)) or "-", ",".join(sorted(vb - va)) or "-"
        lines.append(f"DIFF {stem} {f}: A={va} B={vb}")
    la, lb = lifetime(a[0]), lifetime(b[0])
    if abs(la - lb) > DAY:
        lines.append(f"DIFF {stem} lifetime: A={la / DAY:.2f}d B={lb / DAY:.2f}d")
    return lines


def run(a_src: Path, b_src: Path, node: str | None) -> tuple[list[str], int]:
    if not node and b_src.is_file():
        node = b_src.name.removesuffix(".yaml").removesuffix(".yml")
    a, b = load_set(a_src, node), load_set(b_src, node)
    stems = sorted(a.keys() | b.keys())
    if not stems:
        raise InputError(f"no leaves found in either set{f' for node {node}' if node else ''}")
    out, n = [], dict.fromkeys(("ok", "diff", "miss_a", "miss_b", "info"), 0)
    for s in stems:
        if s not in a:
            out.append(f"MISSING-IN-A {s}")
            n["miss_a"] += 1
            continue
        if s not in b:
            out.append(f"MISSING-IN-B {s}")
            n["miss_b"] += 1
            continue
        lines = compare(s, a[s], b[s])
        out += lines or [f"OK {s}"]
        n["diff" if lines else "ok"] += 1
        if (ca := chain_kind(a[s])) != (cb := chain_kind(b[s])):
            out.append(f"INFO {s} chain: A={ca} B={cb}")
            n["info"] += 1
    out.append(
        f"summary{f' ({node})' if node else ''}: {len(stems)} stems, {n['ok']} OK, {n['diff']} DIFF, "
        f"{n['miss_a']} MISSING-IN-A, {n['miss_b']} MISSING-IN-B, {n['info']} chain INFO"
    )
    return out, int(n["diff"] + n["miss_a"] + n["miss_b"] > 0)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="pki-diff", usage=USAGE, add_help=False)
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("--node")
    p.add_argument("paths", nargs="*", type=Path)
    args = p.parse_args(argv)
    if args.help:
        print(USAGE)
        return 0
    if len(args.paths) != 2:
        print("usage: pki-diff [--node NODE] A B", file=sys.stderr)
        return 2
    try:
        lines, status = run(*args.paths, args.node)
    except InputError as e:
        print(f"pki-diff: {e}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    return status


if __name__ == "__main__":
    sys.exit(main())

import os
import re
import subprocess
import tempfile

import yaml

KEY_SUFFIX = "-key.pem"
AGE_ENV = ("SOPS_AGE_KEY", "SOPS_AGE_KEY_FILE", "SOPS_AGE_KEY_CMD", "SOPS_AGE_SSH_PRIVATE_KEY_FILE")


class _Literal(str):
    pass


yaml.SafeDumper.add_representer(
    _Literal, lambda d, s: d.represent_scalar("tag:yaml.org,2002:str", s, style="|")
)


def is_key(name: str) -> bool:
    return name.endswith(KEY_SUFFIX)


def plain_yaml(files: dict[str, bytes]) -> str:
    data = {k: _Literal(v.decode().rstrip("\n")) for k, v in sorted(files.items())}
    return yaml.safe_dump(data, sort_keys=True, width=1 << 16)


def public_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in AGE_ENV}
    env["SOPS_AGE_KEY_FILE"] = os.devnull
    return env


def encrypt(tree: str, node: str, files: dict[str, bytes]) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        plain = os.path.join(tmp, "plain.yaml")
        fd = os.open(plain, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(plain_yaml(files))
        res = subprocess.run(
            ["sops", "--encrypt", "--config", ".sops.yaml",
             "--filename-override", f"secrets/pki/{node}.yaml",
             "--input-type", "yaml", "--output-type", "yaml", plain],
            cwd=tree, env=public_env(), capture_output=True, text=True,
        )
    if res.returncode != 0:
        raise RuntimeError(
            f"sops --encrypt for {node} failed (is there a .sops.yaml rule for secrets/pki/{node}.yaml?): "
            + res.stderr.strip()
        )
    errs = encryption_errors(res.stdout)
    if errs:
        raise RuntimeError(f"{node}: " + "; ".join(errs))
    return res.stdout


def encryption_errors(text: str) -> list[str]:
    errs = []
    for k, v in yaml.safe_load(text).items():
        if k == "sops":
            continue
        enc = isinstance(v, str) and v.startswith("ENC[")
        if is_key(k) and not enc:
            errs.append(f"{k} is not encrypted")
        if not is_key(k) and enc:
            errs.append(f"{k} is encrypted, certs must be plaintext")
    return errs


def certs(path: str) -> dict[str, bytes]:
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    return {
        k: str(v).encode()
        for k, v in data.items()
        if k != "sops" and re.search(r"\.pem$", k) and not is_key(k)
    }


def recipients(text: str) -> list[str]:
    return [a["recipient"] for a in (yaml.safe_load(text).get("sops", {}).get("age") or [])]

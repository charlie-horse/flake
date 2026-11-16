import base64

import yaml
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from pki import sopsfile
from pki.ceremony import CeremonyError

PUK_PATH = "secrets/admin.yaml"


def pem(cert: x509.Certificate) -> bytes:
    return cert.public_bytes(serialization.Encoding.PEM)


def key_pem(key) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def tls_secret(name: str, ns: str, ca_pem: bytes, tls_pem: bytes, key_pem: bytes) -> str:
    b64 = {k: base64.b64encode(v).decode() for k, v in {"ca.crt": ca_pem, "tls.crt": tls_pem, "tls.key": key_pem}.items()}
    doc = {"apiVersion": "v1", "data": b64, "kind": "Secret", "metadata": {"name": name, "namespace": ns}, "type": "kubernetes.io/tls"}
    return yaml.safe_dump(doc, sort_keys=True, width=1 << 20)


def ca_secret(ca: str, cert: x509.Certificate, root: x509.Certificate, key) -> tuple[str, str, str]:
    """(repo path, output file name, plaintext) for intermediate `ca`."""
    if ca == "workload":
        text = tls_secret("cluster-ca", "cert-manager", pem(root), pem(cert) + pem(root), key_pem(key))
        return "k8s/secrets/cert-manager/cluster-ca.sops.yaml", "cluster-ca.sops.yaml", text
    text = tls_secret(f"{ca}-ca", "cluster-pki", pem(root), pem(cert), key_pem(key))
    return f"k8s/secrets/cluster-pki/{ca}-ca.sops.yaml", f"{ca}-ca.sops.yaml", text


def puk_doc(serial: int, puk: str) -> str:
    return yaml.safe_dump({f"yubikey-{serial}-piv-puk": puk}, sort_keys=True)


def encryption_errors(repo: str, path: str, out: str, keys: list[str]) -> list[str]:
    doc = yaml.safe_load(out)
    values = doc.get("data", {}) if "data" in doc else {k: v for k, v in doc.items() if k != "sops"}
    errs = []
    if sorted(values) != sorted(keys):
        errs.append(f"data keys {sorted(values)}, expected {sorted(keys)}")
    errs += [f"{k} is not encrypted" for k, v in values.items() if not str(v).startswith("ENC[")]
    want = sopsfile.rule_recipients(repo, path)
    if sorted(sopsfile.recipients(out)) != sorted(want):
        errs.append(f"recipients {sopsfile.recipients(out)}, expected the .sops.yaml rule's {want}")
    return errs


def encrypt(repo: str, path: str, text: str, encrypt_stdin=sopsfile.encrypt_stdin) -> str:
    doc = yaml.safe_load(text)
    keys = list(doc.get("data", doc))
    try:
        out = encrypt_stdin(repo, path, text)
    except RuntimeError as e:
        raise CeremonyError(str(e)) from None
    errs = encryption_errors(repo, path, out, keys)
    if errs:
        raise CeremonyError(f"{path}: " + "; ".join(errs))
    return out

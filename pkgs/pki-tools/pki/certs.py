"""Stand-in for Frances's certs.py (same interface); hers replaces it on merge."""

from dataclasses import dataclass
from datetime import datetime, timedelta

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import ExtensionOID, NameOID


@dataclass(frozen=True)
class Summary:
    subject: frozenset
    cn: str | None
    dns: frozenset
    ips: frozenset
    key_usage: frozenset
    ext_key_usage: frozenset
    is_ca: bool
    key: str
    issuer: str
    aki: str | None
    not_before: datetime
    not_after: datetime
    sha256: str


def load_chain(pem: bytes) -> list[x509.Certificate]:
    return x509.load_pem_x509_certificates(pem)


def _ext(cert, oid):
    try:
        return cert.extensions.get_extension_for_oid(oid).value
    except x509.ExtensionNotFound:
        return None


def summarize(cert: x509.Certificate) -> Summary:
    san = _ext(cert, ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
    bc = _ext(cert, ExtensionOID.BASIC_CONSTRAINTS)
    aki = _ext(cert, ExtensionOID.AUTHORITY_KEY_IDENTIFIER)
    cns = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    return Summary(
        subject=frozenset((a.rfc4514_attribute_name, str(a.value)) for a in cert.subject),
        cn=str(cns[0].value) if cns else None,
        dns=frozenset(san.get_values_for_type(x509.DNSName)) if san else frozenset(),
        ips=frozenset(str(i) for i in san.get_values_for_type(x509.IPAddress)) if san else frozenset(),
        key_usage=frozenset(),
        ext_key_usage=frozenset(),
        is_ca=bool(bc and bc.ca),
        key=f"RSA-{cert.public_key().key_size}",
        issuer=cert.issuer.rfc4514_string(),
        aki=aki.key_identifier.hex() if aki and aki.key_identifier else None,
        not_before=cert.not_valid_before_utc,
        not_after=cert.not_valid_after_utc,
        sha256=cert.fingerprint(hashes.SHA256()).hex(),
    )


def _issued_by(leaf, ca) -> bool:
    try:
        leaf.verify_directly_issued_by(ca)
        return True
    except (ValueError, TypeError, Exception):
        return False


def chain_errors(chain, expected, others) -> list[str]:
    leaf = chain[0]
    errs = [] if _issued_by(leaf, expected) else ["does not verify against its intermediate"]
    errs += [f"also verifies against {n}" for n, c in others.items() if _issued_by(leaf, c)]
    return errs


def ownership_errors(stem: str, node: str, s: Summary, nodes: list[str]) -> list[str]:
    errs = []
    if not stem.endswith(f"-{node}"):
        errs.append(f"name must end in -{node}")
    comp = stem[: -len(node) - 1]
    want = {"kubelet": f"system:node:{node}", "etcd-peer": node, "etcd-server": node}.get(comp)
    if want and s.cn != want:
        errs.append(f"CN {s.cn!r}, want {want!r}")
    for o in nodes:
        if o != node and (s.cn in (o, f"system:node:{o}") or any(d == o or d.startswith(o + ".") for d in s.dns)):
            errs.append(f"names another node ({o})")
    return errs


def key_matches(cert: x509.Certificate, key_pem: bytes) -> bool:
    key = serialization.load_pem_private_key(key_pem, None)
    fmt = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return key.public_key().public_bytes(*fmt) == cert.public_key().public_bytes(*fmt)


def expiring(s: Summary, now: datetime, within: timedelta) -> bool:
    return s.not_after <= now + within

import ipaddress
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID
from cryptography.x509.verification import (
    Criticality,
    ExtensionPolicy,
    PolicyBuilder,
    Store,
    VerificationError,
)

KEY_USAGES = {
    "digital_signature": "Digital Signature",
    "content_commitment": "Non Repudiation",
    "key_encipherment": "Key Encipherment",
    "data_encipherment": "Data Encipherment",
    "key_agreement": "Key Agreement",
    "key_cert_sign": "Certificate Sign",
    "crl_sign": "CRL Sign",
}
EKU_NAMES = {
    ExtendedKeyUsageOID.SERVER_AUTH: "TLS Web Server Authentication",
    ExtendedKeyUsageOID.CLIENT_AUTH: "TLS Web Client Authentication",
    ExtendedKeyUsageOID.CODE_SIGNING: "Code Signing",
    ExtendedKeyUsageOID.EMAIL_PROTECTION: "E-mail Protection",
    ExtendedKeyUsageOID.OCSP_SIGNING: "OCSP Signing",
}
CURVES = {"secp256r1": "P256", "secp384r1": "P384", "secp521r1": "P521"}


@dataclass(frozen=True)
class Summary:
    subject: frozenset[tuple[str, str]]
    cn: str | None
    dns: frozenset[str]
    ips: frozenset[str]
    key_usage: frozenset[str]
    ext_key_usage: frozenset[str]
    is_ca: bool
    key: str
    issuer: str
    aki: str | None
    not_before: datetime
    not_after: datetime
    sha256: str


def load_chain(pem: bytes) -> list[x509.Certificate]:
    return x509.load_pem_x509_certificates(pem)


def _ext(cert: x509.Certificate, cls):
    try:
        return cert.extensions.get_extension_for_class(cls).value
    except x509.ExtensionNotFound:
        return None


def _key_usage(ku: x509.KeyUsage | None) -> frozenset[str]:
    if ku is None:
        return frozenset()
    names = {name for attr, name in KEY_USAGES.items() if getattr(ku, attr)}
    if ku.key_agreement:
        names |= {n for a, n in (("encipher_only", "Encipher Only"), ("decipher_only", "Decipher Only")) if getattr(ku, a)}
    return frozenset(names)


def key_name(cert: x509.Certificate) -> str:
    k = cert.public_key()
    if isinstance(k, rsa.RSAPublicKey):
        return f"RSA-{k.key_size}"
    if isinstance(k, ec.EllipticCurvePublicKey):
        return f"EC-{CURVES.get(k.curve.name, k.curve.name)}"
    if isinstance(k, ed25519.Ed25519PublicKey):
        return "Ed25519"
    return type(k).__name__


def summarize(cert: x509.Certificate) -> Summary:
    san = _ext(cert, x509.SubjectAlternativeName)
    eku = _ext(cert, x509.ExtendedKeyUsage)
    bc = _ext(cert, x509.BasicConstraints)
    aki = _ext(cert, x509.AuthorityKeyIdentifier)
    cns = cert.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME)
    return Summary(
        subject=frozenset((a.rfc4514_attribute_name, str(a.value)) for a in cert.subject),
        cn=str(cns[0].value) if cns else None,
        dns=frozenset(san.get_values_for_type(x509.DNSName)) if san else frozenset(),
        ips=frozenset(str(i) for i in san.get_values_for_type(x509.IPAddress)) if san else frozenset(),
        key_usage=_key_usage(_ext(cert, x509.KeyUsage)),
        ext_key_usage=frozenset(EKU_NAMES.get(o, o.dotted_string) for o in eku) if eku else frozenset(),
        is_ca=bool(bc and bc.ca),
        key=key_name(cert),
        issuer=cert.issuer.rfc4514_string(),
        aki=aki.key_identifier.hex() if aki and aki.key_identifier else None,
        not_before=cert.not_valid_before_utc,
        not_after=cert.not_valid_after_utc,
        sha256=cert.fingerprint(hashes.SHA256()).hex(),
    )


def _verifies(leaf: x509.Certificate, anchor: x509.Certificate) -> bool:
    """True if `leaf` alone chains to `anchor` as the sole trust anchor (root or not)."""
    s = summarize(leaf)
    client = EKU_NAMES[ExtendedKeyUsageOID.CLIENT_AUTH] in s.ext_key_usage or not (s.dns or s.ips)
    ee_policy = ExtensionPolicy.permit_all()
    if not client:
        ee_policy = ee_policy.require_present(x509.SubjectAlternativeName, Criticality.AGNOSTIC, None)
    builder = (
        PolicyBuilder()
        .store(Store([anchor]))
        .time(datetime.now(UTC))
        .extension_policies(
            ca_policy=ExtensionPolicy.permit_all().require_present(x509.BasicConstraints, Criticality.AGNOSTIC, None),
            ee_policy=ee_policy,
        )
    )
    if client:
        verifier = builder.build_client_verifier()
    else:
        name = x509.DNSName(min(s.dns)) if s.dns else x509.IPAddress(ipaddress.ip_address(min(s.ips)))
        verifier = builder.build_server_verifier(name)
    try:
        verifier.verify(leaf, [])
    except VerificationError:
        return False
    return True


def chain_errors(
    chain: list[x509.Certificate], expected: x509.Certificate, others: dict[str, x509.Certificate]
) -> list[str]:
    leaf, rest = chain[0], chain[1:]
    errors = []
    if not _verifies(leaf, expected):
        errors.append(f"does not verify against {expected.subject.rfc4514_string()}")
    errors += [f"also verifies against {name}" for name, ca in others.items() if _verifies(leaf, ca)]
    errors += [f"chain cert {i} is not {expected.subject.rfc4514_string()}" for i, c in enumerate(rest, 1) if c != expected]
    return errors


def ownership_errors(stem: str, node: str, s: Summary, nodes: list[str]) -> list[str]:
    if not re.fullmatch(rf"[a-z0-9-]+-{re.escape(node)}", stem):
        return [f"name must be <component>-{node}"]
    component = stem.removesuffix(f"-{node}")
    want = {"kubelet": f"system:node:{node}", "etcd-peer": node, "etcd-server": node}.get(component)
    errors = []
    if want and s.cn != want:
        errors.append(f"CN '{s.cn or ''}', want '{want}'")
    cn = s.cn or ""
    for other in nodes:
        if other == node:
            continue
        if any(d == other or d.startswith(f"{other}.") for d in s.dns) or cn == other or cn.endswith(f":{other}"):
            errors.append(f"names another node ({other})")
    return errors


def key_matches(cert: x509.Certificate, key_pem: bytes) -> bool:
    try:
        key = serialization.load_pem_private_key(key_pem, password=None)
    except (ValueError, TypeError):
        return False
    spki = serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    return key.public_key().public_bytes(*spki) == cert.public_key().public_bytes(*spki)


def expiring(s: Summary, now: datetime, within: timedelta) -> bool:
    return s.not_after < now + within

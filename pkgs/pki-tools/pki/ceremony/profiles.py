import re
from datetime import UTC, datetime, timedelta

from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from pki.ceremony import CeremonyError
from pki.ceremony.signer import Signer, sign_builder

ROOT_LIFE = timedelta(hours=175320)
BOOT_LIFE = timedelta(hours=43824)
WORKLOAD_LIFE = timedelta(hours=17520)
ROOT_PATHLEN = 1
BACKUP_PATHLEN = 2
CROSS_PATHLEN = 1
ROOT_CN = "neurosis Root CA 2026"
BOOTSTRAP_CAS = ("k8s", "etcd", "front-proxy")
ALL_CAS = ("workload", *BOOTSTRAP_CAS)
CA_KEY_USAGE = x509.KeyUsage(False, False, False, False, False, True, True, False, False)


def backup_cn(index: int, year: int) -> str:
    return f"neurosis Backup Root CA {index} {year}"


def intermediate_cn(ca: str, date: str) -> str:
    return f"neurosis {ca} CA {date}"


def name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "neurosis"), x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def now() -> datetime:
    return datetime.now(UTC).replace(microsecond=0)


def parse_lifetime(text: str) -> timedelta:
    m = re.fullmatch(r"([1-9][0-9]*)([hd])", text)
    if not m:
        raise CeremonyError(f"lifetime {text!r}: use <n>h or <n>d, e.g. 43824h or 1826d")
    n = int(m.group(1))
    return timedelta(hours=n) if m.group(2) == "h" else timedelta(days=n)


def ski_of(cert: x509.Certificate) -> x509.SubjectKeyIdentifier:
    return cert.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value


def ca_builder(subject, issuer, pub, ski, aki_digest: bytes, pathlen: int, not_before, not_after):
    return (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(pub)
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(CA_KEY_USAGE, True)
        .add_extension(x509.BasicConstraints(ca=True, path_length=pathlen), True)
        .add_extension(ski, False)
        .add_extension(x509.AuthorityKeyIdentifier(aki_digest, None, None), False)
    )


def self_signed_root(cn: str, signer: Signer, pathlen: int, life: timedelta = ROOT_LIFE, at=None) -> x509.Certificate:
    pub, start = signer.public_key(), at or now()
    ski = x509.SubjectKeyIdentifier.from_public_key(pub)
    return sign_builder(ca_builder(name(cn), name(cn), pub, ski, ski.digest, pathlen, start, start + life), signer, pub)


def lifetime_errors(root: x509.Certificate, lifetime: timedelta, at=None) -> list[str]:
    start = at or now()
    if lifetime <= timedelta(0):
        return ["lifetime must be positive"]
    if start < root.not_valid_before_utc:
        return [f"the root is not valid before {root.not_valid_before_utc:%Y-%m-%d %H:%M}"]
    if start + lifetime > root.not_valid_after_utc:
        return [f"lifetime ends {start + lifetime:%Y-%m-%d}, after the root ({root.not_valid_after_utc:%Y-%m-%d})"]
    return []


def subject_errors(subject: x509.Name, issuer: x509.Name | None) -> list[str]:
    cns = [a.value for a in subject.get_attributes_for_oid(NameOID.COMMON_NAME)]
    if not cns:
        return ["subject has no CN"]
    if subject == issuer:
        return ["subject is the issuer's name"]
    if any("root ca" in cn.lower() for cn in cns):
        return [f"subject CN {cns[0]!r} names a root CA"]
    return []


def csr_errors(csr: x509.CertificateSigningRequest, issuer: x509.Name | None = None) -> list[str]:
    errs = [] if csr.is_signature_valid else ["bad CSR signature"]
    errs += subject_errors(csr.subject, issuer)
    pub = csr.public_key()
    if not (isinstance(pub, ec.EllipticCurvePublicKey) and isinstance(pub.curve, ec.SECP384R1)):
        errs.append("key is not ECDSA P-384")
    for ext in csr.extensions:
        v = ext.value
        if isinstance(v, x509.BasicConstraints):
            if not v.ca or v.path_length != 0:
                errs.append(f"CSR asks for CA={v.ca} pathlen={v.path_length}; only CA:TRUE pathlen:0 is issued")
        elif not isinstance(v, (x509.KeyUsage, x509.SubjectKeyIdentifier)):
            errs.append(f"CSR requests extension {ext.oid.dotted_string}; only BasicConstraints, KeyUsage, SKI allowed")
    return errs


def intermediate(csr, root: x509.Certificate, signer: Signer, lifetime: timedelta, at=None) -> x509.Certificate:
    start = at or now()
    errs = csr_errors(csr, root.subject) + lifetime_errors(root, lifetime, start)
    if errs:
        raise CeremonyError(f"refusing {csr.subject.rfc4514_string()}: " + "; ".join(errs))
    pub = csr.public_key()
    b = ca_builder(
        csr.subject, root.subject, pub, x509.SubjectKeyIdentifier.from_public_key(pub), ski_of(root).digest, 0, start, start + lifetime
    )
    return sign_builder(b, signer, root.public_key())


def cross(subject_cert, issuer_cert, signer: Signer, pathlen: int = CROSS_PATHLEN, at=None) -> x509.Certificate:
    start = max(at or now(), issuer_cert.not_valid_before_utc)
    end = min(subject_cert.not_valid_after_utc, issuer_cert.not_valid_after_utc)
    b = ca_builder(
        subject_cert.subject, issuer_cert.subject, subject_cert.public_key(), ski_of(subject_cert), ski_of(issuer_cert).digest, pathlen, start, end
    )
    return sign_builder(b, signer, issuer_cert.public_key())

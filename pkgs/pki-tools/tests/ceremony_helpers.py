import os
from datetime import timedelta
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from pki.ceremony.profiles import BACKUP_PATHLEN, ROOT_CN, ROOT_PATHLEN, backup_cn, cross, intermediate, name, self_signed_root
from pki.ceremony.signer import PySigner

HERE = Path(__file__).parent
CLUSTER_PKI = Path(os.environ.get("PKI_TEST_CLUSTER_PKI", HERE / ".." / ".." / ".." / "cluster" / "pki"))
SOPS_YAML = Path(os.environ.get("PKI_TEST_SOPS_YAML", HERE / ".." / ".." / ".." / ".sops.yaml"))
ROOT_SERIAL, BACKUP_SERIAL = 19830800, 22616756


def signer() -> PySigner:
    return PySigner(ec.generate_private_key(ec.SECP384R1()))


def make_csr(cn="neurosis test CA", key=None, extensions=()):
    key = key or ec.generate_private_key(ec.SECP384R1())
    b = x509.CertificateSigningRequestBuilder().subject_name(name(cn))
    for ext, critical in extensions:
        b = b.add_extension(ext, critical)
    return b.sign(key, hashes.SHA384()), key


def make_leaf(issuer: x509.Certificate, issuer_key, cn="leaf.example") -> x509.Certificate:
    key = ec.generate_private_key(ec.SECP256R1())
    start = issuer.not_valid_before_utc
    return (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)]))
        .issuer_name(issuer.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(start)
        .not_valid_after(start + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
        .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer.public_key()), False)
        .sign(issuer_key, hashes.SHA384())
    )


class Hierarchy:
    """Root A (pathlen 1), backup B (pathlen 2), both cross certs, an intermediate and a leaf under each."""

    def __init__(self, b_pathlen=BACKUP_PATHLEN, a_by_b_pathlen=1):
        self.sa, self.sb = signer(), signer()
        self.a = self_signed_root(ROOT_CN, self.sa, ROOT_PATHLEN)
        self.b = self_signed_root(backup_cn(1, 2026), self.sb, b_pathlen)
        self.a_by_b = cross(self.a, self.b, self.sb, a_by_b_pathlen)
        self.b_by_a = cross(self.b, self.a, self.sa)
        csr, self.int_key = make_csr("neurosis workload CA")
        self.int = intermediate(csr, self.a, self.sa, timedelta(days=730))
        self.leaf = make_leaf(self.int, self.int_key)
        csr_b, self.intb_key = make_csr("neurosis intB CA")
        self.intb = intermediate(csr_b, self.b, self.sb, timedelta(days=730))
        self.leafb = make_leaf(self.intb, self.intb_key)

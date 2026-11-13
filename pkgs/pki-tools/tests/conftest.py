"""Stand-in for Frances's conftest.py (make_pki); hers replaces it on merge."""

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

NOW = datetime.now(timezone.utc)


def _key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _pem(obj):
    if isinstance(obj, x509.Certificate):
        return obj.public_bytes(serialization.Encoding.PEM)
    return obj.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )


def _cert(subject, key, issuer, issuer_key, days, ca, dns=()):
    name = lambda cn: x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    b = (
        x509.CertificateBuilder()
        .subject_name(name(subject))
        .issuer_name(name(issuer))
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(minutes=5))
        .not_valid_after(NOW + timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=0 if ca else None), critical=True)
    )
    if not ca:
        b = b.add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH, ExtendedKeyUsageOID.SERVER_AUTH]), False
        )
        if dns:
            b = b.add_extension(x509.SubjectAlternativeName([x509.DNSName(d) for d in dns]), False)
    return b.sign(issuer_key, hashes.SHA256())


def make_pki():
    rk = _key()
    root = _cert("fake root", rk, "fake root", rk, 3650, True)
    keys, inter = {}, {}
    for ca in ("k8s", "etcd", "front-proxy"):
        keys[ca] = _key()
        inter[ca] = _cert(f"fake {ca} CA", keys[ca], "fake root", rk, 1825, True)
    wk = _key()
    workload = _cert("fake workload CA", wk, "fake root", rk, 1825, True)

    def leaf(name, node, ca, cn, days=365, dns=None):
        k = _key()
        c = _cert(cn, k, f"fake {ca} CA", keys[ca], days, False, dns or [node])
        return _pem(c) + _pem(inter[ca]), _pem(k)

    def cross(ca):
        return _cert(f"fake {ca} CA", keys[ca], "fake root", rk, 1825, True)

    return SimpleNamespace(root=root, intermediates=inter, workload=workload, leaf=leaf, cross=cross, pem=_pem)


@pytest.fixture
def pki():
    return make_pki()

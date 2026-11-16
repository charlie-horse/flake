import shutil
import subprocess
from datetime import timedelta

import pytest
from ceremony_helpers import BACKUP_SERIAL, CLUSTER_PKI, ROOT_SERIAL, Hierarchy, make_csr, signer
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, SignatureAlgorithmOID

from pki.ceremony import CeremonyError
from pki.ceremony.checks import (
    attestation_errors,
    chain_errors,
    cross_chain_ok,
    fingerprints_txt,
    intermediates_next_to,
    issued_errors,
    load_cert,
)
from pki.ceremony.profiles import (
    BOOT_LIFE,
    ROOT_CN,
    backup_cn,
    cross,
    csr_errors,
    intermediate,
    lifetime_errors,
    now,
    parse_lifetime,
    self_signed_root,
    ski_of,
)
from pki.ceremony.secrets import pem
from pki.ceremony.signer import ECDSA_SHA384, der, sign_builder, spki

REAL_ROOT = CLUSTER_PKI / "root-ca.pem"
needs_real = pytest.mark.skipif(not REAL_ROOT.exists(), reason="cluster/pki not available (PKI_TEST_CLUSTER_PKI)")


@pytest.fixture(scope="module")
def h() -> Hierarchy:
    return Hierarchy()


def shape(cert):
    return [(type(e.value).__name__, e.critical) for e in cert.extensions]


def bc(cert):
    return cert.extensions.get_extension_for_class(x509.BasicConstraints).value


def aki(cert):
    return cert.extensions.get_extension_for_class(x509.AuthorityKeyIdentifier).value.key_identifier


@needs_real
def test_root_profile_matches_the_real_root(h):
    real = load_cert(REAL_ROOT)
    assert shape(h.a) == shape(real) == [
        ("KeyUsage", True), ("BasicConstraints", True), ("SubjectKeyIdentifier", False), ("AuthorityKeyIdentifier", False)
    ]
    assert h.a.signature_algorithm_oid == real.signature_algorithm_oid == SignatureAlgorithmOID.ECDSA_WITH_SHA384
    assert h.a.subject == real.subject
    assert ski_of(real) == x509.SubjectKeyIdentifier.from_public_key(real.public_key())
    assert aki(h.a) == ski_of(h.a).digest
    assert bc(h.a).path_length == bc(real).path_length == 1
    assert bc(h.b).path_length == 2 and h.b.subject.rfc4514_string() == "CN=neurosis Backup Root CA 1 2026,O=neurosis"


@needs_real
@pytest.mark.parametrize("ca", ["workload", "k8s", "etcd", "front-proxy"])
def test_intermediate_profile_matches_the_real_ones(h, ca):
    real = load_cert(CLUSTER_PKI / f"{ca}-ca.pem")
    assert shape(h.int) == shape(real)
    assert issued_errors(real, load_cert(REAL_ROOT)) == []
    assert issued_errors(h.int, h.a) == []
    assert bc(h.int).path_length == 0 and aki(h.int) == ski_of(h.a).digest


BAD_CSRS = {
    "pathlen 1": [(x509.BasicConstraints(ca=True, path_length=1), True)],
    "unlimited pathlen": [(x509.BasicConstraints(ca=True, path_length=None), True)],
    "CA:FALSE": [(x509.BasicConstraints(ca=False, path_length=None), True)],
    "EKU": [(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)],
    "nameConstraints": [(x509.NameConstraints([x509.DNSName("example.com")], None), True)],
}


@pytest.mark.parametrize("case", BAD_CSRS)
def test_csr_refusals(h, case):
    csr, _ = make_csr(extensions=BAD_CSRS[case])
    assert csr_errors(csr)
    with pytest.raises(CeremonyError, match="refusing"):
        intermediate(csr, h.a, h.sa, BOOT_LIFE)


def test_csr_pathlen0_and_ku_accepted(h):
    exts = [(x509.BasicConstraints(ca=True, path_length=0), True)]
    assert csr_errors(make_csr(extensions=exts)[0]) == []


def test_tampered_and_p256_csrs_refused():
    csr, _ = make_csr()
    der_bytes = bytearray(csr.public_bytes(serialization.Encoding.DER))
    der_bytes[-1] ^= 0x01
    assert "bad CSR signature" in csr_errors(x509.load_der_x509_csr(bytes(der_bytes)))
    p256, _ = make_csr(key=ec.generate_private_key(ec.SECP256R1()))
    assert "key is not ECDSA P-384" in csr_errors(p256)


def test_lifetime_refusals(h):
    assert lifetime_errors(h.a, BOOT_LIFE) == []
    assert lifetime_errors(h.a, timedelta(days=365 * 40))
    old = self_signed_root("old", signer(), 1, timedelta(days=365), at=now() - timedelta(days=800))
    assert lifetime_errors(old, timedelta(days=1))
    future = self_signed_root("future", signer(), 1, at=now() + timedelta(days=10))
    assert "not valid before" in lifetime_errors(future, timedelta(days=1))[0]
    csr, _ = make_csr()
    with pytest.raises(CeremonyError, match="after the root"):
        intermediate(csr, h.a, h.sa, timedelta(days=365 * 40))


def test_parse_lifetime():
    assert parse_lifetime("43824h") == timedelta(hours=43824) and parse_lifetime("1826d") == timedelta(days=1826)
    for bad in ("5y", "0h", "-1d", "12"):
        with pytest.raises(CeremonyError):
            parse_lifetime(bad)


def test_signer_must_hold_the_issuer_key(h):
    with pytest.raises(CeremonyError, match="not the issuer"):
        cross(h.a, h.b, h.sa)
    with pytest.raises(CeremonyError, match="not the issuer"):
        intermediate(make_csr()[0], h.a, h.sb, BOOT_LIFE)


def test_cross_keeps_subject_key_and_ski(h):
    for crossed, subject, issuer in [(h.a_by_b, h.a, h.b), (h.b_by_a, h.b, h.a)]:
        assert crossed.subject == subject.subject and crossed.issuer == issuer.subject
        assert spki(crossed.public_key()) == spki(subject.public_key())
        assert ski_of(crossed) == ski_of(subject) and aki(crossed) == ski_of(issuer).digest
        assert crossed.not_valid_after_utc == min(subject.not_valid_after_utc, issuer.not_valid_after_utc)
        assert bc(crossed).path_length == 1
        crossed.verify_directly_issued_by(issuer)


@needs_real
def test_cross_sign_the_real_root():
    real, sb = load_cert(REAL_ROOT), signer()
    b = self_signed_root(backup_cn(1, 2026), sb, 2)
    a_by_b = cross(real, b, sb)
    assert ski_of(a_by_b).digest.hex(":").upper().startswith("75:7A:75:CA")
    assert a_by_b.subject == real.subject and aki(a_by_b) == ski_of(b).digest
    targets = intermediates_next_to(REAL_ROOT)
    assert sorted(targets) == ["etcd", "front-proxy", "k8s", "workload"]
    cross_chain_ok(b, a_by_b, targets)
    with pytest.raises(CeremonyError):
        cross_chain_ok(self_signed_root("other", signer(), 2), a_by_b, targets)


class Corrupt:
    def __init__(self, inner):
        self.inner = inner

    def public_key(self):
        return self.inner.public_key()

    def sign(self, tbs):
        sig = bytearray(self.inner.sign(tbs))
        sig[-1] ^= 0x01
        return bytes(sig)


def test_der_assembly(h):
    assert h.a.signature_algorithm_oid == SignatureAlgorithmOID.ECDSA_WITH_SHA384
    assert ECDSA_SHA384 == bytes.fromhex("300a06082a8648ce3d040303")
    assert der(0x04, b"x" * 5) == b"\x04\x05xxxxx"
    assert der(0x04, b"x" * 200)[:3] == b"\x04\x81\xc8" and der(0x04, b"x" * 300)[:4] == b"\x04\x82\x01\x2c"
    h.int.verify_directly_issued_by(h.a)
    builder = x509.CertificateBuilder().subject_name(h.a.subject).issuer_name(h.a.subject).public_key(h.sa.public_key())
    builder = builder.serial_number(1).not_valid_before(now()).not_valid_after(now() + timedelta(days=1))
    with pytest.raises(CeremonyError, match="does not verify"):
        sign_builder(builder, Corrupt(h.sa), h.sa.public_key())


def chain_ok(anchor, untrusted, leaf) -> bool:
    return chain_errors(anchor, untrusted, {"leaf": leaf}) == []


def test_pathlen_matrix(h):
    assert chain_ok(h.a, [h.int], h.leaf)
    assert chain_ok(h.b, [h.int, h.a_by_b], h.leaf)
    assert chain_ok(h.b, [h.int, h.a, h.a_by_b], h.leaf)
    assert chain_ok(h.b, [h.intb], h.leafb)
    weak = Hierarchy(b_pathlen=1)
    assert not chain_ok(weak.b, [weak.int, weak.a_by_b], weak.leaf)
    narrow = Hierarchy(a_by_b_pathlen=0)
    assert not chain_ok(narrow.b, [narrow.int, narrow.a_by_b], narrow.leaf)


def test_direction_b_limitation_is_pinned(h):
    """leaf -> intB -> B' -> A fails: A is pathlen:1 and verifiers enforce the anchor's pathlen."""
    assert not chain_ok(h.a, [h.intb, h.b_by_a], h.leafb)


@pytest.mark.skipif(not shutil.which("openssl"), reason="openssl not on PATH")
def test_pathlen_matrix_openssl(h, tmp_path):
    def verify(anchor, untrusted, leaf) -> bool:
        files = {"anchor.pem": pem(anchor), "untrusted.pem": b"".join(pem(c) for c in untrusted), "leaf.pem": pem(leaf)}
        for n, data in files.items():
            (tmp_path / n).write_bytes(data)
        argv = ["openssl", "verify", "-x509_strict", "-CAfile", tmp_path / "anchor.pem"]
        argv += ["-untrusted", tmp_path / "untrusted.pem"] if untrusted else []
        return subprocess.run([*map(str, argv), str(tmp_path / "leaf.pem")], capture_output=True).returncode == 0

    weak, narrow = Hierarchy(b_pathlen=1), Hierarchy(a_by_b_pathlen=0)
    assert verify(h.a, [h.int], h.leaf)
    assert verify(h.b, [h.int, h.a_by_b], h.leaf)
    assert verify(h.b, [h.intb], h.leafb)
    assert not verify(weak.b, [weak.int, weak.a_by_b], weak.leaf)
    assert not verify(narrow.b, [narrow.int, narrow.a_by_b], narrow.leaf)
    assert not verify(h.a, [h.intb, h.b_by_a], h.leafb)


@needs_real
def test_real_attestation():
    attest, f9, root = (load_cert(CLUSTER_PKI / n) for n in ("attest-9c.pem", "attest-f9.pem", "root-ca.pem"))
    assert attestation_errors(attest, f9, ROOT_SERIAL, root.public_key()) == []
    assert "attested serial 19830800, expected 22616756" in attestation_errors(attest, f9, BACKUP_SERIAL, root.public_key())
    assert "attested key is not the expected key" in attestation_errors(attest, f9, ROOT_SERIAL, signer().public_key())
    assert attestation_errors(attest, root, ROOT_SERIAL, root.public_key())


def test_fingerprints_txt(h):
    lines = fingerprints_txt({"root": h.a, "front-proxy": h.int}).splitlines()
    assert lines[0].startswith("root         ") and len(lines[0].split()[1]) == 95
    assert lines[1].startswith("front-proxy  ")


def test_root_cn_default():
    assert ROOT_CN == "neurosis Root CA 2026"

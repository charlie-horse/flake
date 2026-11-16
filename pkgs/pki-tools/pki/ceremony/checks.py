from datetime import UTC, datetime
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.x509.verification import ExtensionPolicy, PolicyBuilder, Store, VerificationError

from pki.certs import load_chain
from pki.ceremony import CeremonyError
from pki.ceremony.profiles import ALL_CAS, ski_of
from pki.ceremony.signer import spki

YK_SERIAL = x509.ObjectIdentifier("1.3.6.1.4.1.41482.3.7")
YK_POLICY = x509.ObjectIdentifier("1.3.6.1.4.1.41482.3.8")
PIN_ALWAYS, TOUCH_ALWAYS = 3, 2


def load_cert(path) -> x509.Certificate:
    try:
        certs = load_chain(Path(path).read_bytes())
    except (OSError, ValueError) as e:
        raise CeremonyError(f"{path}: cannot read a PEM certificate ({e})") from None
    if len(certs) != 1:
        raise CeremonyError(f"{path}: expected exactly one certificate, found {len(certs)}")
    return certs[0]


def fingerprint(cert: x509.Certificate) -> str:
    return cert.fingerprint(hashes.SHA256()).hex()


def _ext(cert, oid) -> bytes | None:
    try:
        return cert.extensions.get_extension_for_oid(oid).value.value
    except x509.ExtensionNotFound:
        return None


def attestation_errors(attest, f9, expected_serial: int, pub) -> list[str]:
    try:
        attest.verify_directly_issued_by(f9)
    except (InvalidSignature, ValueError, TypeError) as e:
        return [f"attestation does not chain to the card's f9 certificate ({e.__class__.__name__})"]
    errs = []
    raw = _ext(attest, YK_SERIAL)
    serial = int.from_bytes(raw[2:], "big") if raw and raw[0] == 2 else None
    if serial != expected_serial:
        errs.append(f"attested serial {serial}, expected {expected_serial}")
    if _ext(attest, YK_POLICY) != bytes([PIN_ALWAYS, TOUCH_ALWAYS]):
        errs.append("attested policy is not PIN ALWAYS + touch ALWAYS")
    if spki(attest.public_key()) != spki(pub):
        errs.append("attested key is not the expected key")
    return errs


def verify_attestation(attest, f9, expected_serial: int, pub) -> None:
    errs = attestation_errors(attest, f9, expected_serial, pub)
    if errs:
        raise CeremonyError("attestation: " + "; ".join(errs))


def root_matches(cert_on_card: x509.Certificate | None, expected: x509.Certificate) -> bool:
    if cert_on_card is None:
        return False
    return fingerprint(cert_on_card) == fingerprint(expected) and spki(cert_on_card.public_key()) == spki(expected.public_key())


def chain_errors(anchor: x509.Certificate, untrusted: list[x509.Certificate], targets: dict[str, x509.Certificate]) -> list[str]:
    builder = PolicyBuilder().store(Store([anchor])).time(datetime.now(UTC))
    verifier = builder.extension_policies(ca_policy=ExtensionPolicy.webpki_defaults_ca(), ee_policy=ExtensionPolicy.permit_all())
    errs = []
    for label, cert in targets.items():
        try:
            verifier.build_client_verifier().verify(cert, untrusted)
        except VerificationError as e:
            errs.append(f"{label} does not chain to {anchor.subject.rfc4514_string()}: {e}")
    return errs


def cross_chain_ok(anchor, cross, targets: dict[str, x509.Certificate]) -> None:
    errs = chain_errors(anchor, [cross], targets)
    if errs:
        raise CeremonyError("; ".join(errs))


def intermediates_next_to(root_path) -> dict[str, x509.Certificate]:
    found = {ca: Path(root_path).with_name(f"{ca}-ca.pem") for ca in ALL_CAS}
    return {ca: load_chain(p.read_bytes())[0] for ca, p in found.items() if p.exists()}


def issued_errors(cert, root, pathlen: int = 0) -> list[str]:
    errs = []
    try:
        cert.verify_directly_issued_by(root)
    except (InvalidSignature, ValueError, TypeError):
        errs.append("signature does not verify under the issuer")
    try:
        bc = cert.extensions.get_extension_for_class(x509.BasicConstraints)
        ku = cert.extensions.get_extension_for_class(x509.KeyUsage)
        aki = cert.extensions.get_extension_for_class(x509.AuthorityKeyIdentifier).value
    except x509.ExtensionNotFound as e:
        return errs + [f"missing extension: {e}"]
    if not (bc.critical and bc.value.ca and bc.value.path_length == pathlen):
        errs.append(f"BasicConstraints is not critical CA:TRUE pathlen:{pathlen}")
    if not (ku.critical and ku.value.key_cert_sign and ku.value.crl_sign and not ku.value.digital_signature):
        errs.append("KeyUsage is not critical keyCertSign+cRLSign")
    if aki.key_identifier != ski_of(root).digest:
        errs.append("AKI is not the issuer's SKI")
    return errs


def fingerprints_txt(certs: dict[str, x509.Certificate]) -> str:
    fp = {k: ":".join(f"{b:02X}" for b in c.fingerprint(hashes.SHA256())) for k, c in certs.items()}
    width = max(12, *(len(k) for k in certs))
    return "".join(f"{k:<{width}} {v}\n" for k, v in fp.items())

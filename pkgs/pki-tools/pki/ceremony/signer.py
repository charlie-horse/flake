import base64
import hashlib
import os
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Protocol

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from pki.ceremony import CeremonyError

ECDSA_SHA384 = bytes.fromhex("300a06082a8648ce3d040303")


class Signer(Protocol):
    def public_key(self) -> ec.EllipticCurvePublicKey: ...

    def sign(self, tbs: bytes) -> bytes: ...


def spki(pub) -> bytes:
    return pub.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


@dataclass
class PySigner:
    key: ec.EllipticCurvePrivateKey

    def public_key(self):
        return self.key.public_key()

    def sign(self, tbs: bytes) -> bytes:
        return self.key.sign(tbs, ec.ECDSA(hashes.SHA384()))


@dataclass
class KmsSigner:
    """Signs through `step-kms-plugin`, exactly as `step certificate sign --kms` does."""

    kms: str
    key: str
    precheck: Callable[[], None] = lambda: None
    env: dict[str, str] = field(default_factory=dict)

    def _run(self, args: list[str], stdin: bytes | None = None) -> bytes:
        self.precheck()
        argv = ["step-kms-plugin", *args, "--kms", self.kms, self.key]
        res = subprocess.run(argv, input=stdin, capture_output=True, env={**os.environ, **self.env})
        if res.returncode != 0:
            raise CeremonyError(f"step-kms-plugin {args[0]} failed: {res.stderr.decode(errors='replace').strip()}")
        return res.stdout

    def public_key(self):
        return serialization.load_pem_public_key(self._run(["key"]))

    def sign(self, tbs: bytes) -> bytes:
        return base64.b64decode(self._run(["sign", "--format", "base64"], hashlib.sha384(tbs).digest()))


def der(tag: int, body: bytes) -> bytes:
    n = len(body)
    if n < 0x80:
        return bytes([tag, n]) + body
    size = (n.bit_length() + 7) // 8
    return bytes([tag, 0x80 | size]) + n.to_bytes(size, "big") + body


def sign_builder(builder: x509.CertificateBuilder, signer: Signer, issuer_pub) -> x509.Certificate:
    if spki(signer.public_key()) != spki(issuer_pub):
        raise CeremonyError("the signing key is not the issuer certificate's key; refusing to sign")
    tbs = builder.sign(ec.generate_private_key(ec.SECP384R1()), hashes.SHA384()).tbs_certificate_bytes
    cert = x509.load_der_x509_certificate(der(0x30, tbs + ECDSA_SHA384 + der(0x03, b"\0" + signer.sign(tbs))))
    try:
        issuer_pub.verify(cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(hashes.SHA384()))
    except InvalidSignature:
        raise CeremonyError("the signature returned by the signer does not verify") from None
    return cert

import hashlib
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from pki.ceremony import CardState, CeremonyError
from pki.ceremony.prompts import Prompter

PIN = "rehearsal"
KEY = "pkcs11:id=9c"


def softhsm_module() -> str:
    if os.environ.get("PKI_SOFTHSM_MODULE"):
        return os.environ["PKI_SOFTHSM_MODULE"]
    util = shutil.which("softhsm2-util")
    if not util:
        raise CeremonyError("rehearsal needs softhsm2-util on PATH or PKI_SOFTHSM_MODULE")
    return str(Path(util).resolve().parent.parent / "lib" / "softhsm" / "libsofthsm2.so")


class HsmCard:
    """A SoftHSM token standing in for YubiKey <serial>; HSMDIR/inserted says which card is plugged in."""

    attested = False

    def __init__(self, serial: int, root: Path, prompter: Prompter, no_init=frozenset()):
        self.serial, self.root, self.prompter, self.no_init = serial, root, prompter, no_init
        self.conf, self.base = root / "softhsm2.conf", root / f"card-{serial}"
        self.kms_env = {"SOFTHSM2_CONF": str(self.conf)}

    def _run(self, argv: list[str], check: bool = True) -> subprocess.CompletedProcess:
        res = subprocess.run(argv, capture_output=True, env={**os.environ, **self.kms_env})
        if check and res.returncode != 0:
            raise CeremonyError(f"{argv[0]} failed: {res.stderr.decode(errors='replace').strip()}")
        return res

    def _uri(self, pin_file) -> str:
        return f"pkcs11:module-path={softhsm_module()};token=card-{self.serial}?pin-source={pin_file}"

    def require(self) -> None:
        inserted = self.root / "inserted"
        if not inserted.exists():
            self.prompter.insert(self.serial)
            inserted.write_text(str(self.serial))
        current = int(inserted.read_text())
        if current != self.serial:
            raise CeremonyError(f"card {current} is inserted, expected {self.serial}; refusing")
        if not Path(f"{self.base}.82").exists():
            (self.root / "tokens").mkdir(exist_ok=True)
            self.conf.write_text(f"directories.tokendir = {self.root / 'tokens'}\nobjectstore.backend = file\nlog.level = ERROR\n")
            (self.root / "pin").write_text(PIN)
            self._run(["softhsm2-util", "--init-token", "--free", "--label", f"card-{self.serial}", "--so-pin", "12345678", "--pin", PIN])
            Path(f"{self.base}.82").write_bytes(os.urandom(32))

    def firmware(self) -> tuple[int, int, int]:
        self.require()
        return (5, 7, 0)

    def state(self) -> CardState:
        initialised = Path(f"{self.base}.init").exists()
        key, cert = self.slot_pubkey() is not None, self.slot_cert() is not None
        return CardState(not initialised, not initialised, not initialised, initialised, key, cert)

    def slot_pubkey(self):
        self.require()
        res = self._run(["step-kms-plugin", "key", "--kms", self._uri(self.root / "pin"), KEY], check=False)
        return serialization.load_pem_public_key(res.stdout) if res.returncode == 0 else None

    def slot_cert(self):
        self.require()
        path = Path(f"{self.base}.9c.pem")
        return x509.load_pem_x509_certificate(path.read_bytes()) if path.exists() else None

    def slot_policy(self) -> tuple[str, str]:
        self.require()
        return ("ALWAYS", "ALWAYS")

    def pin_attempts(self) -> int:
        self.require()
        return 3

    def slot82_fingerprint(self) -> str:
        self.require()
        return hashlib.sha256(Path(f"{self.base}.82").read_bytes()).hexdigest()

    def verify_pin(self, pin: str) -> None:
        self.require()
        if pin != PIN:
            raise CeremonyError("wrong PIN (rehearsal PIN is 'rehearsal')")

    def init_access(self, new_pin: str, new_puk: str) -> None:
        if self.serial in self.no_init:
            raise CeremonyError(f"card {self.serial} is protected: its PIN, PUK and management key are never changed here")
        self.require()
        Path(f"{self.base}.init").write_text("PIN/PUK/management key init simulated (SoftHSM has no PIV)\n")
        self.prompter.note(f"rehearsal: PIV access init of card {self.serial} skipped (SoftHSM has no PIV)")

    def generate_9c(self, pin: str):
        if self.slot_pubkey() is not None or self.slot_cert() is not None:
            raise CeremonyError(f"card {self.serial}: slot 9c is not empty; refusing")
        self.verify_pin(pin)
        self._run(["step-kms-plugin", "create", "--kms", self._uri(self.root / "pin"), "--kty", "EC", "--crv", "P384", f"{KEY};object=root"])
        return self.slot_pubkey()

    def attest_9c(self):
        self.require()
        return None

    def import_cert_9c(self, pin: str, cert) -> None:
        if self.slot_cert() is not None:
            raise CeremonyError(f"card {self.serial}: slot 9c already holds a certificate; refusing")
        self.verify_pin(pin)
        Path(f"{self.base}.9c.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))

    def kms_uris(self, pin_file) -> tuple[str, str]:
        return self._uri(pin_file), KEY


@dataclass
class HsmCards:
    root: Path
    prompter: Prompter
    no_init: frozenset = frozenset()

    def card(self, serial: int) -> HsmCard:
        self.root.mkdir(parents=True, exist_ok=True)
        return HsmCard(serial, self.root, self.prompter, self.no_init)

    def inserted(self, serial: int) -> None:
        (self.root / "inserted").write_text(str(serial))

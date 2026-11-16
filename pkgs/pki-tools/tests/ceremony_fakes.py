import hashlib
import os
import stat
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import timedelta
from types import SimpleNamespace

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from yubikit.core import InvalidPinError, Version
from yubikit.core.smartcard import SW, ApduError
from yubikit.piv import DEFAULT_MANAGEMENT_KEY, OBJECT_ID, PIN_POLICY, SLOT, TOUCH_POLICY

from pki.ceremony import card as card_module
from pki.ceremony.checks import YK_POLICY, YK_SERIAL
from pki.ceremony.profiles import now

F9_KEY, YUBICO_KEY = ec.generate_private_key(ec.SECP384R1()), ec.generate_private_key(ec.SECP384R1())
F9_NAME = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, "Fake Yubico PIV Attestation")])
YUBICO_NAME = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, "Fake Yubico PIV Root CA")])


def attestation(serial: int, pub, key=F9_KEY) -> x509.Certificate:
    return (
        x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, "YubiKey PIV Attestation 9c")]))
        .issuer_name(F9_NAME).public_key(pub).serial_number(1).not_valid_before(now()).not_valid_after(now() + timedelta(days=1))
        .add_extension(x509.UnrecognizedExtension(YK_SERIAL, b"\x02\x04" + serial.to_bytes(4, "big")), False)
        .add_extension(x509.UnrecognizedExtension(YK_POLICY, bytes([PIN_POLICY.ALWAYS, TOUCH_POLICY.ALWAYS])), False)
        .sign(key, hashes.SHA256())
    )


def cert(subject, issuer, pub, key) -> x509.Certificate:
    b = x509.CertificateBuilder().subject_name(subject).issuer_name(issuer).public_key(pub).serial_number(2)
    return b.not_valid_before(now()).not_valid_after(now() + timedelta(days=1)).sign(key, hashes.SHA256())


def f9_cert() -> x509.Certificate:
    return cert(F9_NAME, YUBICO_NAME, F9_KEY.public_key(), YUBICO_KEY)


def yubico_root() -> x509.Certificate:
    return cert(YUBICO_NAME, YUBICO_NAME, YUBICO_KEY.public_key(), YUBICO_KEY)


@dataclass
class FakeCard:
    serial: int
    pin: str = "123456"
    puk: str = "12345678"
    mgm_key: bytes = DEFAULT_MANAGEMENT_KEY
    protected: bool = False
    attempts: int = 3
    keys: dict = field(default_factory=dict)
    certs: dict = field(default_factory=dict)


class FakePivSession:
    version = Version(5, 7, 2)

    def __init__(self, card: FakeCard, log: list):
        self.card, self.log, self.pin_ok = card, log, False

    def _absent(self, slot, table):
        if slot not in table:
            raise ApduError(b"", SW.REFERENCE_DATA_NOT_FOUND if table is self.card.keys else SW.FILE_NOT_FOUND)
        return table[slot]

    def get_pin_metadata(self):
        return SimpleNamespace(default_value=self.card.pin == "123456", attempts_remaining=self.card.attempts)

    def get_puk_metadata(self):
        return SimpleNamespace(default_value=self.card.puk == "12345678")

    def get_management_key_metadata(self):
        return SimpleNamespace(default_value=self.card.mgm_key == DEFAULT_MANAGEMENT_KEY)

    def get_slot_metadata(self, slot):
        key, pin_policy, touch_policy = self._absent(slot, self.card.keys)
        pub = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        return SimpleNamespace(public_key=key.public_key(), pin_policy=pin_policy, touch_policy=touch_policy, public_key_encoded=pub)

    def get_certificate(self, slot):
        return f9_cert() if slot == SLOT.ATTESTATION else self._absent(slot, self.card.certs)

    def verify_pin(self, pin):
        self.log.append(("verify_pin",))
        if pin != self.card.pin:
            self.card.attempts -= 1
            raise InvalidPinError(self.card.attempts)
        self.pin_ok = True

    def change_pin(self, old, new):
        self.log.append(("change_pin",))
        assert old == self.card.pin
        self.card.pin = new

    def change_puk(self, old, new):
        self.log.append(("change_puk",))
        assert old == self.card.puk
        self.card.puk = new

    def authenticate(self, key):
        self.log.append(("authenticate", key == DEFAULT_MANAGEMENT_KEY))
        assert key == self.card.mgm_key

    def generate_key(self, slot, key_type, pin_policy, touch_policy):
        self.log.append(("write", slot, key_type, pin_policy, touch_policy))
        key = ec.generate_private_key(ec.SECP384R1())
        self.card.keys[slot] = (key, pin_policy, touch_policy)
        return key.public_key()

    def attest_key(self, slot):
        return attestation(self.card.serial, self.card.keys[slot][0].public_key())

    def put_certificate(self, slot, cert):
        self.log.append(("write", slot))
        self.card.certs[slot] = cert

    def put_object(self, object_id, data=None):
        self.log.append(("write", object_id))
        assert object_id != OBJECT_ID.from_slot(SLOT.RETIRED1)

    def reset(self):
        raise AssertionError("PIV reset must never be called")


class FakeDevices:
    def __init__(self, cards: dict[int, FakeCard], log: list):
        self.cards, self.log, self.inserted = cards, log, []

    def serials(self):
        self.log.append(("serials",))
        return sorted(self.inserted)

    def pcsc_serials(self):
        return list(self.inserted)

    @contextmanager
    def piv(self, serial):
        self.log.append(("open", serial))
        assert self.inserted == [serial]
        yield FakePivSession(self.cards[serial], self.log)


def patch_pivman(monkeypatch, log):
    def set_mgm(s, key, kind, store_on_device=False):
        log.append(("set_mgm_key", kind.name, store_on_device))
        s.card.mgm_key, s.card.protected = key, store_on_device

    def protected(s):
        assert s.pin_ok, "protected data read without a verified PIN"
        return SimpleNamespace(key=s.card.mgm_key if s.card.protected else None)

    monkeypatch.setattr(card_module, "pivman_change_pin", lambda s, old, new: s.change_pin(old, new))
    monkeypatch.setattr(card_module, "pivman_set_mgm_key", set_mgm)
    monkeypatch.setattr(card_module, "get_pivman_data", lambda s: SimpleNamespace(has_stored_key=s.card.protected))
    monkeypatch.setattr(card_module, "get_pivman_protected_data", protected)


@dataclass
class CardSigner:
    """Signs with the fake card's 9c key, through the same precheck as KmsSigner."""

    card: object
    devices: FakeDevices
    pin_path: object
    log: list

    def _key(self):
        self.card.require()
        assert stat.S_IMODE(os.stat(self.pin_path).st_mode) == 0o600
        return self.devices.cards[self.card.serial].keys[SLOT.SIGNATURE][0]

    def public_key(self):
        return self._key().public_key()

    def sign(self, tbs):
        key = self._key()
        self.log.append(("sign", self.card.serial, hashlib.sha256(tbs).hexdigest()[:8]))
        return key.sign(tbs, ec.ECDSA(hashes.SHA384()))

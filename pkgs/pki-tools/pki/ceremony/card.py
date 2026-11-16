import hashlib
from contextlib import contextmanager
from dataclasses import dataclass

from ykman.piv import (
    generate_random_management_key,
    get_pivman_data,
    get_pivman_protected_data,
    pivman_change_pin,
    pivman_set_mgm_key,
)
from yubikit.core import InvalidPinError
from yubikit.core.smartcard import SW, ApduError
from yubikit.piv import DEFAULT_MANAGEMENT_KEY, KEY_TYPE, MANAGEMENT_KEY_TYPE, PIN_POLICY, SLOT, TOUCH_POLICY

from pki.ceremony import CardState, CeremonyError
from pki.ceremony.pcsc import YkDevices, ensure_pcscd
from pki.ceremony.prompts import Prompter

DEFAULT_PIN, DEFAULT_PUK = "123456", "12345678"
INSERT_TRIES = 5


class YubiKeyCard:
    attested = True
    kms_env: dict[str, str] = {}

    def __init__(self, serial: int, devices, prompter: Prompter, no_init=frozenset()):
        self.serial, self.devices, self.prompter, self.no_init = serial, devices, prompter, no_init

    def require(self) -> None:
        for _ in range(INSERT_TRIES):
            found = self.devices.serials()
            if found == [self.serial]:
                ensure_pcscd(self.serial, lambda: self.serial in self.devices.pcsc_serials())
                return
            if found:
                raise CeremonyError(f"expected only YubiKey {self.serial}, found {found}; refusing (one card at a time)")
            self.prompter.insert(self.serial)
        raise CeremonyError(f"YubiKey {self.serial} was not inserted")

    @contextmanager
    def _piv(self):
        self.require()
        with self.devices.piv(self.serial) as session:
            yield session

    @staticmethod
    def _maybe(read, slot):
        try:
            return read(slot)
        except ApduError as e:
            if e.sw in (SW.REFERENCE_DATA_NOT_FOUND, SW.FILE_NOT_FOUND):
                return None
            raise

    def _auth(self, s, pin: str) -> None:
        self._verify(s, pin)
        key = get_pivman_protected_data(s).key
        if key is None:
            raise CeremonyError(f"YubiKey {self.serial}: the management key is not PIN-protected on the card; refusing")
        s.authenticate(key)

    @staticmethod
    def _verify(s, pin: str) -> None:
        try:
            s.verify_pin(pin)
        except InvalidPinError as e:
            raise CeremonyError(f"wrong PIN ({e.attempts_remaining} tries left)") from None

    def firmware(self) -> tuple[int, int, int]:
        with self._piv() as s:
            return tuple(s.version)

    def state(self) -> CardState:
        with self._piv() as s:
            pin, puk, mgm = s.get_pin_metadata(), s.get_puk_metadata(), s.get_management_key_metadata()
            protected = get_pivman_data(s).has_stored_key
            key, cert = self._maybe(s.get_slot_metadata, SLOT.SIGNATURE), self._maybe(s.get_certificate, SLOT.SIGNATURE)
            return CardState(pin.default_value, puk.default_value, mgm.default_value, protected, key is not None, cert is not None)

    def slot_pubkey(self):
        with self._piv() as s:
            meta = self._maybe(s.get_slot_metadata, SLOT.SIGNATURE)
            return meta.public_key if meta else None

    def slot_cert(self):
        with self._piv() as s:
            return self._maybe(s.get_certificate, SLOT.SIGNATURE)

    def slot_policy(self) -> tuple[str, str]:
        with self._piv() as s:
            meta = self._maybe(s.get_slot_metadata, SLOT.SIGNATURE)
            return (meta.pin_policy.name, meta.touch_policy.name) if meta else ("", "")

    def pin_attempts(self) -> int:
        with self._piv() as s:
            return s.get_pin_metadata().attempts_remaining

    def slot82_fingerprint(self) -> str:
        with self._piv() as s:
            meta = self._maybe(s.get_slot_metadata, SLOT.RETIRED1)
            return hashlib.sha256(meta.public_key_encoded).hexdigest() if meta else "absent"

    def verify_pin(self, pin: str) -> None:
        with self._piv() as s:
            self._verify(s, pin)

    def init_access(self, new_pin: str, new_puk: str) -> None:
        if self.serial in self.no_init:
            raise CeremonyError(f"YubiKey {self.serial} is protected: its PIN, PUK and management key are never changed here")
        with self._piv() as s:
            if not s.get_pin_metadata().default_value:
                raise CeremonyError(f"YubiKey {self.serial}: the PIN is not the factory default; refusing to initialise")
            pivman_change_pin(s, DEFAULT_PIN, new_pin)
            s.change_puk(DEFAULT_PUK, new_puk)
            s.authenticate(DEFAULT_MANAGEMENT_KEY)
            s.verify_pin(new_pin)
            kind = MANAGEMENT_KEY_TYPE.AES192 if tuple(s.version) >= (5, 4, 0) else MANAGEMENT_KEY_TYPE.TDES
            pivman_set_mgm_key(s, generate_random_management_key(kind), kind, store_on_device=True)

    def generate_9c(self, pin: str):
        with self._piv() as s:
            if self._maybe(s.get_slot_metadata, SLOT.SIGNATURE) or self._maybe(s.get_certificate, SLOT.SIGNATURE):
                raise CeremonyError(f"YubiKey {self.serial}: slot 9c is not empty; refusing")
            self._auth(s, pin)
            return s.generate_key(SLOT.SIGNATURE, KEY_TYPE.ECCP384, PIN_POLICY.ALWAYS, TOUCH_POLICY.ALWAYS)

    def attest_9c(self):
        with self._piv() as s:
            return s.attest_key(SLOT.SIGNATURE), s.get_certificate(SLOT.ATTESTATION)

    def import_cert_9c(self, pin: str, cert) -> None:
        with self._piv() as s:
            if self._maybe(s.get_certificate, SLOT.SIGNATURE):
                raise CeremonyError(f"YubiKey {self.serial}: slot 9c already holds a certificate; refusing")
            self._auth(s, pin)
            s.put_certificate(SLOT.SIGNATURE, cert)

    def kms_uris(self, pin_file) -> tuple[str, str]:
        return f"yubikey:serial={self.serial}?pin-source={pin_file}", "yubikey:slot-id=9c"


@dataclass
class YubiKeyCards:
    prompter: Prompter
    no_init: frozenset = frozenset()
    devices: object = None

    def card(self, serial: int) -> YubiKeyCard:
        return YubiKeyCard(serial, self.devices or YkDevices(), self.prompter, self.no_init)

    def inserted(self, serial: int) -> None:
        pass

from collections.abc import Callable
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from pki.ceremony import CeremonyError
from pki.ceremony import secrets as k8s_secrets
from pki.ceremony.prompts import Prompter
from pki.ceremony.signer import KmsSigner, Signer, spki
from pki.ceremony.tmpfs import pin_file, workdir

SWAP_TRIES = 5


def kms_signer(card, pin_path: Path) -> Signer:
    kms, key = card.kms_uris(pin_path)
    return KmsSigner(kms, key, card.require, card.kms_env)


@dataclass
class Context:
    repo: Path
    prompter: Prompter
    cards: object
    ask_pin: Callable[[str], str]
    ask_new_pin: Callable[[str], str]
    signer: Callable[[object, Path], Signer] = kms_signer
    encrypt: Callable[[str, str, str], str] = field(default=k8s_secrets.encrypt)
    now: datetime | None = None
    resume_flags: str = ""

    @contextmanager
    def signing(self, card, pin: str, expected_pub):
        with workdir() as work:
            signer = self.signer(card, pin_file(work, pin))
            if spki(signer.public_key()) != spki(expected_pub):
                raise CeremonyError(f"card {card.serial}: the 9c key seen by step-kms-plugin is not the expected key")
            yield signer

    def swap_to(self, card, from_serial: int | None, label: str) -> None:
        for _ in range(SWAP_TRIES):
            self.prompter.swap(from_serial, card.serial, label)
            self.cards.inserted(card.serial)
            try:
                card.require()
                return
            except CeremonyError as e:
                self.prompter.note(f"ERROR: {e}")
        raise CeremonyError(f"card {card.serial} was not inserted after {SWAP_TRIES} tries")


def write_new(path: Path, data: bytes | str) -> Path:
    if path.exists():
        raise CeremonyError(f"{path} exists; refusing to overwrite")
    if isinstance(data, str):
        data = data.encode()
    path.write_bytes(data)
    return path

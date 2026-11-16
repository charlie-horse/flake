from dataclasses import dataclass


class CeremonyError(Exception):
    """A refusal or a failed check: the CLI prints it and exits 1."""


@dataclass(frozen=True)
class CardState:
    pin_default: bool
    puk_default: bool
    mgm_default: bool
    mgm_protected: bool
    key_9c: bool
    cert_9c: bool

    @property
    def empty_9c(self) -> bool:
        return not (self.key_9c or self.cert_9c)

    @property
    def fresh(self) -> bool:
        return self.pin_default and self.puk_default and self.mgm_default and self.empty_9c

    @property
    def initialised(self) -> bool:
        return not (self.pin_default or self.puk_default or self.mgm_default) and self.mgm_protected and self.empty_9c

from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from pki.ceremony import CeremonyError
from pki.ceremony.checks import fingerprints_txt, issued_errors, load_cert, root_matches
from pki.ceremony.context import Context, write_new
from pki.ceremony.profiles import BOOT_LIFE, WORKLOAD_LIFE, csr_errors, intermediate, intermediate_cn, lifetime_errors, name, now
from pki.ceremony.secrets import ca_secret, pem
from pki.ceremony.signer import spki

DESTS = {"workload": "k8s/secrets/cert-manager/", "bootstrap": "k8s/secrets/cluster-pki/"}


@dataclass
class Item:
    label: str
    csr: x509.CertificateSigningRequest
    lifetime: timedelta
    key: ec.EllipticCurvePrivateKey | None = None

    @property
    def pem_name(self) -> str:
        return f"{self.label}-ca.pem" if self.key else f"{self.label}.pem"


def default_life(ca: str) -> timedelta:
    return WORKLOAD_LIFE if ca.removesuffix("-ca") == "workload" else BOOT_LIFE


def new_item(ca: str, date: str, lifetime: timedelta | None = None) -> Item:
    key = ec.generate_private_key(ec.SECP384R1())
    csr = x509.CertificateSigningRequestBuilder().subject_name(name(intermediate_cn(ca, date))).sign(key, hashes.SHA384())
    return Item(ca, csr, lifetime or default_life(ca), key)


def csr_item(label: str, path: Path, lifetime: timedelta | None = None) -> Item:
    try:
        csr = x509.load_pem_x509_csr(Path(path).read_bytes())
    except (OSError, ValueError) as e:
        raise CeremonyError(f"{path}: not a PEM CSR ({e})") from None
    return Item(label, csr, lifetime or default_life(label))


def preview(ctx: Context, items: list[Item], root: x509.Certificate | None, issuer: x509.Name | None = None) -> None:
    errs = []
    for it in items:
        errs += [f"{it.label}: {e}" for e in csr_errors(it.csr, issuer or root.subject)]
        if root is not None:
            errs += [f"{it.label}: {e}" for e in lifetime_errors(root, it.lifetime, ctx.now)]
    if errs:
        raise CeremonyError("refusing to sign:\n  " + "\n  ".join(errs))
    for it in items:
        days = it.lifetime / timedelta(days=1)
        ctx.prompter.note(f"  {it.label}: {it.csr.subject.rfc4514_string()}  ({days:.0f} days, CA:TRUE pathlen:0)")
    ctx.prompter.confirm(f"Sign these {len(items)} as intermediates (one PIN + touch each)?")


def gate_root_card(ctx: Context, card, root: x509.Certificate) -> str:
    """Refuse unless the card's 9c holds exactly this root; returns the slot-82 fingerprint."""
    pub = card.slot_pubkey()
    if pub is None:
        raise CeremonyError(f"card {card.serial}: slot 9c holds no key; refusing")
    if spki(pub) != spki(root.public_key()):
        raise CeremonyError(f"card {card.serial}: the 9c key is not the key of {root.subject.rfc4514_string()}; refusing")
    if not root_matches(card.slot_cert(), root):
        raise CeremonyError(f"card {card.serial}: the 9c certificate is not the expected root certificate; refusing")
    if card.slot_policy() != ("ALWAYS", "ALWAYS"):
        raise CeremonyError(f"card {card.serial}: 9c policy {card.slot_policy()} is not PIN ALWAYS + touch ALWAYS; refusing")
    tries = card.pin_attempts()
    if tries < 3:
        ctx.prompter.confirm(f"Only {tries} PIN tries left on card {card.serial}. Continue?")
    return card.slot82_fingerprint()


def check_slot82(card, before: str) -> None:
    if card.slot82_fingerprint() != before:
        raise CeremonyError(f"card {card.serial}: slot 82 changed during the ceremony!?")


def issue(ctx: Context, card, root: x509.Certificate, pin: str, items: list[Item], out: Path) -> dict[str, x509.Certificate]:
    certs = {}
    with ctx.signing(card, pin, root.public_key()) as signer:
        for it in items:
            ctx.prompter.touch(f"Signing {it.label}")
            cert = intermediate(it.csr, root, signer, it.lifetime, ctx.now)
            errs = issued_errors(cert, root)
            if it.key and spki(cert.public_key()) != spki(it.key.public_key()):
                errs.append("certificate key is not the generated key")
            if errs:
                raise CeremonyError(f"{it.label}: " + "; ".join(errs))
            write_new(out / it.pem_name, pem(cert))
            if it.key:
                repo_path, fname, text = ca_secret(it.label, cert, root, it.key)
                write_new(out / fname, ctx.encrypt(str(ctx.repo), repo_path, text))
                ctx.prompter.note(f"  {out / fname} -> {repo_path}")
            ctx.prompter.note(f"  {out / it.pem_name}")
            certs[it.label] = cert
    return certs


def prepare_out(out: Path) -> Path:
    if out.exists():
        raise CeremonyError(f"{out} exists; refusing to overwrite")
    out.mkdir(parents=True, mode=0o700)
    return out


def run_sign(ctx: Context, args) -> int:
    root = load_cert(args.root)
    date = args.cn_date or f"{now():%Y-%m-%d}"
    items = [new_item(ca, date, args.not_after) for ca in args.new]
    for spec in args.csr:
        label, sep, path = spec.partition("=")
        if not sep or not label:
            raise CeremonyError(f"--csr {spec!r}: use NAME=FILE.csr")
        items.append(csr_item(label, Path(path), args.not_after))
    if not items:
        raise CeremonyError("nothing to sign: give --new CA and/or --csr NAME=FILE")
    if len({it.pem_name for it in items}) != len(items):
        raise CeremonyError("two items would write the same file")
    preview(ctx, items, root)
    if Path(args.out).exists():
        raise CeremonyError(f"{args.out} exists; refusing to overwrite")
    card = ctx.cards.card(args.serial)
    ctx.swap_to(card, None, "the root card")
    before = gate_root_card(ctx, card, root)
    out = prepare_out(Path(args.out))
    pin = ctx.ask_pin(f"PIV PIN of card {card.serial}")
    card.verify_pin(pin)
    certs = issue(ctx, card, root, pin, items, out)
    check_slot82(card, before)
    write_new(out / "fingerprints.txt", fingerprints_txt(certs))
    ctx.prompter.say(f"Done. Nothing in {ctx.repo} was changed. On a branch:")
    ctx.prompter.note("  <ca>-ca.pem -> cluster/pki/ (rotation: new first, old after; docs/pki.md, CA rotation)")
    ctx.prompter.note(f"  cluster-ca.sops.yaml -> {DESTS['workload']}; <ca>-ca.sops.yaml -> {DESTS['bootstrap']}")
    ctx.prompter.note("  fingerprints.txt -> merge into cluster/pki/fingerprints.txt. Unplug the YubiKey.")
    return 0

from pathlib import Path

from pki.ceremony import CeremonyError
from pki.ceremony.checks import fingerprints_txt, verify_attestation
from pki.ceremony.context import Context, write_new
from pki.ceremony.flow_sign import check_slot82, csr_item, issue, new_item, prepare_out, preview
from pki.ceremony.profiles import BOOTSTRAP_CAS, ROOT_LIFE, ROOT_PATHLEN, name, now, self_signed_root
from pki.ceremony.secrets import pem

MIN_FIRMWARE = (5, 3, 0)


def bootstrap_items(args, date: str):
    from_dir = {ca: Path(args.csr_dir) / f"{ca}.csr" for ca in BOOTSTRAP_CAS} if args.csr_dir else {}
    from_dir = {ca: p for ca, p in from_dir.items() if p.exists()}
    both = set(from_dir) & set(args.new)
    if both:
        raise CeremonyError(f"{sorted(both)}: both a CSR in --csr-dir and --new; pick one")
    items = [csr_item(f"{ca}-ca", p) for ca, p in from_dir.items()]
    return items + [new_item(ca, date) for ca in args.new if ca != "workload"]


def make_root(ctx: Context, card, pin: str, cn: str, out: Path):
    pub = card.generate_9c(pin)
    attestation = card.attest_9c()
    if attestation is None:
        ctx.prompter.note("rehearsal: no PIV attestation (SoftHSM)")
    else:
        attest, f9 = attestation
        verify_attestation(attest, f9, card.serial, pub)
        write_new(out / "attest-9c.pem", pem(attest))
        write_new(out / "attest-f9.pem", pem(f9))
    with ctx.signing(card, pin, pub) as signer:
        ctx.prompter.touch(f"Self-signing {cn}")
        root = self_signed_root(cn, signer, ROOT_PATHLEN, ROOT_LIFE, ctx.now)
    root.verify_directly_issued_by(root)
    write_new(out / "root-ca.pem", pem(root))
    card.import_cert_9c(pin, root)
    return root


def run_root(ctx: Context, args) -> int:
    date = args.cn_date or f"{now():%Y-%m-%d}"
    items = [new_item("workload", date), *bootstrap_items(args, date)]
    preview(ctx, items, None, name(args.cn))
    card = ctx.cards.card(args.serial)
    ctx.swap_to(card, None, "the root card")
    firmware = card.firmware()
    if firmware < MIN_FIRMWARE:
        raise CeremonyError(f"card {card.serial}: firmware {firmware} < 5.3 (P-384, metadata, attestation)")
    if not card.state().empty_9c:
        raise CeremonyError(f"card {card.serial}: slot 9c already holds a key or certificate; refusing (never reset this card)")
    before = card.slot82_fingerprint()
    out = prepare_out(Path(args.out))
    pin = ctx.ask_pin(f"PIV PIN of card {card.serial}")
    card.verify_pin(pin)
    root = make_root(ctx, card, pin, args.cn, out)
    certs = issue(ctx, card, root, pin, items, out)
    check_slot82(card, before)
    write_new(out / "fingerprints.txt", fingerprints_txt({"root": root, **{k.removesuffix("-ca"): v for k, v in certs.items()}}))
    ctx.prompter.say(f"Done. Nothing in {ctx.repo} was changed. On a branch:")
    ctx.prompter.note("  cluster/pki/: root-ca.pem, attest-9c.pem, attest-f9.pem, <ca>-ca.pem, fingerprints.txt (public)")
    ctx.prompter.note("  k8s/secrets/cert-manager/cluster-ca.sops.yaml <- cluster-ca.sops.yaml")
    ctx.prompter.note("  k8s/secrets/cluster-pki/<ca>-ca.sops.yaml <- <ca>-ca.sops.yaml (for --new CAs). Unplug the YubiKey.")
    return 0

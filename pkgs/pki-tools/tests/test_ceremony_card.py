import base64
import hashlib
import json
import os
import shutil
import stat
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

pytest.importorskip("yubikit")

from ceremony_fakes import F9_NAME, CardSigner, FakeCard, FakeDevices, attestation, patch_pivman, yubico_root  # noqa: E402
from ceremony_fakes import cert as fake_cert  # noqa: E402
from ceremony_helpers import BACKUP_SERIAL, ROOT_SERIAL, SOPS_YAML, make_csr, signer  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from yubikit.piv import KEY_TYPE, PIN_POLICY, SLOT, TOUCH_POLICY  # noqa: E402

from pki.ceremony import CeremonyError, checks, cli, tmpfs  # noqa: E402
from pki.ceremony.card import YubiKeyCards  # noqa: E402
from pki.ceremony.checks import load_cert  # noqa: E402
from pki.ceremony.context import Context  # noqa: E402
from pki.ceremony.flow_backup import run_backup  # noqa: E402
from pki.ceremony.flow_root import run_root  # noqa: E402
from pki.ceremony.flow_sign import run_sign  # noqa: E402
from pki.ceremony.profiles import ROOT_CN, cross, intermediate, self_signed_root  # noqa: E402
from pki.ceremony.prompts import Prompter  # noqa: E402
from pki.ceremony.secrets import pem  # noqa: E402
from pki.ceremony.signer import KmsSigner  # noqa: E402

PIN_A, PIN_B = "654321", "24680135"


def pem_public(pub) -> bytes:
    return pub.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)


class Env:
    def __init__(self, tmp_path: Path, monkeypatch):
        self.log, self.out, self.answers, self.encrypted = [], [], [], []
        patch_pivman(monkeypatch, self.log)
        monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
        monkeypatch.setattr(tmpfs, "fs_type", lambda p: "tmpfs")
        monkeypatch.setattr(checks, "yubico_cas", lambda: [yubico_root()])
        self.sa = signer()
        self.root = self_signed_root(ROOT_CN, self.sa, 1)
        self.repo = tmp_path / "repo"
        (self.repo / "cluster" / "pki").mkdir(parents=True)
        (self.repo / ".sops.yaml").write_text("creation_rules: []\n")
        self.root_path = self.repo / "cluster" / "pki" / "root-ca.pem"
        self.root_path.write_bytes(pem(self.root))
        workload = intermediate(make_csr("neurosis workload CA")[0], self.root, self.sa, timedelta(days=730))
        (self.repo / "cluster" / "pki" / "workload-ca.pem").write_bytes(pem(workload))
        k82 = ec.generate_private_key(ec.SECP384R1())
        card_a = FakeCard(ROOT_SERIAL, pin=PIN_A, puk="87654321", mgm_key=b"\x11" * 24, protected=True)
        card_a.keys = {SLOT.SIGNATURE: (self.sa.key, PIN_POLICY.ALWAYS, TOUCH_POLICY.ALWAYS), SLOT.RETIRED1: (k82, PIN_POLICY.ONCE, TOUCH_POLICY.NEVER)}
        card_a.certs = {SLOT.SIGNATURE: self.root}
        self.devices = FakeDevices({ROOT_SERIAL: card_a, BACKUP_SERIAL: FakeCard(BACKUP_SERIAL), 7: FakeCard(7)}, self.log)
        self.prompter = Prompter(ask=self.answer, out=self.out.append)
        self.cards = YubiKeyCards(self.prompter, frozenset({ROOT_SERIAL}), self.devices)
        pins = {ROOT_SERIAL: PIN_A}
        self.ctx = Context(
            self.repo, self.prompter, self.cards,
            ask_pin=lambda label: pins.get(int(label.split()[-1]), PIN_B),
            ask_new_pin=lambda label: PIN_B,
            signer=lambda card, path: CardSigner(card, self.devices, path, self.log),
            encrypt=self.encrypt,
        )
        self.tmp = tmp_path

    def answer(self, prompt: str) -> str:
        a = self.answers.pop(0)
        if isinstance(a, int):
            self.devices.inserted = [a]
            return ""
        return a

    def encrypt(self, repo, path, text):
        self.encrypted.append((path, text))
        return f"sops: fake for {path}\n"

    def args(self, *argv):
        args = cli.parser().parse_args(list(argv))
        if getattr(args, "root", "x") is None:
            args.root = str(self.root_path)
        return args

    def card(self, serial):
        return self.cards.card(serial)


@pytest.fixture
def env(tmp_path, monkeypatch) -> Env:
    return Env(tmp_path, monkeypatch)


OPS = [
    ("firmware", ()), ("state", ()), ("slot_pubkey", ()), ("slot_cert", ()), ("slot_policy", ()),
    ("pin_attempts", ()), ("slot82_fingerprint", ()), ("verify_pin", (PIN_A,)),
]


@pytest.mark.parametrize("op,args", OPS)
def test_serial_gate_runs_before_every_card_operation(env, op, args):
    env.devices.inserted = [ROOT_SERIAL]
    getattr(env.card(ROOT_SERIAL), op)(*args)
    assert env.log[0] == ("serials",) and ("open", ROOT_SERIAL) in env.log


def test_serial_gate_before_writes(env):
    env.devices.inserted = [BACKUP_SERIAL]
    card = env.card(BACKUP_SERIAL)
    for call in (lambda: card.init_access(PIN_B, "11223344"), lambda: card.generate_9c(PIN_B), card.attest_9c):
        env.log.clear()
        call()
        assert env.log[:2] == [("serials",), ("open", BACKUP_SERIAL)]


def test_no_card_prompts_then_relists(env):
    env.answers = [ROOT_SERIAL]
    assert env.card(ROOT_SERIAL).pin_attempts() == 3
    assert env.log[:3] == [("serials",), ("serials",), ("open", ROOT_SERIAL)]
    assert any("Insert card 19830800" in line for line in env.out)


@pytest.mark.parametrize("inserted", [[BACKUP_SERIAL], [ROOT_SERIAL, BACKUP_SERIAL]])
def test_wrong_or_extra_card_refused_before_any_card_call(env, inserted):
    env.devices.inserted = inserted
    with pytest.raises(CeremonyError, match="expected only YubiKey 19830800"):
        env.card(ROOT_SERIAL).slot_cert()
    assert not any(e[0] == "open" for e in env.log)


def test_fresh_and_mixed_state(env):
    env.devices.inserted = [BACKUP_SERIAL]
    card = env.card(BACKUP_SERIAL)
    assert card.state().fresh
    env.devices.cards[BACKUP_SERIAL].pin = PIN_B
    st = card.state()
    assert not st.fresh and not st.initialised


def test_init_order_and_protected_mgm_key(env):
    env.devices.inserted = [BACKUP_SERIAL]
    card = env.card(BACKUP_SERIAL)
    card.init_access(PIN_B, "11223344")
    calls = [e for e in env.log if e[0] not in ("serials", "open")]
    assert calls == [("change_pin",), ("change_puk",), ("authenticate", True), ("verify_pin",), ("set_mgm_key", "AES192", True)]
    assert card.state().initialised


def test_init_refused_on_root_card_and_non_fresh(env):
    env.devices.inserted = [ROOT_SERIAL]
    with pytest.raises(CeremonyError, match="protected"):
        env.card(ROOT_SERIAL).init_access(PIN_B, "11223344")
    env.devices.inserted = [7]
    env.devices.cards[7].pin = "999999"
    with pytest.raises(CeremonyError, match="not the factory default"):
        env.card(7).init_access(PIN_B, "11223344")
    assert not any(e[0] in ("change_pin", "change_puk", "set_mgm_key") for e in env.log)


def test_generate_uses_p384_always_always_and_refuses_occupied(env):
    env.devices.inserted = [BACKUP_SERIAL]
    card = env.card(BACKUP_SERIAL)
    card.init_access(PIN_B, "11223344")
    card.generate_9c(PIN_B)
    assert ("write", SLOT.SIGNATURE, KEY_TYPE.ECCP384, PIN_POLICY.ALWAYS, TOUCH_POLICY.ALWAYS) in env.log
    with pytest.raises(CeremonyError, match="not empty"):
        card.generate_9c(PIN_B)


def test_kms_signer_gate_and_argv(env, monkeypatch):
    env.devices.inserted = [ROOT_SERIAL]
    card, runs = env.card(ROOT_SERIAL), []

    def fake_run(argv, input=None, **kw):
        runs.append((argv, input))
        env.log.append(("run", argv[1]))
        stdout = pem_public(env.root.public_key()) if argv[1] == "key" else base64.b64encode(b"sig")
        return SimpleNamespace(returncode=0, stdout=stdout, stderr=b"")

    monkeypatch.setattr("pki.ceremony.signer.subprocess.run", fake_run)
    with tmpfs.workdir() as work:
        path = tmpfs.pin_file(work, PIN_A)
        s = KmsSigner(*card.kms_uris(path), card.require)
        s.public_key()
        s.sign(b"tbs")
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600 and str(path).startswith(str(env.tmp))
    for argv, _ in runs:
        assert PIN_A not in " ".join(argv) and f"pin-source={path}" in " ".join(argv)
    assert runs[1][1] == hashlib.sha384(b"tbs").digest()
    order = [e[0] for e in env.log]
    assert order == ["serials", "run", "serials", "run"]
    assert not path.exists() and not work.exists()


def test_pin_file_is_shredded(env):
    with tmpfs.workdir() as work:
        path = tmpfs.pin_file(work, PIN_A)
        os.link(path, env.tmp / "witness")
        with pytest.raises(FileExistsError):
            tmpfs.pin_file(work, PIN_A)
    assert (env.tmp / "witness").read_bytes() == b"\0" * len(PIN_A) and not work.exists()


def test_workdir_refuses_non_tmpfs(monkeypatch):
    monkeypatch.setattr(tmpfs, "fs_type", lambda p: "ext4")
    with pytest.raises(CeremonyError, match="no tmpfs"):
        with tmpfs.workdir():
            pass


def test_ask_new_pin_rejects_weak_and_mismatch():
    answers = iter(["123456", "12345", "24680135", "24680136", "24680135", "24680135"])
    assert tmpfs.ask_new_pin("PIN", read=lambda prompt: next(answers)) == "24680135"
    with pytest.raises(CeremonyError):
        tmpfs.ask_new_pin("PIN", read=lambda prompt: "123456")


def resume_args(env, out, serial=BACKUP_SERIAL):
    return env.args("backup-root", "--cross-sign-with-root", str(out), "--serial", str(serial), "--root", str(env.root_path))


def backup_args(env, out):
    return env.args("backup-root", "--serial", str(BACKUP_SERIAL), "--index", "1", "--out", str(out), "--root", str(env.root_path))


def test_backup_step1_later_then_resume(env):
    out = env.tmp / "b1"
    env.answers = [BACKUP_SERIAL, "later"]
    slot82 = env.devices.cards[ROOT_SERIAL].keys[SLOT.RETIRED1]
    assert run_backup(env.ctx, backup_args(env, out)) == 0
    state = json.loads((out / "state.json").read_text())
    assert state["step"] == 1 and state["attested"] and state["puk_file"]
    assert sorted(p.name for p in out.iterdir()) == [
        "attest-9c-22616756.pem", "attest-f9-22616756.pem", "backup-root-1.pem", "puk-22616756.sops.yaml", "root-ca-by-backup-1.pem", "state.json"
    ]
    assert env.encrypted[0][0] == "secrets/admin.yaml" and "yubikey-22616756-piv-puk" in env.encrypted[0][1]
    env.answers = [BACKUP_SERIAL, ROOT_SERIAL, "yes"]
    assert run_backup(env.ctx, resume_args(env, out)) == 0
    assert any(load_cert(out / "backup-root-1.pem").fingerprint(hashes.SHA256()).hex() in line for line in env.out)
    b_by_a = load_cert(out / "backup-root-1-by-root.pem")
    b_by_a.verify_directly_issued_by(env.root)
    assert json.loads((out / "state.json").read_text())["step"] == 2
    assert env.devices.cards[ROOT_SERIAL].keys[SLOT.RETIRED1] is slot82
    assert not any(e[0] == "write" and e[1] in (SLOT.RETIRED1, 0x82) for e in env.log)
    signs = [e[1] for e in env.log if e[0] == "sign"]
    assert signs == [BACKUP_SERIAL, BACKUP_SERIAL, ROOT_SERIAL]


def step1(env):
    out = env.tmp / "b1"
    env.answers = [BACKUP_SERIAL, "later"]
    run_backup(env.ctx, backup_args(env, out))
    return out


def tamper_root(env, out):
    env.root_path.write_bytes(pem(self_signed_root(ROOT_CN, signer(), 1)))


def tamper_backup(env, out):
    (out / "backup-root-1.pem").write_bytes(pem(self_signed_root("neurosis Backup Root CA 1 2026", signer(), 2)))


def tamper_cross(env, out):
    other = signer()
    fake_b = self_signed_root("neurosis Backup Root CA 1 2026", other, 2)
    (out / "root-ca-by-backup-1.pem").write_bytes(pem(cross(env.root, fake_b, other)))


def b_by_a_exists(env, out):
    (out / "backup-root-1-by-root.pem").write_text("x")


def forge(env, out, attest_too=False):
    """What someone who can write step 1's directory would do: their own B and A', state.json to match."""
    key = signer()
    fake_b = self_signed_root("neurosis Backup Root CA 1 2026", key, 2)
    (out / "backup-root-1.pem").write_bytes(pem(fake_b))
    (out / "root-ca-by-backup-1.pem").write_bytes(pem(cross(env.root, fake_b, key)))
    state = json.loads((out / "state.json").read_text())
    state.update(backup_sha256=fake_b.fingerprint(hashes.SHA256()).hex(), attested=False)
    (out / "state.json").write_text(json.dumps(state))
    if attest_too:
        self_made = ec.generate_private_key(ec.SECP384R1())
        (out / "attest-9c-22616756.pem").write_bytes(pem(attestation(BACKUP_SERIAL, key.public_key(), self_made)))
        (out / "attest-f9-22616756.pem").write_bytes(pem(fake_cert(F9_NAME, F9_NAME, self_made.public_key(), self_made)))


def forge_with_attestation(env, out):
    forge(env, out, attest_too=True)


def forge_without_attestation(env, out):
    forge(env, out)
    for n in ("attest-9c-22616756.pem", "attest-f9-22616756.pem"):
        (out / n).unlink()


def valid_attestation_wrong_card(env, out):
    forge(env, out)
    (out / "attest-9c-22616756.pem").write_bytes(pem(attestation(BACKUP_SERIAL, load_cert(out / "backup-root-1.pem").public_key())))


@pytest.mark.parametrize("tamper,match", [
    (tamper_root, "not the one step 1 cross-signed"),
    (tamper_backup, "changed since step 1"),
    (tamper_cross, "does not verify under the issuer"),
    (b_by_a_exists, "step 2 already ran"),
    (forge, "attested key is not the expected key"),
    (forge_with_attestation, "not issued by a pinned Yubico PIV attestation CA"),
    (forge_without_attestation, "attest-9c-22616756.pem: cannot read"),
    (valid_attestation_wrong_card, "9c key is not the key of CN=neurosis Backup Root CA 1 2026"),
])
def test_resume_refusals(env, tamper, match):
    out = step1(env)
    tamper(env, out)
    env.answers = [BACKUP_SERIAL, ROOT_SERIAL, "yes"]
    with pytest.raises(CeremonyError, match=match):
        run_backup(env.ctx, resume_args(env, out))
    assert not (out / "backup-root-1-by-root.pem").exists() or tamper is b_by_a_exists
    assert [e[1] for e in env.log if e[0] == "sign"] == [BACKUP_SERIAL, BACKUP_SERIAL]


def test_resume_checks_the_card_and_its_fresh_attestation(env):
    out = step1(env)
    env.devices.cards[BACKUP_SERIAL].certs[SLOT.SIGNATURE] = self_signed_root("neurosis Backup Root CA 1 2026", signer(), 2)
    env.answers = [BACKUP_SERIAL]
    with pytest.raises(CeremonyError, match="9c certificate is not the expected root"):
        run_backup(env.ctx, resume_args(env, out))
    with pytest.raises(CeremonyError, match="step 2 needs --serial 22616756"):
        run_backup(env.ctx, resume_args(env, out, serial=7))


def test_resume_with_wrong_card_reprompts_and_keeps_step1(env):
    out = step1(env)
    before = sorted(p.name for p in out.iterdir())
    env.answers = [ROOT_SERIAL, "later"]
    assert run_backup(env.ctx, resume_args(env, out)) == 0
    assert any("expected only YubiKey 22616756" in line for line in env.out)
    assert sorted(p.name for p in out.iterdir()) == before


def test_wrong_card_at_the_swap_reprompts(env):
    out = env.tmp / "b1"
    env.answers = [BACKUP_SERIAL, 7, ROOT_SERIAL, "yes"]
    assert run_backup(env.ctx, backup_args(env, out)) == 0
    assert any("expected only YubiKey 19830800, found [7]" in line for line in env.out)
    assert (out / "backup-root-1-by-root.pem").exists()


def test_backup_refuses_root_serial_and_mixed_card(env):
    with pytest.raises(CeremonyError, match="is the root card"):
        run_backup(env.ctx, env.args("backup-root", "--serial", str(ROOT_SERIAL), "--index", "1", "--out", str(env.tmp / "x")))
    env.devices.cards[BACKUP_SERIAL].puk = "99999999"
    env.answers = [BACKUP_SERIAL]
    with pytest.raises(CeremonyError, match="neither factory-fresh"):
        run_backup(env.ctx, backup_args(env, env.tmp / "b1"))
    assert not any(e[0] in ("change_pin", "write") for e in env.log)


def break_key(env):
    env.devices.cards[ROOT_SERIAL].keys[SLOT.SIGNATURE] = (ec.generate_private_key(ec.SECP384R1()), PIN_POLICY.ALWAYS, TOUCH_POLICY.ALWAYS)


def break_cert(env):
    env.devices.cards[ROOT_SERIAL].certs[SLOT.SIGNATURE] = self_signed_root(ROOT_CN, env.sa, 1)


def break_policy(env):
    env.devices.cards[ROOT_SERIAL].keys[SLOT.SIGNATURE] = (env.sa.key, PIN_POLICY.ONCE, TOUCH_POLICY.ALWAYS)


def empty_9c(env):
    del env.devices.cards[ROOT_SERIAL].keys[SLOT.SIGNATURE]


@pytest.mark.parametrize("breaker,match", [
    (break_key, "9c key is not the key"), (break_cert, "9c certificate is not the expected root"),
    (break_policy, "policy"), (empty_9c, "holds no key"),
])
def test_sign_gate_refusals(env, breaker, match):
    breaker(env)
    env.answers = ["yes", ROOT_SERIAL]
    with pytest.raises(CeremonyError, match=match):
        run_sign(env.ctx, env.args("sign", "--new", "workload", "--out", str(env.tmp / "s")))
    assert not any(e[0] in ("sign", "verify_pin") for e in env.log) and not (env.tmp / "s").exists()


def test_sign_happy_path(env):
    env.answers = ["yes", ROOT_SERIAL]
    assert run_sign(env.ctx, env.args("sign", "--new", "workload", "--new", "etcd", "--out", str(env.tmp / "s"))) == 0
    workload = load_cert(env.tmp / "s" / "workload-ca.pem")
    workload.verify_directly_issued_by(env.root)
    assert (workload.not_valid_after_utc - workload.not_valid_before_utc).days == 730
    assert [p for p, _ in env.encrypted] == ["k8s/secrets/cert-manager/cluster-ca.sops.yaml", "k8s/secrets/cluster-pki/etcd-ca.sops.yaml"]
    assert sorted(p.name for p in (env.tmp / "s").iterdir()) == [
        "cluster-ca.sops.yaml", "etcd-ca.pem", "etcd-ca.sops.yaml", "fingerprints.txt", "workload-ca.pem"
    ]


def test_root_refuses_occupied_9c(env):
    env.answers = ["yes", ROOT_SERIAL]
    with pytest.raises(CeremonyError, match="already holds a key"):
        run_root(env.ctx, env.args("root", "--out", str(env.tmp / "r")))
    assert not any(e[0] in ("write", "verify_pin") for e in env.log)


def test_root_on_an_empty_card(env):
    card = env.devices.cards[7]
    card.pin, card.puk, card.mgm_key, card.protected = PIN_B, "11223344", b"\x22" * 24, True
    env.answers = ["yes", 7]
    assert run_root(env.ctx, env.args("root", "--serial", "7", "--new", "k8s", "--out", str(env.tmp / "r"))) == 0
    root = load_cert(env.tmp / "r" / "root-ca.pem")
    assert card.certs[SLOT.SIGNATURE] == root
    load_cert(env.tmp / "r" / "k8s-ca.pem").verify_directly_issued_by(root)
    assert (env.tmp / "r" / "attest-9c.pem").exists()


def test_yes_requires_rehearsal(env):
    with pytest.raises(CeremonyError, match="only allowed with --rehearsal"):
        cli.context(env.args("sign", "--yes", "--new", "k8s", "--out", "x", "--repo", str(env.repo)))


@pytest.mark.skipif(not SOPS_YAML.exists(), reason="no .sops.yaml")
def test_cli_maps_errors_to_exit_1(env, capsys):
    shutil.copy(SOPS_YAML, env.repo / ".sops.yaml")
    rc = cli.main(["backup-root", "--repo", str(env.repo), "--serial", str(ROOT_SERIAL), "--index", "1", "--out", str(env.tmp / "x")])
    assert rc == 1 and "ERROR: --serial 19830800 is the root card" in capsys.readouterr().err

import json
import shutil
import subprocess

import pytest
from ceremony_helpers import BACKUP_SERIAL, SOPS_YAML, make_csr, signer
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from pki import sopsfile
from pki.ceremony import cli, tmpfs
from pki.ceremony.checks import chain_errors, issued_errors, load_cert
from pki.ceremony.profiles import ROOT_CN, self_signed_root, ski_of
from pki.ceremony.secrets import pem

TOOLS = ("softhsm2-util", "step-kms-plugin", "sops", "age-plugin-yubikey", "openssl")
pytestmark = pytest.mark.skipif(
    not all(shutil.which(t) for t in TOOLS) or not SOPS_YAML.exists(), reason=f"rehearsal needs {', '.join(TOOLS)} and .sops.yaml"
)


@pytest.fixture
def rehearsal(tmp_path, monkeypatch):
    try:
        tmpfs.tmpfs_base()
    except Exception:
        monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
        monkeypatch.setattr(tmpfs, "fs_type", lambda p: "tmpfs")
    repo = tmp_path / "repo"
    repo.mkdir()
    shutil.copy(SOPS_YAML, repo / ".sops.yaml")
    (repo / "cluster" / "pki").mkdir(parents=True)
    (repo / "cluster" / "pki" / "root-ca.pem").write_bytes(pem(self_signed_root(ROOT_CN, signer(), 1)))
    monkeypatch.chdir(tmp_path)
    return tmp_path, ["--repo", str(repo), "--rehearsal", str(tmp_path / "hsm")]


def write_csr(path, extensions=()):
    path.write_bytes(make_csr("neurosis ext CA", extensions=extensions)[0].public_bytes(serialization.Encoding.PEM))
    return path


def openssl_ok(anchor, untrusted, target) -> bool:
    argv = ["openssl", "verify", "-x509_strict", "-CAfile", str(anchor), *(["-untrusted", str(untrusted)] if untrusted else []), str(target)]
    return subprocess.run(argv, capture_output=True).returncode == 0


def test_all_three_subcommands(rehearsal, monkeypatch, capsys):
    d, common = rehearsal
    assert cli.main(["root", *common, "--yes", "--new", "k8s", "--out", "r"]) == 0
    root = load_cert(d / "r" / "root-ca.pem")
    assert sorted(p.name for p in (d / "r").iterdir()) == [
        "cluster-ca.sops.yaml", "fingerprints.txt", "k8s-ca.pem", "k8s-ca.sops.yaml", "root-ca.pem", "workload-ca.pem"
    ]
    assert sopsfile.recipients((d / "r" / "cluster-ca.sops.yaml").read_text())
    assert cli.main(["root", *common, "--yes", "--out", "r2"]) == 1
    assert "slot 9c already holds" in capsys.readouterr().err

    rootarg = ["--root", str(d / "r" / "root-ca.pem")]
    ext, bad = write_csr(d / "ext.csr"), write_csr(d / "bad.csr", [(x509.BasicConstraints(ca=True, path_length=1), True)])
    assert cli.main(["sign", *common, *rootarg, "--yes", "--csr", f"bad={bad}", "--out", "bad"]) == 1
    assert "only CA:TRUE pathlen:0" in capsys.readouterr().err and not (d / "bad").exists()
    assert cli.main(["sign", *common, "--yes", "--new", "etcd", "--out", "wrong-root"]) == 1
    assert "9c key is not the key" in capsys.readouterr().err
    assert cli.main(["sign", *common, *rootarg, "--yes", "--new", "etcd", "--csr", f"x={ext}", "--out", "s"]) == 0
    etcd, x = load_cert(d / "s" / "etcd-ca.pem"), load_cert(d / "s" / "x.pem")
    assert issued_errors(etcd, root) == [] and issued_errors(x, root) == []

    answers = iter(["", "later"])
    monkeypatch.setattr("builtins.input", lambda prompt="": next(answers))
    backup = ["backup-root", *common, *rootarg]
    assert cli.main([*backup, "--serial", str(BACKUP_SERIAL), "--index", "1", "--out", "b1"]) == 0
    assert "Resume step 2 later" in capsys.readouterr().err
    assert json.loads((d / "b1" / "state.json").read_text())["step"] == 1
    assert cli.main([*backup, "--yes", "--cross-sign-with-root", "b1"]) == 0
    assert "does NOT let clients" in capsys.readouterr().err
    assert cli.main([*backup, "--yes", "--cross-sign-with-root", "b1"]) == 1

    b, a_by_b, b_by_a = (load_cert(d / "b1" / n) for n in ("backup-root-1.pem", "root-ca-by-backup-1.pem", "backup-root-1-by-root.pem"))
    assert ski_of(a_by_b) == ski_of(root) and issued_errors(a_by_b, b, 1) == []
    assert ski_of(b_by_a) == ski_of(b) and issued_errors(b_by_a, root, 1) == [] and issued_errors(b, b, 2) == []
    targets = {"workload": load_cert(d / "r" / "workload-ca.pem"), "k8s": load_cert(d / "r" / "k8s-ca.pem"), "etcd": etcd, "x": x}
    assert chain_errors(root, [], targets) == [] and chain_errors(b, [a_by_b], targets) == []
    assert len(chain_errors(b, [], targets)) == 4
    for t in ("r/workload-ca.pem", "r/k8s-ca.pem", "s/etcd-ca.pem", "s/x.pem"):
        assert openssl_ok(d / "r" / "root-ca.pem", None, d / t)
        assert openssl_ok(d / "b1" / "backup-root-1.pem", d / "b1" / "root-ca-by-backup-1.pem", d / t)
        assert not openssl_ok(d / "b1" / "backup-root-1.pem", None, d / t)

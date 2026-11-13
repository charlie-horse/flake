import json
import os
import subprocess
import urllib.parse
import urllib.request

CRED_HELPER = (
    "!f() { echo username=x-access-token; "
    'printf "%s=%s\\n" password "$GITHUB_TOKEN"; }; f'
)


class Api:
    def __init__(self, repo: str, token: str, base_url: str | None = None):
        self.repo = repo
        self.owner = repo.split("/")[0]
        self.token = token
        self.base = base_url or os.environ.get("GITHUB_API_URL", "https://api.github.com")

    def _call(self, method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(
            self.base + path,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)

    def pulls(self, state: str = "open", head: str | None = None) -> list[dict]:
        q = {"state": state, "per_page": "100"}
        if head:
            q["head"] = f"{self.owner}:{head}"
        return self._call("GET", f"/repos/{self.repo}/pulls?" + urllib.parse.urlencode(q))

    def create_pull(self, title: str, head: str, base: str, body: str) -> dict:
        return self._call(
            "POST",
            f"/repos/{self.repo}/pulls",
            {"title": title, "head": head, "base": base, "body": body, "maintainer_can_modify": True},
        )


class Git:
    def __init__(self, tree: str, token: str = ""):
        self.tree = tree
        self.env = dict(os.environ, GITHUB_TOKEN=token, GIT_TERMINAL_PROMPT="0")

    def __call__(self, *args: str, cwd: bool = True) -> str:
        argv = ["git", "-c", "credential.helper=", "-c", f"credential.helper={CRED_HELPER}"]
        if cwd:
            argv += ["-C", self.tree]
        res = subprocess.run([*argv, *args], env=self.env, check=True, capture_output=True, text=True)
        return res.stdout

    def clone(self, url: str, branch: str) -> None:
        self("clone", "-q", "--depth", "1", "--single-branch", "--branch", branch, url, self.tree, cwd=False)

    def remote_branches(self, pattern: str) -> list[str]:
        out = self("ls-remote", "--heads", "origin", f"refs/heads/{pattern}")
        return [l.split("refs/heads/", 1)[1] for l in out.splitlines() if "refs/heads/" in l]

    def commit_push(self, branch: str, paths: list[str], title: str, body: str) -> None:
        self("switch", "-q", "-c", branch)
        self("add", *paths)
        name = os.environ.get("GIT_AUTHOR_NAME", "pki-export")
        email = os.environ.get("GIT_AUTHOR_EMAIL", "pki-export@users.noreply.github.com")
        self("-c", f"user.name={name}", "-c", f"user.email={email}", "commit", "-q", "-m", title, "-m", body)
        self("push", "-q", "origin", f"HEAD:refs/heads/{branch}")

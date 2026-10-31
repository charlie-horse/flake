# CI

Two workflows run here: `.github/workflows/k8s.yml` covers the cluster and
the servers, and the existing `update.yml` / `buildIso.yml` cover the
desktops. This page explains `k8s.yml`. It also proposes a workflow for
catenix, which this repo cannot push to; [apply it by hand](#catenix-proposed-ci).

- [What triggers it](#what-triggers-it)
- [Jobs](#jobs)
- [Eval only, never build the hosts](#eval-only-never-build-the-hosts)
- [m2mini (aarch64) and the vendor firmware](#m2mini-aarch64-and-the-vendor-firmware)
- [k8s/rendered and the bot commit](#k8srendered-and-the-bot-commit)
- [Secrets guard](#secrets-guard)
- [Pinned actions](#pinned-actions)
- [Running the same checks locally](#running-the-same-checks-locally)
- [catenix: proposed CI](#catenix-proposed-ci)

## What triggers it

The workflow runs on pushes and pull requests to `main` that touch any of these paths:

```
hosts/c4130/**  hosts/r440/**  hosts/m2mini/**  modules/cluster/**
cluster/**  k8s/**  pkgs/**  lib/**  flake.nix  flake.lock
.github/workflows/k8s.yml
```

You can also start it by hand with `workflow_dispatch`.

`lib/**` is on the list because `mkHost`/`mkServer` live there. So is
`flake.lock`, which means the nightly `update.yml` commit runs this workflow too.

The default token permission is `contents: read`. On a pull request, a newer
push cancels the run in progress. On `main`, runs queue instead, so render
commits never race each other.

## Jobs

| Job | Runner | What it does |
| --- | --- | --- |
| `secrets-guard` | ubuntu-24.04 | Fails if the diff adds a key file, a kubeconfig or a plaintext password ([details](#secrets-guard)). |
| `flake-check` | ubuntu-24.04 | Runs `nix flake check --keep-going`, which evaluates every output: all NixOS hosts including the desktops, the ISOs and the packages. Not `--no-build`: that cannot realise the import-from-derivation in the catenix chart renders. The flake has no `checks`, so nothing heavy is built. |
| `eval-hosts` (matrix) | x86: ubuntu-24.04, m2mini: ubuntu-24.04-arm | Runs `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` with import-from-derivation (IFD) disabled for c4130, r440 and m2mini. It also checks that `.system` matches the expected system, and writes the drvPath to the job summary. |
| `k8s-manifests` | ubuntu-24.04 | Runs `nix build .#k8s-manifests` and compares the result with `k8s/rendered/`. It fails if the render contains key material. It runs `k8s-check-images` as an advisory step (amd64+arm64), and uploads the render as an artifact. |
| `publish-rendered` | ubuntu-24.04 | Runs only on a push to `main` when the render changed and every other job passed. It commits `k8s/rendered/`. This is the only job with `contents: write`. |

`flake check` is not enough on its own. It checks that each
`nixosConfigurations.*` evaluates to *a* configuration, but it does not force
`toplevel.drvPath`. During the cluster work it passed for c4130/r440/m2mini
even though their toplevels hit an option conflict. The `eval-hosts` job is
the check that forces the drvPath.

## Eval only, never build the hosts

CI never builds a NixOS toplevel. The c4130 closure contains the CUDA 12.8
toolkit, torch and vLLM, which is hours of build time and tens of GB, far beyond a
hosted runner. r440 and m2mini are skipped as well, for consistency and
speed. The host evals pass `--option allow-import-from-derivation false`
(`$NO_IFD` in the workflow), so evaluation can never turn into a build, even
if a module later starts reading from a derivation. As of 2026-10-31,
evaluating the c4130 `vllm.service` unit and the m2mini Asahi kernel needs no
IFD.

The only build is the catenix render, `.#k8s-manifests`. It consists of YAML,
fixed-output `helm pull`s and `helm template`, and takes minutes. In
`flake-check`, `--no-build` still realises IFD, so the chart renders build
there too.

To compare a CI drvPath with what runs on a host, use the drvPath shown in the job
summary. On the host:

```sh
nix-diff /run/current-system <drvPath>   # after copying/evaluating it there
```

## m2mini (aarch64) and the vendor firmware

m2mini is evaluated on GitHub's native arm64 runner (`ubuntu-24.04-arm`,
which is free for public repos). The configuration has no IFD, so it also
evaluates on x86_64. If the arm runner is unavailable, set `runner:
ubuntu-24.04` on the matrix entry.

Apple's peripheral firmware (`firmware.cpio`) is proprietary and is never
available on a runner. The flake's `m2mini-vendorfw` input defaults to the
firmware-free placeholder `hosts/m2mini/vendorfw`, so CI evaluates with
`hardware.asahi.extractPeripheralFirmware = false`. See
`hosts/m2mini/firmware.nix`. On the box, deploy with
`--override-input m2mini-vendorfw path:/boot/vendorfw`.

**Hook (Max):** in `k8s.yml`, the step `Eval toplevel drvPath (no build)` has
an env var `M2MINI_EVAL_FLAGS`, marked `HOOK(Max)`. Extra flags for the
m2mini eval go there, for example an `--override-input` if the firmware
wiring changes. It is empty today because the placeholder input is what CI
should use.

## k8s/rendered and the bot commit

Flux reads `k8s/rendered/` from `main` over public HTTPS. It is generated
by catenix from `k8s/components/*.nix` (see `k8s/default.nix`), and its layout
matches `nix run .#k8s-render`.

- **Pull request:** a stale `k8s/rendered/` is not an error. The job summary
  shows a `--stat` of what would change, plus a notice, and the render is
  attached as the `k8s-rendered` artifact. To include it in the PR anyway,
  run `nix run .#k8s-render`.
- **Push to main:** `publish-rendered` checks out `main`, swaps in the
  artifact, and commits it as `github-actions[bot]` with
  `k8s: re-render k8s/rendered [skip ci]`. If `main` has moved and the newer
  commits change render inputs (`k8s/` excluding `k8s/rendered`, `cluster/`,
  `pkgs/`, `lib/`, `flake.*`), it skips, because their own run publishes. If
  the push is rejected, it rebases and retries up to 3 times.
- Commits pushed with `GITHUB_TOKEN` don't trigger workflows, and
  `[skip ci]` makes that explicit, so there is no loop.
- If branch protection on `main` requires PRs or status checks, allow
  `github-actions[bot]` to bypass it. Otherwise the push fails and you need
  to run `nix run .#k8s-render` by hand.

## Secrets guard

The guard scans only the diff: the PR's merge-base to head, or on a push,
`before..after` (falling back to `HEAD~1`). It fails on two kinds of finding.

- **Added or modified files whose basename** is `*-key.pem`, `*.key`,
  `kubeconfig`, `kubeconfig.*`, `*.kubeconfig`, `*-kubeconfig` or
  `*_kubeconfig`. `.nix` and `.md` files are exempt, so a module or doc
  *about* kubeconfigs can exist.
- **Added lines** that contain a lowercase `password` followed by optional
  spaces and an equals sign, a PEM private-key header, or a kubeconfig
  client-key field. Lines whose first non-blank character is `#` or `//` are
  skipped, so comments and docs can name the pattern. `hashedPassword` and
  `hashedPasswordFile` never match, because the match is case-sensitive.

The guard prints only `file:line` as a GitHub annotation, never the matching
text. The rendered manifests get the same private-key check before upload.

All key material lives under `/var/lib/kubernetes/secrets/` on the hosts,
and the CA key stays on the operator machine (`docs/pki.md`). Keep
`cluster-pki`'s output directory (`pki-out/`) git-ignored.

The guard is diff-only on purpose. The repo already contains older plaintext
credentials in `hosts/Miniserver` and `hosts/Pestilence`, and they only trip
the guard when those lines are edited. Rotate them and move them out of git
separately.

## Pinned actions

Every action is pinned by full commit SHA. The tag is noted in a comment.
Each SHA was resolved with `git ls-remote` and is a lightweight tag on a
commit. Each release was at least 2 weeks old on 2026-10-31.

| Action | Tag | SHA |
| --- | --- | --- |
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| cachix/install-nix-action | v31.11.2 | `448cde739abec1eaf0646249e3d25bb8d9bc7702` |
| actions/upload-artifact | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| actions/download-artifact | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |

To bump an action, resolve the new tag with
`git ls-remote https://github.com/<owner>/<repo> refs/tags/<tag> refs/tags/<tag>^{}`.
Use the `^{}` line if one exists, because that is the commit an annotated
tag points to. Then re-run actionlint.

## Running the same checks locally

```sh
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint
nix flake check --keep-going
for h in c4130 r440 m2mini; do
  nix eval --raw --option allow-import-from-derivation false \
    ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath"; echo
done
nix build .#k8s-manifests && nix run .#k8s-render -- --check
```

New files must be `git add`ed before Nix can see them.

## catenix: proposed CI

catenix (`github:charlie-horse/catenix`) has no CI yet, and we cannot push
to it. This patch adds `.github/workflows/ci.yml` with three jobs:

- **check:** runs `nix flake check -L --keep-going` on x86_64-linux and
  aarch64-linux (native arm runner). This runs `checks.<system>.nix-unit`
  (the system-agnostic suites) and the eval-time per-system suites.
- **render-examples:** runs `nix run .#render -- examples/<name>.nix` for
  each example. It fails if a document lacks `apiVersion`/`kind`, and
  uploads the YAML as an artifact.
- **format:** runs `nix fmt -- --check` (nixfmt) over the tracked `.nix`
  files.

The patch was verified locally against catenix `5a7507c` (main) on x86_64:

- `nix flake check -L --keep-going` passed all checks (507/507 nix-unit
  cases), in under a minute with a warm nixpkgs.
- The render loop gave basic: 3 objects, crd: 1, helm: 46.
- nixfmt `--check` was clean.
- actionlint was clean.

Apply it in a catenix checkout:

```sh
git switch -c ci
git apply ci.patch     # the block below, saved as ci.patch
git add .github/workflows/ci.yml && git commit -m "ci: flake check + renders"
```

```diff
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
new file mode 100644
index 0000000..cdbe799
--- /dev/null
+++ b/.github/workflows/ci.yml
@@ -0,0 +1,88 @@
+# catenix CI: flake checks (nix-unit + eval-time suites) and example renders.
+name: ci
+
+on:
+  push:
+    branches: [main]
+  pull_request:
+  workflow_dispatch:
+
+permissions:
+  contents: read
+
+concurrency:
+  group: ci-${{ github.ref }}
+  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
+
+jobs:
+  check:
+    name: nix flake check (${{ matrix.system }})
+    runs-on: ${{ matrix.runner }}
+    timeout-minutes: 60
+    strategy:
+      fail-fast: false
+      matrix:
+        include:
+          - system: x86_64-linux
+            runner: ubuntu-24.04
+          - system: aarch64-linux
+            runner: ubuntu-24.04-arm
+    steps:
+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          persist-credentials: false
+      - uses: cachix/install-nix-action@448cde739abec1eaf0646249e3d25bb8d9bc7702 # v31.11.2
+        with:
+          github_access_token: ${{ secrets.GITHUB_TOKEN }}
+      # Only the runner's own system: checks.<system> runs nix-unit and the
+      # eval-time suites (they build `helm template` / yaml2json via IFD).
+      - run: nix flake check -L --keep-going
+
+  render-examples:
+    name: render examples/
+    runs-on: ubuntu-24.04
+    timeout-minutes: 30
+    steps:
+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          persist-credentials: false
+      - uses: cachix/install-nix-action@448cde739abec1eaf0646249e3d25bb8d9bc7702 # v31.11.2
+        with:
+          github_access_token: ${{ secrets.GITHUB_TOKEN }}
+      - name: nix run .#render -- examples/<name>.nix
+        run: |
+          set -euo pipefail
+          mkdir -p rendered
+          for f in examples/*.nix; do
+            name=$(basename "$f" .nix)
+            echo "::group::$name"
+            nix run .#render -- "$f" > "rendered/$name.yaml"
+            # Every document must parse and carry apiVersion + kind.
+            bad=$(nix run nixpkgs#yq-go -- -N \
+              'select(. != null) | select(.apiVersion == null or .kind == null)
+                | document_index' "rendered/$name.yaml")
+            if [ -n "$bad" ]; then
+              echo "::error::$name: documents without apiVersion/kind: $bad"
+              exit 1
+            fi
+            echo "$name: $(grep -c '^kind:' "rendered/$name.yaml") objects"
+            echo "::endgroup::"
+          done
+      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
+        with:
+          name: rendered-examples
+          path: rendered/
+          retention-days: 7
+
+  format:
+    name: nixfmt
+    runs-on: ubuntu-24.04
+    timeout-minutes: 10
+    steps:
+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          persist-credentials: false
+      - uses: cachix/install-nix-action@448cde739abec1eaf0646249e3d25bb8d9bc7702 # v31.11.2
+        with:
+          github_access_token: ${{ secrets.GITHUB_TOKEN }}
+      - run: git ls-files -z '*.nix' | xargs -0 nix fmt -- --check
diff --git a/err.txt b/err.txt
new file mode 100644
index 0000000..66fc7a1
--- /dev/null
+++ b/err.txt
@@ -0,0 +1,118 @@
+warning: Git tree '/tmp/claude-0/-home-user-1Cat-vLLM/039e6515-c12e-5610-9144-870c6732250b/scratchpad/catenix' is dirty
+copying path '/nix/store/zc9xvdvz642n6q20m04ixm30s98m6281-source' from 'https://cache.nixos.org'...
+this derivation will be built:
+  /nix/store/ipwd4f083ra93zxha87qh04cid7rjb90-catenix-render.drv
+these 50 paths will be fetched (30.0 MiB download, 107.6 MiB unpacked):
+  /nix/store/5wlji4631gs4gczzm40bkqrvkb36n1sg-ShellCheck-0.11.0
+  /nix/store/bvqkbbpv0kyspw39v3by6b0cflgfsf9q-acl-2.4.0
+  /nix/store/dy7rlj1ja9s51gnm20h3f56mv424p8fs-attr-2.6.0
+  /nix/store/svx59425zxp552p2b8gm11qj5r09b56i-bash-5.3p15
+  /nix/store/xhgd6rb4h8ssid9yw8nvw74cwq69md5y-brotli-1.2.0-lib
+  /nix/store/l509wk1p0c5sh0i4pvfd9d018pzmjnd8-bzip2-1.0.8
+  /nix/store/j3yz0ag9j442229n8harpmp9aa5qyvhn-bzip2-1.0.8-bin
+  /nix/store/xjl7p8dvyk2j53kqf7f43kdj4ypbxz7g-coreutils-9.11
+  /nix/store/s21axjr25zw6x9g6ripn7kamgbvw0y69-curl-8.22.0
+  /nix/store/b8xvzgd52jby5dfpi0pf46nisy6wma5d-diffutils-3.12
+  /nix/store/x3z8l9qvz5s1c74vfnnpcckzjrvkdasf-ed-1.22.6
+  /nix/store/dyxcy223n2jch1kdf35wxcc39qmz8if5-elfutils-0.195
+  /nix/store/fv9yl55hkskpc2cj9c0sdyq91car9kgl-file-5.48
+  /nix/store/i9wgqa0l88aprvpwfaq5hkfa6pklhlv0-findutils-4.11.0
+  /nix/store/9zib1q94gka8i5q530364cvy25504qz5-gawk-5.4.1
+  /nix/store/604gsr59rj7dzd0nrhp143rpvf7gyiaz-gcc-15.3.0-lib
+  /nix/store/wkiqjb44n5k0fwhmc523dvflspd47q3b-gcc-15.3.0-libgcc
+  /nix/store/lm3pknxi0ipypy3lxh1wmm8wvvavdwrn-glibc-2.42-84
+  /nix/store/jxd26cx6cgbjzal3mzw0vcv8pqdbh0bb-gmp-with-cxx-6.3.0
+  /nix/store/yfrd1ghcyk23shcgd84ya18axiwf5j5m-gmp-with-cxx-6.3.0
+  /nix/store/n8k0wza75nmrx08civlj29h26scx2fjh-gnu-config-2024-01-01
+  /nix/store/xmvbzzxm5snla5a2cyfhm7hjy9bifx7n-gnugrep-3.12
+  /nix/store/c011mk580m964s1zxjccvdax3fcmppnl-gnumake-4.4.1
+  /nix/store/qf2wzyq4irhgyhnq3s2hz0ldjq3w8a3x-gnused-4.10
+  /nix/store/41l3h8s1lr518n03bsrzv5vsf37bhnb9-gnutar-1.35
+  /nix/store/l5sll8nxk70p73l5yqbsjy4mh0c3g0v5-gzip-1.14
+  /nix/store/ajry3r6v263xy5jcj8vksnyqjq0m4wak-json-c-0.18
+  /nix/store/pk03s7pvpzgfhvlk4z9yz69yzn2l8iw9-keyutils-1.6.3-lib
+  /nix/store/rc2xaqhj62ny8xbsqdm77234l9azlchr-krb5-1.22.2-lib
+  /nix/store/3r5wfb1dl3sfknvy1yringvmap0hxj4r-libffi-3.8.0
+  /nix/store/i3jw341xs88r6wxf1j22rjx1mmd8cfjw-libidn2-2.3.8
+  /nix/store/02z9zb3m53l02vp51khji7pbhw8jl08r-libpsl-0.21.5
+  /nix/store/4h71n85xzg7382wmy03v2dp879iczkjk-libssh2-1.11.1
+  /nix/store/bv3lx708clpz3m6zbd5742np4dlry0yj-libunistring-1.4.2
+  /nix/store/6avzrsm02jh7q48ym3hgznj3ypc2shc2-nghttp2-1.70.0-lib
+  /nix/store/dki4fkk75v2x4aqkszmi257wxq6rkkyr-nghttp3-1.16.0
+  /nix/store/2hc131frgdz45bjbajmpvlrj185lah7p-ngtcp2-1.23.0
+  /nix/store/fcnnn4w7sxx96liivqdsm1alwyh9x00d-numactl-2.0.18
+  /nix/store/yj34vymbqf7mf4lmffipy8jqc4kwr1mc-openssl-3.6.4
+  /nix/store/81zqbas7qc02yfdj7142fdcqhxgd3cgz-patch-2.8
+  /nix/store/h9wq5kdv1jc9hxmwgn9vh9bwsigmnsj6-patchelf-0.15.2
+  /nix/store/6vqahj875znq0wlsy1bg926yki3d5m4r-pcre2-10.48
+  /nix/store/xmx3lhqr6r8zlqjmx7nbfwcd95mymhmf-publicsuffix-list-0-unstable-2026-09-02
+  /nix/store/c29a7xzhhv8nk62w1gls6f6jj8zihggv-stdenv-linux-no-cc
+  /nix/store/rjri54xd29c5qfwj124j62ffzjjigjmh-update-autotools-gnu-config-scripts-hook
+  /nix/store/m07syxhld8hpprrdmzq565ziia6vlw9l-xgcc-15.3.0-libgcc
+  /nix/store/cjippm7n89ac2z3rxdghns4p02s6g09m-xz-5.8.3
+  /nix/store/518dig8gpvqyac6pkksyjjfzvi9zn8vq-xz-5.8.3-bin
+  /nix/store/lw86vj9kfwgvlivg3p8qg2nibpmhmsl9-zlib-1.3.2
+  /nix/store/8ik1d1r4l2jzm9mjh6bc0a13yczx62wg-zstd-1.5.7
+copying path '/nix/store/n8k0wza75nmrx08civlj29h26scx2fjh-gnu-config-2024-01-01' from 'https://cache.nixos.org'...
+copying path '/nix/store/m07syxhld8hpprrdmzq565ziia6vlw9l-xgcc-15.3.0-libgcc' from 'https://cache.nixos.org'...
+copying path '/nix/store/wkiqjb44n5k0fwhmc523dvflspd47q3b-gcc-15.3.0-libgcc' from 'https://cache.nixos.org'...
+copying path '/nix/store/bv3lx708clpz3m6zbd5742np4dlry0yj-libunistring-1.4.2' from 'https://cache.nixos.org'...
+copying path '/nix/store/xmx3lhqr6r8zlqjmx7nbfwcd95mymhmf-publicsuffix-list-0-unstable-2026-09-02' from 'https://cache.nixos.org'...
+copying path '/nix/store/rjri54xd29c5qfwj124j62ffzjjigjmh-update-autotools-gnu-config-scripts-hook' from 'https://cache.nixos.org'...
+copying path '/nix/store/i3jw341xs88r6wxf1j22rjx1mmd8cfjw-libidn2-2.3.8' from 'https://cache.nixos.org'...
+copying path '/nix/store/lm3pknxi0ipypy3lxh1wmm8wvvavdwrn-glibc-2.42-84' from 'https://cache.nixos.org'...
+copying path '/nix/store/bvqkbbpv0kyspw39v3by6b0cflgfsf9q-acl-2.4.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/svx59425zxp552p2b8gm11qj5r09b56i-bash-5.3p15' from 'https://cache.nixos.org'...
+copying path '/nix/store/dy7rlj1ja9s51gnm20h3f56mv424p8fs-attr-2.6.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/x3z8l9qvz5s1c74vfnnpcckzjrvkdasf-ed-1.22.6' from 'https://cache.nixos.org'...
+copying path '/nix/store/xhgd6rb4h8ssid9yw8nvw74cwq69md5y-brotli-1.2.0-lib' from 'https://cache.nixos.org'...
+copying path '/nix/store/l509wk1p0c5sh0i4pvfd9d018pzmjnd8-bzip2-1.0.8' from 'https://cache.nixos.org'...
+copying path '/nix/store/604gsr59rj7dzd0nrhp143rpvf7gyiaz-gcc-15.3.0-lib' from 'https://cache.nixos.org'...
+copying path '/nix/store/02z9zb3m53l02vp51khji7pbhw8jl08r-libpsl-0.21.5' from 'https://cache.nixos.org'...
+copying path '/nix/store/l5sll8nxk70p73l5yqbsjy4mh0c3g0v5-gzip-1.14' from 'https://cache.nixos.org'...
+copying path '/nix/store/c011mk580m964s1zxjccvdax3fcmppnl-gnumake-4.4.1' from 'https://cache.nixos.org'...
+copying path '/nix/store/qf2wzyq4irhgyhnq3s2hz0ldjq3w8a3x-gnused-4.10' from 'https://cache.nixos.org'...
+copying path '/nix/store/ajry3r6v263xy5jcj8vksnyqjq0m4wak-json-c-0.18' from 'https://cache.nixos.org'...
+copying path '/nix/store/pk03s7pvpzgfhvlk4z9yz69yzn2l8iw9-keyutils-1.6.3-lib' from 'https://cache.nixos.org'...
+copying path '/nix/store/6avzrsm02jh7q48ym3hgznj3ypc2shc2-nghttp2-1.70.0-lib' from 'https://cache.nixos.org'...
+copying path '/nix/store/3r5wfb1dl3sfknvy1yringvmap0hxj4r-libffi-3.8.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/9zib1q94gka8i5q530364cvy25504qz5-gawk-5.4.1' from 'https://cache.nixos.org'...
+copying path '/nix/store/dki4fkk75v2x4aqkszmi257wxq6rkkyr-nghttp3-1.16.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/yj34vymbqf7mf4lmffipy8jqc4kwr1mc-openssl-3.6.4' from 'https://cache.nixos.org'...
+copying path '/nix/store/81zqbas7qc02yfdj7142fdcqhxgd3cgz-patch-2.8' from 'https://cache.nixos.org'...
+copying path '/nix/store/41l3h8s1lr518n03bsrzv5vsf37bhnb9-gnutar-1.35' from 'https://cache.nixos.org'...
+copying path '/nix/store/6vqahj875znq0wlsy1bg926yki3d5m4r-pcre2-10.48' from 'https://cache.nixos.org'...
+copying path '/nix/store/cjippm7n89ac2z3rxdghns4p02s6g09m-xz-5.8.3' from 'https://cache.nixos.org'...
+copying path '/nix/store/lw86vj9kfwgvlivg3p8qg2nibpmhmsl9-zlib-1.3.2' from 'https://cache.nixos.org'...
+copying path '/nix/store/j3yz0ag9j442229n8harpmp9aa5qyvhn-bzip2-1.0.8-bin' from 'https://cache.nixos.org'...
+copying path '/nix/store/jxd26cx6cgbjzal3mzw0vcv8pqdbh0bb-gmp-with-cxx-6.3.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/fcnnn4w7sxx96liivqdsm1alwyh9x00d-numactl-2.0.18' from 'https://cache.nixos.org'...
+copying path '/nix/store/h9wq5kdv1jc9hxmwgn9vh9bwsigmnsj6-patchelf-0.15.2' from 'https://cache.nixos.org'...
+copying path '/nix/store/yfrd1ghcyk23shcgd84ya18axiwf5j5m-gmp-with-cxx-6.3.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/8ik1d1r4l2jzm9mjh6bc0a13yczx62wg-zstd-1.5.7' from 'https://cache.nixos.org'...
+copying path '/nix/store/2hc131frgdz45bjbajmpvlrj185lah7p-ngtcp2-1.23.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/rc2xaqhj62ny8xbsqdm77234l9azlchr-krb5-1.22.2-lib' from 'https://cache.nixos.org'...
+copying path '/nix/store/fv9yl55hkskpc2cj9c0sdyq91car9kgl-file-5.48' from 'https://cache.nixos.org'...
+copying path '/nix/store/4h71n85xzg7382wmy03v2dp879iczkjk-libssh2-1.11.1' from 'https://cache.nixos.org'...
+copying path '/nix/store/xjl7p8dvyk2j53kqf7f43kdj4ypbxz7g-coreutils-9.11' from 'https://cache.nixos.org'...
+copying path '/nix/store/xmvbzzxm5snla5a2cyfhm7hjy9bifx7n-gnugrep-3.12' from 'https://cache.nixos.org'...
+copying path '/nix/store/518dig8gpvqyac6pkksyjjfzvi9zn8vq-xz-5.8.3-bin' from 'https://cache.nixos.org'...
+copying path '/nix/store/s21axjr25zw6x9g6ripn7kamgbvw0y69-curl-8.22.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/dyxcy223n2jch1kdf35wxcc39qmz8if5-elfutils-0.195' from 'https://cache.nixos.org'...
+copying path '/nix/store/b8xvzgd52jby5dfpi0pf46nisy6wma5d-diffutils-3.12' from 'https://cache.nixos.org'...
+copying path '/nix/store/i9wgqa0l88aprvpwfaq5hkfa6pklhlv0-findutils-4.11.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/5wlji4631gs4gczzm40bkqrvkb36n1sg-ShellCheck-0.11.0' from 'https://cache.nixos.org'...
+copying path '/nix/store/c29a7xzhhv8nk62w1gls6f6jj8zihggv-stdenv-linux-no-cc' from 'https://cache.nixos.org'...
+building '/nix/store/ipwd4f083ra93zxha87qh04cid7rjb90-catenix-render.drv'...
+this derivation will be built:
+  /nix/store/2awfdq98f1rrr9zipxm5mnzlsjn3x9mc-manifests.yaml.drv
+these 4 paths will be fetched (5.8 MiB download, 17.0 MiB unpacked):
+  /nix/store/9v00p4m9cdzn23gmy5m9d3a6c3gfwhl7-iana-etc-20251215
+  /nix/store/549nkjs10xhma2f9kx3rxw61kym0abjx-mailcap-2.1.54
+  /nix/store/fh8svr4ds87z84iarfnxrlfpjlbmc816-tzdata-2026c
+  /nix/store/wnh2xakcycx328c14s9dvpwq2diyg8hf-yq-go-4.53.3
+copying path '/nix/store/9v00p4m9cdzn23gmy5m9d3a6c3gfwhl7-iana-etc-20251215' from 'https://cache.nixos.org'...
+copying path '/nix/store/549nkjs10xhma2f9kx3rxw61kym0abjx-mailcap-2.1.54' from 'https://cache.nixos.org'...
+copying path '/nix/store/fh8svr4ds87z84iarfnxrlfpjlbmc816-tzdata-2026c' from 'https://cache.nixos.org'...
+copying path '/nix/store/wnh2xakcycx328c14s9dvpwq2diyg8hf-yq-go-4.53.3' from 'https://cache.nixos.org'...
+building '/nix/store/2awfdq98f1rrr9zipxm5mnzlsjn3x9mc-manifests.yaml.drv'...
```

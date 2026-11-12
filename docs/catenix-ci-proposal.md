# catenix: proposed CI

Moved out of `docs/ci.md`: a proposal for the catenix repository
(github:charlie-horse/catenix), which this repository cannot push to. The
patch used to also add an `err.txt` (a build log pasted in by mistake);
that hunk is removed.

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
```

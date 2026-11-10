#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/aio-watch-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fixture="$work/repo"
mkdir -p "$fixture/vm" "$fixture/tests"
cp "$repo_root/deploy.sh" "$repo_root/destroy.sh" "$repo_root/README.md" "$fixture/"
cp "$repo_root/vm/cloud-init-aio.tmpl.yaml" "$fixture/vm/"
cp "$repo_root/tests/test-quickstart.sh" "$fixture/tests/"

awk '
  { sub(/\r$/, "") }
  /^      - name: Run static lab-rot checks$/ { target = 1; next }
  target && /^        run: \|$/ { capture = 1; next }
  capture && /^      - name:/ { exit }
  capture { sub(/^          /, ""); print; found = 1 }
  END { if (!found) exit 1 }
' "$repo_root/.github/workflows/lab-rot-watch.yml" > "$work/watch.sh"

run_watcher() (
  cd "$fixture"
  GITHUB_OUTPUT="$work/github-output.txt" bash "$work/watch.sh" > "$work/watch.log" 2>&1 || {
    cat "$work/watch.log" >&2
    fail "The static watcher failed to run."
  }
)

run_watcher
if grep -Eq 'Remote manifest appears to use mutable image tag latest|Simulator manifest pin verification failed' "$fixture/findings.txt"; then
  fail "The watcher must scan the successfully pinned simulator image."
fi
if grep -Eq 'Azure CLI extension add (is not version-pinned|uses --upgrade|allows preview)' "$fixture/findings.txt"; then
  fail "The watcher must not flag an explicitly version-pinned extension upgrade."
fi
if grep -Fq 'apt-get install packages are not version-pinned' "$fixture/findings.txt"; then
  fail "The watcher must recognize the documented Ubuntu utility exceptions."
fi

sed -e 's|mcr.microsoft.com/iotedge/opc-plc@sha256:fa926a6fc4a58d77abe034c8483d91e91aa768c5a50ea3f5d86e45b66d955486|mcr.microsoft.com/iotedge/opc-plc:latest|' \
  -e 's/--name connectedk8s --version 1.11.6 --upgrade/--name connectedk8s --upgrade --allow-preview True/' \
  -e 's/apt-get install -y curl/apt-get install -y unapproved-package curl/' \
  "$fixture/vm/cloud-init-aio.tmpl.yaml" > "$work/unpinned.yaml"
mv "$work/unpinned.yaml" "$fixture/vm/cloud-init-aio.tmpl.yaml"

run_watcher
grep -Fq 'Simulator manifest pin verification failed' "$fixture/findings.txt" ||
  fail "The watcher must report an invalid simulator override."
grep -Fq 'Remote manifest appears to use mutable image tag latest' "$fixture/findings.txt" ||
  fail "The watcher must report the mutable upstream image when the override fails."
grep -Fq 'Azure CLI extension add is not version-pinned' "$fixture/findings.txt" ||
  fail "The watcher must report an unpinned extension."
grep -Fq 'Azure CLI extension add uses --upgrade' "$fixture/findings.txt" ||
  fail "The watcher must report an unpinned extension upgrade."
grep -Fq 'Azure CLI extension add allows preview' "$fixture/findings.txt" ||
  fail "The watcher must report preview-enabled extension installs."
grep -Fq 'apt-get install packages are not version-pinned: unapproved-package' "$fixture/findings.txt" ||
  fail "The watcher must report new unpinned Ubuntu packages."

echo "Lab-rot watcher checks passed."

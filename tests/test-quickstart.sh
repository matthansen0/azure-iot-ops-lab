#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/vm/cloud-init-aio.tmpl.yaml"
work="$(mktemp -d "${TMPDIR:-/tmp}/aio-quickstart-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

export_manifest=""
if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && "$1" == "--export-applied-manifest" && -n "$2" ]] ||
    fail "Usage: $0 [--export-applied-manifest <path>]"
  export_manifest="$2"
fi

for script in "$repo_root/deploy.sh" "$repo_root/destroy.sh"; do
  bash -n "$script"
done
awk '
  /^  - path: \/usr\/local\/bin\/aio-install.sh$/ { found = 1; next }
  found && /^    content: \|$/ { script = 1; next }
  script && /^runcmd:/ { exit }
  script { sub(/^      /, ""); print }
  END { if (!script) exit 1 }
' "$template" > "$work/install.sh"
bash -n "$work/install.sh"

mapfile -t extension_installs < <(grep '^az extension add ' "$work/install.sh")
[[ "${#extension_installs[@]}" -eq 4 ]] || fail "Expected four explicit Azure CLI extension installs."
for install in "${extension_installs[@]}"; do
  [[ "$install" =~ --version[[:space:]]+[0-9] ]] || fail "An Azure CLI extension is not version-pinned."
  [[ "$install" != *"--allow-preview True"* ]] || fail "Preview extensions must not be enabled."
done

manifest_url="$(grep -oE 'https://raw\.githubusercontent\.com/Azure-Samples/explore-iot-operations/[0-9a-f]{40}/samples/quickstarts/opc-plc-deployment\.yaml' "$template")" ||
  fail "The simulator manifest must use an immutable sample revision."
bicep_url="$(grep -oE 'https://raw\.githubusercontent\.com/Azure-Samples/explore-iot-operations/[0-9a-f]{40}/samples/quickstarts/quickstart\.bicep' "$template")" ||
  fail "The quickstart Bicep must use an immutable sample revision."
helm_url="$(grep -oE 'https://raw\.githubusercontent\.com/helm/helm/[0-9a-f]{40}/scripts/get-helm-3' "$template")" ||
  fail "The Helm installer must use an immutable revision."
helm_checksum="$(grep 'sha256sum --check' "$work/install.sh" | grep -oE '[0-9a-f]{64}')" ||
  fail "The Helm installer must have a pinned checksum."
[[ "$(cut -d/ -f6 <<< "$manifest_url")" == "$(cut -d/ -f6 <<< "$bicep_url")" ]] ||
  fail "The sample manifest and Bicep must use the same revision."

curl --fail --location --silent --show-error --retry 3 --connect-timeout 10 --max-time 120 \
  "$manifest_url" --output "$work/upstream-manifest.yaml"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 10 --max-time 120 \
  "$bicep_url" --output "$work/upstream-quickstart.bicep"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 10 --max-time 120 \
  "$helm_url" --output "$work/upstream-helm.sh"
printf '%s  %s\n' "$helm_checksum" "$work/upstream-helm.sh" | sha256sum --check --status ||
  fail "The pinned Helm installer checksum does not match."

awk '
  /^# Simulator \+ quickstart Bicep$/ { capture = 1 }
  capture { print }
  capture && /^log "All done\."$/ { complete = 1; exit }
  END { if (!complete) exit 1 }
' "$work/install.sh" > "$work/quickstart.sh"

mkdir "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    https://*) url="$1"; shift ;;
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  */opc-plc-deployment.yaml)
    [[ "${TEST_FAIL_DOWNLOAD:-}" != manifest ]] || exit 22
    cp "$TEST_MANIFEST" "$output"
    ;;
  */quickstart.bicep)
    [[ "${TEST_FAIL_DOWNLOAD:-}" != bicep ]] || exit 22
    cp "$TEST_BICEP" "$output"
    ;;
  *) echo "Unexpected download: $url" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == apply && "$2" == -f ]] || exit 1
cp "$3" "$TEST_APPLIED_MANIFEST"
EOF
cat > "$work/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}:${3:-}" in
  k8s-extension:list:*) echo test-extension ;;
  iot:ops:list)
    if [[ "$*" == *extendedLocation.name* ]]; then
      echo /subscriptions/test/resourceGroups/test/providers/Microsoft.ExtendedLocation/customLocations/test-location
    else
      echo test-instance
    fi
    ;;
  deployment:group:create) printf '%s\n' "$@" > "$TEST_DEPLOY_ARGS" ;;
  *) echo "Unexpected Azure CLI command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/curl" "$work/bin/kubectl" "$work/bin/az"

export TEST_BICEP="$work/upstream-quickstart.bicep"
export TEST_MANIFEST="$work/upstream-manifest.yaml"
export TEST_APPLIED_MANIFEST="$work/applied.yaml"
export TEST_DEPLOY_ARGS="$work/deploy-args.txt"

run_quickstart() {
  PATH="$work/bin:$PATH" TMPDIR="$work" \
    CLUSTER_NAME=test-cluster OPS_RG=test-rg AIO_NAMESPACE_NAME=test-namespace \
    bash -euo pipefail -c '
      log() { :; }
      cleanup() {
        if [[ -n "${OPC_MANIFEST:-}" ]]; then rm -f -- "$OPC_MANIFEST"; fi
        if [[ -n "${QUICKSTART_BICEP:-}" ]]; then rm -f -- "$QUICKSTART_BICEP"; fi
      }
      trap cleanup EXIT
      source "$1"
    ' _ "$work/quickstart.sh"
}

run_quickstart
grep -Fq 'image: mcr.microsoft.com/iotedge/opc-plc@sha256:fa926a6fc4a58d77abe034c8483d91e91aa768c5a50ea3f5d86e45b66d955486' "$TEST_APPLIED_MANIFEST" ||
  fail "The applied simulator manifest must use the pinned image digest."
if grep -Eq '^[[:space:]]*image:[[:space:]]*[^[:space:]]*:latest([[:space:]]|$)' "$TEST_APPLIED_MANIFEST"; then
  fail "The applied simulator manifest still contains a latest image."
fi

declared="$(awk '$1 == "param" { print $2 }' "$TEST_BICEP")"
required="$(awk '$1 == "param" && $0 !~ /=/ { print $2 }' "$TEST_BICEP")"
supplied="$(grep -E '^[A-Za-z][A-Za-z0-9]*=' "$TEST_DEPLOY_ARGS" | cut -d= -f1)"
while IFS= read -r name; do
  grep -Fxq "$name" <<< "$declared" || fail "Unexpected Bicep parameter: $name"
done <<< "$supplied"
while IFS= read -r name; do
  grep -Fxq "$name" <<< "$supplied" || fail "Missing required Bicep parameter: $name"
done <<< "$required"
grep -Fxq 'adrNamespaceName=test-namespace' "$TEST_DEPLOY_ARGS" ||
  fail "The namespace was not passed to the expected Bicep parameter."

sed 's|mcr.microsoft.com/iotedge/opc-plc:latest|unexpected-image:v1|' \
  "$work/upstream-manifest.yaml" > "$work/unexpected-manifest.yaml"
export TEST_MANIFEST="$work/unexpected-manifest.yaml"
rm -f -- "$TEST_APPLIED_MANIFEST" "$TEST_DEPLOY_ARGS"
if run_quickstart > "$work/unexpected.log" 2>&1; then
  fail "An unexpected simulator image must stop the deployment."
fi
[[ ! -e "$TEST_APPLIED_MANIFEST" && ! -e "$TEST_DEPLOY_ARGS" ]] ||
  fail "An unexpected simulator image must fail before applying resources."

export TEST_MANIFEST="$work/upstream-manifest.yaml"
export TEST_FAIL_DOWNLOAD=manifest
if run_quickstart > "$work/download.log" 2>&1; then
  fail "A failed manifest download must stop the deployment."
fi
[[ ! -e "$TEST_APPLIED_MANIFEST" && ! -e "$TEST_DEPLOY_ARGS" ]] ||
  fail "A failed download must fail before applying resources."

export TEST_FAIL_DOWNLOAD=bicep
if run_quickstart > "$work/bicep-download.log" 2>&1; then
  fail "A failed Bicep download must stop the deployment."
fi
[[ -e "$TEST_APPLIED_MANIFEST" && ! -e "$TEST_DEPLOY_ARGS" ]] ||
  fail "A failed Bicep download must not create the deployment."

if [[ -n "$export_manifest" ]]; then
  cp -- "$TEST_APPLIED_MANIFEST" "$export_manifest"
fi

echo "Quickstart contract and failure-path checks passed."

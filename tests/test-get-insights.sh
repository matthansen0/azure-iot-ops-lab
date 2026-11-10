#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/get-insights.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/aio-fabric-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for these tests."
for file in "$repo_root/deploy.sh" "$repo_root/destroy.sh" "$script"; do
  bash -n "$file"
done
bash "$script" --help > /dev/null

mkdir "$work/bin"
cat > "$work/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG"
case "${1:-}:${2:-}:${3:-}:${4:-}" in
  rest:*)
    [[ "${TEST_FAIL_REST:-0}" != 1 ]] || { echo "Fabric access denied" >&2; exit 1; }
    cat "$TEST_WORKSPACE"
    ;;
  identity:show:*) cat "$TEST_IDENTITY" ;;
  account:show:*) echo aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee ;;
  iot:ops:show:*) ;;
  iot:ops:identity:assign)
    [[ "${TEST_FAIL_ASSIGN:-0}" != 1 ]] || { echo "Identity assignment failed" >&2; exit 1; }
    ;;
  iot:ops:dataflow:endpoint)
    [[ "${TEST_FAIL_ENDPOINT:-0}" != 1 ]] || { echo "Endpoint creation failed" >&2; exit 1; }
    ;;
  iot:ops:dataflow:apply)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --config-file ]]; then
        cp "$2" "$TEST_CONFIG"
        printf '%s\n' "$2" > "$TEST_CONFIG_PATH"
        break
      fi
      shift
    done
    ;;
  *) echo "Unexpected Azure CLI command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/az"

export TEST_LOG="$work/az.log"
export TEST_CONFIG="$work/dataflow.json"
export TEST_CONFIG_PATH="$work/config-path.txt"
export TEST_WORKSPACE="$work/workspace.json"
export TEST_IDENTITY="$work/identity.json"
export FABRIC_WORKSPACE_ID="11111111-2222-4333-8444-555555555555"
export FABRIC_BOOTSTRAP_SERVER="example.servicebus.windows.net:9093"
export FABRIC_TOPIC="es_example-topic"
export DATAFLOW_SOURCE_TOPIC='factory/"quoted"/temperature'
printf '%s\n' '{"id":"11111111-2222-4333-8444-555555555555","type":"Workspace","capacityId":"capacity-id"}' > "$TEST_WORKSPACE"
printf '%s\n' '{"id":"/subscriptions/test/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-mi","clientId":"22222222-3333-4444-8555-666666666666"}' > "$TEST_IDENTITY"

run_script() {
  PATH="$work/bin:$PATH" TMPDIR="$work" FABRIC_MI_NAME=test-mi \
    bash "$script" test-rg
}

reset_results() {
  : > "$TEST_LOG"
  rm -f -- "$TEST_CONFIG" "$TEST_CONFIG_PATH"
}

reset_results
run_script > "$work/success.log"
grep -Fq 'rest --method get --url https://api.fabric.microsoft.com/v1/workspaces/11111111-2222-4333-8444-555555555555' "$TEST_LOG" ||
  fail "The existing workspace was not validated through the Fabric API."
grep -Fq 'iot ops identity assign --name aio-k3s-instance --resource-group test-rg' "$TEST_LOG" ||
  fail "The dataflow identity was not assigned."
grep -Fq -- '--usage dataflow' "$TEST_LOG" || fail "The identity usage must be dataflow."
grep -Fq 'iot ops dataflow endpoint create fabric-realtime' "$TEST_LOG" ||
  fail "The Fabric Real-Time Intelligence endpoint was not created."
grep -Fq -- '--host example.servicebus.windows.net:9093 --auth-type UserAssignedManagedIdentity' "$TEST_LOG" ||
  fail "The Fabric endpoint did not receive the supplied host and identity authentication."
grep -Fq -- '--client-id 22222222-3333-4444-8555-666666666666 --tenant-id aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' "$TEST_LOG" ||
  fail "The Fabric endpoint did not receive the managed identity and tenant IDs."
grep -Fq 'iot ops dataflow apply' "$TEST_LOG" || fail "The data flow was not applied."
if grep -Fq 'Microsoft.Fabric/workspaces' "$TEST_LOG"; then
  fail "The script must not use an ARM workspace resource."
fi
jq -e --arg source "$DATAFLOW_SOURCE_TOPIC" --arg topic "$FABRIC_TOPIC" '
  .mode == "Enabled" and
  (.operations | length == 2) and
  .operations[0].operationType == "Source" and
  .operations[0].sourceSettings.endpointRef == "default" and
  .operations[0].sourceSettings.dataSources == [$source] and
  .operations[1].operationType == "Destination" and
  .operations[1].destinationSettings.endpointRef == "fabric-rti-endpoint" and
  .operations[1].destinationSettings.dataDestination == $topic
' "$TEST_CONFIG" > /dev/null || fail "The generated dataflow configuration is incorrect."
[[ ! -e "$(cat "$TEST_CONFIG_PATH")" ]] || fail "The temporary dataflow configuration was not removed."

reset_results
DATAFLOW_SOURCE_TOPIC='' run_script > "$work/default-topic.log"
jq -e '.operations[0].sourceSettings.dataSources == ["azure-iot-operations/data/oven"]' "$TEST_CONFIG" > /dev/null ||
  fail "The default dataflow source topic is incorrect."

reset_results
FABRIC_ENDPOINT_NAME=custom-endpoint DATAFLOW_NAME=custom-flow DATAFLOW_PROFILE=custom-profile \
  run_script > "$work/overrides.log"
grep -Fq -- '--instance aio-k3s-instance --name custom-endpoint' "$TEST_LOG" ||
  fail "The endpoint name override was not used."
grep -Fq -- '--profile custom-profile --name custom-flow' "$TEST_LOG" ||
  fail "The dataflow name or profile override was not used."
jq -e '.operations[1].destinationSettings.endpointRef == "custom-endpoint"' "$TEST_CONFIG" > /dev/null ||
  fail "The generated configuration did not use the endpoint override."

reset_results
if FABRIC_WORKSPACE_ID=invalid run_script > "$work/invalid.log" 2>&1; then
  fail "An invalid workspace ID must fail."
fi
[[ ! -s "$TEST_LOG" ]] || fail "An invalid workspace ID must fail before Azure calls."

reset_results
if FABRIC_TOPIC='' run_script > "$work/topic.log" 2>&1; then
  fail "A missing eventstream topic must fail."
fi
[[ ! -s "$TEST_LOG" ]] || fail "A missing topic must fail before Azure calls."

reset_results
if FABRIC_BOOTSTRAP_SERVER=example.servicebus.windows.net:70000 run_script > "$work/port.log" 2>&1; then
  fail "An invalid bootstrap port must fail."
fi
[[ ! -s "$TEST_LOG" ]] || fail "An invalid bootstrap port must fail before Azure calls."

reset_results
if TEST_FAIL_REST=1 run_script > "$work/rest.log" 2>&1; then
  fail "An inaccessible workspace must fail."
fi
if grep -Fq 'iot ops identity assign' "$TEST_LOG"; then
  fail "An inaccessible workspace must fail before modifying the AIO instance."
fi

reset_results
printf '%s\n' '{"id":"11111111-2222-4333-8444-555555555555","type":"Workspace"}' > "$TEST_WORKSPACE"
if run_script > "$work/capacity.log" 2>&1; then
  fail "A workspace without capacity must fail."
fi
if grep -Fq 'iot ops identity assign' "$TEST_LOG"; then
  fail "A workspace without capacity must fail before modifying the AIO instance."
fi

reset_results
printf '%s\n' '{"id":"11111111-2222-4333-8444-555555555555","type":"PersonalGroup","capacityId":"capacity-id"}' > "$TEST_WORKSPACE"
if run_script > "$work/personal.log" 2>&1; then
  fail "A personal Fabric workspace must fail."
fi
if grep -Fq 'iot ops identity assign' "$TEST_LOG"; then
  fail "A personal workspace must fail before modifying the AIO instance."
fi

reset_results
printf '%s\n' '{"id":"99999999-2222-4333-8444-555555555555","type":"Workspace","capacityId":"capacity-id"}' > "$TEST_WORKSPACE"
if run_script > "$work/mismatch.log" 2>&1; then
  fail "A mismatched workspace response must fail."
fi
if grep -Fq 'identity show' "$TEST_LOG"; then
  fail "A mismatched workspace response must fail before identity lookup."
fi

reset_results
printf '%s\n' '{"id":"11111111-2222-4333-8444-555555555555","type":"Workspace","capacityId":"capacity-id"}' > "$TEST_WORKSPACE"
if TEST_FAIL_ASSIGN=1 run_script > "$work/assign.log" 2>&1; then
  fail "A failed identity assignment must fail the script."
fi
if grep -Fq 'iot ops dataflow endpoint create' "$TEST_LOG"; then
  fail "A failed identity assignment must not create the endpoint."
fi

reset_results
if TEST_FAIL_ENDPOINT=1 run_script > "$work/endpoint.log" 2>&1; then
  fail "A failed endpoint creation must fail the script."
fi
if grep -Fq 'iot ops dataflow apply' "$TEST_LOG"; then
  fail "A failed endpoint creation must not apply the data flow."
fi

echo "Fabric preflight and dataflow checks passed."

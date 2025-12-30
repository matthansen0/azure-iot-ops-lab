#!/usr/bin/env bash
# test-fabric-integration.sh - Comprehensive test suite for Fabric API integration
# Run this script to validate the Fabric API functions before deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fabric-api.sh"

# Test configuration
TEST_PREFIX="aio-test-$(date +%s)"
TEST_WORKSPACE_NAME="${TEST_PREFIX}-workspace"
TEST_EVENTHOUSE_NAME="${TEST_PREFIX}-eventhouse"
TEST_DATABASE_NAME="${TEST_PREFIX}-db"
TEST_EVENTSTREAM_NAME="${TEST_PREFIX}-eventstream"

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CLEANUP_ITEMS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test utilities
run_test() {
    local test_name="$1"
    local test_func="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}TEST $TESTS_RUN: $test_name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if $test_func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓ PASSED: $test_name${NC}"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗ FAILED: $test_name${NC}"
        return 1
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $message${NC}"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"
    
    if [[ -n "$value" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $message${NC}"
        return 1
    fi
}

assert_http_success() {
    local http_code="$1"
    local message="${2:-HTTP request should succeed}"
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $message (HTTP $http_code)${NC}"
        return 1
    fi
}

# ============================================================================
# UNIT TESTS
# ============================================================================

test_get_fabric_token() {
    local token
    token=$(get_fabric_token 2>/dev/null) || {
        echo "Could not get token - ensure you are logged in with 'az login'"
        return 1
    }
    
    assert_not_empty "$token" "Token should not be empty"
    
    # Token should be a JWT (has 3 parts separated by dots)
    local parts
    parts=$(echo "$token" | tr '.' '\n' | wc -l)
    if [[ $parts -lt 3 ]]; then
        echo "Token does not appear to be a valid JWT"
        return 1
    fi
    
    # Store for other tests
    FABRIC_TOKEN="$token"
    return 0
}

test_validate_fabric_token() {
    if [[ -z "${FABRIC_TOKEN:-}" ]]; then
        FABRIC_TOKEN=$(get_fabric_token) || return 1
    fi
    
    validate_fabric_token "$FABRIC_TOKEN"
}

test_list_workspaces() {
    if [[ -z "${FABRIC_TOKEN:-}" ]]; then
        FABRIC_TOKEN=$(get_fabric_token) || return 1
    fi
    
    local response
    response=$(curl -s -w "\n%{http_code}" -X GET "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $FABRIC_TOKEN" \
        -H "Content-Type: application/json")
    
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    assert_http_success "$http_code" "List workspaces API call"
    
    # Should have a 'value' array (even if empty)
    local has_value
    has_value=$(echo "$body" | jq 'has("value")' 2>/dev/null || echo "false")
    assert_equals "true" "$has_value" "Response should have 'value' array"
}

# ============================================================================
# INTEGRATION TESTS (creates resources)
# ============================================================================

test_create_workspace() {
    if [[ -z "${FABRIC_TOKEN:-}" ]]; then
        FABRIC_TOKEN=$(get_fabric_token) || return 1
    fi
    
    echo "Creating test workspace: $TEST_WORKSPACE_NAME"
    TEST_WORKSPACE_ID=$(create_fabric_workspace "$FABRIC_TOKEN" "$TEST_WORKSPACE_NAME") || return 1
    
    assert_not_empty "$TEST_WORKSPACE_ID" "Workspace ID should be returned"
    CLEANUP_ITEMS+=("workspace:$TEST_WORKSPACE_ID")
    
    # Verify workspace exists
    local retrieved_id
    retrieved_id=$(get_workspace_by_name "$FABRIC_TOKEN" "$TEST_WORKSPACE_NAME")
    assert_equals "$TEST_WORKSPACE_ID" "$retrieved_id" "Retrieved workspace ID should match"
}

test_create_eventhouse() {
    if [[ -z "${TEST_WORKSPACE_ID:-}" ]]; then
        echo "Skipping - no workspace available"
        return 1
    fi
    
    echo "Creating test Eventhouse: $TEST_EVENTHOUSE_NAME"
    TEST_EVENTHOUSE_ID=$(create_eventhouse "$FABRIC_TOKEN" "$TEST_WORKSPACE_ID" "$TEST_EVENTHOUSE_NAME") || return 1
    
    assert_not_empty "$TEST_EVENTHOUSE_ID" "Eventhouse ID should be returned"
    
    # Verify Eventhouse exists
    local retrieved_id
    retrieved_id=$(get_item_by_name "$FABRIC_TOKEN" "$TEST_WORKSPACE_ID" "$TEST_EVENTHOUSE_NAME" "Eventhouse")
    assert_equals "$TEST_EVENTHOUSE_ID" "$retrieved_id" "Retrieved Eventhouse ID should match"
}

test_create_kql_database() {
    if [[ -z "${TEST_WORKSPACE_ID:-}" || -z "${TEST_EVENTHOUSE_ID:-}" ]]; then
        echo "Skipping - no workspace or Eventhouse available"
        return 1
    fi
    
    echo "Creating test KQL Database: $TEST_DATABASE_NAME"
    TEST_DATABASE_ID=$(create_kql_database "$FABRIC_TOKEN" "$TEST_WORKSPACE_ID" "$TEST_DATABASE_NAME" "$TEST_EVENTHOUSE_ID") || return 1
    
    assert_not_empty "$TEST_DATABASE_ID" "Database ID should be returned"
    
    # Verify database exists
    local retrieved_id
    retrieved_id=$(get_item_by_name "$FABRIC_TOKEN" "$TEST_WORKSPACE_ID" "$TEST_DATABASE_NAME" "KQLDatabase")
    assert_equals "$TEST_DATABASE_ID" "$retrieved_id" "Retrieved Database ID should match"
}

test_create_eventstream() {
    if [[ -z "${TEST_WORKSPACE_ID:-}" ]]; then
        echo "Skipping - no workspace available"
        return 1
    fi
    
    echo "Creating test Eventstream: $TEST_EVENTSTREAM_NAME"
    TEST_EVENTSTREAM_ID=$(create_eventstream "$FABRIC_TOKEN" "$TEST_WORKSPACE_ID" "$TEST_EVENTSTREAM_NAME") || return 1
    
    assert_not_empty "$TEST_EVENTSTREAM_ID" "Eventstream ID should be returned"
    
    # Verify Eventstream exists
    local retrieved_id
    retrieved_id=$(get_item_by_name "$FABRIC_TOKEN" "$TEST_WORKSPACE_ID" "$TEST_EVENTSTREAM_NAME" "Eventstream")
    assert_equals "$TEST_EVENTSTREAM_ID" "$retrieved_id" "Retrieved Eventstream ID should match"
}

test_idempotent_workspace_creation() {
    if [[ -z "${TEST_WORKSPACE_ID:-}" ]]; then
        echo "Skipping - no workspace available"
        return 1
    fi
    
    echo "Testing idempotent workspace creation..."
    local second_id
    second_id=$(create_fabric_workspace "$FABRIC_TOKEN" "$TEST_WORKSPACE_NAME") || return 1
    
    assert_equals "$TEST_WORKSPACE_ID" "$second_id" "Second creation should return same ID"
}

test_workspace_items_list() {
    if [[ -z "${TEST_WORKSPACE_ID:-}" ]]; then
        echo "Skipping - no workspace available"
        return 1
    fi
    
    echo "Listing items in test workspace..."
    local response
    response=$(curl -s -X GET \
        "${FABRIC_API_BASE}/workspaces/${TEST_WORKSPACE_ID}/items" \
        -H "Authorization: Bearer $FABRIC_TOKEN" \
        -H "Content-Type: application/json")
    
    local item_count
    item_count=$(echo "$response" | jq '.value | length' 2>/dev/null || echo "0")
    
    echo "Found $item_count items in workspace"
    
    # Should have at least the items we created
    if [[ $item_count -ge 1 ]]; then
        echo "$response" | jq '.value[] | {displayName, type, id}' 2>/dev/null
        return 0
    else
        echo "Expected at least 1 item"
        return 1
    fi
}

# ============================================================================
# CLEANUP
# ============================================================================

cleanup_test_resources() {
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}CLEANUP: Removing test resources${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    for item in "${CLEANUP_ITEMS[@]}"; do
        local type="${item%%:*}"
        local id="${item#*:}"
        
        case "$type" in
            workspace)
                echo "Deleting workspace: $id"
                delete_fabric_workspace "$FABRIC_TOKEN" "$id" || \
                    echo -e "${YELLOW}Warning: Could not delete workspace $id${NC}"
                ;;
        esac
    done
}

# ============================================================================
# TEST RUNNER
# ============================================================================

print_summary() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                         TEST SUMMARY${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Total tests:  $TESTS_RUN"
    echo -e "  ${GREEN}Passed:       $TESTS_PASSED${NC}"
    echo -e "  ${RED}Failed:       $TESTS_FAILED${NC}"
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        return 1
    fi
}

run_unit_tests() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                        UNIT TESTS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    
    run_test "Get Fabric API Token" test_get_fabric_token || true
    run_test "Validate Fabric Token" test_validate_fabric_token || true
    run_test "List Workspaces API" test_list_workspaces || true
}

run_integration_tests() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                     INTEGRATION TESTS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    
    run_test "Create Fabric Workspace" test_create_workspace || true
    run_test "Idempotent Workspace Creation" test_idempotent_workspace_creation || true
    run_test "Create Eventhouse" test_create_eventhouse || true
    run_test "Create KQL Database" test_create_kql_database || true
    run_test "Create Eventstream" test_create_eventstream || true
    run_test "List Workspace Items" test_workspace_items_list || true
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║          Fabric API Integration Test Suite                            ║"
    echo "║          Azure IoT Operations Lab                                     ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    local test_type="${1:-all}"
    local skip_cleanup="${2:-false}"
    
    trap cleanup_test_resources EXIT
    
    case "$test_type" in
        unit)
            run_unit_tests
            ;;
        integration)
            run_unit_tests
            run_integration_tests
            ;;
        all)
            run_unit_tests
            run_integration_tests
            ;;
        *)
            echo "Usage: $0 {unit|integration|all} [skip-cleanup]"
            echo ""
            echo "Test types:"
            echo "  unit        - Run unit tests only (no resources created)"
            echo "  integration - Run unit + integration tests (creates test resources)"
            echo "  all         - Run all tests (default)"
            echo ""
            echo "Options:"
            echo "  skip-cleanup - Don't delete test resources after tests"
            exit 1
            ;;
    esac
    
    if [[ "$skip_cleanup" == "skip-cleanup" ]]; then
        trap - EXIT
        echo -e "\n${YELLOW}Skipping cleanup - test resources remain:${NC}"
        for item in "${CLEANUP_ITEMS[@]}"; do
            echo "  - $item"
        done
    fi
    
    print_summary
}

main "$@"

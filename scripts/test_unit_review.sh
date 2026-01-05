#!/usr/bin/env bash
#
# Unit tests: Review feature core functions (bd-obd9)
#
# Covers:
# - parse_graphql_work_items
# - calculate_item_priority_score
# - validate_review_plan
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "parse_graphql_work_items"
source_ru_function "calculate_item_priority_score"
source_ru_function "validate_review_plan"
source_ru_function "ensure_dir"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "get_review_state_dir"

# Required global for state locking (normally set in ru)
STATE_LOCK_FD=201

# Mock logging (avoid noisy output on error paths)
log_error() { :; }
log_warn() { :; }
log_info() { :; }

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

require_flock_or_skip() {
    if ! command -v flock &>/dev/null; then
        skip_test "flock not installed"
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# parse_graphql_work_items
#------------------------------------------------------------------------------

test_parse_graphql_work_items_filters_archived_and_fork() {
    local test_name="parse_graphql_work_items: filters archived/fork"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local fixture="$PROJECT_DIR/test/fixtures/gh/graphql_batch.json"
    assert_file_exists "$fixture" "Fixture should exist"

    local output
    output=$(parse_graphql_work_items "$(cat "$fixture")")

    assert_contains "$output" $'octo/repo1\tissue\t42' "Includes issue from non-archived repo"
    assert_contains "$output" $'octo/repo1\tpr\t7' "Includes PR from non-archived repo"
    assert_not_contains "$output" "octo/archived" "Archived repo excluded"
    assert_not_contains "$output" "octo/forked" "Forked repo excluded"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# calculate_item_priority_score
#------------------------------------------------------------------------------

test_calculate_item_priority_score_components() {
    local test_name="calculate_item_priority_score: label/age/recency"
    log_test_start "$test_name"

    # Mock days_since_timestamp for deterministic scoring
    days_since_timestamp() {
        case "$1" in
            created) echo 40 ;;
            updated) echo 2 ;;
            *) echo 0 ;;
        esac
    }

    # No recent review
    item_recently_reviewed() { return 1; }

    local score
    score=$(calculate_item_priority_score "pr" "bug" "created" "updated" "false" "octo/repo1" "42")

    # Expected: PR 20 + bug label 30 + age 30 + recency 15 = 95
    assert_equals "95" "$score" "Score should include all components"

    log_test_pass "$test_name"
}

test_calculate_item_priority_score_recent_review_penalty() {
    local test_name="calculate_item_priority_score: recent review penalty"
    log_test_start "$test_name"

    days_since_timestamp() {
        case "$1" in
            created) echo 10 ;;
            updated) echo 1 ;;
            *) echo 0 ;;
        esac
    }

    # Recently reviewed
    item_recently_reviewed() { return 0; }

    local score
    score=$(calculate_item_priority_score "issue" "bug" "created" "updated" "false" "octo/repo1" "7")

    # Base issue 10 + bug label 30 + recency 15 - staleness 20 = 35
    assert_equals "35" "$score" "Score should include recent-review penalty"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# validate_review_plan
#------------------------------------------------------------------------------

test_validate_review_plan_accepts_valid() {
    local test_name="validate_review_plan: accepts valid plan"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)

    local plan_file="$env_root/valid-plan.json"
    cat > "$plan_file" <<'PLAN_EOF'
{
  "schema_version": 1,
  "repo": "octo/repo1",
  "items": [
    {"type": "issue", "number": 42, "decision": "fix"}
  ],
  "questions": [
    {"id": "q1", "prompt": "Apply?", "answered": false}
  ],
  "gh_actions": [
    {"op": "comment", "target": "issue#42"}
  ]
}
PLAN_EOF

    local result
    result=$(validate_review_plan "$plan_file")
    assert_equals "Valid" "$result" "Valid plan should pass"

    log_test_pass "$test_name"
}

test_validate_review_plan_rejects_missing_fields() {
    local test_name="validate_review_plan: rejects missing fields"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)

    local plan_file="$env_root/invalid-plan.json"
    cat > "$plan_file" <<'PLAN_EOF'
{
  "schema_version": 1,
  "items": []
}
PLAN_EOF

    local result
    result=$(validate_review_plan "$plan_file")

    assert_contains "$result" "Missing required fields" "Missing repo should be rejected"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# State persistence: locking + atomic write
#------------------------------------------------------------------------------

test_write_json_atomic_with_lock() {
    local test_name="write_json_atomic: writes JSON under lock"
    log_test_start "$test_name"

    require_jq_or_skip || return 0
    require_flock_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru"

    local state_dir
    state_dir=$(get_review_state_dir)
    local out_file="$state_dir/test-state.json"

    local payload='{"ok":true,"count":3}'

    assert_exit_code 0 "write_json_atomic should succeed" with_state_lock write_json_atomic "$out_file" "$payload"
    assert_file_exists "$out_file" "State file should exist"
    assert_equals "true" "$(jq -r '.ok' "$out_file")" "JSON content should be written"

    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

run_test test_parse_graphql_work_items_filters_archived_and_fork
run_test test_calculate_item_priority_score_components
run_test test_calculate_item_priority_score_recent_review_penalty
run_test test_validate_review_plan_accepts_valid
run_test test_validate_review_plan_rejects_missing_fields
run_test test_write_json_atomic_with_lock

print_results
exit $?

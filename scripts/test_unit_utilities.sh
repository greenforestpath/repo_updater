#!/usr/bin/env bash
#
# Unit tests: Core utilities (ensure_dir, json_escape, write_result)
#
# Tests the fundamental utility functions used throughout ru.
# Uses the test framework for assertions and isolation.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source ru to get access to the functions we're testing
# We need to source it in a way that doesn't run main()
# The functions are defined before the main execution block
source "$PROJECT_DIR/ru" --source-only 2>/dev/null || {
    # If --source-only isn't supported, extract functions manually
    # by sourcing up to line where main execution starts
    eval "$(sed -n '1,/^# SECTION 13:/p' "$PROJECT_DIR/ru" | head -n -1)"
}

#==============================================================================
# Tests: ensure_dir
#==============================================================================

test_ensure_dir_creates_directory() {
    log_test_start "ensure_dir creates non-existent directory"
    local test_env
    test_env=$(create_test_env)

    local new_dir="$test_env/testdir"

    # Directory should not exist initially
    assert_dir_not_exists "$new_dir" "Directory should not exist before ensure_dir"

    # Create it
    ensure_dir "$new_dir"

    # Now it should exist
    assert_dir_exists "$new_dir" "Directory should exist after ensure_dir"

    log_test_pass
}

test_ensure_dir_noop_existing() {
    log_test_start "ensure_dir is no-op for existing directory"
    local test_env
    test_env=$(create_test_env)

    local existing_dir="$test_env/existing"
    mkdir -p "$existing_dir"

    # Create a marker file to verify directory isn't recreated
    echo "marker" > "$existing_dir/marker.txt"

    # ensure_dir should be a no-op
    ensure_dir "$existing_dir"

    # Marker file should still exist
    assert_file_exists "$existing_dir/marker.txt" "Marker file should still exist"

    log_test_pass
}

test_ensure_dir_creates_nested() {
    log_test_start "ensure_dir creates nested directories"
    local test_env
    test_env=$(create_test_env)

    local nested_dir="$test_env/a/b/c/d"

    # None of the parent directories exist
    assert_dir_not_exists "$test_env/a" "Parent directory should not exist"

    # Create the nested structure
    ensure_dir "$nested_dir"

    # All levels should now exist
    assert_dir_exists "$test_env/a" "First level should exist"
    assert_dir_exists "$test_env/a/b" "Second level should exist"
    assert_dir_exists "$test_env/a/b/c" "Third level should exist"
    assert_dir_exists "$nested_dir" "Final level should exist"

    log_test_pass
}

#==============================================================================
# Tests: json_escape
#==============================================================================

test_json_escape_backslash() {
    log_test_start "json_escape escapes backslashes"

    local result
    result=$(json_escape 'path\to\file')

    assert_equals 'path\\to\\file' "$result" "Backslashes should be escaped"

    log_test_pass
}

test_json_escape_double_quote() {
    log_test_start "json_escape escapes double quotes"

    local result
    result=$(json_escape 'say "hello"')

    assert_equals 'say \"hello\"' "$result" "Double quotes should be escaped"

    log_test_pass
}

test_json_escape_newline() {
    log_test_start "json_escape escapes newlines"

    local input=$'line1\nline2'
    local result
    result=$(json_escape "$input")

    assert_equals 'line1\nline2' "$result" "Newlines should be escaped"

    log_test_pass
}

test_json_escape_carriage_return() {
    log_test_start "json_escape escapes carriage returns"

    local input=$'text\rmore'
    local result
    result=$(json_escape "$input")

    assert_equals 'text\rmore' "$result" "Carriage returns should be escaped"

    log_test_pass
}

test_json_escape_tab() {
    log_test_start "json_escape escapes tabs"

    local input=$'col1\tcol2'
    local result
    result=$(json_escape "$input")

    assert_equals 'col1\tcol2' "$result" "Tabs should be escaped"

    log_test_pass
}

test_json_escape_no_special_chars() {
    log_test_start "json_escape handles strings without special characters"

    local result
    result=$(json_escape 'simple string 123')

    assert_equals 'simple string 123' "$result" "String without special chars should be unchanged"

    log_test_pass
}

test_json_escape_empty_string() {
    log_test_start "json_escape handles empty string"

    local result
    result=$(json_escape '')

    assert_equals '' "$result" "Empty string should remain empty"

    log_test_pass
}

test_json_escape_complex() {
    log_test_start "json_escape handles complex strings with multiple special chars"

    local input=$'file: "test\\path"\nline2'
    local result
    result=$(json_escape "$input")

    # Expected: file: \"test\\path\"\nline2
    assert_equals 'file: \"test\\path\"\nline2' "$result" "Complex string should be properly escaped"

    log_test_pass
}

#==============================================================================
# Tests: write_result
#==============================================================================

test_write_result_creates_valid_json() {
    log_test_start "write_result creates valid NDJSON"
    local test_env
    test_env=$(create_test_env)

    local results_file="$test_env/results.ndjson"
    RESULTS_FILE="$results_file"

    write_result "owner/repo" "clone" "success" "1500" "Cloned successfully" "/path/to/repo"

    # File should exist and contain valid JSON
    assert_file_exists "$results_file" "Results file should be created"

    # Validate JSON structure using jq if available, otherwise grep
    if command -v jq >/dev/null 2>&1; then
        local json_valid
        if jq -e . "$results_file" >/dev/null 2>&1; then
            json_valid=true
        else
            json_valid=false
        fi
        assert_true "$json_valid" "Output should be valid JSON"
    else
        # Fallback: check for expected fields
        assert_file_contains "$results_file" '"repo":"owner/repo"' "Should contain repo field"
        assert_file_contains "$results_file" '"action":"clone"' "Should contain action field"
        assert_file_contains "$results_file" '"status":"success"' "Should contain status field"
    fi

    unset RESULTS_FILE
    log_test_pass
}

test_write_result_includes_all_fields() {
    log_test_start "write_result includes all required fields"
    local test_env
    test_env=$(create_test_env)

    local results_file="$test_env/results.ndjson"
    RESULTS_FILE="$results_file"

    write_result "test/repo" "pull" "updated" "2000" "Updated to abc123" "/home/user/test/repo"

    # Check for all expected fields
    assert_file_contains "$results_file" '"repo":' "Should contain repo field"
    assert_file_contains "$results_file" '"path":' "Should contain path field"
    assert_file_contains "$results_file" '"action":' "Should contain action field"
    assert_file_contains "$results_file" '"status":' "Should contain status field"
    assert_file_contains "$results_file" '"duration":' "Should contain duration field"
    assert_file_contains "$results_file" '"message":' "Should contain message field"
    assert_file_contains "$results_file" '"timestamp":' "Should contain timestamp field"

    unset RESULTS_FILE
    log_test_pass
}

test_write_result_escapes_special_chars() {
    log_test_start "write_result escapes special characters"
    local test_env
    test_env=$(create_test_env)

    local results_file="$test_env/results.ndjson"
    RESULTS_FILE="$results_file"

    # Use a message with special characters
    write_result "owner/repo" "clone" "failed" "0" 'Error: "file not found"' "/path/to/repo"

    # The output should have escaped quotes
    assert_file_contains "$results_file" '\"file not found\"' "Quotes in message should be escaped"

    unset RESULTS_FILE
    log_test_pass
}

test_write_result_handles_missing_optional() {
    log_test_start "write_result handles missing optional parameters"
    local test_env
    test_env=$(create_test_env)

    local results_file="$test_env/results.ndjson"
    RESULTS_FILE="$results_file"

    # Call with only required parameters
    write_result "owner/repo" "clone" "success"

    # File should still be created with defaults
    assert_file_exists "$results_file" "Results file should be created"
    assert_file_contains "$results_file" '"duration":0' "Duration should default to 0"

    unset RESULTS_FILE
    log_test_pass
}

test_write_result_noop_without_results_file() {
    log_test_start "write_result is no-op when RESULTS_FILE is unset"
    local test_env
    test_env=$(create_test_env)

    # Ensure RESULTS_FILE is unset
    unset RESULTS_FILE

    # This should not error or create any files
    local output
    if output=$(write_result "owner/repo" "clone" "success" 2>&1); then
        # Should succeed silently
        assert_true "true" "write_result should not error when RESULTS_FILE is unset"
    else
        log_test_fail "write_result should not fail when RESULTS_FILE is unset"
        return 1
    fi

    log_test_pass
}

test_write_result_appends_multiple() {
    log_test_start "write_result appends multiple results"
    local test_env
    test_env=$(create_test_env)

    local results_file="$test_env/results.ndjson"
    RESULTS_FILE="$results_file"

    # Write multiple results
    write_result "repo1" "clone" "success" "1000" "" ""
    write_result "repo2" "pull" "updated" "500" "" ""
    write_result "repo3" "clone" "failed" "0" "Network error" ""

    # Count lines (each result should be one line)
    local line_count
    line_count=$(wc -l < "$results_file")

    assert_equals "3" "$line_count" "Should have 3 result lines"

    unset RESULTS_FILE
    log_test_pass
}

test_write_result_includes_timestamp() {
    log_test_start "write_result includes ISO timestamp"
    local test_env
    test_env=$(create_test_env)

    local results_file="$test_env/results.ndjson"
    RESULTS_FILE="$results_file"

    write_result "owner/repo" "clone" "success" "100" "" ""

    # Timestamp should be in ISO format: YYYY-MM-DDTHH:MM:SSZ
    if command -v jq >/dev/null 2>&1; then
        local timestamp
        timestamp=$(jq -r '.timestamp' "$results_file")
        # Check format with regex
        if [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
            assert_true "true" "Timestamp should be in ISO format"
        else
            log_test_fail "Timestamp format invalid: $timestamp"
            return 1
        fi
    else
        # Fallback: just check timestamp field exists
        assert_file_contains "$results_file" '"timestamp":"' "Should contain timestamp field"
    fi

    unset RESULTS_FILE
    log_test_pass
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Core utilities"
echo "============================================"
echo ""

# ensure_dir tests
run_test test_ensure_dir_creates_directory
run_test test_ensure_dir_noop_existing
run_test test_ensure_dir_creates_nested

# json_escape tests
run_test test_json_escape_backslash
run_test test_json_escape_double_quote
run_test test_json_escape_newline
run_test test_json_escape_carriage_return
run_test test_json_escape_tab
run_test test_json_escape_no_special_chars
run_test test_json_escape_empty_string
run_test test_json_escape_complex

# write_result tests
run_test test_write_result_creates_valid_json
run_test test_write_result_includes_all_fields
run_test test_write_result_escapes_special_chars
run_test test_write_result_handles_missing_optional
run_test test_write_result_noop_without_results_file
run_test test_write_result_appends_multiple
run_test test_write_result_includes_timestamp

echo ""
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"

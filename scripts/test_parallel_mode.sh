#!/usr/bin/env bash
#
# Tests: Parallel mode and rate limiting (bd-0ac9)
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

# Source ru functions needed by these tests (if present)
source_ru_function "dir_lock_acquire"
source_ru_function "dir_lock_release"
source_ru_function "json_get_field"
source_ru_function "agent_sweep_backoff_trigger"
source_ru_function "agent_sweep_backoff_wait_if_needed"
source_ru_function "run_parallel_agent_sweep"

# Mock logging to keep test output clean
log_verbose() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

require_function() {
    local func_name="$1"
    if ! declare -f "$func_name" >/dev/null; then
        skip_test "missing function: $func_name"
        return 1
    fi
    return 0
}

setup_parallel_env() {
    local env_root
    env_root=$(create_test_env)
    export AGENT_SWEEP_STATE_DIR="$env_root/state/ru/agent-sweep"
    mkdir -p "$AGENT_SWEEP_STATE_DIR/locks"
}

test_dir_lock_acquire_release() {
    local test_name="dir_lock_acquire/dir_lock_release: basic lock cycle"
    log_test_start "$test_name"

    if ! require_function "dir_lock_acquire"; then
        return 0
    fi
    if ! require_function "dir_lock_release"; then
        return 0
    fi

    local lock_dir
    lock_dir="$(create_temp_dir)/queue.lock"

    assert_success "acquire lock" dir_lock_acquire "$lock_dir" 1
    assert_true "lock directory created" "[[ -d \"$lock_dir\" ]]"
    assert_success "release lock" dir_lock_release "$lock_dir"
    assert_false "lock directory removed" "[[ -d \"$lock_dir\" ]]"

    log_test_pass "$test_name"
}

test_dir_lock_contention_timeout() {
    local test_name="dir_lock_acquire: times out when lock held"
    log_test_start "$test_name"

    if ! require_function "dir_lock_acquire"; then
        return 0
    fi
    if ! require_function "dir_lock_release"; then
        return 0
    fi

    local lock_dir
    lock_dir="$(create_temp_dir)/queue.lock"
    mkdir -p "$lock_dir"
    printf '%s:%s\n' "$$" "$(date +%s)" > "$lock_dir/owner"

    assert_fails "acquire lock while held" dir_lock_acquire "$lock_dir" 1
    assert_success "release held lock" dir_lock_release "$lock_dir"

    log_test_pass "$test_name"
}

test_dir_lock_stale_cleanup() {
    local test_name="dir_lock_acquire: cleans stale lock"
    log_test_start "$test_name"

    if ! require_function "dir_lock_acquire"; then
        return 0
    fi
    if ! require_function "dir_lock_release"; then
        return 0
    fi

    local lock_dir
    lock_dir="$(create_temp_dir)/queue.lock"
    mkdir -p "$lock_dir"
    printf '%s:%s\n' "99999" "$(( $(date +%s) - 400 ))" > "$lock_dir/owner"

    assert_success "acquire lock after stale cleanup" dir_lock_acquire "$lock_dir" 1
    assert_true "lock directory exists" "[[ -d \"$lock_dir\" ]]"
    assert_success "release lock" dir_lock_release "$lock_dir"

    log_test_pass "$test_name"
}

test_backoff_trigger_creates_state() {
    local test_name="agent_sweep_backoff_trigger: writes backoff state"
    log_test_start "$test_name"

    if ! require_function "agent_sweep_backoff_trigger"; then
        return 0
    fi
    if ! require_function "json_get_field"; then
        return 0
    fi

    setup_parallel_env

    agent_sweep_backoff_trigger "rate_limited" 1

    local state_file="$AGENT_SWEEP_STATE_DIR/backoff.state"
    assert_true "backoff state file created" "[[ -f \"$state_file\" ]]"

    local pause_until
    pause_until=$(json_get_field "$(cat "$state_file")" "pause_until" 2>/dev/null || echo 0)
    assert_true "pause_until is set" "[[ \"$pause_until\" -gt 0 ]]"

    log_test_pass "$test_name"
}

test_backoff_wait_skips_when_expired() {
    local test_name="agent_sweep_backoff_wait_if_needed: no sleep when expired"
    log_test_start "$test_name"

    if ! require_function "agent_sweep_backoff_wait_if_needed"; then
        return 0
    fi

    setup_parallel_env

    local state_file="$AGENT_SWEEP_STATE_DIR/backoff.state"
    cat > "$state_file" <<STATE_EOF
{"reason":"rate_limited","pause_until":0}
STATE_EOF

    local start
    start=$(date +%s)
    agent_sweep_backoff_wait_if_needed
    local end
    end=$(date +%s)

    assert_true "no wait when pause_until expired" "[[ $((end - start)) -lt 2 ]]"

    log_test_pass "$test_name"
}

test_parallel_agent_sweep_requires_function() {
    local test_name="run_parallel_agent_sweep: function exists"
    log_test_start "$test_name"

    if ! declare -f run_parallel_agent_sweep >/dev/null; then
        skip_test "run_parallel_agent_sweep not implemented yet"
        return 0
    fi

    assert_true "run_parallel_agent_sweep is defined" "declare -f run_parallel_agent_sweep >/dev/null"

    log_test_pass "$test_name"
}

# Run tests
setup_cleanup_trap
run_test test_dir_lock_acquire_release
run_test test_dir_lock_contention_timeout
run_test test_dir_lock_stale_cleanup
run_test test_backoff_trigger_creates_state
run_test test_backoff_wait_skips_when_expired
run_test test_parallel_agent_sweep_requires_function
print_results
exit "$(get_exit_code)"

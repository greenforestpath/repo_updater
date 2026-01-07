#!/usr/bin/env bash
#
# Unit tests for repo_preflight_check() and related functions
# Tests all 14 preflight conditions that must pass before agent-sweep
#
# shellcheck disable=SC2034  # Variables are used by sourced functions from ru
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source preflight functions from ru
source <(sed -n '/^repo_preflight_check()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^preflight_skip_reason_message()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^preflight_skip_reason_action()/,/^}/p' "$PROJECT_DIR/ru")

#==============================================================================
# Test Configuration
#==============================================================================

TEMP_DIR=""
PREFLIGHT_SKIP_REASON=""
AGENT_SWEEP_PUSH_STRATEGY=""
AGENT_SWEEP_MAX_UNTRACKED=""

#==============================================================================
# Setup and Teardown
#==============================================================================

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    PREFLIGHT_SKIP_REASON=""
    AGENT_SWEEP_PUSH_STRATEGY=""
    AGENT_SWEEP_MAX_UNTRACKED=""
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Create a valid git repo with proper configuration
# shellcheck disable=SC2120  # Arguments are optional
create_valid_repo() {
    local repo_dir="${1:-$TEMP_DIR/repo}"
    mkdir -p "$repo_dir"

    # Create a bare "remote" first
    local remote_dir="$TEMP_DIR/remote.git"
    git init --bare "$remote_dir" >/dev/null 2>&1
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    # Clone to working directory
    git clone "$remote_dir" "$repo_dir" >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@example.com"
    git -C "$repo_dir" config user.name "Test User"

    # Create initial commit on main
    git -C "$repo_dir" checkout -b main 2>/dev/null || true
    echo "content" > "$repo_dir/file.txt"
    git -C "$repo_dir" add file.txt
    git -C "$repo_dir" commit -m "Initial commit" >/dev/null 2>&1

    # Push to remote and set up tracking
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1

    echo "$repo_dir"
}

#==============================================================================
# Tests for repo_preflight_check()
#==============================================================================

test_preflight_valid_repo() {
    log_test_start "Valid repo should pass all preflight checks"
    setup_test_env

    local repo
    repo=$(create_valid_repo)

    if repo_preflight_check "$repo"; then
        assert_equals "" "$PREFLIGHT_SKIP_REASON" "Skip reason should be empty"
    else
        fail "Valid repo should pass preflight (got: $PREFLIGHT_SKIP_REASON)"
    fi

    cleanup_test_env
}

test_preflight_not_git_repo() {
    log_test_start "Non-git directory should fail preflight"
    setup_test_env

    local not_repo="$TEMP_DIR/not_a_repo"
    mkdir -p "$not_repo"

    if repo_preflight_check "$not_repo"; then
        fail "Non-git directory should fail preflight"
    else
        assert_equals "not_a_git_repo" "$PREFLIGHT_SKIP_REASON" "Should report not_a_git_repo"
    fi

    cleanup_test_env
}

test_preflight_git_email_not_configured() {
    log_test_start "Repo without user.email should fail preflight"
    setup_test_env

    local repo="$TEMP_DIR/repo"
    mkdir -p "$repo"

    # Isolate git config by using a temp home and unsetting global config
    local orig_home="$HOME"
    export HOME="$TEMP_DIR/fake_home"
    mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL="$TEMP_DIR/empty_gitconfig"
    touch "$GIT_CONFIG_GLOBAL"

    git init "$repo" >/dev/null 2>&1
    # Only set name, no email
    git -C "$repo" config user.name "Test"
    # Create an initial commit so we're not on a detached HEAD
    git -C "$repo" checkout -b main 2>/dev/null || true

    # Set push strategy to none to skip upstream check
    AGENT_SWEEP_PUSH_STRATEGY="none"

    if repo_preflight_check "$repo"; then
        fail "Repo without email should fail preflight"
    else
        assert_equals "git_email_not_configured" "$PREFLIGHT_SKIP_REASON" "Should report git_email_not_configured"
    fi

    # Restore environment
    export HOME="$orig_home"
    unset GIT_CONFIG_GLOBAL

    cleanup_test_env
}

test_preflight_git_name_not_configured() {
    log_test_start "Repo without user.name should fail preflight"
    setup_test_env

    local repo="$TEMP_DIR/repo"
    mkdir -p "$repo"

    # Isolate git config by using a temp home and unsetting global config
    local orig_home="$HOME"
    export HOME="$TEMP_DIR/fake_home"
    mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL="$TEMP_DIR/empty_gitconfig"
    touch "$GIT_CONFIG_GLOBAL"

    git init "$repo" >/dev/null 2>&1
    # Only set email, no name
    git -C "$repo" config user.email "test@example.com"
    # Create an initial commit so we're not on a detached HEAD
    git -C "$repo" checkout -b main 2>/dev/null || true

    # Set push strategy to none to skip upstream check
    AGENT_SWEEP_PUSH_STRATEGY="none"

    if repo_preflight_check "$repo"; then
        fail "Repo without name should fail preflight"
    else
        assert_equals "git_name_not_configured" "$PREFLIGHT_SKIP_REASON" "Should report git_name_not_configured"
    fi

    # Restore environment
    export HOME="$orig_home"
    unset GIT_CONFIG_GLOBAL

    cleanup_test_env
}

test_preflight_shallow_clone() {
    log_test_start "Shallow clone should fail preflight"
    setup_test_env

    # Create origin with commits
    local origin="$TEMP_DIR/origin"
    mkdir -p "$origin"
    git init "$origin" >/dev/null 2>&1
    git -C "$origin" config user.email "test@example.com"
    git -C "$origin" config user.name "Test"
    echo "file1" > "$origin/file1.txt"
    git -C "$origin" add . && git -C "$origin" commit -m "commit1" >/dev/null 2>&1
    echo "file2" > "$origin/file2.txt"
    git -C "$origin" add . && git -C "$origin" commit -m "commit2" >/dev/null 2>&1

    # Create shallow clone
    local shallow="$TEMP_DIR/shallow"
    git clone --depth 1 "file://$origin" "$shallow" >/dev/null 2>&1
    git -C "$shallow" config user.email "test@example.com"
    git -C "$shallow" config user.name "Test"

    if [[ ! -f "$shallow/.git/shallow" ]]; then
        skip_test "Test setup failed: not a shallow clone"
        cleanup_test_env
        return
    fi

    if repo_preflight_check "$shallow"; then
        fail "Shallow clone should fail preflight"
    else
        assert_equals "shallow_clone" "$PREFLIGHT_SKIP_REASON" "Should report shallow_clone"
    fi

    cleanup_test_env
}

test_preflight_rebase_in_progress() {
    log_test_start "Repo with rebase in progress should fail preflight"
    setup_test_env

    local repo
    repo=$(create_valid_repo)

    # Simulate rebase in progress by creating marker directory
    mkdir -p "$repo/.git/rebase-merge"

    if repo_preflight_check "$repo"; then
        fail "Repo with rebase in progress should fail preflight"
    else
        assert_equals "rebase_in_progress" "$PREFLIGHT_SKIP_REASON" "Should report rebase_in_progress"
    fi

    cleanup_test_env
}

test_preflight_merge_in_progress() {
    log_test_start "Repo with merge in progress should fail preflight"
    setup_test_env

    local repo
    repo=$(create_valid_repo)

    # Simulate merge in progress by creating marker file
    touch "$repo/.git/MERGE_HEAD"

    if repo_preflight_check "$repo"; then
        fail "Repo with merge in progress should fail preflight"
    else
        assert_equals "merge_in_progress" "$PREFLIGHT_SKIP_REASON" "Should report merge_in_progress"
    fi

    cleanup_test_env
}

test_preflight_cherry_pick_in_progress() {
    log_test_start "Repo with cherry-pick in progress should fail preflight"
    setup_test_env

    local repo
    repo=$(create_valid_repo)

    # Simulate cherry-pick in progress by creating marker file
    touch "$repo/.git/CHERRY_PICK_HEAD"

    if repo_preflight_check "$repo"; then
        fail "Repo with cherry-pick in progress should fail preflight"
    else
        assert_equals "cherry_pick_in_progress" "$PREFLIGHT_SKIP_REASON" "Should report cherry_pick_in_progress"
    fi

    cleanup_test_env
}

test_preflight_detached_head() {
    log_test_start "Repo with detached HEAD should fail preflight"
    setup_test_env

    local repo
    repo=$(create_valid_repo)

    # Detach HEAD
    local commit
    commit=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" checkout "$commit" >/dev/null 2>&1

    if repo_preflight_check "$repo"; then
        fail "Repo with detached HEAD should fail preflight"
    else
        assert_equals "detached_HEAD" "$PREFLIGHT_SKIP_REASON" "Should report detached_HEAD"
    fi

    cleanup_test_env
}

test_preflight_no_upstream_with_push() {
    log_test_start "Repo without upstream should fail when push strategy is set"
    setup_test_env

    local repo="$TEMP_DIR/repo"
    mkdir -p "$repo"
    git init "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" checkout -b main 2>/dev/null || true
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "Initial" >/dev/null 2>&1
    # No remote, no upstream

    AGENT_SWEEP_PUSH_STRATEGY="push"

    if repo_preflight_check "$repo"; then
        fail "Repo without upstream should fail when push is required"
    else
        assert_equals "no_upstream_branch" "$PREFLIGHT_SKIP_REASON" "Should report no_upstream_branch"
    fi

    cleanup_test_env
}

test_preflight_no_upstream_with_none() {
    log_test_start "Repo without upstream should pass when push strategy is none"
    setup_test_env

    local repo="$TEMP_DIR/repo"
    mkdir -p "$repo"
    git init "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" checkout -b main 2>/dev/null || true
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "Initial" >/dev/null 2>&1
    # No remote, no upstream

    AGENT_SWEEP_PUSH_STRATEGY="none"

    if repo_preflight_check "$repo"; then
        assert_equals "" "$PREFLIGHT_SKIP_REASON" "Skip reason should be empty"
    else
        fail "Repo without upstream should pass when push is none (got: $PREFLIGHT_SKIP_REASON)"
    fi

    cleanup_test_env
}

test_preflight_diverged_from_upstream() {
    log_test_start "Diverged repo should fail preflight"
    setup_test_env

    local repo
    repo=$(create_valid_repo)
    local remote_dir="$TEMP_DIR/remote.git"

    # Create commit on remote (simulate upstream changes)
    local temp_clone="$TEMP_DIR/temp_clone"
    git clone "$remote_dir" "$temp_clone" >/dev/null 2>&1
    git -C "$temp_clone" config user.email "other@example.com"
    git -C "$temp_clone" config user.name "Other"
    echo "remote change" >> "$temp_clone/file.txt"
    git -C "$temp_clone" add file.txt
    git -C "$temp_clone" commit -m "Remote commit" >/dev/null 2>&1
    git -C "$temp_clone" push origin main >/dev/null 2>&1

    # Create local commit (diverge)
    echo "local change" > "$repo/local.txt"
    git -C "$repo" add local.txt
    git -C "$repo" commit -m "Local commit" >/dev/null 2>&1

    # Fetch to update tracking refs
    git -C "$repo" fetch origin >/dev/null 2>&1

    if repo_preflight_check "$repo"; then
        fail "Diverged repo should fail preflight"
    else
        assert_equals "diverged_from_upstream" "$PREFLIGHT_SKIP_REASON" "Should report diverged_from_upstream"
    fi

    cleanup_test_env
}

test_preflight_too_many_untracked() {
    log_test_start "Repo with too many untracked files should fail preflight"
    setup_test_env

    local repo
    repo=$(create_valid_repo)

    # Set a low limit for testing
    AGENT_SWEEP_MAX_UNTRACKED=5

    # Create more untracked files than allowed
    for i in {1..10}; do
        echo "untracked $i" > "$repo/untracked_$i.txt"
    done

    if repo_preflight_check "$repo"; then
        fail "Repo with too many untracked files should fail preflight"
    else
        assert_equals "too_many_untracked_files" "$PREFLIGHT_SKIP_REASON" "Should report too_many_untracked_files"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests for helper functions
#==============================================================================

test_preflight_skip_reason_message() {
    log_test_start "Skip reason messages should be human-readable"

    local reasons=(
        "not_a_git_repo"
        "git_email_not_configured"
        "git_name_not_configured"
        "shallow_clone"
        "dirty_submodules"
        "rebase_in_progress"
        "merge_in_progress"
        "cherry_pick_in_progress"
        "detached_HEAD"
        "no_upstream_branch"
        "diverged_from_upstream"
        "unmerged_paths"
        "diff_check_failed"
        "too_many_untracked_files"
    )

    local all_passed=true
    for reason in "${reasons[@]}"; do
        local msg
        msg=$(preflight_skip_reason_message "$reason")
        if [[ -z "$msg" || "$msg" == "Unknown preflight issue: $reason" ]]; then
            log_error "Missing message for reason: $reason"
            all_passed=false
        fi
    done

    if [[ "$all_passed" == "true" ]]; then
        pass "All skip reasons have messages"
    else
        fail "Some skip reasons missing messages"
    fi
}

test_preflight_skip_reason_action() {
    log_test_start "Skip reason actions should be actionable"

    local reasons=(
        "not_a_git_repo"
        "git_email_not_configured"
        "git_name_not_configured"
        "shallow_clone"
        "dirty_submodules"
        "rebase_in_progress"
        "merge_in_progress"
        "cherry_pick_in_progress"
        "detached_HEAD"
        "no_upstream_branch"
        "diverged_from_upstream"
        "unmerged_paths"
        "diff_check_failed"
        "too_many_untracked_files"
    )

    local all_passed=true
    for reason in "${reasons[@]}"; do
        local action
        action=$(preflight_skip_reason_action "$reason")
        if [[ -z "$action" || "$action" == "Investigate and fix the issue" ]]; then
            log_error "Missing action for reason: $reason"
            all_passed=false
        fi
    done

    if [[ "$all_passed" == "true" ]]; then
        pass "All skip reasons have actions"
    else
        fail "Some skip reasons missing actions"
    fi
}

#==============================================================================
# Main Test Runner
#==============================================================================

main() {
    log_suite_start "Preflight Checks"

    # Run all tests
    run_test test_preflight_valid_repo
    run_test test_preflight_not_git_repo
    run_test test_preflight_git_email_not_configured
    run_test test_preflight_git_name_not_configured
    run_test test_preflight_shallow_clone
    run_test test_preflight_rebase_in_progress
    run_test test_preflight_merge_in_progress
    run_test test_preflight_cherry_pick_in_progress
    run_test test_preflight_detached_head
    run_test test_preflight_no_upstream_with_push
    run_test test_preflight_no_upstream_with_none
    run_test test_preflight_diverged_from_upstream
    run_test test_preflight_too_many_untracked
    run_test test_preflight_skip_reason_message
    run_test test_preflight_skip_reason_action

    print_results

    # Exit with appropriate code
    if [[ $TF_TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"

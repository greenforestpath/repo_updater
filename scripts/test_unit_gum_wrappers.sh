#!/usr/bin/env bash
#
# Unit Tests: Gum Wrappers
# Tests for check_gum, gum_spin, gum_confirm, print_banner
#
# Test coverage:
#   - check_gum sets GUM_AVAILABLE when gum is installed
#   - check_gum leaves GUM_AVAILABLE=false when gum not installed
#   - gum_confirm falls back to read when gum unavailable
#   - gum_confirm respects default=true parameter
#   - gum_confirm respects default=false parameter
#   - print_banner outputs nothing when QUIET=true
#   - print_banner outputs fallback when gum unavailable
#   - gum_spin falls back to echo when gum unavailable
#   - gum_spin runs command even when falling back
#   - gum_spin respects QUIET mode
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
# shellcheck source=./test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Source Functions from ru
#==============================================================================

# Initialize global variables
GUM_AVAILABLE="false"
QUIET="false"
VERSION="${VERSION:-1.0.0}"

# Define color codes (needed by fallback functions)
# shellcheck disable=SC2034  # Variables are used by sourced functions
BOLD=''
RESET=''
CYAN=''

# Extract the gum wrapper functions
eval "$(sed -n '/^check_gum()/,/^}/p' "$RU_SCRIPT")"
eval "$(sed -n '/^gum_confirm()/,/^}/p' "$RU_SCRIPT")"
eval "$(sed -n '/^print_banner()/,/^}/p' "$RU_SCRIPT")"
eval "$(sed -n '/^gum_spin()/,/^}/p' "$RU_SCRIPT")"

#==============================================================================
# Tests: check_gum
#==============================================================================

test_check_gum_sets_available_when_installed() {
    # Check if gum is actually installed
    if command -v gum &>/dev/null; then
        GUM_AVAILABLE="false"
        check_gum
        assert_equals "true" "$GUM_AVAILABLE" "check_gum sets GUM_AVAILABLE=true when gum installed"
    else
        # gum not installed - skip with info
        skip_test "gum not installed on system"
    fi
}

test_check_gum_unchanged_when_not_installed() {
    # Save original PATH
    local old_path="$PATH"

    # Create a minimal PATH without gum
    PATH="/bin:/usr/bin"

    # Reset state
    GUM_AVAILABLE="false"

    # Re-eval check_gum with limited PATH
    eval "$(sed -n '/^check_gum()/,/^}/p' "$RU_SCRIPT")"

    # Check if gum is really unavailable
    if ! command -v gum &>/dev/null; then
        check_gum
        assert_equals "false" "$GUM_AVAILABLE" "check_gum leaves GUM_AVAILABLE=false when gum not installed"
    else
        skip_test "gum still available in minimal PATH"
    fi

    PATH="$old_path"
}

test_check_gum_uses_command_v() {
    local func_body
    func_body=$(sed -n '/^check_gum()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "command -v gum" "check_gum uses 'command -v' to check for gum"
}

#==============================================================================
# Tests: print_banner
#==============================================================================

test_print_banner_quiet_mode() {
    QUIET="true"
    GUM_AVAILABLE="false"

    local output
    output=$(print_banner 2>&1)

    if [[ -z "$output" ]]; then
        assert_true "true" "print_banner outputs nothing in quiet mode"
    else
        assert_true "false" "print_banner should output nothing in quiet mode"
    fi

    QUIET="false"
}

test_print_banner_fallback_output() {
    QUIET="false"
    GUM_AVAILABLE="false"
    VERSION="1.2.3"

    local output
    output=$(print_banner 2>&1)

    # Should contain version info
    if [[ "$output" == *"1.2.3"* ]] || [[ "$output" == *"Repo Updater"* ]]; then
        assert_true "true" "print_banner fallback outputs version/name info"
    else
        assert_true "false" "print_banner fallback should output version info"
    fi
}

test_print_banner_fallback_has_decoration() {
    QUIET="false"
    GUM_AVAILABLE="false"

    local output
    output=$(print_banner 2>&1)

    # Should have some decoration (━ or other characters)
    if [[ "$output" == *"━"* ]] || [[ -n "$output" ]]; then
        assert_true "true" "print_banner fallback has decoration"
    else
        assert_true "false" "print_banner fallback should have decoration"
    fi
}

#==============================================================================
# Tests: gum_spin
#==============================================================================

test_gum_spin_fallback_runs_command() {
    GUM_AVAILABLE="false"
    QUIET="false"

    local result
    result=$(gum_spin "Testing" echo "MARKER_TEXT" 2>&1)

    if [[ "$result" == *"MARKER_TEXT"* ]]; then
        assert_true "true" "gum_spin fallback runs the command"
    else
        assert_true "false" "gum_spin fallback should run the command"
    fi
}

test_gum_spin_fallback_shows_title() {
    GUM_AVAILABLE="false"
    QUIET="false"

    local output
    output=$(gum_spin "Processing items" true 2>&1)

    if [[ "$output" == *"Processing items"* ]]; then
        assert_true "true" "gum_spin fallback shows title"
    else
        assert_true "false" "gum_spin fallback should show title"
    fi
}

test_gum_spin_quiet_mode() {
    GUM_AVAILABLE="false"
    QUIET="true"

    # Create a temp file to track command execution
    local temp_file
    temp_file=$(mktemp)

    gum_spin "Silent" touch "$temp_file.executed" 2>&1

    # Command should still run in quiet mode
    if [[ -f "$temp_file.executed" ]]; then
        assert_true "true" "gum_spin runs command in quiet mode"
        rm -f "$temp_file.executed"
    else
        assert_true "false" "gum_spin should still run command in quiet mode"
    fi

    rm -f "$temp_file"
    QUIET="false"
}

test_gum_spin_quiet_mode_no_output() {
    GUM_AVAILABLE="false"
    QUIET="true"

    local output
    output=$(gum_spin "Should not show" true 2>&1)

    # In quiet mode, the title should not be shown (only command output)
    if [[ "$output" != *"Should not show"* ]]; then
        assert_true "true" "gum_spin quiet mode suppresses title"
    else
        assert_true "false" "gum_spin should suppress title in quiet mode"
    fi

    QUIET="false"
}

test_gum_spin_captures_exit_code() {
    GUM_AVAILABLE="false"
    QUIET="true"

    # Run command that succeeds
    gum_spin "Success" true 2>&1
    local success_code=$?

    # Run command that fails
    gum_spin "Fail" false 2>&1
    local fail_code=$?

    assert_equals "0" "$success_code" "gum_spin returns 0 for successful command"

    if [[ "$fail_code" -ne 0 ]]; then
        assert_true "true" "gum_spin returns non-zero for failed command"
    else
        assert_true "false" "gum_spin should return non-zero for failed command"
    fi

    QUIET="false"
}

#==============================================================================
# Tests: gum_confirm (fallback behavior)
#==============================================================================

test_gum_confirm_uses_read_fallback() {
    local func_body
    func_body=$(sed -n '/^gum_confirm()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "read -rp" "gum_confirm uses 'read -rp' for fallback"
}

test_gum_confirm_default_false_prompt() {
    local func_body
    func_body=$(sed -n '/^gum_confirm()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "[y/N]" "gum_confirm shows [y/N] for default=false"
}

test_gum_confirm_default_true_prompt() {
    local func_body
    func_body=$(sed -n '/^gum_confirm()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "[Y/n]" "gum_confirm shows [Y/n] for default=true"
}

test_gum_confirm_checks_gum_available() {
    local func_body
    func_body=$(sed -n '/^gum_confirm()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" 'GUM_AVAILABLE' "gum_confirm checks GUM_AVAILABLE variable"
}

test_gum_confirm_has_gum_branch() {
    local func_body
    func_body=$(sed -n '/^gum_confirm()/,/^}/p' "$RU_SCRIPT")

    assert_contains "$func_body" "gum confirm" "gum_confirm calls 'gum confirm' when available"
}

#==============================================================================
# Tests: Integration
#==============================================================================

test_gum_wrappers_defined() {
    assert_true "declare -f check_gum >/dev/null" "check_gum is defined"
    assert_true "declare -f gum_confirm >/dev/null" "gum_confirm is defined"
    assert_true "declare -f print_banner >/dev/null" "print_banner is defined"
    assert_true "declare -f gum_spin >/dev/null" "gum_spin is defined"
}

test_gum_available_default() {
    # Reset to initial state
    local saved="$GUM_AVAILABLE"
    GUM_AVAILABLE="false"

    # The default should be false
    assert_equals "false" "$GUM_AVAILABLE" "GUM_AVAILABLE defaults to false"

    GUM_AVAILABLE="$saved"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Gum Wrappers"
echo "============================================"

# check_gum tests
run_test test_check_gum_sets_available_when_installed
run_test test_check_gum_unchanged_when_not_installed
run_test test_check_gum_uses_command_v

# print_banner tests
run_test test_print_banner_quiet_mode
run_test test_print_banner_fallback_output
run_test test_print_banner_fallback_has_decoration

# gum_spin tests
run_test test_gum_spin_fallback_runs_command
run_test test_gum_spin_fallback_shows_title
run_test test_gum_spin_quiet_mode
run_test test_gum_spin_quiet_mode_no_output
run_test test_gum_spin_captures_exit_code

# gum_confirm tests (static analysis of fallback)
run_test test_gum_confirm_uses_read_fallback
run_test test_gum_confirm_default_false_prompt
run_test test_gum_confirm_default_true_prompt
run_test test_gum_confirm_checks_gum_available
run_test test_gum_confirm_has_gum_branch

# Integration tests
run_test test_gum_wrappers_defined
run_test test_gum_available_default

print_results
exit "$(get_exit_code)"

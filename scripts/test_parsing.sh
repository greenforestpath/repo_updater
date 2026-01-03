#!/usr/bin/env bash
# Test URL parsing functions
set -uo pipefail

# Extract just the parsing functions from ru
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source <(sed -n '/^parse_repo_url()/,/^}/p' "$SCRIPT_DIR/ru")
source <(sed -n '/^normalize_url()/,/^}/p' "$SCRIPT_DIR/ru")
source <(sed -n '/^url_to_local_path()/,/^}/p' "$SCRIPT_DIR/ru")
source <(sed -n '/^url_to_clone_target()/,/^}/p' "$SCRIPT_DIR/ru")

# Define log functions for testing
log_error() { echo "ERROR: $*" >&2; }

TESTS_PASSED=0
TESTS_FAILED=0

test_parse() {
    local url="$1"
    local expected_host="$2"
    local expected_owner="$3"
    local expected_repo="$4"
    
    local host="" owner="" repo=""
    if parse_repo_url "$url" host owner repo; then
        if [[ "$host" == "$expected_host" && "$owner" == "$expected_owner" && "$repo" == "$expected_repo" ]]; then
            echo "PASS: $url -> $host/$owner/$repo"
            ((TESTS_PASSED++))
        else
            echo "FAIL: $url"
            echo "  Expected: $expected_host/$expected_owner/$expected_repo"
            echo "  Got:      $host/$owner/$repo"
            ((TESTS_FAILED++))
        fi
    else
        echo "FAIL: $url (parse failed)"
        ((TESTS_FAILED++))
    fi
}

echo "Testing URL parsing..."
echo ""

# HTTPS URLs
test_parse "https://github.com/owner/repo" "github.com" "owner" "repo"
test_parse "https://github.com/owner/repo.git" "github.com" "owner" "repo"
test_parse "https://github.com/Dicklesworthstone/repo_updater" "github.com" "Dicklesworthstone" "repo_updater"

# SSH URLs
test_parse "git@github.com:owner/repo.git" "github.com" "owner" "repo"
test_parse "git@github.com:cli/cli.git" "github.com" "cli" "cli"

# Shorthand
test_parse "owner/repo" "github.com" "owner" "repo"
test_parse "charmbracelet/gum" "github.com" "charmbracelet" "gum"

# Host/owner/repo
test_parse "github.com/owner/repo" "github.com" "owner" "repo"

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
exit $TESTS_FAILED

# Plan: Integrating NTM Robot Mode into ru for Automated Agent-Based Repository Maintenance

> **Document Version:** 2.0.0
> **Created:** 2026-01-06
> **Updated:** 2026-01-06
> **Status:** Proposal (Enhanced)
> **Target:** ru v1.2.0

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Background: What Are ru and ntm?](#2-background-what-are-ru-and-ntm)
3. [The Problem We're Solving](#3-the-problem-were-solving)
4. [Proposed Solution Overview](#4-proposed-solution-overview)
5. [The Three-Phase Agent Workflow](#5-the-three-phase-agent-workflow)
6. [Technical Design](#6-technical-design)
7. [ntm Robot Mode Deep Dive](#7-ntm-robot-mode-deep-dive)
8. [Integration Architecture](#8-integration-architecture)
9. [Error Handling & Recovery](#9-error-handling--recovery)
10. [Concurrency & Locking](#10-concurrency--locking)
11. [Installation Flow Changes](#11-installation-flow-changes)
12. [CLI Interface Design](#12-cli-interface-design)
13. [Implementation Plan](#13-implementation-plan)
14. [Testing Strategy](#14-testing-strategy)
15. [Risk Analysis](#15-risk-analysis)
16. [Open Questions](#16-open-questions)
17. [Appendices](#appendices)

---

## 1. Executive Summary

This proposal describes how to integrate **ntm (Named Tmux Manager)** robot mode into **ru (repo_updater)** to enable automated, AI-assisted repository maintenance across large collections of GitHub repositories.

**The vision:** Run a single command (`ru agent-sweep`) that iterates through all configured repositories, launches Claude Code in each one, has the AI deeply understand the codebase, commit any uncommitted changes with detailed messages, and optionally handle GitHub releases—all without human intervention.

**Key benefits:**
- Automate the tedious task of cleaning up uncommitted work across dozens of repos
- Generate high-quality, contextually-aware commit messages via AI analysis
- Ensure consistent release practices across all managed repositories
- Leverage ntm's battle-tested session management and monitoring capabilities

**What's new in v2.0.0:**
- Deep implementation details from actual ntm source code analysis
- Portable directory-based locking (reuses ru's proven pattern)
- Detailed JSON schemas for all robot mode responses
- State detection mechanics (velocity tracking + 53 regex patterns)
- Comprehensive error code mapping
- jq-free JSON parsing fallbacks
- Testing strategy with mock patterns

---

## 2. Background: What Are ru and ntm?

### 2.1 ru (repo_updater)

**ru** is a production-grade, pure Bash CLI tool (~13,000 lines) designed to synchronize collections of GitHub repositories to a local projects directory.

#### Core Functionality

| Feature | Description |
|---------|-------------|
| **Multi-repo sync** | Clone missing repos, pull updates, detect conflicts |
| **Parallel processing** | `-j N` for concurrent operations with portable locking |
| **Resume capability** | `--resume` continues interrupted syncs via state files |
| **Git plumbing** | Uses `git rev-list`, not string parsing |
| **Automation-grade** | Exit codes 0-5, JSON output, non-interactive mode |
| **AI review system** | `ru review` for Claude Code-assisted code review |

#### Architecture Highlights

```
ru (Bash 4.0+)
├── Configuration (XDG-compliant)
│   ├── ~/.config/ru/config
│   └── ~/.config/ru/repos.d/*.txt
├── State Management
│   └── ~/.local/state/ru/ (logs, sync state, review state)
├── Core Operations
│   ├── Sync engine (parallel workers, state tracking)
│   ├── Review system (worktrees, session drivers)
│   └── Prune system (orphan detection)
└── Terminal UI
    └── gum integration with ANSI fallbacks
```

#### Key Design Principles (from actual codebase)

1. **No global `cd`** — Uses `git -C "$path"` everywhere
2. **No `set -e`** — Explicit error handling with `if output=$(cmd 2>&1); then`
3. **Stream separation** — stderr for humans, stdout for data
4. **Graceful degradation** — Works without jq, gum, or other optional deps
5. **Portable locking** — Uses `mkdir` (atomic POSIX) instead of `flock`

#### Existing Parallel Processing Pattern

From `run_parallel_sync()` (lines 2212-2339):

```bash
# Work queue: temp file with repos
# Workers: N background processes atomically popping from queue
# Locking: dir_lock_acquire/release using mkdir (no flock)
# Results: NDJSON file with atomic appends via locks
```

This exact pattern will be reused for parallel agent-sweep.

#### Existing Review System

ru already has an `ru review` command that:
- Discovers open issues/PRs via GitHub GraphQL batch queries (25 repos/query)
- Creates isolated git worktrees per review
- Launches Claude Code sessions via session drivers
- Parses stream-json output for question detection
- Applies approved changes with quality gates

This proposal extends that foundation with a new `ru agent-sweep` command.

---

### 2.2 ntm (Named Tmux Manager)

**ntm** is a Go-based CLI tool (~15,000 lines across internal packages) that transforms tmux into a multi-agent command center for AI coding agents.

#### Core Functionality

| Feature | Description |
|---------|-------------|
| **Multi-agent orchestration** | Run Claude, Codex, Gemini in parallel panes |
| **Robot mode** | JSON-based API with 9 error codes and consistent schemas |
| **Session management** | Named sessions that survive disconnects |
| **State monitoring** | Velocity-based + pattern-based state detection |
| **Checkpointing** | Auto-save session state before operations |
| **One-liner install** | `curl -fsSL .../install.sh \| bash` |

#### Robot Mode API (from actual implementation)

ntm's robot mode is implemented in `/data/projects/ntm/internal/robot/` (~7,000 lines). All commands output JSON with this base structure:

```json
{
  "success": true,
  "timestamp": "2025-01-06T15:30:00Z",
  "error": null,
  "error_code": null,
  "hint": null,
  "_agent_hints": {
    "summary": "Human-readable summary",
    "suggestions": ["Next action 1", "Next action 2"]
  }
}
```

#### Critical Robot Mode Commands

| Command | Purpose | Exit Codes |
|---------|---------|------------|
| `--robot-spawn=SESSION` | Create session with agents | 0=success, 1=error, 2=unavailable |
| `--robot-send=SESSION` | Send prompt to agents | 0=delivered, 1=partial, 2=failed |
| `--robot-wait=SESSION` | Wait for condition | 0=met, 1=timeout, 2=error, 3=agent-error |
| `--robot-status` | Get all sessions (JSON) | 0=success, 1=error |
| `--robot-activity=SESSION` | Get state with velocity | 0=success |
| `--robot-interrupt=SESSION` | Send Ctrl+C | 0=sent |

#### Session Lifecycle (actual spawn sequence)

From `/data/projects/ntm/internal/robot/spawn.go`:

```
1. VALIDATE
   - Check session name format
   - Verify tmux installed
   - If --spawn-safety: fail if session exists
   - Verify working directory exists

2. CREATE
   - tmux.CreateSession(session, dir)
   - tmux.ApplyTiledLayout()
   - Split window to create panes

3. LAUNCH AGENTS
   - Set pane titles: {session}__{type}_{index}
   - Send agent command via tmux.SendKeys()
   - Track startup time per agent

4. WAIT FOR READY (optional)
   - Poll every 500ms up to timeout
   - Check for prompt patterns (50+ patterns)
   - Return ready=true/false per agent
```

#### Agent State Detection (actual implementation)

From `/data/projects/ntm/internal/robot/activity.go` and `patterns.go`:

**Velocity Tracking:**
```
- Capture pane output every poll interval (default 500ms)
- Strip ANSI escape sequences
- Count rune delta (Unicode-aware)
- Calculate: velocity = chars_added / elapsed_seconds
- Maintain circular buffer of 10 samples
```

**State Thresholds:**
| Velocity | + Pattern | = State |
|----------|-----------|---------|
| >10 chars/sec | any | GENERATING |
| <1 char/sec | prompt pattern | WAITING (idle) |
| 1-10 chars/sec | no error | THINKING |
| 0 chars/sec | 5+ seconds | COMPLETE |
| any | error pattern | ERROR |

**Pattern Library:**
- 53 hardcoded regex patterns, priority-ordered (1-250)
- 20 idle patterns (prompts: `$`, `%`, `>`, `❯`, `claude>`, etc.)
- 16 error patterns (rate limits, crashes, auth failures)
- 6 thinking patterns (spinners, "processing...")
- 4 completion patterns ("done", "✓", "summary")

---

## 3. The Problem We're Solving

### 3.1 The Scenario

Developers managing many repositories (20-100+) face a common challenge:

1. **Uncommitted changes accumulate** across repos during rapid development
2. **Context switching** means forgetting what changes were made where
3. **Commit messages** end up as `"WIP"` or `"misc fixes"` due to time pressure
4. **Release management** (tags, changelogs, checksums) is tedious and inconsistent

### 3.2 Current Pain Points

| Pain Point | Impact |
|------------|--------|
| Manual commit per repo | Time-consuming, error-prone |
| Poor commit messages | Lost context, hard to review history |
| Inconsistent releases | Some repos tagged, others not |
| No deep analysis | Changes committed without understanding impact |
| Context loss | "What did I change here 3 days ago?" |

### 3.3 Why AI Agents Help

AI coding agents like Claude Code can:

1. **Read and understand** entire codebases quickly
2. **Analyze changes** in context of the project's architecture
3. **Generate detailed commit messages** that explain *why*, not just *what*
4. **Group related changes** into logical commits
5. **Handle release automation** (version bumps, changelogs, tags)

### 3.4 Why ntm is the Right Tool

ntm provides:

1. **Reliable session management** — Handles tmux complexity
2. **Robot mode API** — JSON-based with proper error codes
3. **State detection** — Velocity + patterns, knows when Claude Code is done
4. **Checkpointing** — Can auto-save state before operations
5. **Same installation pattern** — curl-bash one-liner like ru
6. **Agent Mail integration** — Optional file reservations for multi-agent

---

## 4. Proposed Solution Overview

### 4.1 New Command: `ru agent-sweep`

Add a new subcommand to ru that:

1. Iterates through all configured repositories (or a filtered subset)
2. For each repo with uncommitted changes:
   a. Launches a Claude Code session via ntm robot mode
   b. Sends a sequence of AI prompts (codebase understanding → commit → release)
   c. Monitors completion via ntm's wait mechanism (velocity + patterns)
   d. Collects results and moves to next repo
3. Produces a summary report of all actions taken

### 4.2 The Three-Phase Prompt Sequence

Each repository goes through three phases:

#### Phase 1: Deep Understanding
```
First read ALL of the AGENTS.md file and README.md file super carefully
and understand ALL of both! Then use your code investigation agent mode
to fully understand the code, and technical architecture and purpose of
the project. Use ultrathink.
```

#### Phase 2: Intelligent Commits
```
Now, based on your knowledge of the project, commit all changed files now
in a series of logically connected groupings with super detailed commit
messages for each and then push. Take your time to do it right. Don't edit
the code at all. Don't commit obviously ephemeral files. Use ultrathink.
```

#### Phase 3: GitHub Release (Conditional)
```
Do all the GitHub stuff: commit, deploy, create tag, bump version, release,
monitor gh actions, compute checksums, etc. Use ultrathink.
```

Phase 3 only runs if:
- The repo has GitHub Actions configured for releases
- There are changes that warrant a release
- The `--with-release` flag is passed

### 4.3 High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          ru agent-sweep                                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
            ┌──────────────┐                ┌──────────────┐
            │  Load repos  │                │  Check ntm   │
            │  from config │                │  available   │
            └──────────────┘                └──────────────┘
                    │                               │
                    └───────────────┬───────────────┘
                                    ▼
                          ┌─────────────────┐
                          │  Filter repos   │
                          │  with changes   │
                          │  (git status    │
                          │   --porcelain)  │
                          └─────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
            ┌──────────────┐                ┌──────────────┐
            │ Sequential   │      OR        │  Parallel    │
            │ (default)    │                │  (-j N)      │
            └──────────────┘                └──────────────┘
                    │                               │
                    ▼                               ▼
            ┌──────────────┐                ┌──────────────┐
            │  For each:   │                │  Work queue  │
            │  spawn→send  │                │  + N workers │
            │  →wait→kill  │                │  + dir locks │
            └──────────────┘                └──────────────┘
                    │                               │
                    └───────────────┬───────────────┘
                                    ▼
                          ┌─────────────────┐
                          │  Summary Report │
                          │  (NDJSON file   │
                          │   + human UI)   │
                          └─────────────────┘
```

---

## 5. The Three-Phase Agent Workflow

### 5.1 Phase 1: Deep Understanding

**Purpose:** Ensure the AI has full context before making any changes.

**Prompt:**
```
First read ALL of the AGENTS.md file and README.md file super carefully
and understand ALL of both! Then use your code investigation agent mode
to fully understand the code, and technical architecture and purpose of
the project. Use ultrathink.
```

**Why this matters:**
- Prevents blind commits without understanding
- AI learns project conventions, patterns, and architecture
- Better commit messages because AI knows *why* code exists
- Catches potential issues before committing

**Expected behavior:**
1. Claude Code reads AGENTS.md (project rules and conventions)
2. Claude Code reads README.md (project purpose and usage)
3. Claude Code explores the codebase via Task tool
4. Claude Code builds mental model of architecture

**Completion detection (via ntm):**
- Velocity drops to <1 char/sec
- Idle prompt pattern detected (`claude>`, `$`, etc.)
- 5-second stability threshold met (complete_idle)
- Typical duration: 30-120 seconds depending on repo size

### 5.2 Phase 2: Intelligent Commits

**Purpose:** Commit all changes with detailed, contextual messages.

**Prompt:**
```
Now, based on your knowledge of the project, commit all changed files now
in a series of logically connected groupings with super detailed commit
messages for each and then push. Take your time to do it right. Don't edit
the code at all. Don't commit obviously ephemeral files. Use ultrathink.
```

**Key constraints in prompt:**
- **"logically connected groupings"** — Related changes in same commit
- **"super detailed commit messages"** — Not just "fix bug" but full context
- **"Don't edit the code"** — Read-only analysis, commit existing changes
- **"Don't commit ephemeral files"** — Skip `.pyc`, `node_modules`, etc.
- **"then push"** — Ensure changes reach remote

**Expected behavior:**
1. Claude Code runs `git status` to see changes
2. Analyzes what changed and why (using Phase 1 knowledge)
3. Groups related files into logical commits
4. Writes detailed commit messages with:
   - Summary line (50 chars)
   - Blank line
   - Detailed body explaining *why*
   - References to issues if applicable
   - Co-authored-by trailer
5. Pushes to remote

**Example of AI-generated commit:**
```
feat(auth): implement OAuth2 PKCE flow for mobile clients

This commit adds PKCE (Proof Key for Code Exchange) support to the
OAuth2 authentication flow, addressing security requirements for
public clients (mobile apps) that cannot securely store client secrets.

Changes:
- Add code_verifier and code_challenge generation in auth/pkce.py
- Update /authorize endpoint to accept code_challenge parameter
- Modify /token endpoint to verify code_verifier against stored challenge
- Add PKCE-specific tests covering S256 and plain methods

The implementation follows RFC 7636 and is required for App Store
compliance with OAuth 2.0 best practices for native apps.

🤖 Generated with Claude Code (https://claude.ai/code)
Co-Authored-By: Claude <noreply@anthropic.com>
```

**Completion criteria:**
- All changes committed (nothing in `git status --porcelain`)
- Push successful
- Claude Code returns to idle state

### 5.3 Phase 3: GitHub Release (Conditional)

**Purpose:** Handle version bumps, tags, releases, and GitHub Actions.

**Prompt:**
```
Do all the GitHub stuff: commit, deploy, create tag, bump version, release,
monitor gh actions, compute checksums, etc. Use ultrathink.
```

**Prerequisites (checked before running):**
```bash
# Check for release workflow (jq-free version)
has_release_workflow() {
    local repo_path="$1"
    local workflows_dir="$repo_path/.github/workflows"
    [[ -d "$workflows_dir" ]] || return 1
    grep -riqE '(release|tag|deploy|publish)' "$workflows_dir"/*.yml 2>/dev/null
}
```

**Expected behavior:**
1. Claude Code analyzes what kind of release is needed:
   - Patch (bug fixes only)
   - Minor (new features, backwards compatible)
   - Major (breaking changes)
2. Updates version files (VERSION, package.json, Cargo.toml, etc.)
3. Generates/updates CHANGELOG.md
4. Creates git tag with version
5. Pushes tag to trigger GitHub Actions
6. Monitors Actions for completion
7. If Actions generate artifacts, verifies checksums

**Completion criteria:**
- New tag visible on GitHub
- Release created (if applicable)
- Actions completed successfully
- Claude Code returns to idle state

---

## 6. Technical Design

### 6.1 ntm Driver Integration Layer

Create embedded functions in ru (not separate file, matching ru's single-file pattern):

```bash
#!/usr/bin/env bash
# ntm integration functions (embedded in ru main script)

#=============================================================================
# NTM DRIVER FUNCTIONS
#=============================================================================

# Check if ntm is available and functional
# Returns: 0=available, 1=not installed, 2=not functional
ntm_check_available() {
    if ! command -v ntm &>/dev/null; then
        return 1
    fi
    # Verify robot mode works (fast check)
    if ! ntm --robot-status &>/dev/null; then
        return 2
    fi
    return 0
}

# Parse JSON field without jq (fallback)
# Args: $1=json, $2=field_name
# Returns: field value (simple strings only)
json_get_field() {
    local json="$1" field="$2"
    # Simple pattern: "field":"value" or "field":value
    echo "$json" | grep -oP "\"${field}\"\\s*:\\s*\"?\\K[^\",}]+" | head -1
}

# Check if JSON has success=true
# Args: $1=json
# Returns: 0=success, 1=failure
json_is_success() {
    local json="$1"
    [[ "$json" == *'"success":true'* ]] || [[ "$json" == *'"success": true'* ]]
}

# Spawn a Claude Code session for a repo
# Args: $1=session_name, $2=working_dir, $3=timeout_seconds
# Returns: JSON with session details
# Exit: 0=success, 1=error
ntm_spawn_session() {
    local session="$1"
    local workdir="$2"
    local timeout="${3:-60}"
    local output

    # Spawn with wait-for-ready
    if output=$(ntm --robot-spawn="$session" \
        --spawn-cc=1 \
        --spawn-wait \
        --spawn-dir="$workdir" \
        --ready-timeout="${timeout}s" 2>&1); then
        echo "$output"
        return 0
    else
        local exit_code=$?
        echo "$output"
        return $exit_code
    fi
}

# Send a prompt to a session
# Args: $1=session_name, $2=prompt
# Returns: JSON with send confirmation
# Note: Prompts >4KB should be chunked
ntm_send_prompt() {
    local session="$1"
    local prompt="$2"
    local output

    # Check prompt size (tmux practical limit ~4KB per send)
    if [[ ${#prompt} -gt 4000 ]]; then
        log_warn "Prompt is ${#prompt} chars (>4KB), sending in chunks"
        ntm_send_prompt_chunked "$session" "$prompt"
        return $?
    fi

    if output=$(ntm --robot-send="$session" \
        --msg="$prompt" \
        --type=claude 2>&1); then
        echo "$output"
        return 0
    else
        echo "$output"
        return 1
    fi
}

# Send a large prompt in chunks
# Args: $1=session_name, $2=prompt
ntm_send_prompt_chunked() {
    local session="$1"
    local prompt="$2"
    local chunk_size=3500
    local offset=0
    local length=${#prompt}

    while [[ $offset -lt $length ]]; do
        local chunk="${prompt:$offset:$chunk_size}"
        if ! ntm --robot-send="$session" --msg="$chunk" --type=claude &>/dev/null; then
            return 1
        fi
        ((offset += chunk_size))
        # Small delay between chunks
        sleep 0.1
    done
    return 0
}

# Wait for session to complete (return to idle)
# Args: $1=session_name, $2=timeout_seconds
# Returns: JSON with wait result
# Exit: 0=condition met, 1=timeout, 2=error, 3=agent error
ntm_wait_completion() {
    local session="$1"
    local timeout="${2:-300}"
    local output exit_code

    output=$(ntm --robot-wait="$session" \
        --condition=idle \
        --wait-timeout="${timeout}s" \
        --exit-on-error 2>&1)
    exit_code=$?

    echo "$output"
    return $exit_code
}

# Get current session activity state
# Args: $1=session_name
# Returns: JSON with velocity and state per agent
ntm_get_activity() {
    local session="$1"
    ntm --robot-activity="$session" 2>/dev/null
}

# Get agent state from activity output (jq-free)
# Args: $1=activity_json
# Returns: state string (WAITING, GENERATING, ERROR, etc.)
ntm_parse_agent_state() {
    local json="$1"
    json_get_field "$json" "state"
}

# Kill a session (cleanup)
# Args: $1=session_name
ntm_kill_session() {
    local session="$1"
    ntm kill "$session" -f 2>/dev/null || true
}

# Interrupt a session (send Ctrl+C)
# Args: $1=session_name
ntm_interrupt_session() {
    local session="$1"
    ntm --robot-interrupt="$session" 2>/dev/null || true
}
```

### 6.2 Agent Sweep Command Implementation

```bash
#=============================================================================
# AGENT-SWEEP COMMAND
#=============================================================================

# Phase prompts (configurable via environment)
AGENT_SWEEP_PHASE1_PROMPT="${AGENT_SWEEP_PHASE1_PROMPT:-First read ALL of the AGENTS.md file and README.md file super carefully and understand ALL of both! Then use your code investigation agent mode to fully understand the code, and technical architecture and purpose of the project. Use ultrathink.}"

AGENT_SWEEP_PHASE2_PROMPT="${AGENT_SWEEP_PHASE2_PROMPT:-Now, based on your knowledge of the project, commit all changed files now in a series of logically connected groupings with super detailed commit messages for each and then push. Take your time to do it right. Don't edit the code at all. Don't commit obviously ephemeral files. Use ultrathink.}"

AGENT_SWEEP_PHASE3_PROMPT="${AGENT_SWEEP_PHASE3_PROMPT:-Do all the GitHub stuff: commit, deploy, create tag, bump version, release, monitor gh actions, compute checksums, etc. Use ultrathink.}"

# Run agent workflow for a single repo
# Args: $1=session_name, $2=repo_path, $3=with_release (true/false)
# Returns: JSON result
# Writes: to RESULTS_FILE via write_result()
run_single_agent_workflow() {
    local session="$1"
    local repo_path="$2"
    local with_release="${3:-false}"
    local repo_name
    repo_name=$(basename "$repo_path")

    local start_time phase1_start phase2_start phase3_start
    start_time=$(date +%s)

    # Spawn session
    log_step "  Spawning Claude Code session..."
    local spawn_output
    if ! spawn_output=$(ntm_spawn_session "$session" "$repo_path" 60); then
        local error_code
        error_code=$(json_get_field "$spawn_output" "error_code")
        write_result "$repo_name" "agent-sweep" "spawn_failed" "0" "$error_code" "$repo_path"
        return 1
    fi

    # Phase 1: Understanding
    phase1_start=$(date +%s)
    log_step "  Phase 1: Deep codebase understanding..."

    if ! ntm_send_prompt "$session" "$AGENT_SWEEP_PHASE1_PROMPT" >/dev/null; then
        ntm_kill_session "$session"
        write_result "$repo_name" "agent-sweep" "phase1_send_failed" "0" "send_error" "$repo_path"
        return 1
    fi

    local wait_output wait_code
    wait_output=$(ntm_wait_completion "$session" "${AGENT_SWEEP_PHASE1_TIMEOUT:-180}")
    wait_code=$?

    if [[ $wait_code -ne 0 ]]; then
        ntm_kill_session "$session"
        local error_type="phase1_timeout"
        [[ $wait_code -eq 3 ]] && error_type="phase1_agent_error"
        write_result "$repo_name" "agent-sweep" "$error_type" "$(($(date +%s) - phase1_start))" "" "$repo_path"
        return 1
    fi

    local phase1_duration=$(($(date +%s) - phase1_start))
    log_verbose "    Phase 1 complete (${phase1_duration}s)"

    # Phase 2: Committing
    phase2_start=$(date +%s)
    log_step "  Phase 2: Intelligent commits..."

    if ! ntm_send_prompt "$session" "$AGENT_SWEEP_PHASE2_PROMPT" >/dev/null; then
        ntm_kill_session "$session"
        write_result "$repo_name" "agent-sweep" "phase2_send_failed" "$phase1_duration" "send_error" "$repo_path"
        return 1
    fi

    wait_output=$(ntm_wait_completion "$session" "${AGENT_SWEEP_PHASE2_TIMEOUT:-300}")
    wait_code=$?

    if [[ $wait_code -ne 0 ]]; then
        ntm_kill_session "$session"
        local error_type="phase2_timeout"
        [[ $wait_code -eq 3 ]] && error_type="phase2_agent_error"
        write_result "$repo_name" "agent-sweep" "$error_type" "$(($(date +%s) - start_time))" "" "$repo_path"
        return 1
    fi

    local phase2_duration=$(($(date +%s) - phase2_start))
    log_verbose "    Phase 2 complete (${phase2_duration}s)"

    # Phase 3: Release (conditional)
    local phases_completed=2
    if [[ "$with_release" == "true" ]] && has_release_workflow "$repo_path"; then
        phase3_start=$(date +%s)
        log_step "  Phase 3: GitHub release..."

        if ! ntm_send_prompt "$session" "$AGENT_SWEEP_PHASE3_PROMPT" >/dev/null; then
            ntm_kill_session "$session"
            write_result "$repo_name" "agent-sweep" "phase3_send_failed" "$(($(date +%s) - start_time))" "" "$repo_path"
            return 1
        fi

        wait_output=$(ntm_wait_completion "$session" "${AGENT_SWEEP_PHASE3_TIMEOUT:-600}")
        wait_code=$?

        if [[ $wait_code -ne 0 ]]; then
            ntm_kill_session "$session"
            local error_type="phase3_timeout"
            [[ $wait_code -eq 3 ]] && error_type="phase3_agent_error"
            write_result "$repo_name" "agent-sweep" "$error_type" "$(($(date +%s) - start_time))" "" "$repo_path"
            return 1
        fi

        local phase3_duration=$(($(date +%s) - phase3_start))
        log_verbose "    Phase 3 complete (${phase3_duration}s)"
        phases_completed=3
    fi

    # Cleanup
    ntm_kill_session "$session"

    local total_duration=$(($(date +%s) - start_time))
    write_result "$repo_name" "agent-sweep" "success" "$total_duration" "phases=$phases_completed" "$repo_path"
    return 0
}

# Check if repo has uncommitted changes
# Args: $1=repo_path
# Returns: 0=has changes, 1=clean
has_uncommitted_changes() {
    local repo_path="$1"
    [[ -n $(git -C "$repo_path" status --porcelain 2>/dev/null) ]]
}

# Check if repo has release GitHub Actions
# Args: $1=repo_path
# Returns: 0=has workflow, 1=no workflow
has_release_workflow() {
    local repo_path="$1"
    local workflows_dir="$repo_path/.github/workflows"

    [[ -d "$workflows_dir" ]] || return 1
    grep -riqE '(release|tag|deploy|publish|version)' "$workflows_dir"/*.yml 2>/dev/null
}

# Main agent-sweep command
cmd_agent_sweep() {
    local with_release=false
    local parallel=1
    local repos_filter=""
    local dry_run=false
    local resume=false
    local restart=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-release) with_release=true; shift ;;
            --parallel=*|-j=*) parallel="${1#*=}"; shift ;;
            -j) parallel="$2"; shift 2 ;;
            --repos=*) repos_filter="${1#*=}"; shift ;;
            --dry-run) dry_run=true; shift ;;
            --resume) resume=true; shift ;;
            --restart) restart=true; shift ;;
            --phase1-timeout=*) AGENT_SWEEP_PHASE1_TIMEOUT="${1#*=}"; shift ;;
            --phase2-timeout=*) AGENT_SWEEP_PHASE2_TIMEOUT="${1#*=}"; shift ;;
            --phase3-timeout=*) AGENT_SWEEP_PHASE3_TIMEOUT="${1#*=}"; shift ;;
            --help|-h) show_agent_sweep_help; return 0 ;;
            *) log_error "Unknown option: $1"; return 4 ;;
        esac
    done

    # Check ntm availability
    local ntm_status
    ntm_check_available
    ntm_status=$?
    if [[ $ntm_status -eq 1 ]]; then
        log_error "ntm is not installed. Install with:"
        log_error "  curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash"
        return 3
    elif [[ $ntm_status -eq 2 ]]; then
        log_error "ntm is installed but robot mode is not working."
        log_error "Try: ntm --robot-status"
        return 3
    fi

    # Check for tmux
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is required for agent-sweep. Install tmux first."
        return 3
    fi

    # Load repos
    local repos=()
    load_all_repos repos

    # Filter to repos with changes
    local dirty_repos=()
    for repo_spec in "${repos[@]}"; do
        local repo_path
        repo_path=$(repo_spec_to_path "$repo_spec")

        if [[ -d "$repo_path" ]] && has_uncommitted_changes "$repo_path"; then
            if [[ -z "$repos_filter" ]] || [[ "$repo_spec" == *"$repos_filter"* ]]; then
                dirty_repos+=("$repo_spec")
            fi
        fi
    done

    if [[ ${#dirty_repos[@]} -eq 0 ]]; then
        log_success "No repositories with uncommitted changes found."
        return 0
    fi

    log_info "Found ${#dirty_repos[@]} repositories with uncommitted changes"

    if [[ "$dry_run" == true ]]; then
        log_info "Dry run mode - would process:"
        for repo in "${dirty_repos[@]}"; do
            local path
            path=$(repo_spec_to_path "$repo")
            local changes
            changes=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $(basename "$repo") ($changes files changed)"
        done
        return 0
    fi

    # Setup results tracking
    setup_agent_sweep_results

    # Handle resume/restart
    if [[ "$resume" == true ]] && load_agent_sweep_state; then
        filter_completed_repos dirty_repos
    elif [[ "$restart" == true ]]; then
        cleanup_agent_sweep_state
    fi

    # Trap for cleanup
    trap 'cleanup_agent_sweep_sessions; save_agent_sweep_state "interrupted"' INT TERM

    # Process repositories (sequential or parallel)
    if [[ $parallel -gt 1 ]]; then
        run_parallel_agent_sweep dirty_repos "$parallel" "$with_release"
    else
        run_sequential_agent_sweep dirty_repos "$with_release"
    fi

    local sweep_exit=$?

    # Cleanup state on success
    if [[ $sweep_exit -eq 0 ]]; then
        cleanup_agent_sweep_state
    fi

    # Summary
    print_agent_sweep_summary

    trap - INT TERM
    return $sweep_exit
}

# Sequential processing
run_sequential_agent_sweep() {
    local -n repos_ref=$1
    local with_release="$2"
    local success_count=0
    local fail_count=0

    for repo_spec in "${repos_ref[@]}"; do
        local repo_name repo_path session_name
        repo_name=$(basename "$repo_spec" | sed 's/@.*//')
        repo_path=$(repo_spec_to_path "$repo_spec")
        session_name="ru_sweep_${repo_name//[^a-zA-Z0-9_]/_}_$$"

        log_step "Processing: $repo_name"

        if run_single_agent_workflow "$session_name" "$repo_path" "$with_release"; then
            log_success "  Completed: $repo_name"
            ((success_count++))
            mark_repo_completed "$repo_spec"
        else
            log_error "  Failed: $repo_name"
            ((fail_count++))
        fi

        save_agent_sweep_state "in_progress"
    done

    SWEEP_SUCCESS_COUNT=$success_count
    SWEEP_FAIL_COUNT=$fail_count

    [[ $fail_count -gt 0 ]] && return 1
    return 0
}

# Parallel processing (reuses ru's work queue pattern)
run_parallel_agent_sweep() {
    local -n repos_ref=$1
    local parallel="$2"
    local with_release="$3"

    # Create work queue (temp file with repo specs)
    local work_queue results_file lock_base
    work_queue=$(mktemp)
    results_file="${RESULTS_FILE}"
    lock_base="${AGENT_SWEEP_STATE_DIR}/locks"
    mkdir -p "$lock_base"

    printf '%s\n' "${repos_ref[@]}" > "$work_queue"

    # Spawn workers
    local pids=()
    for ((i=0; i<parallel; i++)); do
        (
            while true; do
                local repo_spec=""

                # Atomic dequeue
                if dir_lock_acquire "${lock_base}/queue.lock" 30; then
                    if [[ -s "$work_queue" ]]; then
                        repo_spec=$(head -1 "$work_queue")
                        tail -n +2 "$work_queue" > "${work_queue}.tmp"
                        mv "${work_queue}.tmp" "$work_queue"
                    fi
                    dir_lock_release "${lock_base}/queue.lock"
                fi

                [[ -z "$repo_spec" ]] && break

                local repo_name repo_path session_name
                repo_name=$(basename "$repo_spec" | sed 's/@.*//')
                repo_path=$(repo_spec_to_path "$repo_spec")
                session_name="ru_sweep_${repo_name//[^a-zA-Z0-9_]/_}_${$}_${i}"

                run_single_agent_workflow "$session_name" "$repo_path" "$with_release"
            done
        ) &
        pids+=($!)
    done

    # Wait for all workers
    local exit_code=0
    for pid in "${pids[@]}"; do
        wait "$pid" || exit_code=1
    done

    rm -f "$work_queue"
    return $exit_code
}
```

### 6.3 Session Naming Convention

Sessions are named to avoid collisions:

```
ru_sweep_{repo_name_sanitized}_{pid}[_{worker_index}]
```

Examples:
- `ru_sweep_mcp_agent_mail_12345` (sequential)
- `ru_sweep_beads_viewer_12345_0` (parallel worker 0)
- `ru_sweep_repo_updater_12345_3` (parallel worker 3)

Sanitization: Replace non-alphanumeric chars with `_`

---

## 7. ntm Robot Mode Deep Dive

### 7.1 Spawn Response Schema

```json
{
  "success": true,
  "timestamp": "2025-01-06T15:30:00Z",
  "session": "ru_sweep_myrepo_12345",
  "created_at": "2025-01-06T15:30:00Z",
  "working_dir": "/data/projects/myrepo",
  "agents": [
    {
      "pane": "0.0",
      "type": "user",
      "title": "ru_sweep_myrepo_12345__user",
      "ready": true,
      "startup_ms": 45
    },
    {
      "pane": "0.1",
      "type": "claude",
      "title": "ru_sweep_myrepo_12345__cc_1",
      "ready": true,
      "startup_ms": 2500
    }
  ],
  "layout": "tiled",
  "total_startup_ms": 2500
}
```

### 7.2 Wait Response Schema

```json
{
  "success": true,
  "timestamp": "2025-01-06T15:35:00Z",
  "session": "ru_sweep_myrepo_12345",
  "condition": "idle",
  "waited_seconds": 45.2,
  "agents": [
    {
      "pane": "0.1",
      "state": "WAITING",
      "met_at": "2025-01-06T15:35:00Z",
      "agent_type": "claude"
    }
  ]
}
```

**On timeout:**
```json
{
  "success": false,
  "error": "Timeout waiting for condition",
  "error_code": "TIMEOUT",
  "hint": "Increase timeout or check agent status with --robot-activity",
  "agents_pending": ["0.1"]
}
```

### 7.3 Activity Response Schema

```json
{
  "success": true,
  "timestamp": "2025-01-06T15:32:00Z",
  "session": "ru_sweep_myrepo_12345",
  "agents": [
    {
      "pane_id": "0.1",
      "pane_index": 1,
      "agent_type": "claude",
      "state": "GENERATING",
      "confidence": 0.95,
      "velocity": 45.2,
      "last_activity": "2025-01-06T15:31:58Z",
      "health_state": "healthy",
      "rate_limited": false
    }
  ],
  "summary": "1 agent, 1 generating"
}
```

### 7.4 Error Codes

| Error Code | Meaning | ru Exit Code |
|------------|---------|--------------|
| `SESSION_NOT_FOUND` | Session doesn't exist | 3 |
| `PANE_NOT_FOUND` | Pane index invalid | 3 |
| `INVALID_FLAG` | Bad CLI arguments | 4 |
| `TIMEOUT` | Wait exceeded timeout | 1 |
| `INTERNAL_ERROR` | Unexpected Go error | 3 |
| `PERMISSION_DENIED` | File/tmux permissions | 3 |
| `RESOURCE_BUSY` | Session locked | 1 |
| `DEPENDENCY_MISSING` | tmux not installed | 3 |
| `NOT_IMPLEMENTED` | Feature not ready | 4 |

### 7.5 State Detection Patterns (subset)

**Idle patterns (priority 200-250):**
- `claude>\s*$` — Claude Code prompt
- `\$\s*$` — Shell prompt
- `>>>\s*$` — Python prompt
- `❯\s*$` — Starship prompt

**Error patterns (priority 150-200):**
- `rate.*limit|429|quota.*exceeded` — Rate limiting
- `SIGSEGV|panic|fatal` — Crashes
- `authentication.*failed|unauthorized` — Auth errors
- `network.*error|connection.*refused` — Network issues

**Generating patterns (velocity-based):**
- Velocity > 10 chars/sec for 2+ samples

---

## 8. Integration Architecture

### 8.1 Component Interaction

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                 ru                                       │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      cmd_agent_sweep()                           │    │
│  │                                                                  │    │
│  │   1. Load repos from ~/.config/ru/repos.d/*.txt                 │    │
│  │   2. Filter to repos with uncommitted changes                   │    │
│  │   3. For each repo (seq or parallel):                           │    │
│  │      └─ run_single_agent_workflow()                             │    │
│  │   4. Aggregate results via NDJSON                               │    │
│  │   5. Print summary                                              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     ntm_* functions                              │    │
│  │                                                                  │    │
│  │   ntm_spawn_session()   → ntm --robot-spawn                     │    │
│  │   ntm_send_prompt()     → ntm --robot-send (with chunking)      │    │
│  │   ntm_wait_completion() → ntm --robot-wait --exit-on-error      │    │
│  │   ntm_get_activity()    → ntm --robot-activity (optional)       │    │
│  │   ntm_kill_session()    → ntm kill -f                           │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼ (subprocess calls)
┌─────────────────────────────────────────────────────────────────────────┐
│                                ntm                                       │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    internal/robot/*.go                           │    │
│  │                                                                  │    │
│  │   robot.go      → command dispatch, send implementation         │    │
│  │   spawn.go      → session creation, agent launch                │    │
│  │   wait.go       → condition polling with velocity check         │    │
│  │   activity.go   → velocity tracking (chars/sec)                 │    │
│  │   patterns.go   → 53 regex patterns for state detection         │    │
│  │   types.go      → error codes, response schemas                 │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    internal/tmux/*.go                            │    │
│  │                                                                  │    │
│  │   CreateSession(), SendKeys(), CapturePaneOutput()              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                               tmux                                       │
│                                                                          │
│   Session: ru_sweep_repo_name_12345                                     │
│   └─ Window 0                                                           │
│      ├─ Pane 0: (user pane, optional)                                   │
│      └─ Pane 1: claude-code --project-dir=/data/projects/repo           │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                            Claude Code                                   │
│                                                                          │
│   Phase 1: Read AGENTS.md, README.md, explore via Task tool             │
│   Phase 2: git status → analyze → git add → git commit → git push       │
│   Phase 3: Version bump → tag → push → monitor Actions                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Error Handling & Recovery

### 9.1 Error Type Mapping

| Scenario | ntm Exit | ntm Error Code | ru Exit | ru Behavior |
|----------|----------|----------------|---------|-------------|
| ntm not installed | N/A | N/A | 3 | Log install command |
| tmux not installed | 2 | DEPENDENCY_MISSING | 3 | Log install advice |
| Session already exists | 1 | RESOURCE_BUSY | Skip | Kill existing, retry |
| Spawn timeout | 1 | TIMEOUT | Skip repo | Log, continue |
| Send failed | 1 | INTERNAL_ERROR | Skip repo | Log, cleanup, continue |
| Wait timeout | 1 | TIMEOUT | Skip repo | Log, cleanup, continue |
| Agent error detected | 3 | (state-based) | Skip repo | Log, cleanup, continue |
| Rate limit detected | 3 | (pattern match) | Pause | Wait 60s, retry |
| Network error | 1 | (pattern match) | Skip repo | Log, continue |
| Interrupted (Ctrl+C) | N/A | N/A | 5 | Save state, cleanup |

### 9.2 Recovery Strategies

**Rate Limit Recovery:**
```bash
# In wait loop, check for rate limit pattern
if ntm_get_activity "$session" | grep -q '"rate_limited":true'; then
    log_warn "Rate limit detected, waiting 60s..."
    sleep 60
    # Continue waiting
fi
```

**Crash Recovery:**
```bash
# If agent crashes, ntm reports ERROR state
wait_output=$(ntm_wait_completion "$session" 300)
wait_code=$?

if [[ $wait_code -eq 3 ]]; then
    # Agent error - check if recoverable
    local state
    state=$(ntm_parse_agent_state "$(ntm_get_activity "$session")")
    if [[ "$state" == "ERROR" ]]; then
        log_error "Agent crashed, attempting restart..."
        ntm_interrupt_session "$session"
        sleep 2
        # Re-send prompt
    fi
fi
```

**Orphan Session Cleanup:**
```bash
cleanup_agent_sweep_sessions() {
    # Kill all sessions matching our pattern
    local sessions
    sessions=$(ntm --robot-status 2>/dev/null | grep -o '"name":"ru_sweep_[^"]*"' | cut -d'"' -f4)
    for session in $sessions; do
        if [[ "$session" == *"_$$"* ]] || [[ "$session" == *"_$$_"* ]]; then
            ntm_kill_session "$session"
        fi
    done
}
```

### 9.3 State File for Resume

Location: `~/.local/state/ru/agent_sweep_state.json`

```json
{
  "run_id": "20260106-153000-12345",
  "status": "in_progress",
  "started_at": "2026-01-06T15:30:00Z",
  "config_hash": "abc123...",
  "with_release": false,
  "repos_total": 5,
  "repos_completed": ["repo1", "repo2"],
  "repos_pending": ["repo3", "repo4", "repo5"],
  "current_repo": "repo3",
  "current_phase": 2
}
```

**Atomic updates (matching ru's existing pattern):**
```bash
save_agent_sweep_state() {
    local status="$1"
    local state_file="${AGENT_SWEEP_STATE_DIR}/state.json"
    local tmp_file="${state_file}.tmp.$$"

    {
        echo "{"
        echo "  \"run_id\": \"$RUN_ID\","
        echo "  \"status\": \"$status\","
        echo "  \"repos_completed\": [$(printf '"%s",' "${COMPLETED_REPOS[@]}" | sed 's/,$//')]"
        echo "}"
    } > "$tmp_file"
    mv "$tmp_file" "$state_file"
}
```

---

## 10. Concurrency & Locking

### 10.1 Portable Directory-Based Locking

Reuses ru's existing pattern (no `flock` dependency):

```bash
# Atomic lock acquisition via mkdir
dir_lock_acquire() {
    local lock_dir="$1"
    local timeout="${2:-60}"
    local start end

    start=$(date +%s)
    end=$((start + timeout))

    while [[ $(date +%s) -lt $end ]]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            echo "$$" > "$lock_dir/pid"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

dir_lock_release() {
    local lock_dir="$1"
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}
```

### 10.2 Lock Points in Agent-Sweep

| Lock | Purpose | Timeout |
|------|---------|---------|
| `queue.lock` | Atomic dequeue from work queue | 30s |
| `results.lock` | Atomic append to results file | 30s |
| `state.lock` | Atomic state file updates | 10s |

### 10.3 ntm Session Serialization

**Important:** ntm robot commands are sequential per session. Do NOT:
- Call `--robot-send` while `--robot-wait` is running on same session
- Call multiple robot commands in parallel on same session

**Safe pattern:**
```bash
# CORRECT: Sequential calls on same session
ntm_send_prompt "$session" "$prompt"    # Returns immediately
ntm_wait_completion "$session" 300      # Blocks until done
ntm_send_prompt "$session" "$next"      # Safe now
```

**For parallel repos:** Each repo gets its own session, so no serialization needed between repos.

---

## 11. Installation Flow Changes

### 11.1 Updated install.sh Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ru install.sh                                    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                          ┌─────────────────┐
                          │  Download ru    │
                          │  Verify SHA256  │
                          │  Install to     │
                          │  ~/.local/bin   │
                          └─────────────────┘
                                    │
                                    ▼
                          ┌─────────────────┐
                          │  Check gh CLI   │───── Missing ────▶ Prompt install
                          └─────────────────┘
                                    │
                                    ▼
                          ┌─────────────────┐
                          │  Check tmux     │───── Missing ────▶ Warn (required for agent-sweep)
                          └─────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │  "Enable ntm integration?"    │
                    │                               │
                    │   Enables: ru agent-sweep     │
                    │   Provides: AI commit/release │
                    │                               │
                    │   [Y] Yes (recommended)       │
                    │   [n] No, skip for now        │
                    └───────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
            Yes / Auto                              No
                    │                               │
                    ▼                               ▼
          ┌─────────────────┐              ┌─────────────────┐
          │  Check ntm      │              │  Skip ntm       │
          │  installed?     │              │  (can install   │
          └─────────────────┘              │   later)        │
                    │                      └─────────────────┘
          ┌─────────┴─────────┐
          ▼                   ▼
      Installed          Not Installed
          │                   │
          ▼                   ▼
    ┌──────────┐        ┌──────────────┐
    │  Verify  │        │  curl -fsSL  │
    │  version │        │  .../ntm...  │
    │          │        │  | bash      │
    └──────────┘        └──────────────┘
                                    │
                                    ▼
                          ┌─────────────────┐
                          │  Installation   │
                          │  complete!      │
                          └─────────────────┘
```

### 11.2 Environment Variables

```bash
# Auto-install ntm without prompting
RU_INSTALL_NTM=yes curl -fsSL .../install.sh | bash

# Skip ntm installation
RU_INSTALL_NTM=no curl -fsSL .../install.sh | bash

# Non-interactive (installs everything including ntm)
RU_NON_INTERACTIVE=1 curl -fsSL .../install.sh | bash
```

---

## 12. CLI Interface Design

### 12.1 Command Syntax

```
ru agent-sweep [options]
```

### 12.2 Options

| Option | Description | Default |
|--------|-------------|---------|
| `--with-release` | Enable Phase 3 (release workflow) | false |
| `-j N`, `--parallel=N` | Process N repos concurrently | 1 |
| `--repos=PATTERN` | Filter repos by pattern | (all) |
| `--dry-run` | Show what would be processed | false |
| `--phase1-timeout=N` | Phase 1 timeout in seconds | 180 |
| `--phase2-timeout=N` | Phase 2 timeout in seconds | 300 |
| `--phase3-timeout=N` | Phase 3 timeout in seconds | 600 |
| `--resume` | Resume interrupted sweep | false |
| `--restart` | Discard state, start fresh | false |
| `--json` | Output JSON results | false |
| `--verbose` | Detailed logging | false |
| `--quiet` | Minimal output | false |

### 12.3 Examples

```bash
# Basic sweep (commit only, no releases)
ru agent-sweep

# With release automation
ru agent-sweep --with-release

# Only specific repos
ru agent-sweep --repos="mcp_*"

# Parallel processing (4 concurrent sessions)
ru agent-sweep -j 4

# Dry run to preview what would happen
ru agent-sweep --dry-run

# Resume interrupted sweep
ru agent-sweep --resume

# Custom timeouts for large repos
ru agent-sweep --phase1-timeout=300 --phase2-timeout=600

# JSON output for scripting
ru agent-sweep --json 2>/dev/null | jq '.summary'
```

### 12.4 Output Examples

**Normal mode (stderr):**
```
→ Checking ntm availability... ok
→ Found 5 repositories with uncommitted changes

→ Processing: mcp_agent_mail
  ├─ Spawning Claude Code session...
  ├─ Phase 1: Deep codebase understanding... done (45s)
  ├─ Phase 2: Intelligent commits... done (78s)
  └─ ✓ Completed (123s)

→ Processing: beads_viewer
  ├─ Spawning Claude Code session...
  ├─ Phase 1: Deep codebase understanding... done (32s)
  ├─ Phase 2: Intelligent commits... done (56s)
  └─ ✓ Completed (88s)

→ Processing: repo_updater
  ├─ Spawning Claude Code session...
  ├─ Phase 1: Deep codebase understanding... done (61s)
  ├─ Phase 2: Intelligent commits... done (124s)
  ├─ Phase 3: GitHub release... done (89s)
  └─ ✓ Completed with release v1.2.0 (274s)

╭─────────────────────────────────────────────────────────────╮
│                   Agent Sweep Complete                       │
│                                                             │
│  Processed: 5 repos                                         │
│  Succeeded: 5                                               │
│  Failed: 0                                                  │
│  Total time: 8m 23s                                         │
╰─────────────────────────────────────────────────────────────╯
```

**JSON mode (stdout):**
```json
{
  "timestamp": "2026-01-06T15:30:00Z",
  "duration_seconds": 503,
  "summary": {
    "total": 5,
    "succeeded": 5,
    "failed": 0
  },
  "repos": [
    {
      "name": "mcp_agent_mail",
      "path": "/data/projects/mcp_agent_mail",
      "success": true,
      "phases_completed": 2,
      "duration_seconds": 123
    },
    {
      "name": "repo_updater",
      "path": "/data/projects/repo_updater",
      "success": true,
      "phases_completed": 3,
      "release": "v1.2.0",
      "duration_seconds": 274
    }
  ]
}
```

---

## 13. Implementation Plan

### 13.1 Phase 1: Foundation (2 days)

**Goal:** Basic ntm integration working end-to-end

**Tasks:**
1. Add ntm_* functions to ru main script
2. Add `ntm_check_available()` with version detection
3. Implement `ntm_spawn_session()` with timeout handling
4. Implement `ntm_send_prompt()` with chunking for >4KB
5. Implement `ntm_wait_completion()` with error detection
6. Add basic `cmd_agent_sweep()` for sequential processing
7. Test with single repo manually

**Deliverables:**
- Working `ru agent-sweep` for single repo
- JSON parsing working (with jq-free fallbacks)

### 13.2 Phase 2: Multi-Repo Processing (2 days)

**Goal:** Process multiple repos with state tracking

**Tasks:**
1. Integrate with existing repo loading (`load_all_repos`)
2. Add `has_uncommitted_changes()` filter
3. Implement sequential repo processing loop
4. Add state file management for resume
5. Implement `--resume` and `--restart` flags
6. Add progress reporting (matching ru's existing style)
7. Add cleanup traps for interrupted runs

**Deliverables:**
- Working multi-repo sweep (sequential)
- Resume capability for interrupted runs
- Proper cleanup on Ctrl+C

### 13.3 Phase 3: Parallel Processing (1 day)

**Goal:** Process repos concurrently

**Tasks:**
1. Adapt existing `run_parallel_sync()` pattern
2. Implement work queue for repos
3. Use unique session names per worker
4. Add directory-based locks for queue/results
5. Aggregate results from parallel workers

**Deliverables:**
- `-j N` parallel processing working
- No session name collisions
- Proper result aggregation

### 13.4 Phase 4: Release Integration (1 day)

**Goal:** Phase 3 (release workflow) working

**Tasks:**
1. Implement `has_release_workflow()` detection
2. Add `--with-release` flag
3. Implement Phase 3 prompt sending
4. Test with repos that have release Actions
5. Handle release-specific errors

**Deliverables:**
- `--with-release` working end-to-end
- Correct detection of release workflows

### 13.5 Phase 5: Installer Integration (0.5 days)

**Goal:** Seamless ntm installation during ru install

**Tasks:**
1. Add ntm detection to install.sh
2. Add prompt for ntm installation
3. Add `RU_INSTALL_NTM` environment variable
4. Test various installation scenarios

**Deliverables:**
- Updated install.sh with ntm integration
- Non-interactive installation working

### 13.6 Phase 6: Testing & Documentation (2 days)

**Goal:** Production-ready quality

**Tasks:**
1. Write unit tests for ntm_* functions
2. Write E2E tests for agent-sweep workflow
3. Add mock pattern for ntm (test without real ntm)
4. Update README.md with new command
5. Update AGENTS.md with agent-sweep guidelines
6. Add troubleshooting section

**Deliverables:**
- Test coverage for new code
- Documentation updated
- CI passing

### 13.7 Timeline Summary

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Foundation | 2 days | 2 days |
| Multi-Repo | 2 days | 4 days |
| Parallel | 1 day | 5 days |
| Release | 1 day | 6 days |
| Installer | 0.5 days | 6.5 days |
| Testing | 2 days | 8.5 days |

**Total estimate: 8-9 days**

---

## 14. Testing Strategy

### 14.1 Unit Tests

**Test file:** `scripts/test_unit_ntm_driver.sh`

```bash
test_ntm_check_available_not_installed() {
    # Mock: ntm not in PATH
    PATH="/empty" ntm_check_available
    assert_equals 1 $? "Should return 1 when ntm not installed"
}

test_json_get_field() {
    local json='{"success":true,"error":"test error"}'
    local result
    result=$(json_get_field "$json" "error")
    assert_equals "test error" "$result" "Should extract error field"
}

test_json_is_success() {
    json_is_success '{"success":true}'
    assert_equals 0 $? "Should return 0 for success:true"

    json_is_success '{"success":false}'
    assert_equals 1 $? "Should return 1 for success:false"
}

test_has_uncommitted_changes() {
    local test_repo=$(mktemp -d)
    git -C "$test_repo" init

    has_uncommitted_changes "$test_repo"
    assert_equals 1 $? "Clean repo should return 1"

    touch "$test_repo/newfile"
    has_uncommitted_changes "$test_repo"
    assert_equals 0 $? "Dirty repo should return 0"

    rm -rf "$test_repo"
}
```

### 14.2 E2E Tests (with mock)

**Test file:** `scripts/test_e2e_agent_sweep.sh`

```bash
# Mock ntm for testing without real sessions
setup_ntm_mock() {
    mkdir -p "$TEST_BIN"
    cat > "$TEST_BIN/ntm" << 'EOF'
#!/bin/bash
case "$1" in
    --robot-status)
        echo '{"success":true,"sessions":[]}'
        ;;
    --robot-spawn=*)
        echo '{"success":true,"session":"test","agents":[{"pane":"0.1","ready":true}]}'
        ;;
    --robot-send=*)
        echo '{"success":true,"delivered":1}'
        ;;
    --robot-wait=*)
        sleep 1  # Simulate work
        echo '{"success":true,"condition":"idle","waited_seconds":1}'
        ;;
    kill)
        echo "killed"
        ;;
esac
EOF
    chmod +x "$TEST_BIN/ntm"
    export PATH="$TEST_BIN:$PATH"
}

test_agent_sweep_dry_run() {
    setup_test_env
    setup_ntm_mock
    setup_dirty_repo "testrepo"

    local output
    output=$("$RU_SCRIPT" agent-sweep --dry-run 2>&1)

    assert_contains "$output" "testrepo" "Should list dirty repo"
    assert_contains "$output" "Dry run" "Should indicate dry run mode"

    cleanup_test_env
}

test_agent_sweep_single_repo() {
    setup_test_env
    setup_ntm_mock
    setup_dirty_repo "testrepo"

    "$RU_SCRIPT" agent-sweep 2>/dev/null
    local exit_code=$?

    assert_equals 0 $exit_code "Should succeed with mock ntm"

    cleanup_test_env
}
```

### 14.3 Test Patterns from ru

Reuse existing test utilities:
- `setup_test_env()` — Creates temp HOME, XDG dirs
- `cleanup_test_env()` — Removes temp dirs
- `assert_equals`, `assert_contains`, `assert_exit_code`
- `skip_test()` — Skip if dependencies missing

**Skip if no tmux:**
```bash
if ! command -v tmux &>/dev/null; then
    skip_test "tmux not available"
fi
```

---

## 15. Risk Analysis

### 15.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| ntm API changes | Low | High | Pin to ntm version, test in CI |
| Claude Code rate limits | Medium | Medium | Detect via patterns, wait and retry |
| Timeout miscalculation | Medium | Medium | Conservative defaults, configurable |
| Race conditions in parallel | Medium | High | Unique session names, proper locking |
| Large repo handling | Low | Medium | Adjustable timeouts, skip option |
| Agent crashes | Low | Medium | Detect via ERROR state, cleanup |
| Prompt too long | Low | Low | Chunking for >4KB |

### 15.2 User Experience Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Long wait times | High | Low | Progress indicators, phase timing |
| Confusing error messages | Medium | Medium | Clear errors with suggestions |
| Unexpected commits | Low | High | Dry-run mode, clear prompts |
| Orphaned tmux sessions | Medium | Low | Cleanup on exit, trap handlers |
| Cost concerns | Medium | Medium | Dry-run shows repo count |

### 15.3 Security Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Secrets in commits | Low | High | Prompt says "Don't commit ephemeral" |
| Unauthorized pushes | Low | High | Respect git credential config |
| Prompt injection | Very Low | Medium | Sanitize repo names in sessions |

---

## 16. Open Questions

### 16.1 Resolved by Deep Dive

1. **State detection mechanism:** Velocity tracking (chars/sec) + 53 regex patterns
2. **Prompt size limits:** ~4KB practical limit, use chunking
3. **Concurrency model:** Sequential per session, parallel across sessions
4. **Error codes:** 9 specific codes mapped to ru exit codes
5. **Completion detection:** 5-second idle threshold + pattern match

### 16.2 Still Open

1. **Activity display:**
   - Should we poll `--robot-activity` for real-time progress?
   - How often? (default 500ms matches ntm's internal poll)

2. **Retry strategy:**
   - How many retries per repo on transient failures?
   - Should we queue failed repos for end-of-run retry?

3. **Cost awareness:**
   - Should we estimate token usage before starting?
   - Integration with `--robot-context` for token tracking?

4. **Multi-agent per repo:**
   - For very large repos, use multiple Claude instances?
   - How to coordinate file reservations?

### 16.3 Future Enhancements

1. **Watch mode:** Continuously monitor for changes and sweep
2. **Webhook integration:** Trigger sweep on GitHub events
3. **Custom phases:** User-defined prompt phases via config
4. **Analytics:** Track commit quality, time savings, patterns
5. **Agent Mail integration:** File reservations for multi-agent

---

## Appendices

### Appendix A: Full Prompt Text

#### Phase 1: Deep Understanding
```
First read ALL of the AGENTS.md file and README.md file super carefully and understand ALL of both! Then use your code investigation agent mode to fully understand the code, and technical architecture and purpose of the project. Use ultrathink.
```

#### Phase 2: Intelligent Commits
```
Now, based on your knowledge of the project, commit all changed files now in a series of logically connected groupings with super detailed commit messages for each and then push. Take your time to do it right. Don't edit the code at all. Don't commit obviously ephemeral files. Use ultrathink.
```

#### Phase 3: GitHub Release
```
Do all the GitHub stuff: commit, deploy, create tag, bump version, release, monitor gh actions, compute checksums, etc. Use ultrathink.
```

### Appendix B: ntm Robot Mode Quick Reference

```bash
# Spawn Claude Code session with wait-for-ready
ntm --robot-spawn=SESSION --spawn-cc=1 --spawn-wait --spawn-dir=/path --ready-timeout=60s

# Send prompt to all Claude agents
ntm --robot-send=SESSION --msg="Your prompt here" --type=claude

# Wait for agents to complete (return to idle)
ntm --robot-wait=SESSION --condition=idle --wait-timeout=300s --exit-on-error

# Get real-time activity state
ntm --robot-activity=SESSION

# Get all sessions status
ntm --robot-status

# Interrupt agent (Ctrl+C)
ntm --robot-interrupt=SESSION

# Kill session
ntm kill SESSION -f
```

### Appendix C: Configuration Reference

#### ru Configuration (~/.config/ru/config)
```bash
# Agent sweep settings
AGENT_SWEEP_PARALLEL=1
AGENT_SWEEP_PHASE1_TIMEOUT=180
AGENT_SWEEP_PHASE2_TIMEOUT=300
AGENT_SWEEP_PHASE3_TIMEOUT=600
AGENT_SWEEP_WITH_RELEASE=false
```

#### Environment Variables
```bash
AGENT_SWEEP_PHASE1_PROMPT="..."  # Override Phase 1 prompt
AGENT_SWEEP_PHASE2_PROMPT="..."  # Override Phase 2 prompt
AGENT_SWEEP_PHASE3_PROMPT="..."  # Override Phase 3 prompt
AGENT_SWEEP_PHASE1_TIMEOUT=180   # Override Phase 1 timeout
AGENT_SWEEP_PHASE2_TIMEOUT=300   # Override Phase 2 timeout
AGENT_SWEEP_PHASE3_TIMEOUT=600   # Override Phase 3 timeout
```

### Appendix D: Exit Codes

| Code | Meaning | Cause |
|------|---------|-------|
| 0 | Success | All repos processed successfully |
| 1 | Partial failure | Some repos failed (timeout, error) |
| 2 | Conflicts | Some repos have unresolved issues |
| 3 | Dependency error | ntm/tmux not available |
| 4 | Invalid arguments | Bad CLI options |
| 5 | Interrupted | User cancelled (use --resume) |

### Appendix E: State Detection Details

**Velocity Tracking (from ntm source):**
- Poll interval: 500ms (configurable)
- Circular buffer: 10 samples
- Calculation: `velocity = runes_added / elapsed_seconds`
- Unicode-aware (counts runes, not bytes)

**State Thresholds:**
| Velocity (chars/sec) | Pattern Match | Resulting State |
|---------------------|---------------|-----------------|
| >10 | any | GENERATING |
| <1 | idle prompt | WAITING |
| 1-10 | no error | THINKING |
| 0 for 5s | any | COMPLETE |
| any | error pattern | ERROR |

**Idle Patterns (priority 200+):**
- `claude>\s*$`
- `\$\s*$`
- `%\s*$`
- `>\s*$`
- `❯\s*$`
- `>>>\s*$`

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-06 | Initial proposal |
| 2.0.0 | 2026-01-06 | Deep dive insights: error codes, state detection, locking, testing |

---

*This document is self-contained and can be shared with other LLMs for review and feedback without requiring access to the ru or ntm source code.*

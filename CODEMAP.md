# Codemap: repo_updater (ru)

> Code structure reference for AI agents
> **Updated**: 2026-01-24 | **Commit**: [`22cd33f`](../../commit/22cd33f)

<!-- TODO: likely will be stale. remote vps does not have repoprompt cli. remove by 2/1/2026. local mac agents can use repoprompt cli directly for codemaps -->

---

## Architecture

**Single-file Bash CLI** (`ru` - 727KB) with comprehensive test suite.

```
repo_updater/
├── ru                    # Main CLI (all commands)
├── install.sh            # Installer script
├── scripts/              # Test suite (90+ test files)
│   ├── test_e2e_*.sh     # End-to-end tests
│   ├── test_unit_*.sh    # Unit tests
│   └── test_framework.sh # Test harness
└── examples/             # Example configurations
```

---

## CLI Commands

| Command | Description |
|---------|-------------|
| `ru sync` | Clone missing repos, pull updates (main use case) |
| `ru status` | Show repo status (ahead/behind/dirty) |
| `ru list` | List configured repositories |
| `ru add` | Add repository to config |
| `ru remove` | Remove repository from config |
| `ru init` | Initialize ru configuration |
| `ru config` | Show/edit configuration |
| `ru doctor` | Health checks and diagnostics |
| `ru review` | AI-assisted issue/PR review (two-phase) |
| `ru agent-sweep` | Automated repo maintenance |
| `ru prune` | Clean up stale worktrees/state |
| `ru worktree` | Manage git worktrees |
| `ru completion` | Shell completion scripts |
| `ru self-update` | Update ru to latest version |

---

## Key Flags

| Flag | Purpose |
|------|---------|
| `--dry-run` | Preview without changes |
| `--parallel N` / `-jN` | Parallel workers |
| `--autostash` | Auto-stash dirty repos |
| `--no-fetch` | Skip network (status only) |
| `--non-interactive` | No prompts (CI mode) |
| `--format json\|toon` | Output format |
| `--json` | Shorthand for `--format json` |
| `--resume` | Resume interrupted operation |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Partial success (some repos failed) |
| 2 | Conflicts detected |
| 3 | System error |
| 4 | Bad arguments |
| 5 | Interrupted (use `--resume`) |

---

## Internal Functions (Selected)

### Core Operations
- `do_sync()` - Main sync orchestration
- `sync_single_repo()` - Clone or pull one repo
- `get_repo_status()` - Git plumbing status check
- `handle_conflict()` - Conflict resolution logic

### Parallel Processing
- `work_stealing_queue()` - Distribute work to workers
- `worker_loop()` - Individual worker process
- `dir_lock_try_acquire()` - Atomic mkdir-based locking

### Review System
- `review_plan()` - Phase 1: discovery
- `review_apply()` - Phase 2: application
- `spawn_session()` - Launch Claude Code session
- `score_work_item()` - Priority scoring algorithm

### Output
- `emit_json()` - JSON output to stdout
- `emit_human()` - Human output to stderr
- `progress_summary()` - Progress bar/spinner

---

## Test Coverage

```
scripts/
├── test_e2e_sync_*.sh      # Sync workflow tests
├── test_e2e_review.sh      # Review system tests
├── test_e2e_worktree.sh    # Worktree management
├── test_unit_*.sh          # Function-level tests
├── test_security_*.sh      # Security guardrails
└── run_all_tests.sh        # Full suite runner
```

**Run tests:**
```bash
./scripts/run_all_tests.sh           # Full suite
./scripts/test_e2e_sync_clone.sh     # Single test
```

---

## Configuration Paths

| Path | Purpose |
|------|---------|
| `~/.config/ru/config` | Main config (projects_dir, etc.) |
| `~/.config/ru/repos.d/` | Repo lists (*.txt files) |
| `~/.local/state/ru/` | Runtime state, logs, checkpoints |
| `~/.cache/ru/` | Cached data |

---

## Agent Integration

**Already has built-in agent blurb in README.** Key points for agents:

- Use `--format json` for structured output
- Never create worktrees in projects dir (use `/tmp/`)
- Never parse human output - use JSON mode
- Check exit codes for automation

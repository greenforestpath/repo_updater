# RESEARCH FINDINGS: repo_updater (ru) — TOON Integration

Date: 2026-01-24 (updated for bd-382)

## Snapshot
- Language/entrypoint: Pure Bash; single executable script `ru` (Bash 4+).
- Output discipline: human-readable logs to stderr, structured data to stdout.
- Structured outputs today: JSON (via `--json`) and NDJSON files on disk under `~/.local/state/ru/`.

## 1) Output Surfaces (stdout data)
### Global `--json` (parse_args → `JSON_OUTPUT=true`)
Structured JSON is emitted for:
- `ru sync --json` → summary object (`generate_json_report`).
- `ru status --json` → array of repo status objects.
- `ru review --json`:
  - discovery summary (`show_discovery_summary_json`)
  - completion summary (`build_review_completion_json`)
  - analytics (`cmd_review_analytics` → metrics file JSON)
  - status (`cmd_review_status` → lock/checkpoint/state JSON)
- `ru ai-sync --json` → dry-run list + final summary object.
- `ru dep-update --json` → final summary object.
- `ru prune --json` → array of orphan repo paths.

### Command-specific `--json`
- `ru agent-sweep --json` uses its own `json_output` flag (exported as `AGENT_SWEEP_JSON_OUTPUT`) and emits a JSON summary object; per-repo details are NDJSON on disk.
- `get_dirty_repos --json` → array of `{path,status}` objects (used by ai-sync).

### Persistent NDJSON/JSON on disk (stdout unaffected)
- `~/.local/state/ru/logs/**/results.ndjson`
- `~/.local/state/ru/review/**` (state.json, checkpoint.json, gh-actions.jsonl, results.ndjson)
- `~/.local/state/ru/agent-sweep/**` (state.json, results.ndjson)

## 2) Serialization Entry Points (file + functions)
File: `ru`
- `parse_args` → sets `JSON_OUTPUT`.
- `cmd_sync` → `generate_json_report`.
- `cmd_status` → JSON array branch.
- `cmd_review_status` → JSON object branch.
- `cmd_review_analytics` → `cat "$metrics_file"` when JSON.
- Review discovery helpers:
  - `show_discovery_summary_json`
  - `build_review_summary_json`
  - `build_review_items_json`
  - `build_review_discovery_json`
  - `build_review_completion_json`
- `cmd_ai_sync` → JSON dry-run list + summary.
- `cmd_dep_update` → JSON summary.
- `cmd_prune` → JSON list of orphan paths.
- `cmd_agent_sweep` → JSON summary (uses local `json_output`).
- JSON helpers: `json_escape`, `json_get_field`, `json_validate` (safe for future TOON integration wrappers).

## 3) Format Flags & Env Precedence (proposed)
Keep existing behavior; add TOON as opt-in:
1. CLI: `--format json|toon` (default `json` for data outputs)
2. Env: `RU_OUTPUT_FORMAT`
3. Env fallback: `TOON_DEFAULT_FORMAT`
4. Default: JSON (maintain backward compatibility)

Notes:
- `--json` should remain a shortcut for `--format json`.
- `ru agent-sweep` currently parses `--json` internally; may need `--format` added separately if TOON support is desired there.

## 4) TOON Strategy (Bash tool)
- Use `toon.sh` (bd-2vm) where available; fallback to direct `tru` CLI if not.
- Convert **stdout structured data only**; keep stderr logs unchanged.
- Preserve JSON output shape when format=json.
- If TOON encode fails or `tru` missing: emit JSON + warning on stderr (non-fatal).
- NDJSON files on disk should remain JSON for auditability unless a future `--format toonl` is explicitly introduced.

## 5) Protocol Constraints / Compatibility
- Many users pipe `ru ... --json` into `jq`; keep JSON intact.
- `agent-sweep`, `review` flows rely on JSON state files; do not alter on-disk formats.
- Maintain stdout/stderr separation (stdout data-only, stderr diagnostics).

## 6) Docs to Update (when implementing)
- `README.md`: Output Modes + examples for `--format toon`, env vars.
- `ru --help` usage text and flag table.
- `AGENTS.md`: note TOON format option + precedence.
- `TESTING.md`: add TOON/format tests and fixtures guidance.

## 7) Fixtures to Capture (for bd-21h)
Suggested commands (run in safe environment):
- `ru status --json` (read-only).
- `ru sync --json --dry-run` (no mutations).
- `ru review --status --json`.
- `ru review --analytics --json` (if metrics exist).
- `ru ai-sync --dry-run --json`.
- `ru dep-update --dry-run --json`.
- `ru prune --json` (no archive/delete flags).
- `ru agent-sweep --dry-run --json` (if safe).

## 8) Test Plan (integration brief)
Unit-style checks (bash tests or scripts):
- Format precedence: CLI `--format` > `RU_OUTPUT_FORMAT` > `TOON_DEFAULT_FORMAT` > default.
- `--json` still outputs JSON (unchanged).
- TOON output decodes to JSON equivalence (`tru --decode`).
- Fallback when `tru` missing → JSON + stderr warning, exit code unchanged.
- Stdout/stderr separation preserved.

E2E script design:
- Run representative commands in `--format json` vs `--format toon`.
- Decode TOON and compare to JSON output via `jq -S .`.
- Log to `test_logs/ru_<timestamp>/` with stdout/stderr/exit codes.

## 9) Risks & Edge Cases
- `tru` binary missing or old: must gracefully fall back.
- Large outputs (review/agent-sweep) → consider streaming/`toonl` only if explicitly requested.
- NDJSON audit logs must remain JSON (do not silently convert).
- Some commands mutate repos; fixture capture must use safe flags (`--dry-run`) and user approval.

## Operational Constraints
- Running ru creates temp files and cleans them up; avoid running destructive paths without explicit approval.
- If TMPDIR issues arise, set `TMPDIR` to a known safe dir before running commands (with approval).

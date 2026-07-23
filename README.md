# gptel-agent-harness

An extension to `gptel-agent` that makes it behave like a reliable coding agent (similar to OpenCode). It adds completion supervision, context management, session persistence, enhanced tools, and a custom agent definition.

## Features

- **Completion supervision** — Prevents agents from stopping prematurely by injecting verification nudges before allowing terminal states. Resets on tool progress.
- **Context supervision** — Monitors token usage, auto-compacts when exceeding threshold, self-calibrates estimation using API-reported counts, displays ratio in mode-line.
- **Session management** — Auto-saves sessions after each response, generates titles, supports restore with live preview.
- **Enhanced tools** — Fast `glob` via `git ls-files`, robust `grep` via `git grep -e`, and a `Question` tool for interactive user input during execution.
- **Custom agent** — `gptel-opencode-agent` with OpenCode-like behavior, loaded from `gptel-agent-harness-agent-dirs`.
- **Commands** — Project initialization, code review, conversation summary, and manual compaction.

## Installation

```elisp
(require 'gptel-agent-harness)
(gptel-agent-harness-mode 1)
```

## Example Configuration

```elisp
(use-package gptel-agent-harness
  :ensure t
  :config
  (require 'gptel-context)
  ;; MUST add task-completion-rules into llm context
  (gptel-add-file
   (expand-file-name
    "rules/task-completion-rules.md"
    (file-name-directory
     (or (locate-library "gptel-agent-harness")
         (error "gptel-agent-harness not found")))))
  (gptel-agent-harness-mode 1)
  (gptel-agent-update)
  ;; Add custom model context windows
  (add-to-list 'gptel-agent-harness-context-windows
               '("openai/gpt-oss-120b" . 128000))
  ;; Optional keybindings
  (global-set-key (kbd "C-c g a") #'gptel-opencode-agent)
  (global-set-key (kbd "C-c g r") #'gptel-agent-harness-commands-review)
  (global-set-key (kbd "C-c g i") #'gptel-agent-harness-commands-initialize)
  (global-set-key (kbd "C-c g u") #'gptel-agent-harness-commands-summary)
  (global-set-key (kbd "C-c g c") #'gptel-agent-harness-commands-compact-buffer)
  (global-set-key (kbd "C-c g s") #'gptel-agent-harness-restore-session)
  (global-set-key (kbd "C-c g l") #'gptel-agent-harness-restore-latest-session))
```

## Completion Supervision

When the agent attempts to stop, the harness injects a nudge message asking it to verify task completion. Configurable via:

- `gptel-agent-harness-max-nudges` — Max consecutive nudges (default: 2). Resets on tool calls.
- `gptel-agent-harness-nudge-message` — Message injected on premature stop.

Only applies to top-level agentic sessions with tools enabled.

## Context Supervision

Estimates token usage before each LLM request. When usage exceeds the threshold, compaction is triggered automatically.

- `gptel-agent-harness-context-trigger` — Ratio threshold (default: 0.70).
- `gptel-agent-harness-context-windows` — Alist of model name patterns to context sizes. Unknown models fall back to 32768.

### Token Calibration

Self-calibrates by comparing heuristic estimates (~4 chars/token Latin, ~2 CJK) against actual API-reported input token counts. Clamped to [0.5, 3.0]. No configuration needed.

### Mode-Line Display

Shows `[Ctx:45%/70%]` color-coded: green (<50%), yellow (50–80%), red (>80%).

- `gptel-agent-harness-show-context-ratio` — Toggle display (default: t).

## Compaction

### Automatic

Triggered when context exceeds `gptel-agent-harness-context-trigger`. The harness:

1. Removes the current round (last response + tool results)
2. Extracts previous summary (if any) into `<previous-summary>` tags
3. Sends buffer to LLM with compact prompt
4. Rebuilds: header + new summary + separator + current round + recent requests
5. Resumes with `gptel-send`

### Manual

```
M-x gptel-agent-harness-commands-compact-buffer
```

Same summarization logic without interrupting active requests or replaying messages.

### Custom Compaction Engine

The harness uses its own `gptel-agent-harness-commands-compact` instead of
`gptel-agent-compact` from `gptel-agent.el`:

| | Built-in (`gptel-agent-compact`) | Harness version |
|---|---|---|
| Prompt delivery | Reads buffer up to point | Sends content as explicit string |
| Buffer replacement | Narrowing + position tracking | `erase-buffer` + `insert` |
| Transforms | Applies default transforms | None (`:transforms nil`) |
| Error handling | Falls through on non-string | Handles all response types |

The built-in's narrowing/position approach caused issues with repeated compaction (stale markers, partial replacement). The harness version is stateless: send string → receive string → replace buffer.

### Configuration

- `gptel-agent-harness-compact-header` — Header text (default: `"**[Compacted Summary]**\n\n"`).
- `gptel-agent-harness-compact-separator` — Separator text (default: `"\n\n---\n\n**[Context compacted]**\n\n---\n\n"`).
- `gptel-agent-harness-compact-resume-count` — Recent user messages to replay after compaction (default: 3).
- Compaction prompt: edit `prompts/compact.txt` directly.

## Session Management

Auto-saves after each LLM response. Generates meaningful titles asynchronously.

- `gptel-agent-harness-session-dir` — Storage directory (default: `~/.emacs.d/gptel-sessions/`).
- `gptel-agent-harness-auto-save-session` — Toggle auto-save (default: t).
- `M-x gptel-agent-harness-restore-session` — Restore with live preview.
- `M-x gptel-agent-harness-restore-latest-session` — Restore most recent.

## Commands

| Command | Description |
|---------|-------------|
| `gptel-opencode-agent` | Start an OpenCode-like agent session |
| `gptel-agent-harness-commands-initialize` | Create/update AGENTS.md for a project |
| `gptel-agent-harness-commands-review` | Code review (uncommitted, commit, branch, or PR) |
| `gptel-agent-harness-commands-summary` | Summarize conversation (full buffer or region) |
| `gptel-agent-harness-commands-compact-buffer` | Manually compact the current buffer |
| `gptel-agent-harness-restore-session` | Restore a saved session |
| `gptel-agent-harness-restore-latest-session` | Restore the most recent session |

## Enhanced Tools

- **Glob**: Uses `git ls-files` for `.gitignore`-aware listing; falls back to `tree`.
- **Grep**: Uses `git grep -e` for safe regex; falls back to `rg` or `grep`.
- **Question**: LLM asks user via `completing-read` (single/multi-select, free-text). Encourage usage by adding guidance to your system prompt.

## File Structure

```
site-lisp/
├── gptel-agent-harness.el          # Core: FSM supervision, context, compaction
├── gptel-agent-harness-session.el  # Session: auto-save, restore, preview
├── gptel-agent-harness-tools.el    # Enhanced tools + Question tool
├── gptel-agent-harness-agent.el    # Agent definition (gptel-opencode-agent)
├── gptel-agent-harness-commands.el # Commands (init, review, summary, compact)
├── gptel-agent-harness-test.el     # ERT test suite
├── prompts/                        # Prompt templates
└── agents/                         # Agent definition files
```

## Requirements

- Emacs 29.1+, gptel-agent >= 0.0.1, compat >= 30.1.0.0
- Optional: `git`, `tree`, `ripgrep`

## License

GPL-3.0-or-later

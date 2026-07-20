# gptel-agent-harness

`gptel-agent-harness` is an extension to the excellent `gptel-agent`，it improves `gptel-agent` by providing:

1. **Completion supervision**

   * Prevents agents from stopping prematurely.
   * Intercepts terminal FSM transitions (`DONE` / `ERRS`).
   * Asks the model to verify completion before allowing termination.
   * Resets the stop guard when real progress happens through tool calls.

2. **Context supervision**

   * Monitors estimated context usage before LLM requests.
   * Automatically triggers context compaction when the context window exceeds a configurable threshold.
   * Supports model-specific context window sizes.
   * Self-calibrates token estimation using actual API-reported input token counts.
   * Displays context usage ratio in mode-line.

3. **Session management**

   * Auto-saves gptel agent buffers after each LLM response.
   * Stores full session state (model, backend, system prompt, tools, parameters).
   * Generates meaningful session titles via LLM after first response.
   * Restore any session with `gptel-agent-harness-restore-session` or the most recent one with `gptel-agent-harness-restore-latest-session`.
   * Live preview during session selection.

4. **Improved tools**

   * Enhanced `glob` tool using `git ls-files` for fast, `.gitignore`-aware file listing in git repos, falling back to `tree`.
   * Enhanced `grep` tool using `git grep -e` for robust regex handling, with automatic fallback to `ripgrep` or `grep`.

5. **Custom agent definition**

   * Provides `gptel-opencode-agent` with OpenCode similar behavior and capabilities
   * Uses agent definitions from `gptel-agent-harness-agent-dirs`.

6. **Project initialization**

   * `gptel-agent-harness-commands-initialize` creates/updates `AGENTS.md` for a project via a dedicated LLM session.
   * Uses the initialize prompt from `prompts/initialize.txt`.

The goal is to make gptel-agent behave more like a reliable coding agent, such as OpenCode.

---

## Installation

Install through Emacs package manager:

```elisp
(package-install 'gptel-agent-harness)
```

Or with `straight.el`:

```elisp
(straight-use-package 'gptel-agent-harness)
```

Enable the mode:

```elisp
(require 'gptel-agent-harness)
(gptel-agent-harness-mode 1)
```

The mode is global and installs advice around gptel's FSM transition and request functions.

---

# Features

# Completion Supervision

### Problem

LLM agents often stop when they believe a task is finished, even when:

* files were not verified,
* tests were not executed,
* requested changes are incomplete,
* tool calls are still needed.

`gptel-agent-harness` adds a lightweight completion guard.

### Workflow

```
LLM finishes response
        |
        v
gptel FSM enters DONE / ERRS
        |
        v
completion check
        |
        +---- incomplete
        |
        v
inject verification prompt
        |
        v
continue agent execution
```

The harness only applies this logic when:

* the session is a top-level user agent session,
* tools are enabled,
* nudge attempts remain.

Sub-agent FSMs are not modified.

---

## Nudge Mechanism

When the agent attempts to stop, the harness injects:

```text
Review the original user request and the Task Completion Rules in the context. Verify whether all completion criteria are satisfied. If not, continue by making tool calls. Do not stop until the rules are fully met.
```

The agent receives another chance to:

* inspect files,
* run commands,
* verify results,
* continue using tools.

---

## Configuration

## `gptel-agent-harness-max-nudges`

Maximum consecutive completion checks.

Default:

```elisp
(setq gptel-agent-harness-max-nudges 2)
```

Example:

```elisp
(setq gptel-agent-harness-max-nudges 3)
```

The counter resets whenever the agent performs tool calls:

```
tool execution
      |
      v
reset nudge counter
```

This prevents unnecessary blocking after genuine progress.

---

## `gptel-agent-harness-nudge-message`

Message injected when the agent tries to stop.

Example:

```elisp
(setq gptel-agent-harness-nudge-message
      "Review your previous response against the user's requirements. If anything remains incomplete, continue working with tools. Only stop when the task is fully verified.")
```

---

## `gptel-agent-harness-verbose`

Enable logging.

Default:

```elisp
(setq gptel-agent-harness-verbose nil)
```

Enable:

```elisp
(setq gptel-agent-harness-verbose t)
```

Example output:

```
gptel-agent-harness: completion nudge 1/2 — asking LLM to review task
```

---

# Context Supervision

Long-running coding agents can exceed the model context window.

`gptel-agent-harness` checks context size before every LLM request.

Workflow:

```
before LLM request
        |
        v
estimate context tokens
        |
        v
usage > threshold?
        |
        +---- yes
        |
        v
run compaction
        |
        v
send request
```

---

## Context Threshold

### `gptel-agent-harness-context-trigger`

Context usage ratio that triggers compaction.

Default:

```elisp
(setq gptel-agent-harness-context-trigger 0.70)
```

Example:

```elisp
(setq gptel-agent-harness-context-trigger 0.80)
```

With the default value, compaction starts when estimated usage exceeds 70% of the model context window.

---

## Supported Context Windows

Default model table:

```elisp
(setq gptel-agent-harness-context-windows
      '(("gpt-5-mini" . 128000)
        ("gpt-5" . 400000)
        ("claude" . 200000)
        ("deepseek-v3" . 128000)
        ("deepseek-v4" . 1000000)
        ("qwen3.5" . 131072)
        ("qwen3" . 131072)
        ("glm-5.2" . 1000000)
        ("glm-5.1" . 128000)
        ("kimi-k2.7" . 256000)
        ("kimi" . 128000)))
```

Unknown models use a safe fallback:

```text
32768 tokens
```

You can extend the table:

```elisp
(add-to-list
 'gptel-agent-harness-context-windows
 '("my-model" . 200000))
```

---

## Compaction Prompt

Read from `prompts/compact.txt`, copied from OpenCode's compaction prompt. It preserves:

* file paths,
* identifiers,
* API names,
* important decisions,
* constraints,
* previous summaries.

It removes stale information and keeps only context required for continuing the task.

The prompt is read from `gptel-agent-harness-compact-prompt-file` (a constant).
To customize, edit the `prompts/compact.txt` file directly.

---

# Session Management

Agent sessions are valuable — losing context after a crash or accidental buffer kill is costly. `gptel-agent-harness` auto-saves sessions to disk after every LLM response.

## How It Works

```
LLM responds
      |
      v
gptel-post-response-functions fires
      |
      v
auto-save buffer + metadata to session dir
```

Each buffer gets a single timestamped session file on first save. Subsequent saves overwrite the same file with updated content and state.

After the first save, the harness asynchronously generates a meaningful title from the user's first message (using the prompt in `prompts/title.txt`). The session file is then renamed from the generic `project_YYMMDDHHMMSS.md` format to `Generated-Title_YYMMDDHHMMSS.md`. When restored, the title is used as the buffer name (truncated to ~20 chars for mode-line space).

## Session Directory

### `gptel-agent-harness-session-dir`

Where session files are stored.

Default:

```elisp
(setq gptel-agent-harness-session-dir
      (expand-file-name "gptel-sessions/" user-emacs-directory))
```

## Enable/Disable Auto-Save

### `gptel-agent-harness-auto-save-session`

Default:

```elisp
(setq gptel-agent-harness-auto-save-session t)
```

Disable:

```elisp
(setq gptel-agent-harness-auto-save-session nil)
```

## Restoring Sessions

Restore a specific session (with live preview):

```
M-x gptel-agent-harness-restore-session
```

Restore the most recent session:

```
M-x gptel-agent-harness-restore-latest-session
```

Restored sessions open in a fresh buffer (not visiting the session file) with all gptel state restored: model, backend, system prompt, temperature, max tokens, etc.

### Live Preview

When selecting a session file, a preview window appears on the right showing:

* Session metadata (model, project directory, backend)
* First 40 lines of content (configurable via `gptel-agent-harness-preview-lines`)

The preview updates as you navigate candidates in the minibuffer.

---

# Mode-Line Display

The harness displays context usage ratio in the mode-line of gptel buffers:

```
[Ctx:45%/70%]
```

Color-coded by severity:

* Green (`success`): Below 50%
* Yellow (`warning`): 50–80%
* Red (`error`): Above 80%

### `gptel-agent-harness-show-context-ratio`

Enable/disable mode-line display.

Default:

```elisp
(setq gptel-agent-harness-show-context-ratio t)
```

Disable:

```elisp
(setq gptel-agent-harness-show-context-ratio nil)
```

---

# Compaction Configuration

## `gptel-agent-harness-compact-header`

Header inserted at the top of the buffer after compaction.

Default:

```elisp
(setq gptel-agent-harness-compact-header
      "**[Compacted Summary]**\n\n")
```

## `gptel-agent-harness-compact-separator`

Separator inserted after the compacted summary.

Default:

```elisp
(setq gptel-agent-harness-compact-separator
      "\n\n---\n\n**[Context compacted]**\n\n---\n\n")
```

## `gptel-agent-harness-compact-resume-count`

Number of recent user requests to replay after compaction.

Default:

```elisp
(setq gptel-agent-harness-compact-resume-count 3)
```

---

# Token Calibration

The context supervision uses a heuristic token estimate (~4 chars/token for Latin, ~2 chars/token for CJK). This can drift from actual tokenizer behavior.

The estimate covers the full request payload: system prompt, all messages (user, assistant, tool results), tool call arguments, and tool definitions (schemas). It supports all gptel backends (OpenAI, Anthropic, Bedrock, Gemini, OpenAI Responses API).

`gptel-agent-harness` self-calibrates by comparing its estimate to the actual **input** token count reported by the API after each response.

```
after LLM response
       |
       v
read actual input tokens from gptel--token-usage
       |
       v
calibration = actual_input / raw_estimate
       |
       v
apply calibration to future estimates
```

The calibration factor is clamped to `[0.5, 3.0]` to avoid pathological values from measurement anomalies.

No configuration needed — calibration happens automatically.

---

# Improved Tools

`gptel-agent-harness` includes enhanced versions of the `glob` and `grep` tools.

## Enhanced Glob Tool

The `glob` tool uses `git ls-files` inside git repositories for:

* **Speed**: Significantly faster than recursive filesystem traversal.
* **`.gitignore` awareness**: Respects your `.gitignore` rules automatically.
* **Fallback**: Outside git repos, falls back to `tree` command.

Configuration:

```elisp
;; No configuration needed — works automatically in git repos
```

## Enhanced Grep Tool

The `grep` tool passes regex patterns via `-e` flag to `git grep`, avoiding misinterpretation of patterns starting with a dash.

It automatically chooses the best available grepper:

1. `git grep` (inside git repos)
2. `ripgrep` (`rg`)
3. Standard `grep`

---

# Custom Agent Definition

`gptel-agent-harness` provides `gptel-opencode-agent`, it reuses the system prompt from OpenCode, and is designed to provide the same behavior and capabilities as the original OpenCode agent within Emacs.

## Usage

Call the agent directly:

```elisp
M-x gptel-opencode-agent
```

Or from within gptel:

```elisp
(gptel-opencode-agent)
```

## Configuration

### `gptel-agent-harness-agent-dirs`

Directories containing agent definition files.

Default:

```elisp
(setq gptel-agent-harness-agent-dirs
      (list (expand-file-name "agents" user-emacs-directory)))
```

Example:

```elisp
(setq gptel-agent-harness-agent-dirs
      '("~/my-custom-agents"
        (expand-file-name "agents" user-emacs-directory)))
```

Agent definition files in these directories are loaded when the harness is enabled.

---

# Project Initialization

`gptel-agent-harness-commands-initialize` creates or updates `AGENTS.md` for a project.

It launches a dedicated gptel buffer with agent tools enabled and uses the
initialize prompt from `prompts/initialize.txt` to guide the LLM in analyzing
the repository and generating AGENTS.md.

```
M-x gptel-agent-harness-commands-initialize
```

When called interactively, it detects the current project root and prompts for
confirmation.  You can provide extra instructions via the `$ARGUMENTS`
placeholder in the initialize prompt.

If a region is active when calling, the selected text is sent as initial context.

---

# Example Configuration

```elisp
(use-package gptel-agent-harness
  :ensure t
  :config
  (progn
    (setq gptel-agent-harness-max-nudges 2
          gptel-agent-harness-context-trigger 0.70
          gptel-agent-harness-auto-save-session t
          gptel-agent-harness-verbose t)
    (require 'gptel-context)
    ;; add task-completion-rules into llm context
    (gptel-add-file
     (expand-file-name
      "task-completion-rules.md"
      (file-name-directory
       (or (locate-library "gptel-agent-harness")
           (error "gptel‑agent‑harness not found")))))
    (gptel-agent-harness-mode 1)
    (gptel-agent-update)
    (add-to-list 'gptel-agent-harness-context-windows
                 '("openai/gpt-oss-120b" . 128000))))
```

---

# File Structure

```
site-lisp/
├── gptel-agent-harness.el          # Core: FSM supervision, context management, compaction, mode-line
├── gptel-agent-harness-session.el  # Session: auto-save, title generation, preview, restore
├── gptel-agent-harness-tools.el    # Enhanced glob/grep tools
├── gptel-agent-harness-agent.el    # Agent definition (gptel-opencode-agent)
├── gptel-agent-harness-commands.el # Commands (project initialization)
├── gptel-agent-harness-test.el     # ERT test suite
├── prompts/
│   ├── compact.txt                 # Context compaction prompt
│   ├── title.txt                   # Session title generation prompt
│   └── initialize.txt              # Project initialization prompt
└── agents/                         # Agent definition files
```

---

# Requirements

* Emacs 29.1+
* gptel-agent >= 0.0.1
* compat >= 30.1.0.0

Optional (for enhanced tools):

* `git` — for fast glob/grep in git repositories
* `tree` — fallback for glob outside git repos
* `ripgrep` (`rg`) — alternative grepper

---

# License

GPL-3.0-or-later

---

# gptel-agent-harness

Agent execution harness for `gptel-agent`.

`gptel-agent-harness` improves the reliability of gptel agent sessions by providing two execution supervisors:

1. **Completion supervision**

   * Prevents agents from stopping prematurely.
   * Intercepts terminal FSM transitions (`DONE` / `ERRS`).
   * Asks the model to verify completion before allowing termination.
   * Resets the stop guard when real progress happens through tool calls.

2. **Context supervision**

   * Monitors estimated context usage before LLM requests.
   * Automatically triggers context compaction when the context window exceeds a configurable threshold.
   * Supports model-specific context window sizes.

The goal is to make gptel agents behave more like reliable coding agents:

> Continue working until completion is verified, and keep long-running sessions usable through automatic context management.

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

## 1. Completion Supervision

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

## 2. Nudge Mechanism

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
      '(("gpt-5" . 400000)
        ("gpt-5-mini" . 128000)
        ("claude" . 200000)
        ("deepseek-v3" . 128000)
        ("deepseek-v4" . 1000000)
        ("qwen3" . 131072)
        ("qwen3.5" . 131072)
        ("glm-5" . 128000)
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

Copied compaction prompt from opencode, it preserves:

* file paths,
* identifiers,
* API names,
* important decisions,
* constraints,
* previous summaries.

It removes stale information and keeps only context required for continuing the task.

Configure with:

```elisp
(setq gptel-agent-harness-compact-prompt
      "Your custom compaction instructions...")
```

---

# Example Configuration

```elisp
(use-package gptel-agent-harness
  :ensure t
  :config
  (progn
    (setq gptel-agent-harness-max-nudges 3
          gptel-agent-harness-context-trigger 0.75
          gptel-agent-harness-verbose t)
    (gptel-agent-harness-mode 1)
    (require 'gptel-context)
    ;; add task-completion-rules into llm context
    (gptel-add-file
     (expand-file-name
      "task-completion-rules.md"
      (file-name-directory
       (or (locate-library "gptel-agent-harness")
           (error "gptel‑agent‑harness not found")))))))
```

---

# How It Works Internally

The harness extends gptel execution through one advice.

## FSM Transition Advice

Intercepts:

```
gptel--fsm-transition
```

Logic:

1. Detect terminal states:

```
DONE
ERRS
```

2. Check:

* agent has tools,
* session is top-level,
* nudge budget remains.

3. If allowed:

```
DONE
 |
 v
WAIT
 |
 v
inject verification prompt
 |
 v
continue execution
```

4. When tool calls occur:

```
TOOL / TPRE
      |
      v
reset nudge counter
```

---

# Design Goals

`gptel-agent-harness` follows three principles:

## 1. Completion should be verified

An agent should not stop simply because it believes it is finished.

It should stop after:

* checking results,
* validating changes,
* satisfying requirements.

## 2. Progress should be rewarded

Tool usage indicates real progress.

Therefore:

```
tool call
    |
    v
reset completion guard
```

## 3. Long sessions should remain usable

Automatic compaction keeps long coding sessions within the model context window.

---

# Requirements

* Emacs 25.1+
* gptel >= 0.9.9.5
* compat >= 0.33.0
* nadvice >= 0.4

---

# Compatibility

Tested with:

* Emacs 25+
* gptel 0.9.9.5+

---

# License

GPL-3.0-or-later

---

# Author

Huming Chen

GitHub:

https://github.com/beacoder/gptel-agent-harness

---

# Package Information

* Version: 0.3
* Keywords: programming, convenience, ai, agent
* Description: Agent execution harness for gptel-agent.

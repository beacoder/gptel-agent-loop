# gptel-agent-loop.el

[![MELPA](https://melpa.org/images/gptel-agent-loop.svg)](https://melpa.org/#/gptel-agent-loop)

## Description

Prevents gptel agent from stopping prematurely without confirming task completion. Intercepts terminal FSM states (DONE/ERRS) and asks the LLM to review the full conversation history before deciding to stop. Resets after every successful tool call.

## Installation

Add to your `.emacs.el` or initialize via Emacs package manager:

```el
(package-install 'gptel-agent-loop)
```

Or with straight:

```el
(straight-use-package 'gptel-agent-loop)
```

Then enable the minor mode:

```el
(require 'gptel-agent-loop)
(gptel-agent-loop-mode 1)
```

## Usage

- **Enable**: `(gptel-agent-loop-mode 1)`
- **Disable**: `(gptel-agent-loop-mode 0)`

The mode is global by default and activates automatically when you type `M-x gptel-agent-loop-mode`.

## Configuration

### `gptel-agent-loop-max-nudges`

Maximum consecutive nudges before allowing the agent to stop. The counter resets to 0 whenever the LLM makes a tool call (real progress).

**Default**: 2

```el
(setq gptel-agent-loop-max-nudges 3)
```

### `gptel-agent-loop-nudge-message`

Message injected when the LLM would stop. Appended as a user turn, instructing the LLM to review the full history and decide whether to continue or stop.

**Default**: "Review the original user request and the Task Completion Rules in the context. Verify whether all completion criteria are satisfied. If not, continue by making tool calls. Do not stop until the rules are fully met."

```el
(setq gptel-agent-loop-nudge-message
      "Review your previous response and task requirements. Are you confident you've fully completed the user's request? If yes, please acknowledge and we can stop. If no, please continue with additional tool calls.")
```

### `gptel-agent-loop-verbose`

Log agent loop actions to *Messages* buffer.

**Default**: nil

```el
(setq gptel-agent-loop-verbose t)
```

### Include task-completion-rules.md as llm context

```el
(require 'gptel-context)
(gptel-add-file
 (expand-file-name "task-completion-rules.md"
                   (file-name-directory
                    (or (locate-library "gptel-agent-loop")
                        (error "gptel‑agent‑loop not found")))))
```

## How It Works

1. When the agent would normally stop (reaching DONE or ERRS FSM states)
2. The package intercepts this and sends a "nudge" message asking the LLM to review the task
3. The LLM can decide to continue by making tool calls or stop if fully confident
4. The counter resets when the LLM makes any tool call (TOOL/TPRE states)

## Examples

```el
(use-package gptel-agent-loop :ensure t)

(use-package gptel-agent
  :ensure t
  :config
  (progn
    (gptel-agent-update)
    ;; add project related information as llm context, e.g: coding guideline, etc.
    (require 'gptel-context)
    (gptel-add-file
     (expand-file-name "task-completion-rules.md"
                       (file-name-directory
                        (or (locate-library "gptel-agent-loop")
                            (error "gptel‑agent‑loop not found")))))
    ;; improve gptel agent loop resilience
    (require 'gptel-agent-loop)
    (gptel-agent-loop-mode 1)))
```

## Requirements

- Emacs 24.3+ (for `defvar-local`)
- gptel package (>= 0.9.9.5)
- compat package (>= 0.33.0, for `when-let*`)
- nadvice package (>= 0.4, for `advice-remove`)

## Compatibility

- Emacs: 24.3+
- gptel: 0.9.9.5+

## License

This program is free software; you can redistribute it and/or modify
it under the terms of the MIT License.

See <https://opensource.org/licenses/MIT> for more details.

## Author

Huming Chen (<chenhuming@gmail.com>)

## Package Information

- **Version**: 0.1
- **License**: GPL-3.0-or-later
- **Keywords**: programming, convenience
- **Maintainer**: Huming Chen (<chenhuming@gmail.com>)

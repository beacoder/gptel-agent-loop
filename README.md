# gptel-agent-loop.el

[![MELPA](https://melpa.org/images/gptel-agent-loop.svg)](https://melpa.org/#/gptel-agent-loop)

## Description

`gptel-agent-loop` improves the reliability of gptel agent sessions by preventing the agent from stopping prematurely before verifying task completion.

It intercepts terminal FSM transitions (`DONE` / `ERRS`) for top-level agent sessions and asks the LLM to review the original request, task completion rules, and conversation history before allowing the session to finish.

The nudge mechanism is conservative:

* It only applies to top-level user-initiated agent sessions.
* It does not interfere with sub-agent FSMs.
* It stops nudging after a configurable number of attempts.
* The nudge counter resets whenever the agent makes real progress through tool calls.

## Installation

Install through Emacs package manager:

```elisp
(package-install 'gptel-agent-loop)
```

Or with `straight.el`:

```elisp
(straight-use-package 'gptel-agent-loop)
```

Enable the mode:

```elisp
(require 'gptel-agent-loop)
(gptel-agent-loop-mode 1)
```

## Usage

Enable:

```elisp
(gptel-agent-loop-mode 1)
```

Disable:

```elisp
(gptel-agent-loop-mode 0)
```

The mode is global and installs an advice around gptel's FSM transition function.

## Configuration

### `gptel-agent-loop-max-nudges`

Maximum number of consecutive stop interceptions before allowing the agent to finish.

The counter is reset to zero whenever the top-level agent performs tool calls, which indicates real progress.

Default:

```elisp
(setq gptel-agent-loop-max-nudges 2)
```

Example:

```elisp
(setq gptel-agent-loop-max-nudges 3)
```

### `gptel-agent-loop-nudge-message`

Message injected when the agent attempts to stop.

The message is appended as a user turn and asks the LLM to verify whether the task is actually complete.

Default:

```elisp
(setq gptel-agent-loop-nudge-message
      "Review the original user request and the Task Completion Rules in the context. Verify whether all completion criteria are satisfied. If not, continue by making tool calls. Do not stop until the rules are fully met.")
```

Custom example:

```elisp
(setq gptel-agent-loop-nudge-message
      "Review your previous response against the user's requirements. If anything remains incomplete, continue working with tools. Only stop when the task is fully verified.")
```

### `gptel-agent-loop-verbose`

Enable logging of agent-loop actions in the `*Messages*` buffer.

Default:

```elisp
(setq gptel-agent-loop-verbose nil)
```

Enable:

```elisp
(setq gptel-agent-loop-verbose t)
```

## Task Completion Rules Context

For best results, provide explicit completion criteria as context.

Example:

```elisp
(require 'gptel-context)

(gptel-add-file
 (expand-file-name "task-completion-rules.md"
                   (file-name-directory
                    (or (locate-library "gptel-agent-loop")
                        (error "gptel-agent-loop not found")))))
```

A typical `task-completion-rules.md` may contain rules such as:

* Do not stop until the original user goal is satisfied.
* Verify generated files, commands, or external actions.
* Use tools when verification is possible.
* Check the final result before reporting completion.

## How It Works

The agent loop works by extending gptel's FSM behavior:

1. The LLM finishes a response and gptel attempts to enter a terminal state:

   * `DONE`
   * `ERRS`

2. `gptel-agent-loop` checks whether:

   * The FSM is an agentic session.
   * The FSM is a top-level user session.
   * The nudge limit has not been reached.

3. If interception is allowed:

   * The terminal transition is replaced with `WAIT`.
   * A verification prompt is injected.
   * The LLM gets another chance to continue using tools.

4. If the LLM performs tool calls:

   * The nudge counter is reset.
   * Future stopping attempts are evaluated again.

5. After the maximum number of nudges:

   * The agent is allowed to stop normally.

## Design Goals

The package is designed around the principle:

> The agent should not stop merely because it believes it is finished; it should stop after verifying completion.

It improves agent reliability without forcing infinite loops:

* No unconditional retry loop.
* No interference with normal gptel conversations.
* No interference with sub-agent execution.
* Progress through tool usage is rewarded by resetting the stop guard.

## Example Configuration

```elisp
(use-package gptel-agent-loop
  :ensure t
  :config
  (setq gptel-agent-loop-max-nudges 3
        gptel-agent-loop-verbose t)

  (gptel-agent-loop-mode 1))
```

Example with gptel-agent:

```elisp
(use-package gptel-agent
  :ensure t
  :config
  (progn
    (gptel-agent-update)

    ;; Add project-specific instructions.
    (require 'gptel-context)
    (gptel-add-file
     (expand-file-name "task-completion-rules.md"
                       (file-name-directory
                        (or (locate-library "gptel-agent-loop")
                            (error "gptel-agent-loop not found")))))

    ;; Improve agent loop resilience.
    (require 'gptel-agent-loop)
    (gptel-agent-loop-mode 1)))
```

## Requirements

* Emacs 24.3+
* gptel >= 0.9.9.5
* compat >= 0.33.0
* nadvice >= 0.4

## Compatibility

* Emacs: 24.3+
* gptel: 0.9.9.5+

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See the `LICENSE` file for details.

## Author

Huming Chen ([chenhuming@gmail.com](mailto:chenhuming@gmail.com))

## Package Information

* **Version**: 0.2
* **License**: GPL-3.0-or-later
* **Keywords**: programming, convenience
* **Maintainer**: Huming Chen ([chenhuming@gmail.com](mailto:chenhuming@gmail.com))

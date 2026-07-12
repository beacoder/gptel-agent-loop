;;; gptel-agent-harness.el --- Agent execution harness for gptel-agent -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "25.1") (compat "0.33.0") (nadvice "0.4") (gptel "0.9.9.5"))
;; Package-Author: Huming Chen
;; Package-Keywords: programming, convenience, ai, agent
;; Package-Description: Agent execution harness for gptel-agent.
;;
;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; 1. Completion supervision:
;;
;;    DONE/ERRS
;;        |
;;        v
;;    review task completion
;;        |
;;        +-- continue if incomplete
;;
;; 2. Context supervision:
;;
;;    before LLM request
;;          |
;;          v
;;    context > threshold?
;;          |
;;          v
;;       compact
;;
;; Usage:
;;   (require 'gptel-agent-harness)
;;   (gptel-agent-harness-mode 1)
;;
;;; Code:

(require 'gptel-agent)
(eval-when-compile (require 'cl-lib))

;;;; User Options
(defgroup gptel-agent-harness nil
  "Agent execution harness for gptel."
  :group 'gptel
  :prefix "gptel-agent-harness-")

(defcustom gptel-agent-harness-verbose nil
  "Log harness actions."
  :type 'boolean)

;;;; Completion Supervision
(defcustom gptel-agent-harness-max-nudges 2
  "Maximum consecutive completion nudges.

Reset whenever the LLM performs tool calls."
  :type 'integer)

(defcustom gptel-agent-harness-nudge-message
  "Review the original user request and the Task Completion Rules \
in the context. Verify whether all completion criteria are satisfied. \
If not, continue by making tool calls. Do not stop until the rules are fully met."
  "Message injected when the agent tries to stop."
  :type 'string)

;;;; Context Management
(defcustom gptel-agent-harness-context-trigger 0.70
  "Compact when context usage exceeds this ratio."
  :type 'float)

(defcustom gptel-agent-harness-context-windows
  '(("gpt-5" . 400000)
    ("gpt-5-mini" . 128000)
    ("claude" . 200000)
    ("deepseek-v3" . 128000)
    ("deepseek-v4" . 1000000)
    ("qwen3" . 131072)
    ("qwen3.5" . 131072)
    ("glm-5" . 128000)
    ("kimi" . 128000))
  "Known model context window sizes."
  :type '(alist
          :key-type string
          :value-type integer))

(defcustom gptel-agent-harness-compact-prompt
  "You are an anchored context summarization assistant for coding sessions.

Summarize only the conversation history you are given.

The newest turns may be kept verbatim outside your summary,
so focus on older context that still matters for continuing the work.

If the prompt includes a <previous-summary> block,
treat it as the current anchored summary.

Update it by:
- preserving still-true details
- removing stale details
- merging new facts

Always preserve:
- exact file paths
- identifiers
- API names
- important decisions
- constraints

Prefer terse bullets over paragraphs.

Do not answer the conversation itself.
Do not mention summarizing, compacting, or merging context.

Respond in the same language as the conversation."
  "Prompt used for context compaction."
  :type 'string)

;;;; Internal State
(defvar-local
    gptel-agent-harness--nudge-count 0
  "Current completion nudge count.")

(defvar-local
    gptel-agent-harness--compacting nil
  "Non-nil while context compaction is running.")

;;;; FSM Helpers
(defun gptel-agent-harness--buffer (fsm)
  "Return buffer associated with FSM."
  (plist-get (gptel-fsm-info fsm) :buffer))

(defun gptel-agent-harness--get-nudges (fsm)
  "Return current nudge count for FSM's buffer."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (if buf (buffer-local-value 'gptel-agent-harness--nudge-count buf) 0)))

(defun gptel-agent-harness--inc-nudges (fsm)
  "Increment and return nudge count for FSM's buffer."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (when buf
      (with-current-buffer buf
        (cl-incf gptel-agent-harness--nudge-count)))))

(defun gptel-agent-harness--reset-nudges (fsm)
  "Reset nudge count for FSM's buffer to 0."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (when buf
      (with-current-buffer buf
        (setq gptel-agent-harness--nudge-count 0)))))

(defun gptel-agent-harness--terminal-p (state)
  "Return non-nil if STATE is a terminal FSM state."
  (memq state '(DONE ERRS)))

(defun gptel-agent-harness--agentic-p (fsm)
  "Return non-nil when FSM has tools."
  (plist-get (gptel-fsm-info fsm) :tools))

(defun gptel-agent-harness--top-level-p (fsm)
  "Return non-nil if FSM is a top-level (user-initiated) session.
Sub-agent FSMs use `gptel-agent-request--handlers' instead of
`gptel-send--handlers'."
  (eq (gptel-fsm-handlers fsm) gptel-send--handlers))

(defun gptel-agent-harness--can-nudge-p (fsm)
  "Return non-nil when nudge budget remains for FSM."
  (< (gptel-agent-harness--get-nudges fsm)
     gptel-agent-harness-max-nudges))

;;;; Completion Actions
(defun gptel-agent-harness--nudge (fsm)
  "Inject nudge message into FSM prompt data and bump counter."
  (let ((info (gptel-fsm-info fsm)))
    (gptel-agent-harness--inc-nudges fsm)
    (gptel--inject-prompt
     (plist-get info :backend)
     (plist-get info :data)
     (list :role "user" :content gptel-agent-harness-nudge-message))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness: completion nudge %d/%d — asking LLM to review task"
               (gptel-agent-harness--get-nudges fsm)
               gptel-agent-harness-max-nudges))))

;;;; Context Window Management
(defun gptel-agent-harness--model-name ()
  "Return current model name."
  (cond ((symbolp gptel-model)
         (symbol-name gptel-model))
        ((stringp gptel-model)
         gptel-model)
        (t "")))

(defun gptel-agent-harness--context-window ()
  "Return current model context window."
  (let ((model (gptel-agent-harness--model-name)))
    (or
     (cdr (seq-find
           (lambda (entry) (string-match-p (car entry) model))
           gptel-agent-harness-context-windows))
     ;; safe fallback
     32768)))

(defun gptel-agent-harness--estimate-tokens (start end)
  "Estimate tokens between START and END.
Uses:
- Latin: ~4 chars/token
- CJK: ~2 chars/token"
  (let* ((text (buffer-substring-no-properties start end))
         (len (length text))
         (cjk-count 0))
    (dotimes (i len)
      (let ((c (aref text i)))
        (when (and (>= c #x4e00) (<= c #x9fff))
          (setq cjk-count (1+ cjk-count)))))
    (+ (/ (- len cjk-count) 4) (/ cjk-count 2))))

(defun gptel-agent-harness--context-tokens ()
  "Return estimated context tokens."
  (gptel-agent-harness--estimate-tokens (point-min) (point-max)))

(defun gptel-agent-harness--context-ratio ()
  "Return context usage ratio."
  (/
   (float (gptel-agent-harness--context-tokens))
   (float (gptel-agent-harness--context-window))))

(defun gptel-agent-harness--need-compaction-p ()
  "Return non-nil when compaction is needed."
  (>
   (gptel-agent-harness--context-ratio)
   gptel-agent-harness-context-trigger))

;;;; Automatic Compaction
(defun gptel-agent-harness--compact ()
  "Run context compaction."
  (when (fboundp 'gptel-agent-compact)
    (when gptel-agent-harness-verbose
      (message
       "gptel-agent-harness: compacting context %.1f%%"
       (* 100 (gptel-agent-harness--context-ratio))))
    (let ((gptel-agent-compact-prompt
           gptel-agent-harness-compact-prompt))
      (gptel-agent-compact))))

(defun gptel-agent-harness--compact-if-needed ()
  "Compact current context when required."
  (when (and (not gptel-agent-harness--compacting)
             (gptel-agent-harness--need-compaction-p))
    (setq gptel-agent-harness--compacting t)
    (unwind-protect
        (gptel-agent-harness--compact)
      (setq gptel-agent-harness--compacting nil))))

;;;; Pre-request Hook
(defun gptel-agent-harness--around-request (orig-fn &rest args)
  "Compact before sending request to LLM.

ORIG-FN is the original `gptel-request' function.
ARGS is its args."
  (gptel-agent-harness--compact-if-needed)
  (apply orig-fn args))

;;;; FSM Supervisor
(defun gptel-agent-harness--transition-advice (orig-fn machine &optional new-state)
  "Around advice for `gptel--fsm-transition'.

Intercepts terminal states and redirects to WAIT with a nudge.
Resets counter when LLM makes tool calls.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the optional new state to transition to."
  (let ((target (or new-state (gptel--fsm-next machine))))
    (cond
     ;; LLM attempts to finish
     ((gptel-agent-harness--terminal-p target)
      ;; last chance compaction check
      (gptel-agent-harness--compact-if-needed)
      (if (and (gptel-agent-harness--agentic-p machine)
               (gptel-agent-harness--top-level-p machine)
               (gptel-agent-harness--can-nudge-p machine))
          (progn
            (gptel-agent-harness--nudge machine)
            ;; continue FSM
            (funcall orig-fn machine 'WAIT))
        ;; allow normal completion
        (funcall orig-fn machine new-state)))
     ;; Tool execution means real progress
     ((and (memq target '(TOOL TPRE))
           (gptel-agent-harness--top-level-p machine))
      (funcall orig-fn machine new-state)
      (gptel-agent-harness--reset-nudges machine))
     ;; Everything else
     (t (funcall orig-fn machine new-state)))))

;;;; Minor Mode

;;;###autoload
(define-minor-mode
  gptel-agent-harness-mode
  "Enable gptel-agent-harness mode.

Provides completion and context supervision."
  :global t
  :lighter " AgentHarness"
  (if gptel-agent-harness-mode
      (progn
        ;; Completion supervisor
        (advice-add 'gptel--fsm-transition
                    :around #'gptel-agent-harness--transition-advice)
        ;; Context supervisor
        (advice-add 'gptel-request
                    :around #'gptel-agent-harness--around-request)
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness enabled")))
    ;; disable
    (advice-remove 'gptel--fsm-transition
                   #'gptel-agent-harness--transition-advice)
    (advice-remove 'gptel-request
                   #'gptel-agent-harness--around-request)
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness disabled"))))

(provide 'gptel-agent-harness)
;;; gptel-agent-harness.el ends here

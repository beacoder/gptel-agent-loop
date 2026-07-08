;;; gptel-agent-loop.el --- Prevent gptel agent from stopping prematurely -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-loop
;; Package-Version: 0.2
;; Package-Requires: ((emacs "24.3") (compat "0.33.0") (nadvice "0.4") (gptel "0.9.9.5"))
;; Package-Author: Huming Chen
;; Package-Keywords: programming, convenience
;; Package-Description: Prevents gptel agent from stopping prematurely without confirming task completion
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

;; Prevents gptel's agentic loop from stopping without confirming task
;; completion.  Intercepts terminal FSM states (DONE/ERRS) and asks the
;; LLM to review the conversation and decide if more work is needed.
;;
;; Usage:
;;   (require 'gptel-agent-loop)
;;   (gptel-agent-loop-mode 1)

;;; Code:

(require 'gptel)
(eval-when-compile (require 'cl-lib))

;;;; User Options

(defgroup gptel-agent-loop nil
  "Prevent gptel agent from stopping prematurely."
  :group 'gptel
  :prefix "gptel-agent-loop-")

(defcustom gptel-agent-loop-max-nudges 2
  "Max consecutive nudges before allowing the agent to stop.

Reset to 0 whenever the LLM makes a tool call (real progress)."
  :type 'integer)

(defcustom gptel-agent-loop-nudge-message
  "Review the original user request and the Task Completion Rules \
in the context. Verify whether all completion criteria are satisfied. \
If not, continue by making tool calls. Do not stop until the rules are fully met."
  "Message injected when the LLM would stop.

Appended as a user turn.  Should instruct the LLM to review the
full history and decide whether to continue or stop."
  :type 'string)

(defcustom gptel-agent-loop-verbose nil
  "Log agent loop actions to *Messages*."
  :type 'boolean)

;;;; Internal State

(defvar gptel-agent-loop--nudge-counts (make-hash-table :test 'eq :weakness 'key)
  "Map from FSM to its nudge count.
Uses weak keys so entries are GC'd when the FSM is collected.")

;;;; Counter Access

(defun gptel-agent-loop--get-count (fsm)
  "Get nudge count for FSM."
  (gethash fsm gptel-agent-loop--nudge-counts 0))

(defun gptel-agent-loop--incf-count (fsm)
  "Increment and return nudge count for FSM."
  (puthash fsm (1+ (gptel-agent-loop--get-count fsm))
           gptel-agent-loop--nudge-counts))

(defun gptel-agent-loop--reset-count (fsm)
  "Reset nudge count for FSM to 0."
  (remhash fsm gptel-agent-loop--nudge-counts))

;;;; Predicates

(defun gptel-agent-loop--terminal-p (state)
  "Return non-nil if STATE is a terminal FSM state."
  (memq state '(DONE ERRS)))

(defun gptel-agent-loop--agentic-p (fsm)
  "Return non-nil if FSM represents an agentic session (tools active)."
  (plist-get (gptel-fsm-info fsm) :tools))

(defun gptel-agent-loop--can-nudge-p (fsm)
  "Return non-nil if we have nudge budget remaining for FSM."
  (< (gptel-agent-loop--get-count fsm)
     gptel-agent-loop-max-nudges))

(defun gptel-agent-loop--should-intercept-p (fsm target-state)
  "For `FSM', return non-nil if transition to TARGET-STATE should be intercepted."
  (and (gptel-agent-loop--terminal-p target-state)
       (gptel-agent-loop--agentic-p fsm)
       (gptel-agent-loop--can-nudge-p fsm)))

;;;; Actions

(defun gptel-agent-loop--nudge (fsm)
  "Inject nudge message into FSM prompt data and bump counter."
  (let* ((info (gptel-fsm-info fsm)))
    (gptel-agent-loop--incf-count fsm)
    (gptel--inject-prompt
     (plist-get info :backend)
     (plist-get info :data)
     (list :role "user" :content gptel-agent-loop-nudge-message))
    (when gptel-agent-loop-verbose
      (message "gptel-agent-loop: nudge %d/%d — asking LLM to review task"
               (gptel-agent-loop--get-count fsm)
               gptel-agent-loop-max-nudges))))

(defun gptel-agent-loop--reset-counter (fsm)
  "For `FSM', reset nudge counter — the LLM made tool-calls (real progress)."
  (when (> (gptel-agent-loop--get-count fsm) 0)
    (when gptel-agent-loop-verbose
      (message "gptel-agent-loop: tool calls made, resetting nudge counter"))
    (gptel-agent-loop--reset-count fsm)))

;;;; Advice

(defun gptel-agent-loop--transition-advice (orig-fn machine &optional new-state)
  "Around advice for `gptel--fsm-transition'.

Intercepts terminal states and redirects to WAIT with a nudge.
Resets counter when LLM makes tool calls.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the optional new state to transition to."
  (let ((target (or new-state (gptel--fsm-next machine))))
    (cond
     ;; Intercept stop → nudge → WAIT
     ((gptel-agent-loop--should-intercept-p machine target)
      (gptel-agent-loop--nudge machine)
      (funcall orig-fn machine 'WAIT))
     ;; LLM made tool calls → reset counter
     ((memq target '(TOOL TPRE))
      (funcall orig-fn machine new-state)
      (gptel-agent-loop--reset-counter machine))
     ;; Everything else — pass through
     (t
      (funcall orig-fn machine new-state)))))

;;;; Minor Mode

;;;###autoload
(define-minor-mode gptel-agent-loop-mode
  "Prevent gptel agent from stopping without confirming task completion.

Intercepts terminal FSM states and asks the LLM to review the
full conversation history before deciding to stop.  Resets after
every successful tool call."
  :global t
  :lighter " AgentLoop"
  (if gptel-agent-loop-mode
      (advice-add 'gptel--fsm-transition :around
                  #'gptel-agent-loop--transition-advice)
    (advice-remove 'gptel--fsm-transition
                   #'gptel-agent-loop--transition-advice)))

(provide 'gptel-agent-loop)
;;; gptel-agent-loop.el ends here

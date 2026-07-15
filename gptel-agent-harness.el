;;; gptel-agent-harness.el --- Agent execution harness for gptel-agent -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "25.1") (compat "0.33.0") (nadvice "0.4") (gptel-agent "0.0.1"))
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
;;    TOOL finished
;;        |
;;        v
;;       WAIT
;;        |
;;        v
;;    context > threshold?
;;        |
;;        v
;;     compact
;;
;; Usage:
;;   (require 'gptel-agent-harness)
;;   (gptel-agent-harness-mode 1)
;;
;;; Code:

(require 'gptel-agent)
(require 'cl-lib)

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
    ("kimi" . 128000))
  "Known model context window sizes.

Entries are matched in order using `string-match-p', so place
more specific patterns before general ones."
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
(defvar-local gptel-agent-harness--nudge-count 0
  "Current completion nudge count.")

(defvar-local gptel-agent-harness--compacting-p nil
  "Non-nil when compaction is in progress for this buffer.")

(defvar-local gptel-agent-harness--context-ratio nil
  "Last computed context usage ratio (0.0–1.0) for this buffer.")

;;;; FSM Helpers
(defun gptel-agent-harness--buffer (fsm)
  "Return buffer associated with FSM."
  (plist-get (gptel-fsm-info fsm) :buffer))

(defun gptel-agent-harness--get-nudges (fsm)
  "Return current nudge count for FSM's buffer."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (if (and buf (buffer-live-p buf))
        (buffer-local-value 'gptel-agent-harness--nudge-count buf)
      0)))

(defun gptel-agent-harness--inc-nudges (fsm)
  "Increment and return nudge count for FSM's buffer."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (cl-incf gptel-agent-harness--nudge-count)))))

(defun gptel-agent-harness--reset-nudges (fsm)
  "Reset nudge count for FSM's buffer to 0."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (when (and buf (buffer-live-p buf))
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

(defun gptel-agent-harness--cjk-char-p (c)
  "Return non-nil if C is a CJK or full-width character."
  (or (and (>= c #x3000) (<= c #x9fff))    ; CJK + kana + punctuation
      (and (>= c #xf900) (<= c #xfaff))    ; CJK compat ideographs
      (and (>= c #xff00) (<= c #xffef))    ; full-width forms
      (and (>= c #x20000) (<= c #x2fa1f)))) ; CJK extensions B–F

(defun gptel-agent-harness--estimate-tokens (start end)
  "Estimate tokens between START and END.
Uses:
- Latin: ~4 chars/token
- CJK/full-width: ~2 chars/token"
  (let* ((text (buffer-substring-no-properties start end))
         (len (length text))
         (cjk-count 0))
    (dotimes (i len)
      (when (gptel-agent-harness--cjk-char-p (aref text i))
        (setq cjk-count (1+ cjk-count))))
    (round (+ (/ (float (- len cjk-count)) 4.0)
              (/ (float cjk-count) 2.0)))))

(defun gptel-agent-harness--context-tokens-from-data (fsm)
  "Estimate tokens from the full prompt payload of FSM.
Includes system prompt, all user/assistant/tool messages.
When `gptel-agent-harness-verbose' is non-nil, logs the
serialized content to *gptel-agent-harness-debug*."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (plist-get data :messages))
         (system (or (plist-get data :system)
                     (plist-get data :system_instruction)
                     ""))
         (total 0)
         (debug-buf (when gptel-agent-harness-verbose
                      (get-buffer-create "*gptel-agent-harness-debug*"))))
    (when debug-buf
      (with-current-buffer debug-buf
        (erase-buffer)
        (insert "=== Context Token Estimation ===\n\n")))
    (with-temp-buffer
      ;; System prompt
      (cond
       ((stringp system) (insert system))
       ((listp system)
        (dolist (s system)
          (insert (or (and (stringp s) s)
                      (plist-get s :text)
                      (format "%s" s))
                  "\n"))))
      (setq total (gptel-agent-harness--estimate-tokens (point-min) (point-max)))
      (when debug-buf
        (let ((text (buffer-string)))
          (with-current-buffer debug-buf
            (insert "--- [system] ---\n" text "\n\n"))))
      ;; All messages
      (when messages
        (cl-loop
         for msg across messages
         for role = (plist-get msg :role)
         for content = (plist-get msg :content)
         for tool-calls = (plist-get msg :tool_calls)
         do (erase-buffer)
         (cond
          ((stringp content)
           (insert content))
          ((listp content)
           (dolist (part content)
             (cond
              ((stringp part) (insert part))
              ((plist-get part :text) (insert (plist-get part :text)))
              ((plist-get part :arguments) (insert (plist-get part :arguments)))
              (t (insert (format "%S" part))))))
          (t (insert (format "%S" content))))
         ;; Tool calls (assistant messages with function invocations)
         (when tool-calls
           (dolist (tc (if (vectorp tool-calls)
                           (append tool-calls nil)
                         tool-calls))
             (let ((func (plist-get tc :function)))
               (when func
                 (let ((name (plist-get func :name))
                       (args (plist-get func :arguments)))
                   (when name (insert name "\n"))
                   (when args (insert args "\n")))))))
         (cl-incf total
                  (gptel-agent-harness--estimate-tokens (point-min) (point-max)))
         (when debug-buf
           (let ((text (buffer-string)))
             (with-current-buffer debug-buf
               (insert (format "--- [%s] ---\n%s\n\n" role text))))))))
    (when debug-buf
      (with-current-buffer debug-buf
        (insert (format "=== Total estimated tokens: %d ===\n" total)))
      (message "gptel-agent-harness: token estimation logged to *gptel-agent-harness-debug*"))
    total))

(defun gptel-agent-harness--context-ratio-for-fsm (fsm)
  "Return context usage ratio based on full prompt payload of FSM."
  (/ (float (gptel-agent-harness--context-tokens-from-data fsm))
     (float (gptel-agent-harness--context-window))))

(defun gptel-agent-harness--need-compaction-p (fsm)
  "Return non-nil when compaction is needed for FSM.
Uses the cached `gptel-agent-harness--context-ratio' if available."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (and buf
         (buffer-live-p buf)
         (gptel-agent-harness--agentic-p fsm)
         (gptel-agent-harness--top-level-p fsm)
         (not (buffer-local-value 'gptel-agent-harness--compacting-p buf))
         (let ((ratio (buffer-local-value 'gptel-agent-harness--context-ratio buf)))
           (and ratio
                (> ratio gptel-agent-harness-context-trigger))))))

;;;; Automatic Compaction
(defcustom gptel-agent-harness-compact-header
  "**[Compacted Summary]**\n\n"
  "Header inserted at the top of the buffer after compaction.
Helps distinguish the summary from original conversation text."
  :type 'string
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-compact-separator
  "\n\n---\n\n**[Context compacted]**\n\n---\n\n"
  "Separator inserted after compaction to visually indicate the boundary."
  :type 'string
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-compact-resume-count 3
  "Number of recent user requests to replay after compaction.
Only non-nudge user messages are counted."
  :type 'integer
  :group 'gptel-agent-harness)

(defun gptel-agent-harness--recent-user-requests (fsm)
  "Return the last N user messages from FSM, excluding nudge messages.
N is `gptel-agent-harness-compact-resume-count'.
Returns a list of content strings in chronological order."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (plist-get data :messages))
         (nudge gptel-agent-harness-nudge-message)
         (n gptel-agent-harness-compact-resume-count)
         result)
    ;; Collect from end to get the most recent ones
    (cl-loop for i downfrom (1- (length messages)) to 0
             for msg = (aref messages i)
             while (< (length result) n)
             when (and (equal (plist-get msg :role) "user")
                       (not (equal (plist-get msg :content) nudge)))
             do (push msg result))
    (mapcar (lambda (msg) (plist-get msg :content)) result)))

(cl-defun gptel-agent-harness--compact (fsm)
  "Abort and run context compaction for FSM.
Return non-nil if compaction was initiated, nil otherwise."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (unless (and buf (buffer-live-p buf))
      (when gptel-agent-harness-verbose
        (message "gptel-agent-harness: compact skipped — buffer not live"))
      (cl-return-from gptel-agent-harness--compact nil))
    (with-current-buffer buf
      ;; 1. Save recent user requests (excluding nudges)
      (let ((requests (gptel-agent-harness--recent-user-requests fsm)))
        (unless requests
          (when gptel-agent-harness-verbose
            (message "gptel-agent-harness: compact skipped — no user requests to resume"))
          (cl-return-from gptel-agent-harness--compact nil))
        (setq gptel-agent-harness--compacting-p t)
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness: compacting context %.1f%%"
                   (* 100 (gptel-agent-harness--context-ratio-for-fsm fsm))))
        ;; 2. Stop old FSM
        (gptel-abort buf)
        ;; 3. Compact with closure capturing per-buffer state
        (let ((resume-buf buf)
              (resume-requests requests)
              (gptel-agent-compact-prompt
               gptel-agent-harness-compact-prompt))
          (condition-case err
              (gptel-agent-compact
               nil
               (lambda (&optional _info)
                 (when (and resume-requests resume-buf (buffer-live-p resume-buf))
                   (with-current-buffer resume-buf
                     (setq gptel-agent-harness--compacting-p nil)
                     (setq gptel-agent-harness--nudge-count 0)
                     (condition-case err
                         (progn
                           ;; Header at top of compacted summary
                           (goto-char (point-min))
                           (insert gptel-agent-harness-compact-header)
                           (goto-char (point-max))
                           ;; Visual separator
                           (insert gptel-agent-harness-compact-separator)
                           ;; Re-insert recent user requests in order
                           (insert (mapconcat #'identity resume-requests "\n\n"))
                           (gptel-send))
                       (error
                        (when gptel-agent-harness-verbose
                          (message "gptel-agent-harness: resume failed — %s"
                                   (error-message-string err)))))))))
            (error
             (setq gptel-agent-harness--compacting-p nil)
             (when gptel-agent-harness-verbose
               (message "gptel-agent-harness: gptel-agent-compact failed — %s"
                        (error-message-string err)))
             (cl-return-from gptel-agent-harness--compact nil))))
        t))))

;;;; FSM Supervisor
(defun gptel-agent-harness--update-context-ratio (fsm)
  "Compute and store context ratio for FSM's buffer."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (when (and buf (buffer-live-p buf)
               (gptel-agent-harness--top-level-p fsm)
               ;; :data must be a plist (not a buffer during assembly)
               (not (bufferp (plist-get (gptel-fsm-info fsm) :data))))
      (let ((ratio (gptel-agent-harness--context-ratio-for-fsm fsm)))
        (with-current-buffer buf
          (setq gptel-agent-harness--context-ratio ratio)
          (force-mode-line-update))))))

(defun gptel-agent-harness--transition-advice (orig-fn machine &optional new-state)
  "Around advice for `gptel--fsm-transition'.

Intercepts terminal states and redirects to WAIT with a nudge.
Resets counter when LLM makes tool calls.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the optional new state to transition to."
  (let ((target (or new-state (gptel--fsm-next machine))))
    (cond
     ;; Before next LLM turn — check if compaction needed
     ((eq target 'WAIT)
      (gptel-agent-harness--update-context-ratio machine)
      (if (gptel-agent-harness--need-compaction-p machine)
          ;; If compact bails out, fall through to normal transition
          (unless (gptel-agent-harness--compact machine)
            (funcall orig-fn machine new-state))
        (funcall orig-fn machine new-state)))
     ;; LLM attempts to finish
     ((gptel-agent-harness--terminal-p target)
      (gptel-agent-harness--update-context-ratio machine)
      (if (and (gptel-agent-harness--agentic-p machine)
               (gptel-agent-harness--top-level-p machine)
               (gptel-agent-harness--can-nudge-p machine))
          (progn
            (gptel-agent-harness--nudge machine)
            (funcall orig-fn machine 'WAIT))
        (funcall orig-fn machine new-state)))
     ;; Tool execution means real progress
     ((and (memq target '(TOOL TPRE))
           (gptel-agent-harness--top-level-p machine))
      (funcall orig-fn machine new-state)
      (gptel-agent-harness--reset-nudges machine))
     ;; Everything else
     (t (funcall orig-fn machine new-state)))))

;;;; Mode-line Context Ratio Display

(defcustom gptel-agent-harness-show-context-ratio t
  "Whether to show context usage ratio in the mode-line."
  :type 'boolean
  :group 'gptel-agent-harness)

(defun gptel-agent-harness--context-ratio-indicator ()
  "Return a propertized string showing context usage ratio.
Returns empty string if ratio is not yet computed or display is disabled."
  (if (and gptel-agent-harness-show-context-ratio
           gptel-agent-harness--context-ratio)
      (let* ((pct (round (* 100 gptel-agent-harness--context-ratio)))
             (face (cond
                    ((>= pct 80) 'error)
                    ((>= 80 pct 50) 'warning)
                    (t 'success)))
             ;; Use %%%% so `format' produces "%%", which mode-line
             ;; renders as a literal "%" (since % is a mode-line format spec).
             (text (format " [Ctx:%d%%%%]" pct)))
        (propertize text 'face face
                    'help-echo (format "Context window usage: %d%%\nCompaction threshold: %d%%"
                                       pct
                                       (round (* 100 gptel-agent-harness-context-trigger)))))
    ""))

(defvar-local gptel-agent-harness--mode-line-construct
  '(:eval (gptel-agent-harness--context-ratio-indicator))
  "Mode-line construct showing context usage ratio in gptel buffers.")
(put 'gptel-agent-harness--mode-line-construct 'risky-local-variable t)

(defun gptel-agent-harness--setup-mode-line ()
  "Add context ratio indicator to mode-line for the current gptel buffer."
  (unless (memq 'gptel-agent-harness--mode-line-construct
                mode-line-misc-info)
    (setq-local mode-line-misc-info
                (append mode-line-misc-info
                        '(gptel-agent-harness--mode-line-construct)))))

(defun gptel-agent-harness--teardown-mode-line ()
  "Remove context ratio indicator from mode-line for the current buffer."
  (setq-local mode-line-misc-info
              (delq 'gptel-agent-harness--mode-line-construct
                    mode-line-misc-info)))

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
        (advice-add 'gptel--fsm-transition
                    :around #'gptel-agent-harness--transition-advice)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
        ;; Set up for already-open gptel buffers
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when gptel-mode
              (gptel-agent-harness--setup-mode-line))))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness enabled")))
    ;; disable
    (advice-remove 'gptel--fsm-transition
                   #'gptel-agent-harness--transition-advice)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
    ;; Clean up from all gptel buffers
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when gptel-mode
          (gptel-agent-harness--teardown-mode-line)
          (setq gptel-agent-harness--context-ratio nil)
          (force-mode-line-update))))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness disabled"))))

;; (require 'ert) — tests have moved to gptel-agent-harness-test.el

(provide 'gptel-agent-harness)
;;; gptel-agent-harness.el ends here

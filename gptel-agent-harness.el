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
;; 3. Session management:
;;
;;    Auto-save gptel agent buffers after each LLM response to
;;    `gptel-agent-harness-session-dir'.  Restore manually with
;;    `gptel-agent-harness-restore-session' or
;;    `gptel-agent-harness-restore-latest-session'.
;;
;; Usage:
;;   (require 'gptel-agent-harness)
;;   (gptel-agent-harness-mode 1)
;;
;;; Code:

(require 'gptel-agent nil t)
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

;;;; Session Management
(defcustom gptel-agent-harness-session-dir
  (expand-file-name "gptel-sessions/" user-emacs-directory)
  "Directory where gptel agent sessions are auto-saved."
  :type 'directory
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-auto-save-session t
  "When non-nil, auto-save gptel agent buffers after each LLM response."
  :type 'boolean
  :group 'gptel-agent-harness)

(defvar-local gptel-agent-harness--project-dir nil
  "Project directory associated with this gptel agent buffer.
Used for session restore to set `default-directory'.")

;; Declare variables safe-local-variable so session restore can set them.
(dolist (entry '((gptel-agent-harness--project-dir . stringp)
                 (gptel-model                      . stringp)
                 (gptel--backend-name              . stringp)
                 (gptel-system-prompt              . stringp)
                 (gptel-temperature                . numberp)
                 (gptel-max-tokens                 . integerp)
                 (gptel--num-messages-to-send      . integerp)))
  (put (car entry) 'safe-local-variable (cdr entry)))

(defvar-local gptel-agent-harness--session-file-cache nil
  "Cached session file path for this buffer.
Set once on first auto-save, reused for subsequent saves.")

(defun gptel-agent-harness--session-file (&optional buffer)
  "Return the session file path for BUFFER (default: current buffer).
Returns the cached path if available, otherwise generates a new one.
Returns nil if the buffer is not a gptel agent buffer."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when gptel-mode
          (or gptel-agent-harness--session-file-cache
              (let* ((proj-dir (or gptel-agent-harness--project-dir
                                   default-directory))
                     (proj-name (file-name-nondirectory
                                 (directory-file-name proj-dir)))
                     (timestamp (format-time-string "%y%m%d%H%M%S"))
                     (file-name (format "%s_%s.md" proj-name timestamp)))
                (setq gptel-agent-harness--session-file-cache
                      (expand-file-name file-name
                                        gptel-agent-harness-session-dir)))))))))

(defun gptel-agent-harness--write-local-vars (vars)
  "Insert a ;; Local Variables: block for VARS at point.
VARS is an alist of (VAR-NAME-STRING . VALUE).
Entries with nil values are skipped."
  (insert "\n;; Local Variables:\n")
  (pcase-dolist (`(,name . ,val) vars)
    (when val
      (insert (format ";; %s: %S\n" name val))))
  (insert ";; End:\n"))

(defun gptel-agent-harness--auto-save-session (&rest _)
  "Auto-save the current gptel agent buffer to session dir.
Intended as a hook function for `gptel-post-response-functions'."
  (when (and gptel-mode
             gptel-agent-harness-auto-save-session)
    (unless (file-exists-p gptel-agent-harness-session-dir)
      (make-directory gptel-agent-harness-session-dir t))
    (when-let* ((file (gptel-agent-harness--session-file)))
      (with-temp-message "gptel-agent-harness: auto-saving session..."
        (let* ((source-buf (current-buffer))
               (proj-dir (or gptel-agent-harness--project-dir
                             default-directory))
               (backend-name (or (and (boundp 'gptel--backend-name) gptel--backend-name)
                                 (when (and (boundp 'gptel-backend) gptel-backend)
                                   (gptel-backend-name gptel-backend))))
               (vars `(("gptel-agent-harness--project-dir" . ,proj-dir)
                       ("gptel--bounds"                    . ,(gptel--get-buffer-bounds))
                       ("gptel-model"                      . ,gptel-model)
                       ("gptel--backend-name"              . ,backend-name)
                       ("gptel-system-prompt"              . ,gptel-system-prompt)
                       ("gptel--tool-names"                . ,(mapcar #'gptel-tool-name gptel-tools))
                       ("gptel-temperature"                . ,gptel-temperature)
                       ("gptel-max-tokens"                 . ,gptel-max-tokens)
                       ("gptel--num-messages-to-send"      . ,(and (natnump gptel--num-messages-to-send)
                                                                    gptel--num-messages-to-send)))))
          (with-temp-buffer
            (insert-buffer-substring source-buf)
            (goto-char (point-max))
            (let ((print-escape-newlines t))
              (gptel-agent-harness--write-local-vars vars))
            (write-region (point-min) (point-max) file nil 'silent)))))))

(defun gptel-agent-harness-restore-session (session-file)
  "Restore a gptel agent session from SESSION-FILE.
The file should have been created by
`gptel-agent-harness--auto-save-session'.
This opens the file, enables `gptel-mode', and restores all state."
  (interactive
   (list (read-file-name "Session file: "
                         gptel-agent-harness-session-dir
                         nil t)))
  (let ((buf (generate-new-buffer
              (file-name-nondirectory session-file))))
    (switch-to-buffer buf)
    (insert-file-contents session-file)
    (setq major-mode 'markdown-mode)
    (when (fboundp 'markdown-mode) (markdown-mode))
    ;; Manually parse and apply local variables, then strip the block
    (save-excursion
      (goto-char (point-min))
      (when (search-forward "\n;; Local Variables:" nil t)
        (let ((start (match-beginning 0)))
          (forward-line 1)
          (while (looking-at ";; \\([^:]+\\): \\(.*\\)")
            (let* ((var-name (string-trim (match-string 1)))
                   (val-str (match-string 2))
                   (var-sym (intern var-name)))
              (when (get var-sym 'safe-local-variable)
                (set (make-local-variable var-sym)
                     (car (read-from-string val-str)))))
            (forward-line 1))
          (delete-region start (point-max)))))
    (gptel-mode 1)
    (when gptel-agent-harness--project-dir
      (setq default-directory gptel-agent-harness--project-dir))
    (set-buffer-modified-p nil)
    (message "gptel-agent-harness: session restored from %s" session-file)))

(defun gptel-agent-harness-restore-latest-session ()
  "Restore the most recently modified gptel agent session.
Looks in `gptel-agent-harness-session-dir' for the newest .md file."
  (interactive)
  (if (file-directory-p gptel-agent-harness-session-dir)
      (let* ((files (directory-files gptel-agent-harness-session-dir
                                     t "\\.md\\'"))
             (latest (car (sort files #'file-newer-than-file-p))))
        (if latest
            (gptel-agent-harness-restore-session latest)
          (message "No gptel agent sessions found in %s"
                   gptel-agent-harness-session-dir)))
    (message "Session directory %s does not exist"
             gptel-agent-harness-session-dir)))

;;;; Internal State
(defvar-local gptel-agent-harness--nudge-count 0
  "Current completion nudge count.")

(defvar-local gptel-agent-harness--compacting-p nil
  "Non-nil when compaction is in progress for this buffer.")

(defvar-local gptel-agent-harness--context-ratio nil
  "Last computed context usage ratio (0.0–1.0) for this buffer.")

(defvar-local gptel-agent-harness--token-calibration 1.0
  "Calibration factor: actual_tokens / estimated_tokens.

Updated after each LLM response using the API-reported input token
count.  Applied to future estimations to reduce drift.")

(defvar-local gptel-agent-harness--last-raw-estimate nil
  "Raw token estimate from the last context ratio computation.
Used by `gptel-agent-harness--update-token-calibration' to compare
against the actual token count reported by the API.")

;;;; FSM Helpers

(defmacro gptel-agent-harness--with-fsm-buffer (fsm &rest body)
  "Execute BODY in FSM's associated buffer if it is live.
Binds nothing extra; use `current-buffer' inside BODY."
  (declare (indent 1) (debug (form body)))
  (let ((buf (gensym "buf")))
    `(let ((,buf (gptel-agent-harness--buffer ,fsm)))
       (when (and ,buf (buffer-live-p ,buf))
         (with-current-buffer ,buf ,@body)))))

(defun gptel-agent-harness--buffer (fsm)
  "Return buffer associated with FSM."
  (plist-get (gptel-fsm-info fsm) :buffer))

(defun gptel-agent-harness--get-nudges (fsm)
  "Return current nudge count for FSM's buffer."
  (or (gptel-agent-harness--with-fsm-buffer fsm
        gptel-agent-harness--nudge-count)
      0))

(defun gptel-agent-harness--inc-nudges (fsm)
  "Increment and return nudge count for FSM's buffer."
  (gptel-agent-harness--with-fsm-buffer fsm
    (cl-incf gptel-agent-harness--nudge-count)))

(defun gptel-agent-harness--reset-nudges (fsm)
  "Reset nudge count for FSM's buffer to 0."
  (gptel-agent-harness--with-fsm-buffer fsm
    (setq gptel-agent-harness--nudge-count 0)))

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
  "Return context usage ratio based on full prompt payload of FSM.
Applies the calibration factor from `gptel-agent-harness--token-calibration'."
  (let* ((calibration (or (gptel-agent-harness--with-fsm-buffer fsm
                            gptel-agent-harness--token-calibration)
                          1.0))
         (estimated (gptel-agent-harness--context-tokens-from-data fsm))
         (calibrated (* estimated calibration)))
    (/ calibrated (float (gptel-agent-harness--context-window)))))

(defun gptel-agent-harness--update-token-calibration (&rest _)
  "Update token calibration factor using the LLM-reported total tokens.

Reads `gptel--token-usage' (set by gptel after each response) and
compares the actual total token count (input + output) to the raw
estimate stored during the last context ratio computation.
The new calibration factor is:

  (actual_input + actual_output) / raw_estimated_tokens

This is called via `gptel-post-response-functions'."
  (when-let* ((usage (and (boundp 'gptel--token-usage) gptel--token-usage))
              (request-usage (car usage))
              (actual-input (plist-get request-usage :input))
              (actual-output (plist-get request-usage :output))
              (raw-estimate gptel-agent-harness--last-raw-estimate))
    (when (and (numberp actual-input) (numberp actual-output)
               (> (+ actual-input actual-output) 0)
               (numberp raw-estimate) (> raw-estimate 0))
      (let* ((actual-total (+ actual-input actual-output))
             (new-ratio (/ (float actual-total) (float raw-estimate))))
        ;; Clamp to reasonable range to avoid pathological values
        (setq new-ratio (max 0.5 (min 3.0 new-ratio)))
        (setq gptel-agent-harness--token-calibration new-ratio)
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness: calibration updated — total:%d est:%d ratio:%.2f"
                   actual-total raw-estimate new-ratio))))))

(defun gptel-agent-harness--need-compaction-p (fsm)
  "Return non-nil when compaction is needed for FSM.
Uses the cached `gptel-agent-harness--context-ratio' if available."
  (and (gptel-agent-harness--agentic-p fsm)
       (gptel-agent-harness--top-level-p fsm)
       (gptel-agent-harness--with-fsm-buffer fsm
         (and (not gptel-agent-harness--compacting-p)
              gptel-agent-harness--context-ratio
              (> gptel-agent-harness--context-ratio
                 gptel-agent-harness-context-trigger)))))

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
              (resume-requests requests))
          ;; Set compact prompt buffer-locally so it persists through
          ;; the async operation (a dynamic `let' would unwind before
          ;; the LLM request is actually sent).
          (setq-local gptel-agent-compact-prompt
                      gptel-agent-harness-compact-prompt)
          (condition-case err
              (gptel-agent-compact
               nil
               (lambda (&optional _info)
                 (when (and resume-requests resume-buf (buffer-live-p resume-buf))
                   (with-current-buffer resume-buf
                     (kill-local-variable 'gptel-agent-compact-prompt)
                     (setq gptel-agent-harness--compacting-p nil)
                     (setq gptel-agent-harness--nudge-count 0)
                     (condition-case resume-err
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
                                   (error-message-string resume-err)))))))))
            (error
             (kill-local-variable 'gptel-agent-compact-prompt)
             (setq gptel-agent-harness--compacting-p nil)
             (when gptel-agent-harness-verbose
               (message "gptel-agent-harness: gptel-agent-compact failed — %s"
                        (error-message-string err)))
             (cl-return-from gptel-agent-harness--compact nil))))
        t))))

;;;; FSM Supervisor
(defun gptel-agent-harness--update-context-ratio (fsm)
  "Compute and store context ratio for FSM's buffer.
Also stores the raw (uncalibrated) estimate for calibration."
  (when (and (gptel-agent-harness--top-level-p fsm)
             ;; :data must be a plist (not a buffer during assembly)
             (not (bufferp (plist-get (gptel-fsm-info fsm) :data))))
    (let* ((raw-estimate (gptel-agent-harness--context-tokens-from-data fsm))
           (calibration (or (gptel-agent-harness--with-fsm-buffer fsm
                              gptel-agent-harness--token-calibration)
                            1.0))
           (calibrated (* raw-estimate calibration))
           (ratio (/ calibrated (float (gptel-agent-harness--context-window)))))
      (gptel-agent-harness--with-fsm-buffer fsm
        (setq gptel-agent-harness--context-ratio ratio)
        (setq gptel-agent-harness--last-raw-estimate raw-estimate)
        (force-mode-line-update)))))

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
             (threshold-pct (round (* 100 gptel-agent-harness-context-trigger)))
             (face (cond
                    ((>= pct 80) 'error)
                    ((and (>= pct 50) (< pct 80)) 'warning)
                    (t 'success)))
             ;; Use %%%% so `format' produces "%%", which mode-line
             ;; renders as a literal "%" (since % is a mode-line format spec).
             (text (format " [Ctx:%d%%%%/%d%%%%]" pct threshold-pct)))
        (propertize text 'face face
                    'help-echo (format "Context window usage: %d%%\nCompaction threshold: %d%%"
                                       pct
                                       threshold-pct)))
    ""))

(defvar-local gptel-agent-harness--mode-line-construct
  '(:eval (gptel-agent-harness--context-ratio-indicator))
  "Mode-line construct showing context usage ratio in gptel buffers.")
(put 'gptel-agent-harness--mode-line-construct 'risky-local-variable t)

(defun gptel-agent-harness--setup-mode-line ()
  "Add context ratio indicator to mode-line for the current gptel buffer.
Also hides `which-function-mode' display as it provides no useful info
in gptel buffers but consumes mode-line space."
  (unless (memq 'gptel-agent-harness--mode-line-construct
                mode-line-misc-info)
    (setq-local mode-line-misc-info
                (append mode-line-misc-info
                        '(gptel-agent-harness--mode-line-construct))))
  ;; Hide which-func from this buffer's mode-line without disabling the global mode
  (setq-local which-func-mode nil))

(defun gptel-agent-harness--teardown-mode-line ()
  "Remove context ratio indicator from mode-line for the current buffer.
Restores `which-func-mode' to its global default."
  (setq-local mode-line-misc-info
              (delq 'gptel-agent-harness--mode-line-construct
                    mode-line-misc-info))
  (kill-local-variable 'which-func-mode))

;;;; Session Auto-Save Setup

(defun gptel-agent-harness--setup-session ()
  "Set up session auto-save and token calibration for the current gptel buffer.
Adds hooks to `gptel-post-response-functions' buffer-locally."
  (when gptel-agent-harness-auto-save-session
    (add-hook 'gptel-post-response-functions
              #'gptel-agent-harness--auto-save-session
              nil t))
  (add-hook 'gptel-post-response-functions
            #'gptel-agent-harness--update-token-calibration
            nil t))

(defun gptel-agent-harness--teardown-session ()
  "Remove session auto-save and token calibration from the current gptel buffer."
  (remove-hook 'gptel-post-response-functions
               #'gptel-agent-harness--auto-save-session
               t)
  (remove-hook 'gptel-post-response-functions
               #'gptel-agent-harness--update-token-calibration
               t))

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
        (when (boundp 'gptel-mode-map)
          (define-key gptel-mode-map (kbd "C-c C-k") #'gptel-abort))
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-session)
        ;; Set up for already-open gptel buffers
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when gptel-mode
              (gptel-agent-harness--setup-mode-line)
              (gptel-agent-harness--setup-session))))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness enabled")))
    ;; disable
    (advice-remove 'gptel--fsm-transition
                   #'gptel-agent-harness--transition-advice)
    (when (boundp 'gptel-mode-map)
      (define-key gptel-mode-map (kbd "C-c C-k") nil))
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-session)
    ;; Clean up from all gptel buffers
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when gptel-mode
          (gptel-agent-harness--teardown-mode-line)
          (gptel-agent-harness--teardown-session)
          (setq gptel-agent-harness--context-ratio nil)
          (setq gptel-agent-harness--token-calibration 1.0)
          (setq gptel-agent-harness--last-raw-estimate nil)
          (force-mode-line-update))))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness disabled"))))

;; (require 'ert) — tests have moved to gptel-agent-harness-test.el

(provide 'gptel-agent-harness)
;;; gptel-agent-harness.el ends here

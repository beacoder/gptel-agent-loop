;;; gptel-agent-harness-test.el --- Tests for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "25.1"))
;; Keywords: programming, convenience, ai, agent
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
;; ERT tests for gptel-agent-harness.
;;
;; Run with:
;;   Emacs --batch -L /path/to/gptel \
;;     -L /path/to/gptel-agent \
;;     -L /path/to/gptel-agent-harness \
;;     -l gptel-agent-harness-test \
;;     --eval '(ert-run-tests-batch "^gptel-agent-harness-test")'
;;
;;; Code:

(require 'ert)
(require 'gptel-agent-harness)

;;;; Stubs — minimal gptel API surface needed for testing
;; These provide a minimal gptel API surface when the real packages
;; are not available.  We use `fset' to avoid package-lint prefix errors.

(eval-and-compile
  (unless (fboundp 'gptel-make-tool)
    (fset 'gptel-make-tool (lambda (&rest args) (apply #'list args))))
  (unless (fboundp 'gptel-tool-name)
    (fset 'gptel-tool-name (lambda (tool) (plist-get tool :name))))
  (unless (boundp 'gptel-tools) (defvar gptel-tools nil))
  (unless (boundp 'gptel-model) (defvar gptel-model nil))
  (unless (boundp 'gptel-mode) (defvar gptel-mode nil))
  (unless (boundp 'gptel-post-response-functions) (defvar gptel-post-response-functions nil))
  (unless (boundp 'gptel--backend-name) (defvar gptel--backend-name nil))
  (unless (boundp 'gptel-system-prompt) (defvar gptel-system-prompt nil))
  (unless (boundp 'gptel-temperature) (defvar gptel-temperature nil))
  (unless (boundp 'gptel-max-tokens) (defvar gptel-max-tokens nil))
  (unless (boundp 'gptel--num-messages-to-send) (defvar gptel--num-messages-to-send nil))
  (unless (boundp 'gptel--token-usage) (defvar gptel--token-usage nil))
  (unless (fboundp 'markdown-mode)
    (fset 'markdown-mode (lambda () (setq major-mode 'markdown-mode))))
  (unless (fboundp 'gptel-mode)
    (fset 'gptel-mode
          (lambda (&optional arg)
            (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t))))))
  (unless (fboundp 'gptel--get-buffer-bounds)
    (fset 'gptel--get-buffer-bounds (lambda () (cons (point-min) (point-max)))))
  (unless (fboundp 'gptel-fsm-info)
    (fset 'gptel-fsm-info (lambda (fsm) (plist-get fsm :info))))
  (unless (fboundp 'gptel--fsm-next)
    (fset 'gptel--fsm-next (lambda (_machine) nil)))
  (unless (fboundp 'gptel-make-fsm)
    (fset 'gptel-make-fsm
          (lambda (&rest args) (list :info (plist-get args :info))))))

;;;; Test Helpers

(defmacro gptel-agent-harness-test--with-buffer (buf-var &rest body)
  "Create a temp buffer bound to BUF-VAR, execute BODY, kill buffer."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,buf-var (generate-new-buffer " *harness-test*")))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,buf-var)
         (kill-buffer ,buf-var)))))

(defmacro gptel-agent-harness-test--with-temp-dir (dir-var &rest body)
  "Create a temp directory bound to DIR-VAR, execute BODY, clean up."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,dir-var (make-temp-file "gptel-sess-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,dir-var)
         (delete-directory ,dir-var t)))))

(defun gptel-agent-harness-test--make-fsm (buf &rest data-plist)
  "Create a fake FSM with BUF and DATA-PLIST as the :data payload."
  (gptel-make-fsm :info (list :buffer buf :data data-plist)))

(defun gptel-agent-harness-test--setup-gptel-buffer (buf &optional proj-dir)
  "Set up BUF as a gptel buffer with optional PROJ-DIR."
  (with-current-buffer buf
    (setq-local gptel-mode t)
    (when proj-dir
      (setq-local gptel-agent-harness--project-dir proj-dir))))

;;;; Token Estimation Tests

(ert-deftest gptel-agent-harness-test-cjk-char-p ()
  "Test CJK character detection."
  (should (gptel-agent-harness--cjk-char-p ?中))
  (should (gptel-agent-harness--cjk-char-p ?あ))
  (should (gptel-agent-harness--cjk-char-p ?Ａ))
  (should-not (gptel-agent-harness--cjk-char-p ?A))
  (should-not (gptel-agent-harness--cjk-char-p ?é)))

(ert-deftest gptel-agent-harness-test-estimate-tokens ()
  "Test token estimation for mixed content."
  (with-temp-buffer
    (insert "abcdefghijklmnopqrst")  ; 20 latin chars → 5 tokens
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 5)))
  (with-temp-buffer
    (insert "你好世界")  ; 4 CJK chars → 2 tokens
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 2)))
  (with-temp-buffer
    (insert "hello   你好世界")  ; 8 latin + 4 CJK → 2+2=4
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 4))))

;;;; Model / Context Window Tests

(ert-deftest gptel-agent-harness-test-model-name ()
  "Test model name coercion from various types."
  (let ((gptel-model 'claude-sonnet))
    (should (equal (gptel-agent-harness--model-name) "claude-sonnet")))
  (let ((gptel-model "gpt-5"))
    (should (equal (gptel-agent-harness--model-name) "gpt-5")))
  (let ((gptel-model 42))
    (should (equal (gptel-agent-harness--model-name) ""))))

(ert-deftest gptel-agent-harness-test-context-window ()
  "Test model context window lookup with pattern matching."
  (let ((gptel-model "claude-sonnet-4-20250514"))
    (should (= (gptel-agent-harness--context-window) 200000)))
  (let ((gptel-model "gpt-5-mini-2026"))
    (should (= (gptel-agent-harness--context-window) 128000)))
  (let ((gptel-model "unknown-model-xyz"))
    (should (= (gptel-agent-harness--context-window) 32768))))

;;;; FSM State Tests

(ert-deftest gptel-agent-harness-test-terminal-p ()
  "Test terminal state detection."
  (should (gptel-agent-harness--terminal-p 'DONE))
  (should (gptel-agent-harness--terminal-p 'ERRS))
  (should-not (gptel-agent-harness--terminal-p 'WAIT))
  (should-not (gptel-agent-harness--terminal-p 'TOOL))
  (should-not (gptel-agent-harness--terminal-p nil)))

;;;; Nudge Counter Tests

(ert-deftest gptel-agent-harness-test-nudge-counter ()
  "Test nudge count increment, get, and reset via fake FSM."
  (gptel-agent-harness-test--with-buffer buf
    (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
               (lambda (_fsm) buf)))
      (let ((fsm 'ignored))
        (should (= (gptel-agent-harness--get-nudges fsm) 0))
        (gptel-agent-harness--inc-nudges fsm)
        (should (= (gptel-agent-harness--get-nudges fsm) 1))
        (gptel-agent-harness--inc-nudges fsm)
        (should (= (gptel-agent-harness--get-nudges fsm) 2))
        (gptel-agent-harness--reset-nudges fsm)
        (should (= (gptel-agent-harness--get-nudges fsm) 0))))))

(ert-deftest gptel-agent-harness-test-can-nudge-p ()
  "Test nudge budget check."
  (gptel-agent-harness-test--with-buffer buf
    (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
               (lambda (_fsm) buf)))
      (let ((fsm 'ignored)
            (gptel-agent-harness-max-nudges 2))
        (should (gptel-agent-harness--can-nudge-p fsm))
        (gptel-agent-harness--inc-nudges fsm)
        (should (gptel-agent-harness--can-nudge-p fsm))
        (gptel-agent-harness--inc-nudges fsm)
        (should-not (gptel-agent-harness--can-nudge-p fsm))))))

;;;; Context Token Estimation from FSM Data

(ert-deftest gptel-agent-harness-test-context-tokens-from-data ()
  "Test token estimation from full prompt payload."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "system prompt here"
                   :messages (vector
                              (list :role "user" :content "hello world")
                              (list :role "assistant" :content "hi there")
                              (list :role "user" :content "do something")))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 12))))))

(ert-deftest gptel-agent-harness-test-context-tokens-from-data-with-list-content ()
  "Test token estimation with structured (list) content in messages."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "sys"
                   :messages (vector
                              (list :role "assistant"
                                    :content (list (list :text "part one")
                                                   (list :text "part two")))))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 5))))))

(ert-deftest gptel-agent-harness-test-context-tokens-from-data-nil-content ()
  "Test token estimation handles nil content with tool_calls."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system ""
                   :messages (vector
                              (list :role "assistant"
                                    :content nil
                                    :tool_calls
                                    (vector
                                     (list :type "function"
                                           :id "call_123"
                                           :function
                                           (list :name "Skill"
                                                 :arguments "{\"skill\":\"test\"}"))))))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 6))))))

;;;; Context Ratio Tests

(ert-deftest gptel-agent-harness-test-context-ratio-for-fsm ()
  "Test FSM-based context ratio calculation."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))  ; 32768 fallback
    (gptel-agent-harness-test--with-buffer buf
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :system (make-string 40000 ?x)
                    :messages (vector)))
             (ratio (gptel-agent-harness--context-ratio-for-fsm fsm)))
        ;; 40000/4 = 10000 tokens, 10000/32768 ≈ 0.305
        (should (> ratio 0.3))
        (should (< ratio 0.31))))))

(ert-deftest gptel-agent-harness-test-context-ratio-indicator ()
  "Test context ratio indicator string generation."
  (let ((gptel-agent-harness-show-context-ratio t)
        (gptel-agent-harness-context-trigger 0.70))
    ;; nil ratio → empty string
    (let ((gptel-agent-harness--context-ratio nil))
      (should (equal (gptel-agent-harness--context-ratio-indicator) "")))
    ;; Low usage → success face
    (let ((gptel-agent-harness--context-ratio 0.25))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:25%%/70%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'success))))
    ;; Medium usage → warning face
    (let ((gptel-agent-harness--context-ratio 0.60))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:60%%/70%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'warning))))
    ;; High usage → error face
    (let ((gptel-agent-harness--context-ratio 0.85))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:85%%/70%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'error))))
    ;; Display disabled → empty string
    (let ((gptel-agent-harness-show-context-ratio nil)
          (gptel-agent-harness--context-ratio 0.50))
      (should (equal (gptel-agent-harness--context-ratio-indicator) "")))))

;;;; Mode-line Tests

(ert-deftest gptel-agent-harness-test-mode-line-setup-idempotent ()
  "Test mode-line setup is idempotent and uses a risky construct."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-mode t)
      (should (get 'gptel-agent-harness--mode-line-construct
                   'risky-local-variable))
      (gptel-agent-harness--setup-mode-line)
      (gptel-agent-harness--setup-mode-line)
      (should (= 1 (cl-count 'gptel-agent-harness--mode-line-construct
                             mode-line-misc-info))))))

;;;; Global Mode Enable/Disable

(ert-deftest gptel-agent-harness-test-mode-enable-disable ()
  "End-to-end regression: enabling and disabling the global mode."
  (let ((was-enabled gptel-agent-harness-mode))
    (gptel-agent-harness-test--with-buffer buf
      (when was-enabled (gptel-agent-harness-mode -1))
      (with-current-buffer buf (setq-local gptel-mode t))
      ;; Enable
      (gptel-agent-harness-mode 1)
      (should (advice-member-p
               #'gptel-agent-harness--transition-advice
               'gptel--fsm-transition))
      (should (memq #'gptel-agent-harness--setup-mode-line gptel-mode-hook))
      (with-current-buffer buf
        (should (memq 'gptel-agent-harness--mode-line-construct
                      mode-line-misc-info))
        (setq-local gptel-agent-harness--context-ratio 0.42)
        (should (string-match-p
                 "\\[Ctx:42%%/70%%\\]"
                 (gptel-agent-harness--context-ratio-indicator))))
      ;; Disable
      (gptel-agent-harness-mode -1)
      (should-not (advice-member-p
                   #'gptel-agent-harness--transition-advice
                   'gptel--fsm-transition))
      (should-not (memq #'gptel-agent-harness--setup-mode-line gptel-mode-hook))
      (with-current-buffer buf
        (should-not (memq 'gptel-agent-harness--mode-line-construct
                          mode-line-misc-info))
        (should-not gptel-agent-harness--context-ratio)))
    ;; Restore original state
    (if was-enabled
        (gptel-agent-harness-mode 1)
      (gptel-agent-harness-mode -1))))

;;;; Session Management Tests

(ert-deftest gptel-agent-harness-test-session-file-naming ()
  "Verify session file name includes timestamp and project info."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (rename-buffer "*test-session*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (let* ((file (gptel-agent-harness--session-file))
                 (basename (file-name-nondirectory file)))
            (should (string-prefix-p "project_" basename))
            (should (string-suffix-p ".md" basename))
            (should (string-match-p "[0-9]\\{12\\}" basename))
            (should (string-prefix-p temp-dir file))))))))

(ert-deftest gptel-agent-harness-test-session-file-nil-when-not-gptel-mode ()
  "Ensure session-file returns nil if `gptel-mode' is off."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-mode nil)
      (should (null (gptel-agent-harness--session-file))))))

(ert-deftest gptel-agent-harness-test-auto-save-and-restore ()
  "Test auto-save creates a file with local variables and restore loads them."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (gptel-model "gpt-5-mini")
          (gptel--backend-name "test-backend")
          (gptel-system-prompt "system prompt")
          (gptel-tools (list (gptel-make-tool :name "test-tool" :function #'ignore)))
          (gptel-temperature 0.5)
          (gptel-max-tokens 1000)
          (gptel--num-messages-to-send 2))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (rename-buffer "*test-auto*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (insert "Hello session")
          (gptel-agent-harness--auto-save-session)
          ;; Verify file was created with expected content
          (let* ((files (directory-files temp-dir t "\\.md\\'"))
                 (file (car files)))
            (should (file-exists-p file))
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (should (search-forward "gptel-agent-harness--project-dir" nil t))
              (should (search-forward "gptel-model" nil t))
              (should (search-forward "gptel--backend-name" nil t))
              (should (search-forward "gptel-system-prompt" nil t))
              (should (search-forward "gptel--tool-names" nil t)))
            ;; Test restore — creates a new non-file-visiting buffer
            (gptel-agent-harness-restore-session file)
            (should (derived-mode-p 'markdown-mode))
            (should gptel-mode)
            (should-not buffer-file-name)  ; not visiting a file
            (should-not (buffer-modified-p))
            (should (equal gptel-agent-harness--project-dir "/tmp/project"))
            (should (equal default-directory "/tmp/project"))
            (should (equal gptel-model "gpt-5-mini"))
            (should (equal gptel--backend-name "test-backend"))
            (should (equal gptel-system-prompt "system prompt"))
            (should (equal gptel-temperature 0.5))
            (should (equal gptel-max-tokens 1000))
            (should (equal gptel--num-messages-to-send 2))
            (kill-buffer (current-buffer))))))))

(ert-deftest gptel-agent-harness-test-restore-latest-session ()
  "Ensure the latest session file is chosen for restore."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir))
      ;; Create two session files from different buffers
      (gptel-agent-harness-test--with-buffer buf1
        (with-current-buffer buf1
          (rename-buffer "*test-first*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf1 "/tmp/project")
          (insert "first")
          (gptel-agent-harness--auto-save-session)))
      (sleep-for 1)
      (gptel-agent-harness-test--with-buffer buf2
        (with-current-buffer buf2
          (rename-buffer "*test-second*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf2 "/tmp/project")
          (insert "second")
          (gptel-agent-harness--auto-save-session)))
      ;; Verify latest is "second"
      (let* ((files (directory-files temp-dir t "\\.md\\'"))
             (latest (car (sort files #'file-newer-than-file-p))))
        (should (= (length files) 2))
        (with-temp-buffer
          (insert-file-contents latest)
          (should (search-forward "second" nil t)))
        (gptel-agent-harness-restore-latest-session)
        (should (derived-mode-p 'markdown-mode))
        (should-not buffer-file-name)
        (should (string= (buffer-string) "second"))
        (kill-buffer (current-buffer))))))

(ert-deftest gptel-agent-harness-test-auto-save-creates-dir ()
  "Verify auto-save creates the session directory if it does not exist."
  (gptel-agent-harness-test--with-temp-dir temp-parent
    (let* ((temp-dir (expand-file-name "subdir" temp-parent))
           (gptel-agent-harness-session-dir temp-dir)
           (gptel-model "gpt-5-mini"))
      (should-not (file-exists-p temp-dir))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (insert "content")
          (gptel-agent-harness--auto-save-session)
          (should (file-exists-p temp-dir))
          (should (= 1 (length (directory-files temp-dir t "\\.md\\'")))))))))
(ert-deftest gptel-agent-harness-test-auto-save-overwrites-same-file ()
  "Verify repeated auto-saves from same buffer overwrite the same file."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (gptel-model "gpt-5-mini"))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (insert "version-1")
          (gptel-agent-harness--auto-save-session)
          (should (= 1 (length (directory-files temp-dir t "\\.md\\'"))))
          ;; Save again with different content
          (erase-buffer)
          (insert "version-2")
          (gptel-agent-harness--auto-save-session)
          ;; Still only one file
          (should (= 1 (length (directory-files temp-dir t "\\.md\\'"))))
          ;; Content is updated
          (let ((file (car (directory-files temp-dir t "\\.md\\'"))))
            (with-temp-buffer
              (insert-file-contents file)
              (should (search-forward "version-2" nil t)))))))))
;;;; Token Calibration Tests

(ert-deftest gptel-agent-harness-test-calibration-updates-ratio ()
  "Test that calibration factor is updated from `gptel--token-usage' (total)."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--token-calibration 1.0)
      (setq-local gptel-agent-harness--last-raw-estimate 100)
      ;; Simulate gptel reporting 100 input + 20 output = 120 total tokens
      (setq-local gptel--token-usage (list (list :input 100 :output 20) nil))
      (gptel-agent-harness--update-token-calibration)
      ;; (100 + 20) / 100 = 1.2
      (should (= gptel-agent-harness--token-calibration 1.2)))))

(ert-deftest gptel-agent-harness-test-calibration-clamped ()
  "Test that calibration factor is clamped to [0.5, 3.0]."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--token-calibration 1.0)
      (setq-local gptel-agent-harness--last-raw-estimate 100)
      ;; Extremely high total (800+200=1000) → 10x → clamped to 3.0
      (setq-local gptel--token-usage (list (list :input 800 :output 200) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 3.0))
      ;; Extremely low total (5+5=10) → 0.1x → clamped to 0.5
      (setq-local gptel--token-usage (list (list :input 5 :output 5) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 0.5)))))

(ert-deftest gptel-agent-harness-test-calibration-no-usage ()
  "Test that calibration is unchanged when `gptel--token-usage' is nil."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--token-calibration 1.5)
      (setq-local gptel-agent-harness--last-raw-estimate 100)
      (setq-local gptel--token-usage nil)
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 1.5)))))

(ert-deftest gptel-agent-harness-test-calibration-no-estimate ()
  "Test that calibration is unchanged when last-raw-estimate is nil."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--token-calibration 1.5)
      (setq-local gptel-agent-harness--last-raw-estimate nil)
      (setq-local gptel--token-usage (list (list :input 120 :output 50) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 1.5)))))

(ert-deftest gptel-agent-harness-test-calibration-applied-to-ratio ()
  "Test that context ratio incorporates calibration factor."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))  ; 32768 fallback
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--token-calibration 1.5))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :system (make-string 40000 ?x)
                    :messages (vector)))
             (ratio (gptel-agent-harness--context-ratio-for-fsm fsm)))
        ;; Raw: 10000 tokens, calibrated: 15000, ratio: 15000/32768 ≈ 0.458
        (should (> ratio 0.44))
        (should (< ratio 0.47))))))

(provide 'gptel-agent-harness-test)

;;; gptel-agent-harness-test.el ends here

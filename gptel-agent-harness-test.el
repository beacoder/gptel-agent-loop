;;; gptel-agent-harness-test.el --- Tests for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "25.1") (compat "0.33.0") (nadvice "0.4") (gptel-agent "0.0.1"))
;; Package-Author: Huming Chen
;; Package-Keywords: programming, convenience, ai, agent
;; Package-Description: Tests for gptel-agent-harness.
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

(ert-deftest gptel-agent-harness-test-cjk-char-p ()
  "Test CJK character detection."
  (should (gptel-agent-harness--cjk-char-p ?中))
  (should (gptel-agent-harness--cjk-char-p ?あ))
  (should (gptel-agent-harness--cjk-char-p ?Ａ))
  (should-not (gptel-agent-harness--cjk-char-p ?A))
  (should-not (gptel-agent-harness--cjk-char-p ?é)))

(ert-deftest gptel-agent-harness-test-terminal-p ()
  "Test terminal state detection."
  (should (gptel-agent-harness--terminal-p 'DONE))
  (should (gptel-agent-harness--terminal-p 'ERRS))
  (should-not (gptel-agent-harness--terminal-p 'WAIT))
  (should-not (gptel-agent-harness--terminal-p 'TOOL))
  (should-not (gptel-agent-harness--terminal-p nil)))

(ert-deftest gptel-agent-harness-test-estimate-tokens ()
  "Test token estimation for mixed content."
  (with-temp-buffer
    (insert "abcdefghijklmnopqrst")
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 5)))
  (with-temp-buffer
    (insert "你好世界")
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 2)))
  (with-temp-buffer
    (insert "hello   你好世界")
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 4))))

(ert-deftest gptel-agent-harness-test-context-window ()
  "Test model context window lookup."
  (let ((gptel-model "claude-sonnet-4-20250514"))
    (should (= (gptel-agent-harness--context-window) 200000)))
  (let ((gptel-model "gpt-5-mini-2026"))
    (should (= (gptel-agent-harness--context-window) 128000)))
  (let ((gptel-model "unknown-model-xyz"))
    (should (= (gptel-agent-harness--context-window) 32768))))

(ert-deftest gptel-agent-harness-test-model-name ()
  "Test model name coercion."
  (let ((gptel-model 'claude-sonnet))
    (should (equal (gptel-agent-harness--model-name) "claude-sonnet")))
  (let ((gptel-model "gpt-5"))
    (should (equal (gptel-agent-harness--model-name) "gpt-5")))
  (let ((gptel-model 42))
    (should (equal (gptel-agent-harness--model-name) ""))))

(ert-deftest gptel-agent-harness-test-nudge-counter ()
  "Test nudge count increment, get, and reset via fake FSM."
  (let ((buf (generate-new-buffer " *harness-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
                   (lambda (_fsm) buf)))
          (let ((fake-fsm 'ignored))
            (should (= (gptel-agent-harness--get-nudges fake-fsm) 0))
            (gptel-agent-harness--inc-nudges fake-fsm)
            (should (= (gptel-agent-harness--get-nudges fake-fsm) 1))
            (gptel-agent-harness--inc-nudges fake-fsm)
            (should (= (gptel-agent-harness--get-nudges fake-fsm) 2))
            (gptel-agent-harness--reset-nudges fake-fsm)
            (should (= (gptel-agent-harness--get-nudges fake-fsm) 0))))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-can-nudge-p ()
  "Test nudge budget check."
  (let ((buf (generate-new-buffer " *harness-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
                   (lambda (_fsm) buf)))
          (let ((fake-fsm 'ignored)
                (gptel-agent-harness-max-nudges 2))
            (should (gptel-agent-harness--can-nudge-p fake-fsm))
            (gptel-agent-harness--inc-nudges fake-fsm)
            (should (gptel-agent-harness--can-nudge-p fake-fsm))
            (gptel-agent-harness--inc-nudges fake-fsm)
            (should-not (gptel-agent-harness--can-nudge-p fake-fsm))))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-context-tokens-from-data ()
  "Test token estimation from full prompt payload."
  (let ((buf (generate-new-buffer " *harness-test*"))
        (gptel-agent-harness-verbose nil))
    (unwind-protect
        (let ((fake-fsm (gptel-make-fsm
                         :info (list :buffer buf
                                     :data (list :system "system prompt here"
                                                 :messages (vector
                                                            (list :role "user"
                                                                  :content "hello world")
                                                            (list :role "assistant"
                                                                  :content "hi there")
                                                            (list :role "user"
                                                                  :content "do something")))))))
          (should (= (gptel-agent-harness--context-tokens-from-data fake-fsm) 12)))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-context-tokens-from-data-with-list-content ()
  "Test token estimation with structured (list) content in messages."
  (let ((buf (generate-new-buffer " *harness-test*"))
        (gptel-agent-harness-verbose nil))
    (unwind-protect
        (let ((fake-fsm (gptel-make-fsm
                         :info (list :buffer buf
                                     :data (list :system "sys"
                                                 :messages (vector
                                                            (list :role "assistant"
                                                                  :content
                                                                  (list (list :text "part one")
                                                                        (list :text "part two")))))))))
          (should (= (gptel-agent-harness--context-tokens-from-data fake-fsm) 5)))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-context-tokens-from-data-nil-content ()
  "Test token estimation handles nil content with tool_calls."
  (let ((buf (generate-new-buffer " *harness-test*"))
        (gptel-agent-harness-verbose nil))
    (unwind-protect
        (let ((fake-fsm (gptel-make-fsm
                         :info (list :buffer buf
                                     :data (list :system ""
                                                 :messages (vector
                                                            (list :role "assistant"
                                                                  :content nil
                                                                  :tool_calls
                                                                  (vector
                                                                   (list :type "function"
                                                                         :id "call_123"
                                                                         :function
                                                                         (list :name "Skill"
                                                                               :arguments "{\"skill\":\"test\"}"))))))))))
          (should (= (gptel-agent-harness--context-tokens-from-data fake-fsm) 6)))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-context-ratio-for-fsm ()
  "Test FSM-based context ratio calculation."
  (let ((buf (generate-new-buffer " *harness-test*"))
        (gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))
    (unwind-protect
        (let ((fake-fsm (gptel-make-fsm
                         :info (list :buffer buf
                                     :data (list :system (make-string 40000 ?x)
                                                 :messages (vector))))))
          (let ((ratio (gptel-agent-harness--context-ratio-for-fsm fake-fsm)))
            (should (> ratio 0.3))
            (should (< ratio 0.31))))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-context-ratio-indicator ()
  "Test context ratio indicator string generation."
  (let ((gptel-agent-harness-show-context-ratio t)
        (gptel-agent-harness-context-trigger 0.70))
    (let ((gptel-agent-harness--context-ratio nil))
      (should (equal (gptel-agent-harness--context-ratio-indicator) "")))
    (let ((gptel-agent-harness--context-ratio 0.25))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:25%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'success))))
    (let ((gptel-agent-harness--context-ratio 0.60))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:60%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'warning))))
    (let ((gptel-agent-harness--context-ratio 0.85))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:85%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'error))))
    (let ((gptel-agent-harness-show-context-ratio nil)
          (gptel-agent-harness--context-ratio 0.50))
      (should (equal (gptel-agent-harness--context-ratio-indicator) "")))))

(ert-deftest gptel-agent-harness-test-mode-line-setup-idempotent ()
  "Test mode-line setup is idempotent and uses a risky construct."
  (let ((buf (generate-new-buffer " *harness-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local gptel-mode t)
          (should (get 'gptel-agent-harness--mode-line-construct
                       'risky-local-variable))
          (gptel-agent-harness--setup-mode-line)
          (gptel-agent-harness--setup-mode-line)
          (should (= 1 (cl-count 'gptel-agent-harness--mode-line-construct
                                 mode-line-misc-info))))
      (kill-buffer buf))))

(ert-deftest gptel-agent-harness-test-mode-enable-disable ()
  "End-to-end regression: enabling and disabling the global mode."
  (let ((buf (generate-new-buffer " *harness-test*"))
        (was-enabled gptel-agent-harness-mode))
    (unwind-protect
        (progn
          (when was-enabled (gptel-agent-harness-mode -1))
          (with-current-buffer buf (setq-local gptel-mode t))
          (gptel-agent-harness-mode 1)
          (should (advice-member-p
                   #'gptel-agent-harness--transition-advice
                   'gptel--fsm-transition))
          (should (memq #'gptel-agent-harness--setup-mode-line
                        gptel-mode-hook))
          (with-current-buffer buf
            (should (memq 'gptel-agent-harness--mode-line-construct
                          mode-line-misc-info))
            (setq-local gptel-agent-harness--context-ratio 0.42)
            (should (string-match-p
                     "\\[Ctx:42%%\\]"
                     (gptel-agent-harness--context-ratio-indicator))))
          (gptel-agent-harness-mode -1)
          (should-not (advice-member-p
                       #'gptel-agent-harness--transition-advice
                       'gptel--fsm-transition))
          (should-not (memq #'gptel-agent-harness--setup-mode-line
                            gptel-mode-hook))
          (with-current-buffer buf
            (should-not (memq 'gptel-agent-harness--mode-line-construct
                              mode-line-misc-info))
            (should-not gptel-agent-harness--context-ratio)))
      (kill-buffer buf)
      (if was-enabled
          (gptel-agent-harness-mode 1)
        (gptel-agent-harness-mode -1)))))

(provide 'gptel-agent-harness-test)

;;; gptel-agent-harness-test.el ends here

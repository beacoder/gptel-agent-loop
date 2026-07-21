;;; gptel-agent-harness-commands.el --- Commands for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
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
;; Commands for gptel-agent-harness.
;;
;;; Code:

(require 'gptel)
(require 'gptel-agent)
(require 'project)

(defconst gptel-agent-harness-commands--initialize-prompt-file
  (expand-file-name
   "prompts/initialize.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "File path for the project initialization prompt.")

(defconst gptel-agent-harness-commands--review-prompt-file
  (expand-file-name
   "prompts/review.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "File path for the code review prompt.")

(defun gptel-agent-harness-commands--read-initialize-prompt ()
  "Read and return the initialize prompt file contents."
  (if (file-exists-p gptel-agent-harness-commands--initialize-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness-commands--initialize-prompt-file)
        (buffer-string))
    (error "Initialize prompt file not found: %s"
           gptel-agent-harness-commands--initialize-prompt-file)))

(defun gptel-agent-harness-commands--read-review-prompt ()
  "Read and return the review prompt file contents."
  (if (file-exists-p gptel-agent-harness-commands--review-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness-commands--review-prompt-file)
        (buffer-string))
    (error "Review prompt file not found: %s"
           gptel-agent-harness-commands--review-prompt-file)))

(defun gptel-agent-harness-commands--substitute-placeholders (template project-dir extra)
  "Substitute ${path} and $ARGUMENTS in TEMPLATE with PROJECT-DIR and EXTRA."
  (let ((result template))
    (setq result (replace-regexp-in-string
                  "\\${path}" project-dir result t t))
    (setq result (replace-regexp-in-string
                  "\\$ARGUMENTS" (or extra "") result t t))
    result))

;;;###autoload
(defun gptel-agent-harness-commands-initialize (&optional project-dir extra)
  "Initialize a project by creating or updating AGENTS.md.

Creates a dedicated gptel buffer with agent tools enabled and uses the
initialize prompt from `gptel-agent-harness-commands--initialize-prompt-file' to
guide the LLM in analyzing the repository and generating AGENTS.md.

PROJECT-DIR defaults to the current project root (via `project-current')
or `default-directory'.  The detected directory is presented to the
user, who can confirm it or provide a different one.

EXTRA is additional instructions to substitute into the $ARGUMENTS
placeholder of the initialize prompt.  When called interactively, the
user is prompted to provide extra instructions.

If region is active, the selected text is sent as initial context."
  (interactive
   (let* ((detected (if-let* ((proj (project-current)))
                        (project-root proj)
                      default-directory))
          (proj-name (file-name-nondirectory
                      (directory-file-name detected)))
          (dir (if (y-or-n-p (format "Initialize project %s? " proj-name))
                   detected
                 (read-directory-name "Project directory: ")))
          (extra-str (read-string "Extra instructions (for $ARGUMENTS): ")))
     (list dir (and (not (string-blank-p extra-str)) extra-str))))
  (unless (file-directory-p project-dir)
    (user-error "Invalid project directory: %s" project-dir))
  (let* ((raw-prompt (gptel-agent-harness-commands--read-initialize-prompt))
         (prompt-content (gptel-agent-harness-commands--substitute-placeholders
                          raw-prompt project-dir extra))
         (proj-name (file-name-nondirectory
                     (directory-file-name project-dir)))
         (region-content (and (use-region-p)
                              (buffer-substring (region-beginning)
                                                (region-end))))
         ;; Set up gptel variables for the new buffer
         (gptel-system-prompt prompt-content)
         (gptel-temperature 0)
         (gptel-buf
          (gptel (generate-new-buffer-name
                  (format "*gptel-agent-init:%s*" proj-name))
                 nil region-content 'interactive)))
    (with-current-buffer gptel-buf
      (setq default-directory project-dir)
      (gptel-agent-update)
      ;; Enable tools for this buffer
      (setq-local gptel-use-tools t)
      (setq-local gptel-tools
                  (flatten-list
                   (mapcar #'gptel-get-tool
                           '("TodoWrite" "Glob" "Grep" "Read" "Insert"
                             "Edit" "Write" "Mkdir" "Bash" "Skill" "Question"))))
      (gptel--update-status " Initializing..." 'warning)
      (unless region-content
        (goto-char (point-max))
        (insert (format
                 "Analyze the repository at %s and create/update AGENTS.md."
                 project-dir))
        (insert "\n"))
      (gptel-send))
    gptel-buf))

;;;###autoload
(defun gptel-agent-harness-commands-review (&optional arguments)
  "Perform a code review using the review prompt.

ARGUMENTS can be:
- nil or empty: Review all uncommitted changes (default)
- A commit hash (40-char SHA or short hash): Review that specific commit
- A branch name: Compare current branch to the specified branch
- A PR URL or number: Review the pull request

If region is active, the selected text is sent as initial context.

If called from a buffer where `gptel-mode' is enabled, output goes
to that buffer.
Otherwise, a dedicated *gptel-agent-review* buffer is created."
  (interactive
   (let ((arg-str (read-string "Review arguments (commit/branch/PR, or empty for uncommitted changes): ")))
     (list (and (not (string-blank-p arg-str)) arg-str))))
  (let* ((raw-prompt (gptel-agent-harness-commands--read-review-prompt))
         (prompt-content (gptel-agent-harness-commands--substitute-placeholders
                          raw-prompt default-directory arguments))
         (region-content (and (use-region-p)
                              (buffer-substring (region-beginning)
                                                (region-end))))
         (in-agent-buffer (bound-and-true-p gptel-mode))
         gptel-buf)
    (if in-agent-buffer
        (setq gptel-buf (current-buffer))
      (setq gptel-buf (gptel (generate-new-buffer-name "*gptel-agent-review*")
                             nil region-content 'interactive)))
    (with-current-buffer gptel-buf
      (setq-local gptel-system-prompt prompt-content)
      (setq-local gptel-temperature 0)
      (unless in-agent-buffer
        (setq default-directory (or (and (boundp 'project-local-vars)
                                         (let ((proj (project-current)))
                                           (and proj (project-root proj))))
                                    default-directory))
        (gptel-agent-update)
        (setq-local gptel-use-tools t)
        (setq-local gptel-tools
                    (flatten-list
                     (mapcar #'gptel-get-tool
                             '("Agent" "TodoWrite" "Glob" "Grep" "Read" "Insert"
                               "Edit" "Write" "Mkdir" "Bash" "Skill" "Question")))))
      (gptel--update-status " Reviewing..." 'warning)
      (goto-char (point-max))
      (if region-content
          (insert region-content "\n")
        (insert (format "Review code changes%s.\n"
                        (if arguments
                            (format " with arguments: %s" arguments)
                          ""))))
      (gptel-send)
      gptel-buf)))

(provide 'gptel-agent-harness-commands)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-commands.el ends here

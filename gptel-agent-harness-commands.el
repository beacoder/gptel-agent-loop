;;; gptel-agent-harness-commands.el --- Commands for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
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
;; Commands for gptel-agent-harness.
;;
;;; Code:

(require 'gptel)
(require 'gptel-agent)
(require 'project)
(require 'cl-lib)

(defconst gptel-agent-harness-initialize-prompt-file
  (expand-file-name
   "prompts/initialize.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "File path for the project initialization prompt.")

(defun gptel-agent-harness--read-initialize-prompt ()
  "Read the initialize prompt from `gptel-agent-harness-initialize-prompt-file'."
  (if (file-exists-p gptel-agent-harness-initialize-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness-initialize-prompt-file)
        (buffer-string))
    (error "Initialize prompt file not found: %s"
           gptel-agent-harness-initialize-prompt-file)))

(defun gptel-agent-harness--substitute-placeholders (template project-dir extra)
  "Substitute ${path} and $ARGUMENTS in TEMPLATE with PROJECT-DIR and EXTRA."
  (let ((result template))
    (setq result (replace-regexp-in-string
                  "\\${path}" project-dir result t t))
    (setq result (replace-regexp-in-string
                  "\\$ARGUMENTS" (or extra "") result t t))
    result))

;;;###autoload
(defun gptel-agent-harness-initialize (&optional project-dir extra)
  "Initialize a project by creating or updating AGENTS.md.

Creates a dedicated gptel buffer with agent tools enabled and uses the
initialize prompt from `gptel-agent-harness-initialize-prompt-file' to
guide the LLM in analyzing the repository and generating AGENTS.md.

PROJECT-DIR defaults to the current project root (via `project-current')
or `default-directory'.  The detected directory is presented to the
user, who can confirm it or provide a different one.

EXTRA is additional instructions to substitute into the $ARGUMENTS
placeholder of the initialize prompt.  When called interactively, the
user is prompted to provide extra instructions.

If region is active, the selected text is sent as initial context."
  (interactive
   (let* ((detected (if-let ((proj (project-current)))
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
  (gptel--update-status " Initializing..." 'warning)
  (let* ((raw-prompt (gptel-agent-harness--read-initialize-prompt))
         (prompt-content (gptel-agent-harness--substitute-placeholders
                         raw-prompt project-dir extra))
         (preset-name (cl-gensym "gptel-agent-harness-init-"))
         (proj-name (file-name-nondirectory
                     (directory-file-name project-dir)))
         (region-content (and (use-region-p)
                              (buffer-substring (region-beginning)
                                                (region-end)))))
    (gptel-make-preset preset-name
      :description "A preset optimized for project initialization (AGENTS.md)"
      :backend gptel-backend
      :model gptel-model
      :stream t
      :system prompt-content
      :tools '("TodoWrite" "Glob" "Grep" "Read" "Insert" "Edit" "Write"
               "Mkdir" "Bash" "Skill")
      :temperature 0)
    (let* ((gptel-buf
            (gptel (generate-new-buffer-name
                    (format "*gptel-agent-init:%s*" proj-name))
                   nil region-content 'interactive)))
      (with-current-buffer gptel-buf
        (setq default-directory project-dir)
        (gptel-agent-update)
        (gptel--apply-preset
         preset-name
         (lambda (sym val) (set (make-local-variable sym) val)))
        (gptel--update-status " Initializing..." 'warning)
        (unless region-content
          (goto-char (point-max))
          (insert (format
                   "Analyze the repository at %s and create/update AGENTS.md."
                   project-dir))
          (when extra
            (insert (format "\n\nAdditional instructions: %s" extra)))
          (insert "\n"))
        (gptel-send))
      gptel-buf)))

(provide 'gptel-agent-harness-commands)

;; Local Variables:
;; package-lint-main-file: "/home/huming/.emacs.d/site-lisp/gptel-agent-harness.el"
;; End:

;;; gptel-agent-harness-commands.el ends here

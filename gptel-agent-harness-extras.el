;;; gptel-agent-harness-extras.el --- Extras for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "29.1") (gptel-agent "0.0.1"))
;; Package-Keywords: programming, convenience, ai, agent
;; Package-Description: Improved tools and agent definition for gptel-agent-harness.
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
;; Extras for gptel-agent-harness: improved glob/grep tools and the
;; gptel-opencode-agent definition.
;;
;; Tools:
;;
;; - `gptel-agent-harness-extras--glob': Uses `git ls-files' for fast,
;;   .gitignore-aware file listing in git repos, falling back to `tree'
;;   outside of git.
;;
;; - `gptel-agent-harness-extras--grep': Like the upstream grep but passes
;;   the regex via `-e' flag to git-grep for robustness.
;;
;; Agent:
;;
;; - `gptel-opencode-agent': A special agent entry point that uses custom
;;   agent definitions from `gptel-agent-harness-extras-agent-dirs'.
;;
;; These are activated/deactivated by `gptel-agent-harness-mode' in
;; gptel-agent-harness.el.  No separate mode is needed.
;;
;; Usage:
;;   (require 'gptel-agent-harness-extras)
;;
;;; Code:

(require 'gptel-agent)
(require 'cl-lib)

;;;; Internal State

(defvar gptel-agent-harness-extras--orig-glob nil
  "Original `gptel-agent--glob' function, saved before override.")

(defvar gptel-agent-harness-extras--orig-grep nil
  "Original `gptel-agent--grep' function, saved before override.")

;;;; Glob Tool — git ls-files with tree fallback

(defun gptel-agent-harness-extras--glob (pattern &optional path depth)
  "Find files matching PATTERN using `git ls-files' or `tree'.

Inside a git repository, uses `git ls-files' which is significantly
faster and respects .gitignore.  Falls back to `tree' outside git.

PATTERN is a glob pattern to match filenames against.
PATH is the optional directory to search (defaults to current directory).
DEPTH limits recursion depth when provided (non-negative integer).

Returns a string listing matching files with full paths.  If the
output is too large, it is truncated by `gptel-agent--truncate-buffer'."
  (when (string-empty-p pattern)
    (error "Error: pattern must not be empty"))
  (if path
      (unless (and (file-readable-p path) (file-directory-p path))
        (error "Error: path %s is not readable" path))
    (setq path "."))
  (unless (executable-find "tree")
    (error "Error: Executable `tree` not found.  This tool cannot be used"))
  (let* ((full-path (directory-file-name (expand-file-name path)))
         (git-root
          (and (executable-find "git") (locate-dominating-file full-path ".git"))))
    (with-temp-buffer
      (if git-root
          ;; --- Git Strategy ---
          (let* ((default-directory git-root)
                 (relative-dir (file-relative-name full-path git-root))
                 (pathspec (if (string= relative-dir ".")
                               pattern
                             (concat relative-dir "/" pattern)))
                 (exit-code
                  (call-process "git" nil t nil
                                "ls-files" "-z"
                                "--full-name"
                                "--cached"           ; Tracked files
                                "--others"           ; Untracked files
                                "--exclude-standard" ; Respect .gitignore
                                "--" pathspec)))
            (if (/= exit-code 0)
                (progn (goto-char (point-min))
                       (insert (format "Glob failed with exit code %d\n.STDOUT:\n\n"
                                       exit-code)))
              ;; Convert null-terminated strings to newline-separated full paths
              (goto-char (point-min))
              (while (search-forward "\0" nil t)
                (replace-match "\n"))
              ;; Filter by depth if specified
              (when (natnump depth)
                (let ((base-depth (if (string= relative-dir ".")
                                      0
                                    (1+ (cl-count ?/ relative-dir)))))
                  (goto-char (point-min))
                  (while (not (eobp))
                    (if (and (not (looking-at-p "^$"))
                             (>= (cl-count ?/ (buffer-substring
                                               (line-beginning-position)
                                               (line-end-position)))
                                 (+ base-depth depth)))
                        (delete-region (line-beginning-position)
                                       (min (1+ (line-end-position)) (point-max)))
                      (forward-line 1)))))
              ;; Prepend git-root to make paths absolute
              (goto-char (point-min))
              (let ((path-prefix (file-name-as-directory git-root)))
                (while (not (eobp))
                  (unless (looking-at-p "^$") ; Skip empty lines
                    (insert path-prefix))
                  (forward-line 1)))))
        ;; --- Tree Strategy (Fallback) ---
        (let* ((args (list "-l" "-f" "-i" "-I" ".git"
                           "--sort=mtime" "--ignore-case"
                           "--prune" "-P" pattern full-path))
               (args (if (natnump depth)
                         (nconc args (list "-L" (number-to-string depth)))
                       args))
               (exit-code (apply #'call-process "tree" nil t nil args)))
          (when (/= exit-code 0)
            (goto-char (point-min))
            (insert (format "Glob failed with exit code %d\n.STDOUT:\n\n"
                            exit-code)))))
      (gptel-agent--truncate-buffer "glob")
      (buffer-string))))

;;;; Grep Tool — git grep with -e flag

(defun gptel-agent-harness-extras--grep (regex path &optional glob context-lines)
  "Search for REGEX in file or directory at PATH.

Like the upstream `gptel-agent--grep' but passes REGEX via `-e'
flag to git-grep, which avoids misinterpretation of patterns
starting with a dash.

REGEX is a PCRE-format regular expression to search for.
PATH can be a file or directory to search in.

Optional arguments:
GLOB restricts the search to files matching the glob pattern.
CONTEXT-LINES specifies the number of lines of context to show
  around each match (0-15 inclusive, defaults to 0).

Returns a string containing matches grouped by file, with line numbers
and optional context."
  (unless (file-readable-p path)
    (error "Error: File or directory %s is not readable" path))
  (let* ((full-path (expand-file-name (substitute-in-file-name path)))
         ;; Explicitly set remote to save ourselves multiple file-remote-p
         ;; checks inside `executable-find'
         (remote (file-remote-p default-directory))
         (git-root (and (executable-find "git" remote)
                        (locate-dominating-file full-path ".git")))
         (grepper (cond
                   (git-root "git")
                   ((executable-find "rg" remote) "rg")
                   ((executable-find "grep" remote) "grep")
                   (t (error "Error: ripgrep/grep/git-grep not available, \
this tool cannot be used")))))
    (with-temp-buffer
      (let* ((default-directory (or git-root default-directory))
             (args
              (cond
               ((string= "git" grepper)
                (let* ((rel-path (file-relative-name full-path git-root))
                       (pathspecs
                        (list (if (and glob (file-directory-p full-path))
                                  (file-name-concat rel-path glob)
                                rel-path))))
                  (delq nil
                        (nconc
                         (list "grep"
                               "--line-number"
                               "--no-color"
                               (and (natnump context-lines)
                                    (format "-C%d" context-lines))
                               "--max-count=1000"
                               "--untracked"
                               "-P" "-e" regex
                               "--")
                         pathspecs))))
               ((string= "rg" grepper)
                (delq nil (list "--sort=modified"
                                (and (natnump context-lines)
                                     (format "--context=%d" context-lines))
                                (and glob (format "--glob=%s" glob))
                                "--max-count=1000"
                                "--heading" "--line-number" "-e" regex
                                (file-local-name full-path))))
               ((string= "grep" grepper)
                (delq nil (list "--recursive"
                                (and (natnump context-lines)
                                     (format "--context=%d" context-lines))
                                (and glob (format "--include=%s" glob))
                                "--max-count=1000"
                                "--line-number" "--regexp" regex
                                (file-local-name full-path))))))
             (exit-code (apply #'process-file grepper nil '(t t) nil args)))
        (when (>= exit-code 2)
          (goto-char (point-min))
          (insert (format "Error: search failed with exit-code %d.  Tool output:\n\n"
                          exit-code)))
        (gptel-agent--truncate-buffer "grep")
        (buffer-string)))))

;;;; Agent Definition — gptel-opencode-agent

(defcustom gptel-agent-harness-extras-agent-dirs
  (list (expand-file-name "agents" user-emacs-directory))
  "Directories containing agent definition files for the harness.
Replaces `gptel-agent-dirs' when the harness is enabled."
  :type '(repeat directory)
  :group 'gptel-agent-harness)

(defmacro gptel-agent-harness-extras--define-agent (name mcp-servers)
  "Define a gptel agent function with gptel-name as NAME and connect it to MCP-SERVERS."
  (let ((func-name (intern (format "gptel-%s" name)))
        (agent-name (format "gptel-%s" name)))
    `(defun ,func-name (&optional project-dir)
       (interactive
        (list (if-let ((proj (project-current)))
                  (project-root proj)
                default-directory)))
       (when ',mcp-servers
         (require 'gptel-integrations)
         (gptel-mcp-connect ',mcp-servers)
         (while (not (gptel-mcp--get-tools ',mcp-servers))
           (sleep-for 0.1)))
       (let ((gptel-use-tools t)
             (gptel-tools gptel-tools)
             (gptel-buf
              (gptel (generate-new-buffer-name
                      (format ,(format "*%s:%%s*" agent-name)
                              (cadr (nreverse (file-name-split project-dir)))))
                     nil
                     (and (use-region-p)
                          (buffer-substring (region-beginning) (region-end)))
                     'interactive)))
         (with-current-buffer gptel-buf
           (setq default-directory project-dir)
           (gptel-agent-update)
           (when-let* ((gptel-agent-plist
                        (assoc-default ,agent-name gptel-agent--agents nil nil)))
             (apply #'gptel-make-preset ',func-name gptel-agent-plist))
           (gptel--apply-preset
            ',func-name
            (lambda (sym val) (set (make-local-variable sym) val))))))))

(defvar gptel-agent-harness-extras--orig-agent-dirs nil
  "Original `gptel-agent-dirs' value, saved before override.")

(defvar gptel-agent-harness-extras--orig-agent-fn nil
  "Original `gptel-agent' function, saved before override.")

;; Define `gptel-opencode-agent' at load time.
(gptel-agent-harness-extras--define-agent opencode-agent nil)

;;;; Activation / Deactivation (called by gptel-agent-harness-mode)

(defun gptel-agent-harness-extras-enable ()
  "Override `gptel-agent--glob' and `gptel-agent--grep' with improved versions.
Also set up `gptel-opencode-agent' as the default agent."
  ;; Glob/Grep overrides
  (when (fboundp 'gptel-agent--glob)
    (unless gptel-agent-harness-extras--orig-glob
      (setq gptel-agent-harness-extras--orig-glob
            (symbol-function 'gptel-agent--glob)))
    (fset 'gptel-agent--glob #'gptel-agent-harness-extras--glob))
  (when (fboundp 'gptel-agent--grep)
    (unless gptel-agent-harness-extras--orig-grep
      (setq gptel-agent-harness-extras--orig-grep
            (symbol-function 'gptel-agent--grep)))
    (fset 'gptel-agent--grep #'gptel-agent-harness-extras--grep))
  ;; Agent override
  (unless gptel-agent-harness-extras--orig-agent-dirs
    (setq gptel-agent-harness-extras--orig-agent-dirs gptel-agent-dirs))
  (setq gptel-agent-dirs gptel-agent-harness-extras-agent-dirs)
  (unless gptel-agent-harness-extras--orig-agent-fn
    (setq gptel-agent-harness-extras--orig-agent-fn
          (and (fboundp 'gptel-agent) (symbol-function 'gptel-agent))))
  (fset 'gptel-agent #'gptel-opencode-agent))

(defun gptel-agent-harness-extras-disable ()
  "Restore original `gptel-agent--glob' and `gptel-agent--grep'.
Also restore the original `gptel-agent' function and agent dirs."
  ;; Glob/Grep restore
  (when gptel-agent-harness-extras--orig-glob
    (fset 'gptel-agent--glob gptel-agent-harness-extras--orig-glob)
    (setq gptel-agent-harness-extras--orig-glob nil))
  (when gptel-agent-harness-extras--orig-grep
    (fset 'gptel-agent--grep gptel-agent-harness-extras--orig-grep)
    (setq gptel-agent-harness-extras--orig-grep nil))
  ;; Agent restore
  (when gptel-agent-harness-extras--orig-agent-dirs
    (setq gptel-agent-dirs gptel-agent-harness-extras--orig-agent-dirs)
    (setq gptel-agent-harness-extras--orig-agent-dirs nil))
  (when gptel-agent-harness-extras--orig-agent-fn
    (fset 'gptel-agent gptel-agent-harness-extras--orig-agent-fn)
    (setq gptel-agent-harness-extras--orig-agent-fn nil)))

(provide 'gptel-agent-harness-extras)
;;; gptel-agent-harness-extras.el ends here

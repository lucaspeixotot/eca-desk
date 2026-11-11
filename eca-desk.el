;;; eca-desk.el --- Chats, sessions and projects workflow on top of ECA  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucas Peixoto

;; Author: Lucas Peixoto <lucaspeixotoac@gmail.com>
;; URL: https://github.com/lucaspeixotot/eca-desk
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (eca "0.0.1"))
;; Keywords: tools, convenience

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
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; eca-desk layers a GitHub Copilot Desktop App-style workflow on top of
;; eca-emacs without touching the ECA core.  It organizes agent work in
;; three kinds of places under a hidden base directory
;; (`eca-desk-base-directory'):
;;
;;   chats/              one permanent, empty folder anchoring a scratch
;;                       ECA session for disposable conversations;
;;   sessions/<name>/    a disposable work folder, optionally with one
;;                       shallow repository clone, its own ECA session;
;;   projects/<name>/    a persistent, multi-repository workspace with a
;;                       library of artifacts and conversation summaries.
;;
;; Every project and session gets an AGENTS.md and a set of rules under
;; `.eca/rules/' (see `eca-desk-templates') that teach the agent the
;; worktree protocol, the library layout and the conversation export
;; convention.  Local folders can be registered with a project or session;
;; they are not copied — they become extra ECA workspace folders.
;;
;; Commands (no keybindings are defined; bind what you use):
;;
;;   `eca-desk-chat'            open/reuse the scratch session, new chat tab
;;   `eca-desk-new-project'     scaffold a project (name → repos → folders)
;;   `eca-desk-new-session'     scaffold a session (name → repo → folders)
;;   `eca-desk-open'            open an existing project or session
;;   `eca-desk-reference-chat'  insert a reference to a chat summary of any
;;                              project/session into the current prompt
;;   `eca-desk-export-chat'     save the current chat transcript into the
;;                              workspace's library/chats/
;;   `eca-desk-add-repo'        clone one more repository into the current
;;                              project/session
;;   `eca-desk-add-local-folder' register one more local folder
;;
;; Sample configuration:
;;
;;   (use-package eca-desk
;;     :after eca
;;     :custom
;;     (eca-desk-git-ssh-hosts '(("personal" . "personal-github.com")
;;                               ("work" . "work-github.com"))))
;;
;; Tested with eca-emacs 0.11.0 (commit 9076540).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eca)
(require 'eca-util)
(require 'eca-chat)
(require 'eca-desk-templates)

;;;; Customization

(defgroup eca-desk nil
  "Chats, sessions and projects workflow on top of ECA."
  :group 'tools
  :prefix "eca-desk-")

(defcustom eca-desk-base-directory
  (expand-file-name "eca-desk"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Base directory holding `chats/', `sessions/' and `projects/'."
  :type 'directory
  :group 'eca-desk)

(defcustom eca-desk-clone-arguments '("--filter=blob:none")
  "Extra arguments passed to `git clone' for repositories.
The default produces a blobless clone: full history metadata, file
contents fetched lazily.  Use (\"--depth\" \"1\") for a shallow clone."
  :type '(repeat string)
  :group 'eca-desk)

(defcustom eca-desk-git-ssh-hosts nil
  "Alist of (LABEL . SSH-HOST) used to expand `owner/repo' shorthands.
SSH-HOST is a `Host' entry of your ssh config (or a real hostname).
When nil, `owner/repo' expands to `git@github.com:owner/repo.git'.
When non-nil, the host is asked with completion."
  :type '(alist :key-type (string :tag "Label")
                :value-type (string :tag "SSH host"))
  :group 'eca-desk)

(defcustom eca-desk-initial-prompt
  "Read AGENTS.md and the rules under .eca/rules/, then summarize what this workspace is about and ask me what to do."
  "Prompt sent to the agent when a project or session is created.
Set to nil to open the chat without sending anything."
  :type '(choice (const :tag "No initial prompt" nil) string)
  :group 'eca-desk)

;;;; Paths

(defconst eca-desk--kinds '("project" "session")
  "Workspace kinds managed by eca-desk.")

(defun eca-desk--dir (&rest segments)
  "Return a path under `eca-desk-base-directory' joining SEGMENTS."
  (let ((dir (expand-file-name eca-desk-base-directory)))
    (dolist (s segments)
      (setq dir (expand-file-name s dir)))
    dir))

(defun eca-desk--kind-dir (kind)
  "Return the directory holding all workspaces of KIND."
  (eca-desk--dir (concat kind "s")))

(defun eca-desk--workspace-dir (kind name)
  "Return the directory of workspace NAME of KIND."
  (expand-file-name name (eca-desk--kind-dir kind)))

(defun eca-desk--ensure-base-directory ()
  "Create the base directory layout if missing."
  (dolist (d (list (eca-desk--dir "chats")
                   (eca-desk--dir "sessions")
                   (eca-desk--dir "projects")))
    (make-directory d t)))

(defun eca-desk--list-workspaces (&optional kind)
  "Return a list of (KIND . NAME) for existing workspaces.
Restrict to KIND when given."
  (cl-loop for k in (if kind (list kind) eca-desk--kinds)
           for dir = (eca-desk--kind-dir k)
           when (file-directory-p dir)
           append (cl-loop for name in (directory-files dir nil "\\`[^.]")
                           when (file-directory-p (expand-file-name name dir))
                           collect (cons k name))))

(defun eca-desk--read-workspace (prompt &optional kind)
  "Ask for a workspace with PROMPT, return (KIND . NAME).
Restrict to KIND when given."
  (let* ((items (eca-desk--list-workspaces kind))
         (labels (mapcar (lambda (it) (format "%s/%s" (car it) (cdr it))) items)))
    (unless items (user-error "No workspaces found under %s"
                              eca-desk-base-directory))
    (let ((choice (completing-read prompt labels nil t)))
      (nth (cl-position choice labels :test #'string=) items))))

(defun eca-desk--validate-name (name)
  "Signal an error unless NAME is a safe directory name."
  (when (or (string-empty-p name)
            (string-match-p "[/\\\\]" name)
            (member name '("." "..")))
    (user-error "Invalid name %S" name))
  name)

;;;; Repository specs

(defun eca-desk--repo-url (spec)
  "Expand SPEC into a clonable git URL.
Full URLs (ssh, https, git, file, scp-like) pass through.  An
`owner/repo' shorthand becomes `git@HOST:owner/repo.git' where HOST is
chosen from `eca-desk-git-ssh-hosts' or defaults to github.com."
  (cond
   ((string-match-p "\\`\\(?:[a-z+]+://\\|[^/@:]+@[^/:]+:\\|/\\|~\\)" spec) spec)
   ((string-match-p "\\`[[:alnum:]_.-]+/[[:alnum:]_.-]+\\'" spec)
    (let ((host (if eca-desk-git-ssh-hosts
                    (cdr (assoc (completing-read
                                 (format "SSH host for %s: " spec)
                                 eca-desk-git-ssh-hosts nil t)
                                eca-desk-git-ssh-hosts))
                  "github.com"))
          (path (if (string-suffix-p ".git" spec) spec (concat spec ".git"))))
      (format "git@%s:%s" host path)))
   (t (user-error "Cannot understand repository spec %S" spec))))

(defun eca-desk--repo-name (url)
  "Return the directory name a clone of URL would get."
  (let ((base (file-name-nondirectory (directory-file-name
                                       (replace-regexp-in-string ":" "/" url)))))
    (if (string-suffix-p ".git" base) (substring base 0 -4) base)))

(defvar eca-desk--repo-history nil
  "Minibuffer history of repository specs.")

(defun eca-desk--known-repo-urls ()
  "Return origin URLs of repositories already cloned in any workspace."
  (cl-loop for (kind . name) in (eca-desk--list-workspaces)
           for dir = (expand-file-name (if (string= kind "session") "repo" "repos")
                                       (eca-desk--workspace-dir kind name))
           when (file-directory-p dir)
           append (cl-loop for repo in (directory-files dir t "\\`[^.]")
                           for url = (and (file-directory-p (expand-file-name ".git" repo))
                                          (with-temp-buffer
                                            (when (zerop (call-process "git" nil t nil "-C" repo
                                                                       "remote" "get-url" "origin"))
                                              (string-trim (buffer-string)))))
                           when (and url (not (string-empty-p url))) collect url)))

(defun eca-desk--read-repos (prompt)
  "Ask for repository specs with PROMPT, comma separated.
Completion offers repositories already cloned in other workspaces and
the input history.  Return a list of expanded URLs."
  (let* ((candidates (delete-dups (append eca-desk--repo-history
                                          (eca-desk--known-repo-urls))))
         (specs (completing-read-multiple
                 (format "%s (comma separated, empty for none): " prompt)
                 candidates nil nil nil 'eca-desk--repo-history)))
    (mapcar #'eca-desk--repo-url
            (cl-remove-if #'string-empty-p (mapcar #'string-trim specs)))))

(defun eca-desk--read-repo (prompt)
  "Ask for a single optional repository spec with PROMPT.
Return the expanded URL or nil."
  (let ((spec (string-trim
               (completing-read (format "%s (optional): " prompt)
                                (delete-dups (append eca-desk--repo-history
                                                     (eca-desk--known-repo-urls)))
                                nil nil nil 'eca-desk--repo-history))))
    (unless (string-empty-p spec) (eca-desk--repo-url spec))))

(defun eca-desk--read-local-folders ()
  "Repeatedly ask for local folders until RET on an empty prompt.
Return a list of absolute directory paths."
  (let (dirs dir (n 1))
    (while (not (string-empty-p
                 (setq dir (string-trim
                            (read-directory-name
                             (format "Local folder #%d (RET on empty to finish): " n)
                             nil "" nil)))))
      (setq dir (expand-file-name dir))
      (if (file-directory-p dir)
          (progn (push (directory-file-name dir) dirs) (cl-incf n))
        (message "Not a directory, skipped: %s" dir)))
    (nreverse dirs)))

;;;; Cloning (async, sequential)

(defvar eca-desk--log-buffer "*eca-desk*"
  "Buffer collecting git output and scaffolding progress.")

(defun eca-desk--log (format-string &rest args)
  "Append FORMAT-STRING with ARGS to the eca-desk log buffer."
  (with-current-buffer (get-buffer-create eca-desk--log-buffer)
    (goto-char (point-max))
    (insert (apply #'format format-string args) "\n")))

(defun eca-desk--clone-queue (urls dest-dir on-done)
  "Clone URLS sequentially into DEST-DIR, then call ON-DONE.
ON-DONE receives the list of URLs that failed.  Existing clones are
skipped so re-running a scaffold is idempotent."
  (let (failed)
    (cl-labels
        ((next (rest)
           (if (null rest)
               (funcall on-done (nreverse failed))
             (let* ((url (car rest))
                    (target (expand-file-name (eca-desk--repo-name url) dest-dir)))
               (if (file-directory-p (expand-file-name ".git" target))
                   (progn (eca-desk--log "skip %s (already cloned)" url)
                          (next (cdr rest)))
                 (eca-desk--log "clone %s → %s" url target)
                 (make-process
                  :name "eca-desk-clone"
                  :buffer (get-buffer-create eca-desk--log-buffer)
                  :command (append (list "git" "clone") eca-desk-clone-arguments
                                   (list url target))
                  :noquery t
                  :sentinel
                  (lambda (proc _event)
                    (when (memq (process-status proc) '(exit signal))
                      (if (zerop (process-exit-status proc))
                          (eca-desk--log "done %s" url)
                        (eca-desk--log "FAILED %s (exit %d)" url
                                       (process-exit-status proc))
                        (push url failed))
                      (next (cdr rest))))))))))
      (next urls))))

;;;; Scaffolding

(defun eca-desk--markdown-list (items &optional formatter)
  "Render ITEMS as a Markdown list, applying FORMATTER to each.
Return \"(none)\" when ITEMS is empty."
  (if items
      (mapconcat (lambda (it) (concat "- " (if formatter (funcall formatter it) it)))
                 items "\n")
    "(none)"))

(defun eca-desk--write-file (path content)
  "Write CONTENT to PATH unless the file already exists."
  (if (file-exists-p path)
      (eca-desk--log "keep %s (exists)" path)
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content))
    (eca-desk--log "write %s" path)))

(defun eca-desk--scaffold (kind name urls local-folders)
  "Create the directory layout for workspace NAME of KIND.
URLS are repositories to clone; LOCAL-FOLDERS are registered paths.
Return the workspace root."
  (eca-desk--ensure-base-directory)
  (let* ((root (eca-desk--workspace-dir kind name))
         (repos-dir (expand-file-name (if (string= kind "project") "repos" "repo") root))
         (vars `(("name" . ,name)
                 ("type" . ,kind)
                 ("root" . ,root)
                 ("date" . ,(format-time-string "%Y-%m-%d"))
                 ("repos" . ,(eca-desk--markdown-list
                              urls (lambda (u) (format "`%s/%s` ← %s"
                                                       (file-name-nondirectory repos-dir)
                                                       (eca-desk--repo-name u) u))))
                 ("local-folders" . ,(eca-desk--markdown-list
                                      local-folders (lambda (d) (format "`%s`" d)))))))
    (dolist (sub (list repos-dir
                       (expand-file-name "worktrees" root)
                       (expand-file-name "library/agent" root)
                       (expand-file-name "library/chats" root)
                       (expand-file-name ".eca/rules" root)))
      (make-directory sub t))
    (when (string= kind "project")
      (make-directory (expand-file-name "library/user" root) t))
    (eca-desk--write-file (expand-file-name "AGENTS.md" root)
                          (eca-desk-templates-render (concat kind "-AGENTS.md") vars))
    (dolist (rule '("worktrees" "library" "export" "workspace"))
      (eca-desk--write-file (expand-file-name (format ".eca/rules/%s.md" rule) root)
                            (eca-desk-templates-render (format "rules-%s.md" rule) vars)))
    (eca-desk--write-file (expand-file-name ".eca-desk" root)
                          (prin1-to-string `((kind . ,kind)
                                             (local-folders . ,local-folders))))
    root))

(defun eca-desk--read-metadata (root)
  "Return the metadata alist stored in ROOT, or nil."
  (let ((file (expand-file-name ".eca-desk" root)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (read (current-buffer)))))))

(defun eca-desk--repos-dir (root)
  "Return the directory holding clones under ROOT."
  (let ((kind (alist-get 'kind (eca-desk--read-metadata root))))
    (expand-file-name (if (equal kind "session") "repo" "repos") root)))

(defun eca-desk--write-metadata (root meta)
  "Overwrite the metadata file of ROOT with alist META."
  (with-temp-file (expand-file-name ".eca-desk" root)
    (insert (prin1-to-string meta))))

(defun eca-desk--current-root ()
  "Return the eca-desk workspace root of the live ECA session, else ask."
  (or (when-let* ((session (ignore-errors (eca-session))))
        (cl-find-if #'eca-desk--read-metadata
                    (eca--session-workspace-folders session)))
      (pcase-let ((`(,kind . ,name) (eca-desk--read-workspace "Workspace: ")))
        (eca-desk--workspace-dir kind name))))

(defun eca-desk--agents-append (root heading line)
  "Append bullet LINE under the `## HEADING' section of ROOT's AGENTS.md.
Replace a `(none)' placeholder when present.  Return nil when LINE is
already there."
  (let ((file (expand-file-name "AGENTS.md" root)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (if (search-forward line nil t)
            nil
          (goto-char (point-min))
          (unless (re-search-forward (format "^## %s\\s-*$" (regexp-quote heading)) nil t)
            (goto-char (point-max))
            (insert (format "\n## %s\n\n" heading)))
          (let ((end (save-excursion
                       (or (re-search-forward "^## " nil t) (point-max)))))
            (cond
             ((re-search-forward "^(none)\\s-*$" end t)
              (replace-match line t t))
             (t
              (goto-char end)
              (unless (eq end (point-max)) (beginning-of-line))
              (skip-chars-backward "\n")
              (insert "\n" line)))
            ;; Keep one blank line before the next heading.
            (when (looking-at "\n## ") (insert "\n"))
            (save-buffer)
            t))))))

;;;; ECA integration

(defun eca-desk--start (root &optional prompt)
  "Start or reuse the ECA session rooted at ROOT and open a chat.
Registered local folders become extra workspace roots.  When PROMPT is
non-nil it is sent once the session is ready."
  (let* ((meta (eca-desk--read-metadata root))
         (roots (cons root (alist-get 'local-folders meta)))
         (session (or (eca-session-for-root root)
                      (eca-create-session roots))))
    (eca-start-session
     session
     (lambda (s)
       (when prompt
         (eca-chat-open s)
         (with-current-buffer (eca-chat--get-last-buffer s)
           (eca-chat--send-prompt s prompt)))))))

(defun eca-desk--create (kind)
  "Interactive flow creating a workspace of KIND.
With a prefix argument only scaffold; otherwise also start ECA."
  (let* ((scaffold-only current-prefix-arg)
         (name (eca-desk--validate-name
                (string-trim (read-string (format "New %s name: " kind)))))
         (root (eca-desk--workspace-dir kind name))
         (existing (file-directory-p root)))
    (when (and existing
               (not (y-or-n-p (format "%s %s exists; resume/fix scaffold? " kind name))))
      (user-error "Aborted"))
    (let* ((urls (if (string= kind "project")
                     (eca-desk--read-repos "Repositories")
                   (let ((u (eca-desk--read-repo "Repository")))
                     (and u (list u)))))
           (local-folders (eca-desk--read-local-folders))
           (root (eca-desk--scaffold kind name urls local-folders)))
      (message "Scaffolded %s at %s%s" kind root
               (if urls " — cloning…" ""))
      (eca-desk--clone-queue
       urls (eca-desk--repos-dir root)
       (lambda (failed)
         (when failed
           (display-buffer eca-desk--log-buffer)
           (message "%d clone(s) failed, see %s"
                    (length failed) eca-desk--log-buffer))
         (unless scaffold-only
           (eca-desk--start root eca-desk-initial-prompt))))
      root)))

;;;; Commands

;;;###autoload
(defun eca-desk-chat ()
  "Open the scratch ECA session and start a new chat tab in it.
The session is anchored at `chats/' under `eca-desk-base-directory'."
  (interactive)
  (eca-desk--ensure-base-directory)
  (let* ((root (eca-desk--dir "chats"))
         (session (eca-session-for-root root)))
    (if (and session (eq (eca--session-status session) 'started))
        (eca-chat--new-chat session)
      (eca-start-session (or session (eca-create-session (list root)))))))

;;;###autoload
(defun eca-desk-new-project ()
  "Create a new project: name → repositories → local folders.
Repositories are cloned asynchronously into `repos/'; local folders
are registered, not copied.  With a prefix argument only scaffold,
otherwise start the ECA session when cloning finishes."
  (interactive)
  (eca-desk--create "project"))

;;;###autoload
(defun eca-desk-new-session ()
  "Create a new session: name → optional repository → local folders.
Sessions are disposable; delete the folder when done.  With a prefix
argument only scaffold, otherwise start the ECA session."
  (interactive)
  (eca-desk--create "session"))

;;;###autoload
(defun eca-desk-open ()
  "Open an existing project or session, starting ECA if needed.
Use `eca-chat-resume' inside the chat to restore a past conversation."
  (interactive)
  (pcase-let ((`(,kind . ,name) (eca-desk--read-workspace "Open: ")))
    (eca-desk--start (eca-desk--workspace-dir kind name))))

(defun eca-desk--chat-summaries ()
  "Return an alist of (LABEL . PATH) for all library/chats/*.md files."
  (cl-loop for (kind . name) in (eca-desk--list-workspaces)
           for dir = (expand-file-name "library/chats" (eca-desk--workspace-dir kind name))
           when (file-directory-p dir)
           append (cl-loop for f in (directory-files dir t "\\.md\\'")
                           collect (cons (format "%s/%s: %s" kind name
                                                 (file-name-base f))
                                         f))))

;;;###autoload
(defun eca-desk-reference-chat ()
  "Insert a reference to a chat summary of any project or session.
Completion covers every `library/chats/*.md'.  Inserts an instruction
asking the agent to read the file at point (normally the chat prompt)."
  (interactive)
  (let ((items (eca-desk--chat-summaries)))
    (unless items (user-error "No chat summaries found"))
    (let* ((choice (completing-read "Reference chat summary: " items nil t))
           (path (cdr (assoc choice items))))
      (insert (format "Read %s for context from a previous conversation. " path)))))

;;;###autoload
(defun eca-desk-export-chat ()
  "Save the current chat transcript into the workspace's library/chats/.
Wraps `eca-chat-save-to-file'.  The curated summary written by the
agent (see rules/export.md) remains the primary memory; this exports
the full transcript on demand."
  (interactive)
  (let* ((session (eca-session))
         (_ (eca-assert-session-running session))
         (root (cl-find-if (lambda (f) (eca-desk--read-metadata f))
                           (eca--session-workspace-folders session))))
    (unless root
      (user-error "Current session is not an eca-desk project/session"))
    (let* ((dir (expand-file-name "library/chats" root))
           (name (read-string "Transcript name: "))
           (file (expand-file-name (format "%s-transcript.md" name) dir)))
      (make-directory dir t)
      (eca-chat-save-to-file file)
      (message "Transcript saved to %s" file))))

;;;###autoload
(defun eca-desk-add-repo (urls)
  "Clone one or more repositories URLS into the current project or session.
Interactively, specs are read comma separated (git URLs or
`owner/repo').  The workspace is taken from the live ECA session,
otherwise asked.  AGENTS.md lists each successful clone; no restart is
needed since clones land inside the workspace."
  (interactive (list (eca-desk--read-repos "Repositories")))
  (unless urls (user-error "No repository given"))
  (let* ((root (eca-desk--current-root))
         (repos-dir (eca-desk--repos-dir root)))
    (eca-desk--clone-queue
     urls repos-dir
     (lambda (failed)
       (dolist (url (cl-set-difference urls failed :test #'string=))
         (eca-desk--agents-append
          root "Repositories"
          (format "- `%s/%s` ← %s" (file-name-nondirectory repos-dir)
                  (eca-desk--repo-name url) url)))
       (if failed
           (progn (display-buffer eca-desk--log-buffer)
                  (message "%d clone(s) failed, see %s" (length failed)
                           eca-desk--log-buffer))
         (message "Added %d repositor%s to %s" (length urls)
                  (if (cdr urls) "ies" "y") root))))))

;;;###autoload
(defun eca-desk-add-local-folder (dir)
  "Register local folder DIR with the current project or session.
Updates `.eca-desk' and AGENTS.md and, when the ECA session is live,
adds DIR as a workspace folder immediately."
  (interactive (list (read-directory-name "Local folder: ")))
  (let* ((dir (directory-file-name (expand-file-name dir)))
         (root (eca-desk--current-root))
         (meta (eca-desk--read-metadata root))
         (folders (alist-get 'local-folders meta)))
    (unless (file-directory-p dir) (user-error "Not a directory: %s" dir))
    (if (member dir folders)
        (message "%s is already registered" dir)
      (setf (alist-get 'local-folders meta) (append folders (list dir)))
      (eca-desk--write-metadata root meta)
      (eca-desk--agents-append root "Local folders" (format "- `%s`" dir))
      (when-let* ((session (eca-session-for-root root)))
        (when (eq (eca--session-status session) 'started)
          (eca--session-add-workspace-folder session dir)))
      (message "Registered %s in %s" dir root))))

(provide 'eca-desk)
;;; eca-desk.el ends here

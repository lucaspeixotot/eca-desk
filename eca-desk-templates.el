;;; eca-desk-templates.el --- Embedded templates for eca-desk  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucas Peixoto

;; Author: Lucas Peixoto <lucaspeixotoac@gmail.com>
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "28.1"))

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

;; Default agent-facing templates shipped with eca-desk: the AGENTS.md
;; written at the root of every project and session, and the rules
;; dropped into `.eca/rules/'.
;;
;; Templates are plain strings with `${name}' placeholders expanded by
;; `eca-desk-templates-render'.  Each template can be overridden by
;; placing a file with the same name under
;; `eca-desk-template-directory'; see `eca-desk-templates-get'.
;;
;; Available placeholders:
;;
;;   ${name}           project or session name
;;   ${type}           "project" or "session"
;;   ${root}           absolute path of the project/session directory
;;   ${repos}          Markdown list of cloned repositories (or "(none)")
;;   ${local-folders}  Markdown list of registered local folders (or "(none)")
;;   ${date}           creation date, ISO 8601

;;; Code:

(defgroup eca-desk-templates nil
  "Templates used by eca-desk when scaffolding projects and sessions."
  :group 'eca-desk
  :prefix "eca-desk-template")

(defcustom eca-desk-template-directory nil
  "Directory holding user overrides for eca-desk templates.
When non-nil, a file named like the template (for example
\"project-AGENTS.md\" or \"rules-export.md\") found in this directory
replaces the embedded default.  When nil, or when a file is missing,
the embedded template is used."
  :type '(choice (const :tag "Embedded templates only" nil)
                 directory)
  :group 'eca-desk-templates)

;;;; Embedded templates

(defconst eca-desk-templates--project-agents
  "# ${name}

> eca-desk project created on ${date}.
> Root: `${root}`

## Goal

<!-- Describe the goal of this project.  The agent reads this first. -->

## Repositories

Cloned under `repos/` with a minimal history (blobless/shallow).  Fetch
more history on demand (`git fetch --unshallow`, `git fetch --deepen`).

${repos}

## Local folders

Registered as extra workspace folders; not copied.

${local-folders}

## Conventions

- Work on isolated tasks inside `worktrees/` — see `.eca/rules/worktrees.md`.
- Put generated artifacts under `library/agent/`; the user drops material
  under `library/user/` — see `.eca/rules/library.md`.
- When a significant task ends, write a curated summary to
  `library/chats/` — see `.eca/rules/export.md`.
"
  "Default AGENTS.md for a project.")

(defconst eca-desk-templates--session-agents
  "# ${name}

> eca-desk session created on ${date}.
> Root: `${root}`

## Task

<!-- Describe the task of this session.  Sessions are disposable. -->

## Repository

${repos}

## Local folders

${local-folders}

## Conventions

- Isolated work goes into `worktrees/` — see `.eca/rules/worktrees.md`.
- Generated artifacts go to `library/agent/`.
- On finishing, write a curated summary to `library/chats/` — see
  `.eca/rules/export.md`.
"
  "Default AGENTS.md for a session.")

(defconst eca-desk-templates--rules-worktrees
  "# Worktree protocol

Repositories live under `repos/` (projects) or `repo/` (sessions) and are
cloned with minimal history.  Never work directly on the clone's checked-out
branch when the task may be reviewed, reverted or run in parallel.

1. For each isolated task create a worktree:
   `git -C <repo> worktree add ../../worktrees/<repo>-<task> -b <task>`
   (projects) — adapt the relative path for sessions.
2. Branch names: `<task>` in kebab-case, prefixed with a ticket id when one
   exists (e.g. `GLCP-1234-fix-login`).
3. When history is missing, fetch what you need instead of re-cloning:
   `git fetch --deepen=100` or `git fetch --unshallow`.
4. Clean up finished worktrees: `git worktree remove <path>` then
   `git worktree prune`.  Tell the user before deleting anything with
   uncommitted changes.
"
  "Default `.eca/rules/worktrees.md'.")

(defconst eca-desk-templates--rules-library
  "# Library conventions

- `library/user/`  — material the user provides (specs, notes, exports).
  Read-only for the agent unless asked otherwise.
- `library/agent/` — artifacts you produce that are not source code:
  designs, reports, diagrams, scripts.  Use descriptive kebab-case names.
- `library/chats/` — curated conversation summaries (see `export.md`).

External local folders registered in AGENTS.md are workspace folders; do
not copy them into the library.
"
  "Default `.eca/rules/library.md'.")

(defconst eca-desk-templates--rules-export
  "# Conversation export rule

When a significant unit of work is complete (a decision reached, a feature
implemented, an investigation concluded), write a **curated summary** to
`library/chats/<task>.md` before moving on.  Do not paste the transcript.

Template:

```markdown
# <task title>

- Date: <ISO date>
- Status: done | partial | blocked

## Outcome
<what was achieved, 2-5 bullets>

## Decisions
<decisions taken and why>

## Pointers
<files, commits, worktrees, external links>

## Follow-ups
<what remains>
```

These summaries are the project's memory and are what other projects read
when they reference this conversation.  The full transcript is only exported
on explicit request (`eca-desk-export-chat`).
"
  "Default `.eca/rules/export.md'.")

(defconst eca-desk-templates--alist
  `(("project-AGENTS.md" . ,eca-desk-templates--project-agents)
    ("session-AGENTS.md" . ,eca-desk-templates--session-agents)
    ("rules-worktrees.md" . ,eca-desk-templates--rules-worktrees)
    ("rules-library.md" . ,eca-desk-templates--rules-library)
    ("rules-export.md" . ,eca-desk-templates--rules-export))
  "Alist of template NAME to embedded content.")

;;;; API

(defun eca-desk-templates-get (name)
  "Return the content of template NAME.
Look for an override in `eca-desk-template-directory' first, then fall
back to the embedded default.  Signal an error for unknown NAME."
  (let ((override (and eca-desk-template-directory
                       (expand-file-name name eca-desk-template-directory))))
    (cond
     ((and override (file-readable-p override))
      (with-temp-buffer
        (insert-file-contents override)
        (buffer-string)))
     ((assoc name eca-desk-templates--alist)
      (cdr (assoc name eca-desk-templates--alist)))
     (t (error "Unknown template %s" name)))))

(defun eca-desk-templates-render (name vars)
  "Render template NAME substituting VARS.
VARS is an alist of (PLACEHOLDER . VALUE) where PLACEHOLDER is a string
without the `${}' wrapper.  Unknown placeholders are left untouched."
  (let ((text (eca-desk-templates-get name)))
    (replace-regexp-in-string
     "\\${\\([a-z-]+\\)}"
     (lambda (match)
       (let* ((key (match-string 1 match))
              (cell (assoc key vars)))
         (if cell (cdr cell) match)))
     text t t)))

(provide 'eca-desk-templates)
;;; eca-desk-templates.el ends here

# eca-desk

Chats, sessions and projects for [ECA](https://eca.dev) in Emacs — a
GitHub Copilot Desktop App-style workflow layered on
[eca-emacs](https://github.com/editor-code-assistant/eca-emacs) without
touching the ECA core.

**Status:** v0.1.0, early. Tested with eca-emacs 0.11.0 (commit `9076540`).

## Concepts

| eca-desk | What it is | On disk |
|---|---|---|
| **Chat** | A disposable conversation. All chats share one scratch ECA session. | `<base>/chats/` (empty anchor) |
| **Session** | A disposable work folder, optionally with one minimal repo clone, its own ECA session. | `<base>/sessions/<name>/` |
| **Project** | A persistent multi-repository workspace with a library of artifacts and conversation summaries. | `<base>/projects/<name>/` |

`<base>` defaults to `$XDG_DATA_HOME/eca-desk` (`~/.local/share/eca-desk`).

```
projects/<name>/
├── AGENTS.md            goal, repos, local folders, conventions
├── .eca/rules/          worktrees.md · library.md · export.md · workspace.md
├── .eca-desk            metadata (kind, local folders)
├── library/
│   ├── user/            material you provide
│   ├── agent/           artifacts the agent produces
│   └── chats/           curated conversation summaries — the memory
├── repos/<repo>/        blobless clones
└── worktrees/           <repo>-<task>/ created by the agent
```

Sessions have the same layout minus `library/user/`, with a single `repo/`.

Local folders you register are **not copied**: they are listed in
`AGENTS.md` and added as extra ECA workspace folders when the session
starts.

### GCDA mapping

| GitHub Copilot Desktop App | eca-desk |
|---|---|
| Chat | tab in the scratch session (`eca-desk-chat`) |
| Session (repo + worktree) | `sessions/<name>/`, worktree protocol rule |
| Project (multi-repo) | `projects/<name>/` |
| Library | `library/{user,agent,chats}/` |
| Memory / chat referencing | `library/chats/*.md` + `eca-desk-reference-chat` |
| Overview, Automations, Agent Merge | out of scope (v2 / upstream ECA) |

## Installation

Requires Emacs 28.1+, eca-emacs, and `git` on `PATH`.

```elisp
;; straight.el
(use-package eca-desk
  :straight (:host github :repo "lucaspeixotot/eca-desk")
  :after eca)
```

Or add the directory to `load-path` and `(require 'eca-desk)`.

eca-desk defines **no keybindings**. Bind what you use:

```elisp
(use-package eca-desk
  :after eca
  :bind (("C-c e c" . eca-desk-chat)
         ("C-c e o" . eca-desk-open)
         ("C-c e p" . eca-desk-new-project)
         ("C-c e s" . eca-desk-new-session))
  :custom
  (eca-desk-git-ssh-hosts '(("personal" . "personal-github.com")
                            ("work" . "work-github.com"))))
```

## Commands

| Command | Does |
|---|---|
| `eca-desk-chat` | Open (or reuse) the scratch ECA session and start a new chat tab. |
| `eca-desk-new-project` | name → repositories (repeat, empty to finish) → local folders (repeat). Scaffolds, clones asynchronously, starts ECA and sends `eca-desk-initial-prompt`. `C-u` = scaffold only. |
| `eca-desk-new-session` | Same flow with a single optional repository. |
| `eca-desk-open` | Pick an existing project/session; start or switch to its ECA session. Use `eca-chat-resume` inside to restore past conversations. |
| `eca-desk-reference-chat` | Complete over every `library/chats/*.md` of all projects and sessions and insert a "read this file" instruction into the prompt. |
| `eca-desk-export-chat` | Save the current chat transcript to the workspace's `library/chats/<name>-transcript.md` (wraps `eca-chat-save-to-file`). |
| `eca-desk-add-repo` | Clone one more repository into the current project/session (taken from the live ECA session, else asked) and list it in `AGENTS.md`. No restart needed. |
| `eca-desk-add-local-folder` | Register one more local folder: updates `.eca-desk` and `AGENTS.md`, and adds it to the live ECA session immediately. |

The agent gets the same knowledge through `.eca/rules/workspace.md`, so
asking "add repo owner/x to this project" in the chat works too; for
local folders the agent will ask you to run `eca-desk-add-local-folder`,
since only Emacs can change the session's workspace folders. Rules and
`AGENTS.md` are loaded by the ECA server per workspace on every prompt,
so they apply whatever agent or model is active, and to subagents.

Repository input accepts a full URL (`git@host:o/r.git`,
`https://…`, `file://…`) or the `owner/repo` shorthand, which expands to
`git@github.com:owner/repo.git` — or, when `eca-desk-git-ssh-hosts` is
set, asks which ssh host to use.

Re-running `eca-desk-new-project` on an existing name offers to resume:
existing files are kept and already-cloned repositories are skipped.
Progress and git output go to the `*eca-desk*` buffer.

## Workflows

1. **Morning scratch chat** — `M-x eca-desk-chat`; rename a tab with
   `eca-chat-rename` when it deserves a name.
2. **New project** — `M-x eca-desk-new-project`, answer the prompts, wait
   for the clones, the agent greets you with a summary of `AGENTS.md`.
3. **Resume yesterday** — `M-x eca-desk-open`, pick the project, then
   `eca-chat-resume` for the conversation history.
4. **Small task** — `M-x eca-desk-new-session`; delete the folder when done.
5. **Cross-project memory** — in any chat, `M-x eca-desk-reference-chat`,
   pick a summary written by another project's agent.

## Customization

| Variable | Default | Purpose |
|---|---|---|
| `eca-desk-base-directory` | `$XDG_DATA_HOME/eca-desk` | Root of chats/sessions/projects. |
| `eca-desk-clone-arguments` | `("--filter=blob:none")` | Extra `git clone` arguments. |
| `eca-desk-git-ssh-hosts` | `nil` | `(label . ssh-host)` alist for `owner/repo` expansion. |
| `eca-desk-initial-prompt` | read AGENTS.md and summarize | Sent when a workspace is created; `nil` to disable. |
| `eca-desk-template-directory` | `nil` | Directory with template overrides. |

### Templates

Templates are embedded (`eca-desk-templates.el`) and can be overridden
by placing a file with the same name in `eca-desk-template-directory`:
`project-AGENTS.md`, `session-AGENTS.md`, `rules-worktrees.md`,
`rules-library.md`, `rules-export.md`, `rules-workspace.md`. Placeholders: `${name}`,
`${type}`, `${root}`, `${repos}`, `${local-folders}`, `${date}`.

## Notes on eca-emacs coupling

eca-desk calls two private eca-emacs functions, `eca-chat--new-chat` and
`eca-chat--send-prompt`, because no public equivalent exists yet. If an
eca-emacs update breaks them, check the tested commit above.

## License

GPL-3.0-or-later.

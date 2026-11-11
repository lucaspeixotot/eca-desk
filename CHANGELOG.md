# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-11

### Added

- Base directory layout `chats/`, `sessions/`, `projects/` under
  `$XDG_DATA_HOME/eca-desk`.
- Commands `eca-desk-chat`, `eca-desk-new-project`, `eca-desk-new-session`,
  `eca-desk-open`, `eca-desk-reference-chat`, `eca-desk-export-chat`.
- Embedded templates (AGENTS.md for projects and sessions; rules for
  worktrees, library and conversation export) with a user override
  directory.
- Repository shorthand `owner/repo` with optional ssh-host selection and
  asynchronous, idempotent, minimal (blobless) clones.
- Local folders registered as extra ECA workspace folders.

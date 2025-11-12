# WHEN TO USE THIS TOOL

- Use PresentEdits to open the inline diff review UI for any pending, deferred edits created by the Edit tool.
- Call this after you have iterated with Edit and reviewed the returned diagnostics; when you are ready for user review or approval.
- Use it to present all pending edits at once, or a specific subset of files when only some changes are ready.
- Prefer PresentEdits over asking the user to inspect raw diffs in chat; it provides an in‑editor review workflow.

# HOW TO USE

- Provide the required `paths` parameter as an array of file paths.
  - Use `[]` (an empty array) to present all pending deferred edits.
  - Provide one or more specific paths (relative to the current working directory; absolute paths are also accepted) to present only those files.
- This tool does not itself apply changes to disk; it opens the Neovim inline diff UI so the user can review and accept/reject changes.
- After calling PresentEdits, wait for the review outcome message before proceeding.

Examples (JSON arguments passed to the tool):
```json
{ "paths": [] }
```

Present only specific files:
```json
{ "paths": ["src/app.ts", "README.md"] }
```

# FEATURES

- Opens Neovim's inline diff view comparing the original baseline against the latest proposed content for each file.
- Supports multiple files; files are queued and opened for review one‑by‑one.
- Deduplicates by path: if a file has multiple proposed edits, only the latest proposal is presented.
- Safe by default: no immediate writes; acceptance happens via the review UI.

# LIMITATIONS

- If there are no pending deferred edits, this tool has nothing to present and will return a notice.
- Only files previously edited via the Edit tool and still pending in the deferred queue can be presented.
- Paths that do not correspond to pending edits are ignored.

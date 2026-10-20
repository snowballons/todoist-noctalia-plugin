# Todoist for Noctalia

Manage your Todoist tasks from the Noctalia panel, and capture new ones from the
launcher — without leaving the shell.

Read, capture, complete, edit, move and delete. One background service owns the
API and the cache; the panel only renders and asks it to act.

## Features

- **Panel** (`snowballons/todoist:manager`)
  - Filter tiles: **Overdue**, **Due today**, **Priority 1** (with live counts)
  - Navigation: **Today**, **Inbox**, **Projects** (pick a project to list it)
  - Task rows: priority flag, a **live checkbox** (complete/reopen), title, `project · due`,
    **Open in Todoist**, **copy link**, **edit**, **delete** (with confirmation by default)
  - **Edit form** per task: title, description, priority, due (or clear it), project,
    section and labels — only the changed fields are sent, and moving is a separate step
  - **Quick Add** box at the bottom — Todoist parses the text, so `buy milk tomorrow p1 #Errands` works
  - Refreshes on open, after every mutation, and via the header refresh button
- **Launcher** — type `td ` and either jump to a task or add one
- **Bar widget** — a checklist button that toggles the panel
- **Offline-friendly** — the last loaded tasks can be cached so the panel paints instantly

## Requirements

- Noctalia with `plugin_api = 24` or newer
- A Todoist account and an API token
- `chmod` and `xdg-open` (used to protect the token/cache files and to open task links)

## Install

```sh
cp -r todoist ~/.config/noctalia/plugins/snowballons-todoist
noctalia plugins lint          # optional: should print 0 errors, 0 warnings
```

Then enable **Todoist** in Noctalia's plugin settings.

## Configure the token

Provide the token in **one** of these places (first match wins):

1. `TODOIST_API_TOKEN` in the environment Noctalia runs in
2. **Token file** setting — e.g. `~/.config/todoist/token`
3. **Token** setting — plain text, stored in Noctalia's settings

You can find the token in Todoist under *Settings → Integrations → Developer → API token*.

The token file accepts either the bare token or an environment-style line, so a
file you already keep for the CLI works as-is:

```
TODOIST_API_TOKEN = 0123456789abcdef0123456789abcdef01234567
```

(or `export TODOIST_API_TOKEN=…`, quotes are fine, `#` comment lines are skipped).

Restrict it:

```sh
chmod 600 ~/.config/todoist/token
```

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `token` | *(empty)* | Plain-text token fallback |
| `token_file` | *(empty)* | Path to the token file (recommended) |
| `default_project` | *(empty)* | Shown as a capture hint — **not** appended to the text |
| `default_labels` | *(empty)* | Shown as a capture hint |
| `default_priority` | `none` | Shown as a capture hint |
| `cache_tasks` | `false` | Cache the last loaded tasks on disk to paint before the first request |
| `confirm_delete` | `true` | Ask before deleting a task |
| `max_retries` | `1` | Retries for a failed read or an idempotent write (create is never retried) |

Captures are never rewritten: Todoist's own parser handles `#project`, `@label`,
`p1`–`p4`, and dates, so the hints exist to remind you of the syntax rather than
to modify what you type.

## Usage

- **Panel** — click the widget, or bind the panel toggle in Noctalia.
- **Launcher** — `/td` or `td `, then:
  - type a task name and pick **Add "…"** to quick-add it
  - pick an existing task to open the panel on it
- **Open in Todoist** opens `https://app.todoist.com/app/task/<id>` via `xdg-open`;
  **copy link** is there for when it can't launch a browser.
- **Editing** — the pencil opens a form over the list. Save sends only the fields
  you changed; if the project or section changed, **Move** sends them together
  (the API rejects a project change on the update endpoint). Cancel discards.
- **Deleting** — the trash asks first when `confirm_delete` is on. A task that
  Todoist already deleted counts as deleted, not as an error.

## Privacy

- The token is used only in the `Authorization` header to `api.todoist.com`.
  It is never logged, never written to the cache file, and never published to
  other plugin entries.
- With `cache_tasks` enabled, task titles, notes and due dates are written in
  plain text to Noctalia's plugin data directory (mode `700`, file `600`).
- Nothing is ever sent anywhere except the Todoist API you configured.

## Development

```sh
# offline: stubs the Noctalia runtime and a fake Todoist backend
lua5.4 tools/mock_phase1.lua

# live: exercises the real API, creates a few tasks and deletes them again
./tools/smoke-todoist.sh

noctalia plugins lint
```

`tools/mock_phase1.lua` needs no token and no network: it drives the real
`service.luau` / `panel.luau` / `launcher.luau` against a stubbed `noctalia`
table and asserts the published state, the HTTP calls, and the rendered tree.

## Architecture

```
panel.luau / launcher.luau / widget.luau     entries (render + user intent)
        │  cmd.<entry> (seq, op, args)
        ▼
service.luau                                  the only entry that does HTTP
        │  state.set("todoist", snapshot)
        ▼
panel / launcher / widget                     state.watch → repaint
```

- Only `service.luau` performs HTTP; every request/response is correlated by a
  client sequence number so a stale reply can't clobber newer UI state.
- Reads and **idempotent writes** (update/move/close/reopen/delete) are retried
  with backoff. **Create is never retried** — a retried `POST` would duplicate
  the task; a failed create is published as `unknown_outcome`.
- When a write's response is lost, one `GET /tasks/{id}` settles it: the service
  reconciles to what the server actually holds instead of replaying the write.
- Filter views are cached briefly (`VIEW_TTL_MS`), the project list longer.
- `lib/` is split into `api` (HTTP + errors + pagination), `dates` (due
  parsing/formatting), `cache` (atomic snapshot), `state` (the command protocol).

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Read-only views + quick capture | ✅ done, verified against the live API |
| 2 | Complete / edit / move / delete tasks | ✅ done, verified against the live API |
| 3 | Richer capture and panel | partially (launcher search + due formatting) |
| 4 | Caching & sync | partially (read-through cache, refresh on open/mutation) |
| 5 | Release hardening | in progress (token/cache hardening, mock, smoke, lint) |

Known limits: completing a task removes it from the list and there is no
completed view yet, so **reopening from the panel is not reachable** — use
Todoist. Quick Add returns no task id, so the panel refetches its view instead
of inserting the task locally. There is no background sync, so data is as fresh
as the last open/refresh. Labels are editable but not shown on rows, and
sections are assignable but projects are not grouped by them. The UI is English
only.

## License

MIT

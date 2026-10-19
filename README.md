# Todoist for Noctalia

Read your Todoist tasks from the Noctalia panel, and capture new ones from the
launcher — without leaving the shell.

Phase 1 is **read + capture only**. Completing, editing, and deleting tasks are
deliberately not implemented yet (see [Status](#status)).

## Features

- **Panel** (`snowballons/todoist:manager`)
  - Filter tiles: **Overdue**, **Due today**, **Priority 1** (with live counts)
  - Navigation: **Today**, **Inbox**, **Projects** (pick a project to list it)
  - Task rows: priority flag, title, `project · due`, **Open in Todoist**, **copy link**
  - **Quick Add** box at the bottom — Todoist parses the text, so `buy milk tomorrow p1 #Errands` works
  - Backed by a poll: the panel refreshes on open and via the header refresh button
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
| `max_retries` | `1` | How many times a failed **read** is retried |

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

# live: exercises the real API, creates 2 tasks and deletes them again
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

- Only `service.luau` performs HTTP; every request/responses is correlated by a
  client sequence number so a stale reply can't clobber newer UI state.
- Reads are retried with backoff; **writes are never retried** — a failed
  `POST` is published as `unknown_outcome` so you can check Todoist rather than
  silently creating a duplicate.
- Filter views are cached briefly (`VIEW_TTL_MS`), the project list longer.
- `lib/` is split into `api` (HTTP + errors + pagination), `dates` (due
  parsing/formatting), `cache` (atomic snapshot), `state` (the command protocol).

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Read-only views + quick capture | ✅ done, verified against the live API |
| 2 | Complete / edit / delete tasks | not started |
| 3 | Richer capture and panel | not started |
| 4 | Caching & sync | partially (read-through cache only) |
| 5 | Release hardening | not started |

Known limits in Phase 1: the checkbox in a task row is decorative; Quick Add
returns no task id, so the panel refreshes its view instead of inserting the new
task locally; there is no background sync yet, so data is as fresh as the last
refresh.

## License

MIT

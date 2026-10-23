# Todoist

Manage your Todoist tasks from the Noctalia panel and capture new ones from the
launcher — without leaving the shell. Read, complete, edit, move, delete, and
quick-add tasks backed by a single service that owns the API and the cache.

## Plugin

| Field | Value |
| --- | --- |
| ID | `snowballons/todoist` |
| Entries | Service: `core`; panel: `manager`; launcher: `capture`; bar widget: `button` |
| Launcher prefix | `/td` |

## Requirements

- Noctalia with `plugin_api = 24` or newer
- A Todoist account and an API token (Settings → Integrations → Developer → API token)
- `chmod` — used to restrict permissions on the token file and cache
- `xdg-open` — used to open task links in the browser

## Usage

### Panel

Toggle the panel from the bar widget or with:

```
noctalia msg panel-toggle snowballons/todoist:manager
```

The panel opens on the last active view. The header row shows **Overdue**,
**Due today**, and **Priority 1** filter tiles with live counts. The nav row
switches between **Today**, **Inbox**, **Projects**, and **Completed**.

Each task row shows a priority flag, a circle checkbox (click to expand
Complete / Reopen), the title, `project · due`, and action buttons:
**Open in Todoist**, **copy link**, **edit** (pencil), **delete** (trash).

- **Completing** a task removes it from the current view and shows a 5-second
  **Undo** toast. Click Undo to reopen it immediately.
- **Edit form** — the pencil opens a form with title, description, priority, due
  date, project, section, and labels. **Save** sends only the changed fields.
  Use **Move** when the project or section changes (the API requires a separate
  endpoint for that). Cancel discards all edits.
- **Completed view** — the Completed nav tab lists tasks completed in the last
  7 days. Click the circle-check on any row to reopen it.
- **Quick Add** — type at the bottom of any list view. Todoist parses the text,
  so `buy milk tomorrow p1 #Errands` works as-is.
- The **refresh** button in the header forces a full re-fetch.

### Launcher

Type `/td` or `td ` in the Noctalia launcher, then:

- Pick an existing task from the list to jump to it in the panel.
- Type a new task name and pick **Add "…"** to quick-add it.

Todoist's own parser handles `#project`, `@label`, `p1`–`p4`, and dates in
the text — no rewriting is done.

### Bar widget

The checklist button (`button`) toggles the panel. Add it to your bar in
Noctalia's widget settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `token` | `string` | *(empty)* | Plain-text API token — stored in Noctalia's settings. Prefer `token_file` or the environment variable. |
| `token_file` | `file` | *(empty)* | Path to a file holding the token. Accepts the bare token or a line like `TODOIST_API_TOKEN = xxx`. |
| `default_project` | `string` | *(empty)* | Shown as a capture hint in the launcher. Not appended to the text. |
| `default_labels` | `string_list` | *(empty)* | Shown as a capture hint in the launcher. Not appended to the text. |
| `default_priority` | `select` | `none` | Shown as a capture hint in the launcher. Not appended to the text. |
| `cache_tasks` | `bool` | `false` | Cache the last loaded tasks to disk so the panel paints before the first request completes. |
| `confirm_delete` | `bool` | `true` | Ask for confirmation in the panel before deleting a task. |
| `max_retries` | `int` | `1` | How many times a failed read or idempotent write is retried (0–3). Create is never retried. |

## IPC

```
noctalia msg plugin snowballons/todoist:core all ping
noctalia msg plugin snowballons/todoist:core all refresh
```

`ping` checks the API token and publishes a status. `refresh` forces a full
re-fetch of all views, equivalent to clicking the refresh button in the panel.

## Notes

**Token handling** — the token is read from `TODOIST_API_TOKEN` in the
environment, then from `token_file`, then from the `token` setting (first match
wins). It is used only in the `Authorization` header to `api.todoist.com`. It
is never logged, never written to the cache file, and never published to other
plugin entries.

**Cache** — with `cache_tasks` enabled, task titles, notes and due dates are
written in plain text to Noctalia's plugin data directory (directory mode `700`,
file mode `600`). Nothing is ever sent anywhere except the Todoist API you
configured.

**Retry policy** — reads and idempotent mutations (update, move, complete,
reopen, delete) are retried up to `max_retries` times on network errors, server
errors, or 429 rate-limit responses (429 uses a 10-second backoff). Create
(Quick Add) is never retried — a retried POST would duplicate the task. When a
write's response is lost, one `GET /tasks/{id}` settles the outcome instead of
replaying the write.

**Known limits** — Quick Add returns no task id, so the panel refetches the
active view after adding instead of inserting locally. There is no background
sync; data is as fresh as the last open or manual refresh. Labels are editable
but not shown on task rows. Sections are assignable but project views are not
grouped by them. The UI is English only.

---

## Configure the token

Provide the token in **one** of these places (first match wins):

1. `TODOIST_API_TOKEN` in the environment Noctalia runs in
2. **Token file** setting — e.g. `~/.config/todoist/token`
3. **Token** setting — plain text, stored in Noctalia's settings

The token file accepts either the bare token or an environment-style line:

```
TODOIST_API_TOKEN = 0123456789abcdef0123456789abcdef01234567
```

(`export TODOIST_API_TOKEN=…`, quotes, and `#` comment lines are all handled.)

Restrict the file:

```sh
chmod 600 ~/.config/todoist/token
```

## Install

```sh
cp -r todoist ~/.config/noctalia/plugins/snowballons-todoist
noctalia plugins lint          # should print 0 errors, 0 warnings
```

Then enable **Todoist** in Noctalia's plugin settings.

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

## Roadmap

Features not yet implemented, in rough priority order:

Phase 3/4 — richer panel and sync:

- **Labels on task rows** — labels are stored and editable in the form but not
  displayed on the row itself.
- **Widget count** — the bar button is a plain glyph; it should show the
  overdue or due-today count as a badge.
- **Background sync / polling** — data is only as fresh as the last open or
  manual refresh; a background timer would keep counts current without opening
  the panel.
- **Section grouping in project view** — tasks inside a project are listed flat;
  they should be grouped under their section headers.
- **In-panel search** — no way to filter the visible task list by keyword.

Phase 5 — polish:

- **Non-English locales** — all strings are in `translations/en.json`; the
  plugin ships no other locale.

## License

MIT

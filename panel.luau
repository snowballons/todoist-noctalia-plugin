--!nonstrict
-- panel.luau (Phase 1)
-- Declarative panel: filter tiles, quick capture, read-only task list.
-- Read-only by design: the row checkbox is a glyph, not a control, and every
-- row carries Open / Copy link so Todoist stays the place you edit.
local state = require("./lib/state.luau")
local dates = require("./lib/dates.luau")

noctalia.setUpdateInterval(1000)

local PCOLOR = {
	[1] = "#e5484d", -- p1 / very urgent
	[2] = "#f5a524", -- p2
	[3] = "#3b82f6", -- p3
	[4] = "#8b8d98", -- p4 / natural
}
local MUTED = "#8b8d98"
local DANGER = "#e5484d"

local client = state.new("panel")

local snap = {}
local open = false
local mode = "list" -- "list" | "projects"
local highlightId = nil
local statusText = nil
local statusKind = nil -- nil | "ok" | "err" | "warn"
local quickText = ""
local quickKey = 0

-- Forward declaration: callbacks defined above render() below.
local render
local defaultsSummary

local function view()
	return snap.view or "today"
end

local function projectName(id)
	for _, p in ipairs(snap.projects or {}) do
		if p.id == id then
			return p.name
		end
	end
	return nil
end

local function setStatus(kind, text)
	statusKind = kind
	statusText = text
	if open then
		render()
	end
end

local function errText(err)
	local kind = (type(err) == "table" and err.kind) or "server"
	local key = "err." .. tostring(kind)
	local s = noctalia.tr(key)
	-- todoist.tr falls back to the key itself when unknown
	if s == key then
		return noctalia.tr("err.server")
	end
	return s
end

-- ── actions ─────────────────────────────────────────────────────
local function openUrl(url)
	if type(url) ~= "string" or url == "" then
		return
	end
	if noctalia.commandExists("xdg-open") then
		noctalia.runAsync({ "xdg-open", url })
	else
		noctalia.copyToClipboard(url, "text/plain")
		setStatus("ok", noctalia.tr("ui.panel.link_copied"))
	end
end

local function goView(key)
	mode = "list"
	highlightId = nil
	if client.send("tasks.fetch", { view = key }) then
		render()
	end
end

local function openProject(id)
	mode = "list"
	highlightId = nil
	if client.send("tasks.fetch", { view = "project", project_id = id }) then
		render()
	end
end

local function submitQuick()
	local text = noctalia.string.trim(quickText)
	if text == "" or client.busy() then
		return
	end
	if client.send("task.create", { text = text }) then
		quickText = ""
		quickKey = quickKey + 1
		render()
	end
end

-- ── pieces ──────────────────────────────────────────────────────
local function header()
	return ui.row({ align = "center", gap = 6 }, {
		ui.label({
			text = noctalia.tr("ui.panel.title"),
			fontSize = 16,
			fontWeight = "bold",
			color = "primary",
			flexGrow = 1,
		}),
		ui.button({
			glyph = "refresh",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.refresh"),
			enabled = not client.busy(),
			onClick = function()
				if client.send("tasks.refresh", {}) then
					render()
				end
			end,
		}),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "x",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

local function tiles()
	local counts = snap.counts or {}
	local function tile(key, labelKey)
		local c = tonumber(counts[key]) or 0
		return ui.button({
			text = noctalia.tr(labelKey) .. (c > 0 and ("  " .. tostring(c)) or ""),
			variant = (mode == "list" and view() == key) and "primary" or "ghost",
			controlSize = "sm",
			onClick = function()
				goView(key)
			end,
		})
	end
	return ui.row({ gap = 6 }, {
		tile("overdue", "ui.panel.filter.overdue"),
		tile("today", "ui.panel.filter.today"),
		tile("p1", "ui.panel.filter.p1"),
	})
end

local function nav()
	local activeProjectId = nil
	local v = view()
	if mode == "list" and type(v) == "string" and v:match("^project:") then
		activeProjectId = v:sub(9)
	end
	local function tab(key, labelKey, active)
		return ui.button({
			text = noctalia.tr(labelKey),
			variant = active and "secondary" or "ghost",
			controlSize = "sm",
			onClick = function()
				if key == "__projects" then
					mode = "projects"
					render()
				else
					goView(key)
				end
			end,
		})
	end
	local items = {
		tab("today", "ui.panel.nav.today", mode == "list" and v == "today"),
		tab("inbox", "ui.panel.nav.inbox", mode == "list" and v == "inbox"),
		tab("__projects", "ui.panel.nav.projects", mode == "projects" or activeProjectId ~= nil),
	}
	if activeProjectId then
		local name = projectName(activeProjectId)
		if name then
			items[#items + 1] = ui.label({
				text = "·  " .. name,
				fontSize = 12,
				color = MUTED,
				flexGrow = 1,
				maxLines = 1,
			})
		end
	end
	return ui.row({ gap = 6, align = "center" }, items)
end

-- Complete a task, or reopen it when it is already closed. Both are
-- idempotent server-side; an unknown outcome is resolved by refreshing rather
-- than by guessing.
local function toggleTask(t)
	if client.busy() then
		return
	end
	local id = tostring(t.id)
	local op = (t.checked == true) and "task.reopen" or "task.complete"
	highlightId = id
	if client.send(op, { id = id }) then
		render()
	end
end

local function taskRow(t)
	local rowItems = {}

	local p = tonumber(t.p) or 4
	rowItems[#rowItems + 1] = ui.glyph({ name = "flag", size = 14, color = PCOLOR[p] or MUTED })
	local closed = t.checked == true
	rowItems[#rowItems + 1] = ui.button({
		glyph = closed and "circle-check" or "circle",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr(closed and "ui.panel.reopen" or "ui.panel.complete"),
		enabled = not client.busy(),
		onClick = function()
			toggleTask(t)
		end,
	})

	local due = dates.formatDue(t.due)
	local metaParts = {}
	local pname = projectName(t.project_id)
	if pname then
		metaParts[#metaParts + 1] = pname
	end
	if due then
		metaParts[#metaParts + 1] = due.text
	end
	if tonumber(t.p) == 1 then
		metaParts[#metaParts + 1] = noctalia.tr("priority.p1")
	end
	local sectionItems = {
		ui.label({ text = t.content, maxLines = 2 }),
	}
	if #metaParts > 0 then
		sectionItems[#sectionItems + 1] = ui.label({
			text = table.concat(metaParts, "  ·  "),
			fontSize = 11,
			color = (due and due.overdue) and DANGER or MUTED,
			maxLines = 1,
		})
	end
	rowItems[#rowItems + 1] = ui.column({ gap = 1, flexGrow = 1 }, sectionItems)

	rowItems[#rowItems + 1] = ui.button({
		glyph = "external-link",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr("ui.panel.open_in_todoist"),
		onClick = function()
			openUrl(t.url)
		end,
	})
	rowItems[#rowItems + 1] = ui.button({
		glyph = "link",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr("ui.panel.copy_link"),
		onClick = function()
			noctalia.copyToClipboard(t.url or "", "text/plain")
			setStatus("ok", noctalia.tr("ui.panel.link_copied"))
		end,
	})

	return ui.row({
		gap = 6,
		align = "center",
		key = "t" .. tostring(t.id),
		paddingV = 4,
		fill = true,
	}, rowItems)
end

local function taskList()
	local tasks = snap.tasks or {}
	if #tasks == 0 then
		if snap.loading then
			return ui.label({ text = noctalia.tr("ui.panel.loading"), color = MUTED })
		end
		return ui.label({ text = noctalia.tr("ui.panel.tasks.empty"), color = MUTED })
	end
	local rows = {}
	for _, t in ipairs(tasks) do
		rows[#rows + 1] = taskRow(t)
	end
	return ui.scroll({
		flexGrow = 1,
		fill = true,
		revealKey = highlightId,
	}, rows)
end

local function projectList()
	local projects = snap.projects or {}
	if #projects == 0 then
		return ui.label({ text = noctalia.tr("ui.panel.projects.empty"), color = MUTED })
	end
	local rows = {}
	for _, p in ipairs(projects) do
		rows[#rows + 1] = ui.button({
			text = (p.inbox and ("[Inbox]  " .. p.name) or p.name),
			variant = "ghost",
			contentAlign = "start",
			key = "p" .. tostring(p.id),
			onClick = function()
				openProject(p.id)
			end,
		})
	end
	return ui.scroll({ flexGrow = 1, fill = true }, rows)
end

local function body()
	if snap.token_configured == false then
		return ui.label({ text = noctalia.tr("ui.panel.not_configured"), color = DANGER, maxLines = 3 })
	end
	if mode == "projects" then
		return projectList()
	end
	return taskList()
end

local function footer()
	local items = { ui.separator({}) }

	local banner = nil
	if snap.error then
		banner = ui.label({
			text = errText(snap.error),
			color = (snap.error.kind == "auth") and DANGER or MUTED,
			maxLines = 2,
		})
	elseif statusText then
		banner = ui.label({
			text = statusText,
			color = (statusKind == "err" and DANGER) or (statusKind == "warn" and "#f5a524") or MUTED,
			maxLines = 2,
		})
	end
	if banner then
		items[#items + 1] = banner
	end

	items[#items + 1] = ui.row({ gap = 6, align = "center" }, {
		ui.input({
			key = "quick" .. tostring(quickKey),
			value = "",
			placeholder = noctalia.tr("ui.panel.quick.placeholder"),
			flexGrow = 1,
			controlSize = "md",
			enabled = not client.busy(),
			onChange = function(text)
				quickText = text or ""
			end,
			onSubmit = function()
				submitQuick()
			end,
		}),
		ui.button({
			glyph = "plus",
			text = noctalia.tr("ui.panel.quick.add"),
			variant = "primary",
			controlSize = "md",
			enabled = (not client.busy()) and noctalia.string.trim(quickText) ~= "",
			onClick = function()
				submitQuick()
			end,
		}),
	})

	items[#items + 1] = ui.label({
		text = noctalia.tr("ui.panel.quick.hint"),
		fontSize = 11,
		color = MUTED,
		maxLines = 2,
	})

	local summary = defaultsSummary()
	if summary then
		items[#items + 1] = ui.label({
			text = noctalia.tr("ui.panel.quick.defaults", { summary = summary }),
			fontSize = 11,
			color = MUTED,
			maxLines = 1,
		})
	end

	return ui.column({ gap = 8 }, items)
end

defaultsSummary = function()
	local d = snap.defaults or {}
	local parts = {}
	if type(d.project) == "string" and noctalia.string.trim(d.project) ~= "" then
		parts[#parts + 1] = "#" .. noctalia.string.trim(d.project)
	end
	if type(d.labels) == "table" then
		for _, l in ipairs(d.labels) do
			if type(l) == "string" and noctalia.string.trim(l) ~= "" then
				parts[#parts + 1] = "@" .. noctalia.string.trim(l)
			end
		end
	end
	if type(d.priority) == "string" and d.priority ~= "" and d.priority ~= "none" then
		parts[#parts + 1] = d.priority
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

render = function()
	panel.render(ui.column({ gap = 10, padding = 12 }, {
		header(),
		tiles(),
		nav(),
		body(),
		footer(),
	}))
end

-- ── protocol ────────────────────────────────────────────────────
noctalia.state.watch("todoist", function(msg)
	if type(msg) ~= "table" then
		return
	end
	snap = msg
	if open then
		render()
	end
end)

noctalia.state.watch("svc_boot", function()
	-- The service restarted: any in-flight command died with its old VM.
	if client.busy() then
		client.abandon()
		setStatus("warn", noctalia.tr("err.timeout"))
	end
end)

noctalia.state.watch("evt.panel", function(msg)
	local op = client.take(msg)
	if op == nil then
		return
	end
	if op == "ping" then
		if msg.ok then
			setStatus("ok", noctalia.tr("ui.panel.status.ok"))
		else
			setStatus("err", errText(msg.err))
		end
	elseif op == "task.create" then
		if msg.ok then
			snap.error = nil
			setStatus("ok", noctalia.tr("ui.panel.quick.sent"))
			noctalia.notify(noctalia.tr("notify.created"))
		elseif msg.unknown_outcome then
			setStatus("warn", noctalia.tr("err.unknown_outcome"))
			noctalia.notifyError(noctalia.tr("notify.unknown"), noctalia.tr("err.unknown_outcome"))
			quickKey = quickKey + 1
		else
			setStatus("err", errText(msg.err))
			noctalia.notifyError(noctalia.tr("notify.failed"), errText(msg.err))
		end
		render()
	elseif op == "task.complete" or op == "task.reopen" then
		if msg.ok then
			snap.error = nil
			statusKind, statusText = nil, nil
		elseif msg.unknown_outcome then
			-- The mutation may or may not have landed: re-read rather than
			-- retry, so we never close or reopen a task twice.
			setStatus("warn", noctalia.tr("err.unknown_outcome_refresh"))
			client.send("tasks.refresh", {})
		else
			setStatus("err", errText(msg.err))
		end
		render()
	elseif op == "tasks.fetch" or op == "tasks.refresh" then
		if msg.ok then
			snap.error = nil
			if statusKind ~= "ok" then
				statusText = nil
			end
		else
			setStatus("err", errText(msg.err))
		end
		render()
	end
end)

-- ── lifecycle ───────────────────────────────────────────────────
function onOpen(_context)
	open = true
	local current = noctalia.state.get("todoist")
	if type(current) == "table" then
		snap = current
	end

	-- Deep link from the launcher: switch to the task's project and reveal it.
	local focus = noctalia.state.get("open_task")
	if type(focus) == "table" and focus.id ~= nil then
		noctalia.state.set("open_task", nil)
		highlightId = tostring(focus.id)
		if type(focus.project_id) == "string" and focus.project_id ~= "" then
			mode = "list"
			client.send("tasks.fetch", { view = "project", project_id = focus.project_id })
		end
	end

	render()
end

function onClose()
	open = false
	client.abandon()
	highlightId = nil
end

function update()
	if not open then
		return
	end
	if client.watchdog() then
		setStatus("warn", noctalia.tr("err.timeout"))
		render()
	end
end

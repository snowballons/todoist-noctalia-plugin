--!nonstrict
-- service.luau (Phase 1)
-- The only entry that talks to Todoist. Owns the token, the command queue
-- (one request in flight, FIFO) and the published snapshot that the panel,
-- launcher and widget read.
--
-- Phase 1 is read-only plus quick capture: refresh views, serve cached views
-- to the UI, and POST natural-language text to Todoist Quick Add. No edit,
-- complete or delete yet.
local api = require("./lib/api.luau")
local cache = require("./lib/cache.luau")
local dates = require("./lib/dates.luau")

local SCHEMA = 1
local WATCHDOG_MS = 30000 -- documented http() has no timeout
local RETRY_DELAY_MS = 2000
local VIEW_TTL_MS = 60 * 1000
local PROJECTS_TTL_MS = 5 * 60 * 1000

noctalia.setUpdateInterval(1000)

-- ── settings ────────────────────────────────────────────────────
local function cfg(key)
	return noctalia.getConfig(key)
end

local function maxRetries()
	local n = tonumber(cfg("max_retries"))
	if n == nil or n < 0 then
		return 0
	end
	return math.floor(n)
end

-- ── token ───────────────────────────────────────────────────────
-- Order: TODOIST_API_TOKEN -> token_file -> token setting (Lunatask order).
-- Never logged, never published, never written to the cache file.
--
-- A token file is often just the token, but saving the whole environment line
-- ("TODOIST_API_TOKEN = xxx", "export TODOIST_API_TOKEN=xxx") is common enough
-- to unwrap: the first non-comment line wins, an optional "export " and an
-- optional NAME= prefix are stripped, and one layer of quotes is removed.
local function parseTokenText(raw)
	if type(raw) ~= "string" then
		return nil
	end
	for line in raw:gmatch("[^\r\n]+") do
		local t = noctalia.string.trim(line)
		if t ~= "" and t:sub(1, 1) ~= "#" then
			t = t:gsub("^export%s+", "")
			local value = t:match("^[A-Za-z_][A-Za-z0-9_]*%s*=%s*(.+)$")
			if value ~= nil then
				t = value
			end
			t = t:gsub('^"%s*(.*)%s*"$', "%1")
			t = t:gsub("^'%s*(.*)%s*'$", "%1")
			t = noctalia.string.trim(t)
			if t ~= "" then
				return t
			end
		end
	end
	return nil
end

local function readTokenFile(path)
	if type(path) ~= "string" or noctalia.string.trim(path) == "" then
		return nil
	end
	local raw = noctalia.readFile(noctalia.expandPath(noctalia.string.trim(path)))
	return parseTokenText(raw)
end

local function resolveToken()
	local env = noctalia.getenv("TODOIST_API_TOKEN")
	if type(env) == "string" and noctalia.string.trim(env) ~= "" then
		return noctalia.string.trim(env), "env"
	end
	local fromFile = readTokenFile(cfg("token_file"))
	if fromFile then
		return fromFile, "file"
	end
	local s = cfg("token")
	if type(s) == "string" and noctalia.string.trim(s) ~= "" then
		return noctalia.string.trim(s), "setting"
	end
	return nil, nil
end

-- ── data dir hardening ──────────────────────────────────────────
do
	local dir = noctalia.pluginDataDir()
	if type(dir) == "string" and dir ~= "" and noctalia.commandExists("chmod") then
		noctalia.runAsync({ "chmod", "700", dir })
	end
end

-- ── snapshot ────────────────────────────────────────────────────
local FILTER_VIEWS = {
	overdue = "overdue",
	today = "today",
	p1 = "priority:4",
}

local snapshot = {
	schema = SCHEMA,
	fetched_at = nil,
	loading = false,
	token_configured = false,
	token_source = nil,
	view = "today",
	views = {},
	tasks = {},
	projects = {},
	inbox_project_id = nil,
	counts = {},
	defaults = {},
	error = nil,
}

local function publish()
	noctalia.state.set("todoist", snapshot)
end

local function setActiveView(key)
	snapshot.view = key
	local v = snapshot.views[key]
	snapshot.tasks = (type(v) == "table" and v.tasks) or {}
end

local function readDefaults()
	snapshot.defaults = {
		project = cfg("default_project"),
		labels = cfg("default_labels"),
		priority = cfg("default_priority"),
	}
end

-- ── normalization ───────────────────────────────────────────────
local function normTask(t)
	return {
		id = t.id,
		content = t.content or "",
		description = t.description,
		project_id = t.project_id,
		section_id = t.section_id,
		parent_id = t.parent_id,
		labels = t.labels or {},
		priority = t.priority, -- raw API 1..4 (4 = very urgent)
		p = api.priorityFromApi(t.priority), -- client 1..4 (1 highest)
		due = t.due,
		deadline = t.deadline,
		checked = t.checked == true,
		added_at = t.added_at,
		child_order = t.child_order,
		url = "https://app.todoist.com/app/task/" .. tostring(t.id),
	}
end

local function normProject(p)
	return {
		id = p.id,
		name = p.name or "",
		color = p.color,
		parent_id = p.parent_id,
		inbox = p.inbox_project == true,
		shared = p.is_shared == true or p.shared == true,
		child_order = p.child_order,
	}
end

local function sortTasks(items)
	table.sort(items, function(a, b)
		local ka = dates.dueSortKey(a.due)
		local kb = dates.dueSortKey(b.due)
		if ka ~= kb then
			return ka < kb
		end
		local pa = a.p or 5
		local pb = b.p or 5
		if pa ~= pb then
			return pa < pb
		end
		return (a.child_order or 0) < (b.child_order or 0)
	end)
end

local function findInboxId(projects)
	for _, p in ipairs(projects) do
		if p.inbox then
			return p.id
		end
	end
	for _, p in ipairs(projects) do
		if string.lower(p.name) == "inbox" then
			return p.id
		end
	end
	return nil
end

-- ── queue ───────────────────────────────────────────────────────
local queue = {}
local busy = false
local current = nil
local lastSeq = { panel = 0, launcher = 0, internal = 0 }
local retryTimers = {} -- { at, fn }

local function publishSeq()
	noctalia.state.set("svc_seq", { panel = lastSeq.panel or 0, launcher = lastSeq.launcher or 0 })
end

local function reply(sender, seq, op, result)
	noctalia.state.set("evt." .. sender, {
		seq = seq,
		op = op,
		ok = result.ok == true,
		err = result.err,
		unknown_outcome = result.unknown_outcome == true,
		warning = result.warning,
		-- Additive: lets the panel highlight the task a result refers to.
		data = result.data,
	})
end

-- ── retry (GET only) ────────────────────────────────────────────
local function delay(ms, fn)
	retryTimers[#retryTimers + 1] = { at = noctalia.nowMs() + ms, fn = fn }
end

-- Reads may be replayed safely; callers must never pass a mutating call.
local function getRetry(fn, cb, attempt)
	attempt = attempt or 0
	fn(function(r)
		local kind = r.err and r.err.kind
		if r.ok or not api.isTransient(kind) or attempt >= maxRetries() then
			cb(r)
		else
			delay(RETRY_DELAY_MS, function()
				getRetry(fn, cb, attempt + 1)
			end)
		end
	end)
end

-- ── fetching ────────────────────────────────────────────────────
local function fetchProjects(token, cb)
	getRetry(function(c)
		api.listProjects(token, c)
	end, function(r)
		if not r.ok then
			cb(false, r.err)
			return
		end
		local projects = {}
		for _, p in ipairs(r.items or {}) do
			projects[#projects + 1] = normProject(p)
		end
		snapshot.projects = projects
		snapshot.inbox_project_id = findInboxId(projects)
		cb(true)
	end)
end

local function fetchView(token, key, spec, cb)
	local function got(r)
		if not r.ok then
			cb(false, r.err)
			return
		end
		local items = {}
		for _, t in ipairs(r.items or {}) do
			if t.is_deleted ~= true then
				items[#items + 1] = normTask(t)
			end
		end
		sortTasks(items)
		snapshot.views[key] = { tasks = items, count = #items, fetched_at = noctalia.nowMs() }
		cb(true)
	end

	if spec.kind == "filter" then
		getRetry(function(c)
			api.filterTasks(token, spec.query, c)
		end, got)
	elseif spec.kind == "inbox" then
		local pid = snapshot.inbox_project_id
		if pid == nil then
			cb(true) -- no inbox project in this account; nothing to list
			return
		end
		getRetry(function(c)
			api.listTasks(token, { project_id = pid }, c)
		end, got)
	else
		getRetry(function(c)
			api.listTasks(token, { project_id = spec.project_id }, c)
		end, got)
	end
end

-- Sequential runner: stops at the first failure.
local function chain(steps, done)
	local i = 0
	local function next_()
		i = i + 1
		if i > #steps then
			done(nil)
			return
		end
		steps[i](function(ok, err)
			if not ok then
				done(err)
				return
			end
			next_()
		end)
	end
	next_()
end

local function refreshCounts()
	local c = {}
	for key in pairs(FILTER_VIEWS) do
		local v = snapshot.views[key]
		c[key] = (type(v) == "table" and v.count) or 0
	end
	snapshot.counts = c
end

local function persist()
	if cfg("cache_tasks") ~= true then
		return
	end
	cache.save({
		schema = SCHEMA,
		saved_at = noctalia.nowMs(),
		projects = snapshot.projects,
		views = snapshot.views,
		view = snapshot.view,
		inbox_project_id = snapshot.inbox_project_id,
		counts = snapshot.counts,
	})
end

-- Full refresh: projects, the three filter views, and the inbox view.
local function refreshAll(done)
	local token, source = resolveToken()
	snapshot.token_configured = token ~= nil
	snapshot.token_source = source
	readDefaults()

	if token == nil then
		snapshot.loading = false
		snapshot.error = { kind = "config", status = 0, message = "missing token" }
		publish()
		done({ ok = false, err = snapshot.error })
		return
	end

	snapshot.loading = true
	snapshot.error = nil
	publish()

	chain({
		function(cb)
			if snapshot.projects and #snapshot.projects > 0 and snapshot.fetched_at
				and (noctalia.nowMs() - snapshot.fetched_at) < PROJECTS_TTL_MS then
				cb(true)
				return
			end
			fetchProjects(token, cb)
		end,
		function(cb)
			fetchView(token, "overdue", { kind = "filter", query = FILTER_VIEWS.overdue }, cb)
		end,
		function(cb)
			fetchView(token, "today", { kind = "filter", query = FILTER_VIEWS.today }, cb)
		end,
		function(cb)
			fetchView(token, "p1", { kind = "filter", query = FILTER_VIEWS.p1 }, cb)
		end,
		function(cb)
			fetchView(token, "inbox", { kind = "inbox" }, cb)
		end,
	}, function(err)
		snapshot.loading = false
		if err then
			snapshot.error = err
		else
			snapshot.error = nil
			snapshot.fetched_at = noctalia.nowMs()
		end
		refreshCounts()
		if snapshot.token_configured and snapshot.projects then
			-- keep the active view valid
			if snapshot.views[snapshot.view] == nil then
				snapshot.view = "today"
			end
		end
		setActiveView(snapshot.view)
		publish()
		persist()
		done({ ok = err == nil, err = err })
	end)
end

-- On-demand load of a single view (project click, or a stale view).
local function fetchOne(view, projectId, force, done)
	local token = resolveToken()
	if token == nil then
		done({ ok = false, err = { kind = "config", status = 0, message = "missing token" } })
		return
	end
	local key, spec
	if view == "project" then
		if type(projectId) ~= "string" or projectId == "" then
			done({ ok = false, err = { kind = "validation", status = 0, message = "project_id" } })
			return
		end
		key = "project:" .. projectId
		spec = { kind = "project", project_id = projectId }
	else
		key = view
		if FILTER_VIEWS[view] then
			spec = { kind = "filter", query = FILTER_VIEWS[view] }
		elseif view == "inbox" then
			spec = { kind = "inbox" }
		else
			done({ ok = false, err = { kind = "validation", status = 0, message = "unknown view" } })
			return
		end
	end

	local existing = snapshot.views[key]
	if not force and type(existing) == "table" and existing.fetched_at
		and (noctalia.nowMs() - existing.fetched_at) < VIEW_TTL_MS then
		setActiveView(key)
		publish()
		done({ ok = true })
		return
	end

	if view == "inbox" and snapshot.inbox_project_id == nil and #snapshot.projects == 0 then
		-- need projects before the inbox id is known
		fetchProjects(token, function(ok, err)
			if not ok then
				snapshot.error = err
				publish()
				done({ ok = false, err = err })
				return
			end
			fetchView(token, key, spec, function(ok2, err2)
				snapshot.error = err2
				setActiveView(key)
				publish()
				done({ ok = ok2, err = err2 })
			end)
		end)
		return
	end

	snapshot.loading = true
	snapshot.error = nil
	publish()
	fetchView(token, key, spec, function(ok, err)
		snapshot.loading = false
		if err then
			snapshot.error = err
		else
			snapshot.error = nil
		end
		setActiveView(key)
		publish()
		done({ ok = ok, err = err })
	end)
end

-- ── local reconcile ─────────────────────────────────────────────
-- A completed task leaves every view we hold: the filter views because it no
-- longer matches them, and the project/inbox views because the panel lists
-- actionable work only. Reopening is the reverse, but a filter view cannot be
-- recomputed locally, so the caller re-fetches instead of guessing.

local function removeFromViews(id)
	local any = false
	for _, v in pairs(snapshot.views) do
		if type(v) == "table" and type(v.tasks) == "table" then
			local kept, hit = {}, false
			for _, t in ipairs(v.tasks) do
				if t.id == id then
					hit = true
				else
					kept[#kept + 1] = t
				end
			end
			if hit then
				v.tasks = kept
				v.count = #kept
				any = true
			end
		end
	end
	-- The view arrays were replaced, so re-point the published active list;
	-- otherwise the panel keeps rendering the removed task.
	if any then
		setActiveView(snapshot.view)
	end
	return any
end

local function patchInViews(id, patch)
	local any = false
	for _, v in pairs(snapshot.views) do
		if type(v) == "table" and type(v.tasks) == "table" then
			for _, t in ipairs(v.tasks) do
				if t.id == id then
					for k, val in pairs(patch) do
						t[k] = val
					end
					any = true
				end
			end
		end
	end
	return any
end

-- Re-fetch whatever the panel is showing: a filter view, inbox, or the
-- "project:<id>" key that setActiveView stores.
local function refetchActive(done)
	local key = snapshot.view
	if type(key) ~= "string" or key == "" then
		done({ ok = true })
		return
	end
	local pid = key:match("^project:(.+)$")
	if pid then
		fetchOne("project", pid, true, done)
	else
		fetchOne(key, nil, true, done)
	end
end

-- ── ops ─────────────────────────────────────────────────────────
local enqueueInternal

local function opPing(done)
	local token = resolveToken()
	if token == nil then
		done({ ok = false, err = { kind = "config", status = 0, message = "missing token" } })
		return
	end
	api.ping(token, function(r)
		if r.ok then
			done({ ok = true })
		else
			done({ ok = false, err = r.err })
		end
	end)
end

local function opTaskCreate(args, done)
	local text = noctalia.string.trim(tostring((args and args.text) or ""))
	if text == "" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "empty" } })
		return
	end
	local token = resolveToken()
	if token == nil then
		done({ ok = false, err = { kind = "config", status = 0, message = "missing token" } })
		return
	end
	local note = args and args.note
	-- POST is never retried: a lost response may still have created the task.
	api.quickAdd(token, text, note, function(r)
		if r.ok then
			done({ ok = true })
			enqueueInternal("tasks.refresh", {})
		elseif r.err and api.isTransient(r.err.kind) then
			done({ ok = false, unknown_outcome = true, err = r.err })
		else
			done({ ok = false, err = r.err })
		end
	end)
end

-- closeTask answers 204 and is idempotent, so a transient failure leaves the
-- task closed or not — report the doubt rather than guess. (Bounded retry and
-- a confirming GET land with the retry-policy split.)
local function opTaskComplete(args, done)
	local id = args and args.id
	if type(id) ~= "string" or id == "" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "id" } })
		return
	end
	local token = resolveToken()
	if token == nil then
		done({ ok = false, err = { kind = "config", status = 0, message = "missing token" } })
		return
	end
	api.closeTask(token, id, function(r)
		if not r.ok then
			if r.err and api.isTransient(r.err.kind) then
				done({ ok = false, unknown_outcome = true, err = r.err })
			else
				done({ ok = false, err = r.err })
			end
			return
		end
		removeFromViews(id)
		refreshCounts()
		publish()
		persist()
		done({ ok = true, data = { id = id, checked = true } })
	end)
end

local function opTaskReopen(args, done)
	local id = args and args.id
	if type(id) ~= "string" or id == "" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "id" } })
		return
	end
	local token = resolveToken()
	if token == nil then
		done({ ok = false, err = { kind = "config", status = 0, message = "missing token" } })
		return
	end
	api.reopenTask(token, id, function(r)
		if not r.ok then
			if r.err and api.isTransient(r.err.kind) then
				done({ ok = false, unknown_outcome = true, err = r.err })
			else
				done({ ok = false, err = r.err })
			end
			return
		end
		patchInViews(id, { checked = false })
		publish()
		persist()
		done({ ok = true, data = { id = id, checked = false } })
		-- It may now belong to a filter view it was removed from, which we
		-- cannot recompute locally: re-read what the panel is showing.
		enqueueInternal("tasks.refetch", {})
	end)
end

local function opTaskDelete(args, done)
	local id = args and args.id
	if type(id) ~= "string" or id == "" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "id" } })
		return
	end
	local token = resolveToken()
	if token == nil then
		done({ ok = false, err = { kind = "config", status = 0, message = "missing token" } })
		return
	end
	api.deleteTask(token, id, function(r)
		-- A 404 means the task is already gone: the goal state is reached, so
		-- do not infer failure from absence. Any other error is real.
		if not r.ok and not (r.err and r.err.kind == "not_found") then
			if r.err and api.isTransient(r.err.kind) then
				done({ ok = false, unknown_outcome = true, err = r.err })
			else
				done({ ok = false, err = r.err })
			end
			return
		end
		removeFromViews(id)
		refreshCounts()
		publish()
		persist()
		done({ ok = true, data = { id = id, deleted = true } })
	end)
end

local function handleOp(op, args, done)
	if op == "ping" then
		opPing(done)
	elseif op == "tasks.refresh" then
		refreshAll(done)
	elseif op == "tasks.fetch" then
		fetchOne((args and args.view) or "today", args and args.project_id, args and args.force, done)
	elseif op == "tasks.refetch" then
		refetchActive(done)
	elseif op == "task.create" then
		opTaskCreate(args, done)
	elseif op == "task.complete" then
		opTaskComplete(args, done)
	elseif op == "task.reopen" then
		opTaskReopen(args, done)
	elseif op == "task.delete" then
		opTaskDelete(args, done)
	else
		done({ ok = false, err = { kind = "validation", status = 0, message = "unknown op" } })
	end
end

-- ── queue mechanics ─────────────────────────────────────────────
-- Forward declaration: finishJob() and enqueueJob() both call pump(), which is
-- defined below them.
local pump

local function finishJob(job, result)
	if job.settled then
		return
	end
	job.settled = true
	if current == job then
		current = nil
	end
	busy = false
	reply(job.sender, job.seq, job.op, result)
	pump()
end

pump = function()
	if busy or #queue == 0 then
		return
	end
	busy = true
	local job = table.remove(queue, 1)
	job.deadline = noctalia.nowMs() + WATCHDOG_MS
	current = job
	job.run(function(result)
		finishJob(job, result)
	end)
end

local function enqueueJob(sender, seq, op, args)
	if seq <= (lastSeq[sender] or 0) then
		return false
	end
	lastSeq[sender] = seq
	publishSeq()
	table.insert(queue, {
		sender = sender,
		seq = seq,
		op = op,
		run = function(done)
			handleOp(op, args, done)
		end,
	})
	pump()
	return true
end

local function enqueue(sender, msg)
	if type(msg) ~= "table" or type(msg.seq) ~= "number" or type(msg.op) ~= "string" then
		return
	end
	enqueueJob(sender, msg.seq, msg.op, msg.args)
end

enqueueInternal = function(op, args)
	lastSeq.internal = (lastSeq.internal or 0) + 1
	table.insert(queue, {
		sender = "internal",
		seq = lastSeq.internal,
		op = op,
		run = function(done)
			handleOp(op, args, done)
		end,
	})
	pump()
end

-- ── boot ────────────────────────────────────────────────────────
noctalia.state.set("svc_boot", noctalia.nowMs())
publishSeq()
readDefaults()

do
	-- Gate the read on the setting as well: turning caching off must stop the
	-- panel from painting an old snapshot, not just stop writing new ones.
	local cached = nil
	if cfg("cache_tasks") == true then
		cached = cache.load()
	end
	if type(cached) == "table" then
		snapshot.projects = cached.projects or {}
		snapshot.views = cached.views or {}
		snapshot.inbox_project_id = cached.inbox_project_id
		snapshot.counts = cached.counts or {}
		snapshot.fetched_at = cached.saved_at
		snapshot.view = cached.view or "today"
		setActiveView(snapshot.view)
	end
	publish()
end

noctalia.state.watch("cmd.panel", function(msg)
	enqueue("panel", msg)
end)
noctalia.state.watch("cmd.launcher", function(msg)
	enqueue("launcher", msg)
end)

-- A settings change (new token, cache toggle, defaults) must not wait for the
-- next scheduled refresh.
function onConfigChanged()
	readDefaults()
	enqueueInternal("tasks.refresh", {})
end

local booted = false

function update()
	local now = noctalia.nowMs()

	if busy and current ~= nil and now > current.deadline then
		finishJob(current, { ok = false, err = { kind = "timeout", status = 0, message = "deadline" } })
	end

	for i = #retryTimers, 1, -1 do
		if retryTimers[i].at <= now then
			local t = table.remove(retryTimers, i)
			t.fn()
		end
	end

	if not booted then
		booted = true
		enqueueInternal("tasks.refresh", {})
	end
end

-- Test hook: noctalia msg plugin snowballons/todoist:core all ping|refresh
function onIpc(event)
	if event == "ping" then
		enqueueInternal("ping", {})
	elseif event == "refresh" then
		enqueueInternal("tasks.refresh", {})
	end
end

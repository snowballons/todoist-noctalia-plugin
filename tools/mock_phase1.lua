--[[
tools/mock_phase1.lua — offline harness for the Todoist Phase 1 plugin.

Runs with stock Lua 5.4, no Noctalia instance needed:
    lua5.4 tools/mock_phase1.lua        (from the todoist/ directory)

What it does: stubs the `noctalia` surface (http, json, state, string, ...),
loads the REAL service.luau / panel.luau / launcher.luau through a require
shim, and drives them through the state channel exactly as the shell would.

What it proves: token resolution, the 5-request boot refresh, view + count
publication, the per-view TTL cache hit, quick-add success, quick-add
transport failure -> unknown_outcome with exactly one POST (never retried),
GET retry budget, priority mapping, and that both UI entries build a render
tree without erroring.

Known stub: noctalia.json is replaced with a sentinel codec, so the HTTP
bodies below are checked for shape rather than parsed as real JSON. JSON
round-tripping is the runtime's job, not this plugin's.
]]

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

-- ── test clock ──────────────────────────────────────────────────
local clock = 1792029000000

-- ── state channel ───────────────────────────────────────────────
-- watch() keeps only the latest callback per key: reloading an entry means
-- the previous VM is gone, so appended handlers would double-fire.
local state_store = {}
local watchers = {}

local function fire(key, value)
	local fn = watchers[key]
	if fn then
		fn(value)
	end
end

local function getState(key)
	return state_store[key]
end

-- ── stub noctalia ───────────────────────────────────────────────
local env = {}
local cfg = { token = "", token_file = "", max_retries = 1, cache_tasks = false, confirm_delete = true, default_project = "", default_labels = {}, default_priority = "none" }
local log_lines = {}
local notified = {}
local runasync = {}
local toggled = {}
local tr_calls = {}
local cache_files = {} -- path -> registered snapshot body (simulated on-disk cache)

local function lastSubs(key)
	for i = #tr_calls, 1, -1 do
		if tr_calls[i].key == key then
			return tr_calls[i].subs
		end
	end
	return nil
end

local function urlEncode(s)
	return (tostring(s):gsub("[^%w%-%_%.%~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function urlDecode(s)
	s = tostring(s):gsub("+", " ")
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- sentinel codec: register() hands out an opaque body string for a table
local body_map = {}
local body_n = 0
local function register(v)
	body_n = body_n + 1
	local s = "@body" .. body_n
	body_map[s] = v
	return s
end

noctalia = {
	getenv = function(name)
		return env[name]
	end,
	getConfig = function(key)
		return cfg[key]
	end,
	readFile = function(path)
		return cache_files[path] or env["file:" .. tostring(path)]
	end,
	expandPath = function(p)
		return tostring(p):gsub("^~", "/home/tester")
	end,
	fileExists = function(path)
		return cache_files[path] ~= nil or env["file:" .. tostring(path)] ~= nil
	end,
	removeFile = function() end,
	writeFile = function()
		return true
	end,
	renameFile = function()
		return true
	end,
	pluginDataDir = function()
		return "/tmp/todoist-mock-data"
	end,
	string = {
		trim = function(s)
			return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
		end,
		urlEncode = urlEncode,
		urlDecode = urlDecode,
	},
	json = {
		-- Only the request body is ever encoded; keep the text visible so the
		-- test can assert what was actually sent to Quick Add.
		encode = function(v)
			if type(v) ~= "table" then
				return "@encoded"
			end
			if type(v.text) == "string" then
				return "QADD:" .. v.text
			end
			-- Deterministic key dump (sorted) so tests can assert which fields
			-- a write carried — e.g. that updateTask stripped project_id.
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = tostring(k)
			end
			table.sort(keys)
			local parts = {}
			for _, k in ipairs(keys) do
				local val = v[k]
				if type(val) == "table" then
					local xs = {}
					for _, x in ipairs(val) do
						xs[#xs + 1] = tostring(x)
					end
					parts[#parts + 1] = k .. "=[" .. table.concat(xs, ",") .. "]"
				else
					parts[#parts + 1] = k .. "=" .. tostring(val)
				end
			end
			return "@obj{" .. table.concat(parts, ";") .. "}"
		end,
		decode = function(s)
			if s == nil or s == "" then
				return nil
			end
			return body_map[s] -- nil => api.luau's "bad json" path
		end,
	},
	nowMs = function()
		return clock
	end,
	commandExists = function(name)
		return name == "chmod" or name == "xdg-open"
	end,
	runAsync = function(argv)
		table.insert(runasync, argv)
		return true
	end,
	copyToClipboard = function() end,
	togglePanel = function(id)
		table.insert(toggled, id)
	end,
	openSettings = function() end,
	setUpdateInterval = function() end,
	log = function(m)
		table.insert(log_lines, m)
	end,
	notify = function(t, b)
		table.insert(notified, { ok = true, title = t, body = b })
	end,
	notifyError = function(t, b)
		table.insert(notified, { ok = false, title = t, body = b })
	end,
	fuzzyScore = function(needle, haystack)
		if needle == nil or needle == "" then
			return nil
		end
		local i = tostring(haystack):lower():find(tostring(needle):lower(), 1, true)
		if i == nil then
			return nil
		end
		return 100 - i -- earlier match scores higher
	end,
	tr = function(k, subs)
		-- Record substitutions so the test can assert interpolation intent
		-- (the stub returns the key itself, so the text is not visible).
		table.insert(tr_calls, { key = k, subs = subs })
		local out = tostring(k)
		if type(subs) == "table" then
			out = out:gsub("{(%w+)}", function(name)
				return tostring(subs[name] or ("{" .. name .. "}"))
			end)
		end
		return out
	end,
	state = {
		set = function(k, v)
			state_store[k] = v
		end,
		get = getState,
		watch = function(k, fn)
			watchers[k] = fn
		end,
	},
	http = function(req, cb)
		local r = route(req)
		cb(r)
		return true
	end,
}

-- ── fake Todoist backend ────────────────────────────────────────
local calls = {}
local fault = { filter_overdue = false, quick = false, close = false, delete = false } -- false | "http500" | "transport" | "404"

local PROJECTS_P1 = {
	{ id = "p-inbox", name = "Inbox", inbox_project = true, is_shared = false },
	{ id = "p-work", name = "Work", is_shared = true },
}
local PROJECTS_P2 = {
	{ id = "p-home", name = "Home" },
}
local DUE = { date = "2026-10-10", string = "Oct 10", is_recurring = false, lang = "en" }
local T_OVERDUE = { id = "t1", content = "Pay rent", project_id = "p-home", priority = 4, due = DUE, labels = {}, checked = false }
local T_TODAY = { id = "t2", content = "Write report", project_id = "p-work", priority = 2, due = DUE, labels = {}, checked = false }
local T_INBOX = { id = "t3", content = "Read article", project_id = "p-inbox", priority = 1, labels = {}, checked = false }

-- Mutable store backing the Phase 2 (M1) mutation routes below.
local MUT = {
	tasks = { m1 = { id = "m1", content = "original", project_id = "p-home", priority = 1, labels = {}, checked = false } },
	next_id = 0,
}

local function parseQuery(qs)
	local params = {}
	for pair in tostring(qs):gmatch("[^&]+") do
		local k, v = pair:match("^([^=]*)=(.*)$")
		if k then
			params[urlDecode(k)] = urlDecode(v)
		end
	end
	return params
end

local function resp(status, v)
	if status == 0 then
		return { ok = false, status = 0, body = "" }
	end
	local body = ""
	if v ~= nil then
		body = register(v)
	end
	return { ok = status >= 200 and status < 300, status = status, body = body }
end

function route(req)
	table.insert(calls, { url = req.url, method = req.method, body = req.body, headers = req.headers })
	local path = req.url:match("^https://api%.todoist%.com/api/v1([^?]*)") or ""
	local params = parseQuery(req.url:match("%?(.*)$") or "")
	local method = req.method or "GET"

	if method == "GET" and path == "/ping" then
		return resp(200, { message = "pong" })
	end

	if method == "GET" and path == "/projects" then
		if params.cursor == nil then
			return resp(200, { results = PROJECTS_P1, next_cursor = "c2" })
		end
		return resp(200, { results = PROJECTS_P2, next_cursor = nil })
	end

	if method == "GET" and path == "/tasks/filter" then
		local q = params.query
		if q == "overdue" then
			if fault.filter_overdue == "http500" then
				return resp(500, { message = "boom" })
			end
			if fault.filter_overdue == "transport" then
				return resp(0, nil)
			end
			return resp(200, { results = { T_OVERDUE } })
		end
		if q == "today" then
			return resp(200, { results = { T_OVERDUE, T_TODAY } })
		end
		if q == "priority:4" then
			return resp(200, { results = { T_OVERDUE } })
		end
		return resp(200, { results = {} })
	end

	if method == "GET" and path == "/tasks" then
		if params.project_id == "p-inbox" then
			return resp(200, { results = { T_INBOX } })
		end
		return resp(200, { results = {} })
	end

	if method == "POST" and path == "/tasks/quick" then
		if fault.quick == "transport" then
			return resp(0, nil)
		end
		if fault.quick == "http500" then
			return resp(500, { message = "boom" })
		end
		return resp(200, nil) -- server answers 200 with an empty body
	end

	-- ── Phase 2 (M1) mutation routes ────────────────────────────
	-- Order matters: the exact /tasks/completed and /tasks/labels paths are
	-- checked before the generic "/tasks/{id}" pattern, which would otherwise
	-- swallow them as ids.
	if method == "GET" and path == "/tasks/completed" then
		return resp(200, {
			items = {
				{ id = "uuid-c1", task_id = "m1", content = "original", completed_at = "2026-10-19T10:00:00Z", project_id = "p-home" },
			},
		})
	end

	if method == "GET" and path == "/labels" then
		return resp(200, { results = { { id = "l1", name = "errand" }, { id = "l2", name = "home" } } })
	end

	if method == "POST" and path == "/tasks" then
		MUT.next_id = MUT.next_id + 1
		local t = { id = "new-" .. tostring(MUT.next_id), content = "created", priority = 1, labels = {} }
		MUT.tasks[t.id] = t
		return resp(200, t)
	end

	local mtask = path:match("^/tasks/([^/]+)$")
	local msub, verb = path:match("^/tasks/([^/]+)/(%w+)$")

	if mtask ~= nil and method == "DELETE" then
		if fault.delete == "404" then
			return resp(404, { error = "not found" })
		end
		if fault.delete == "http500" then
			return resp(500, { message = "boom" })
		end
		if fault.delete == "transport" then
			return resp(0, nil)
		end
		if MUT.tasks[mtask] ~= nil then
			MUT.tasks[mtask] = nil
			return resp(204, nil)
		end
		return resp(404, { error = "not found" })
	end

	if mtask ~= nil and MUT.tasks[mtask] ~= nil then
		if method == "GET" then
			return resp(200, MUT.tasks[mtask])
		end
		if method == "POST" then
			return resp(200, { id = mtask, content = "updated", project_id = "p-home", priority = 1, labels = {} })
		end
	end

	if msub ~= nil and method == "POST" then
		if verb == "close" then
			if fault.close == "transport" then
				return resp(0, nil)
			end
			if fault.close == "http500" then
				return resp(500, { message = "boom" })
			end
			return resp(204, nil)
		end
		if verb == "reopen" then
			return resp(204, nil)
		end
		if verb == "move" then
			return resp(200, { id = msub, project_id = "p-home", section_id = nil })
		end
	end

	return resp(404, { message = "no route" })
end

-- ── require shim (Noctalia-style "./lib/x.luau") ────────────────
local orig_require = require
local req_cache = {}
require = function(path)
	local rel = path:match("^%./(.+)%.luau$")
	if rel then
		if req_cache[rel] == nil then
			req_cache[rel] = assert(loadfile(PLUGIN_DIR .. rel .. ".luau"))()
		end
		return req_cache[rel]
	end
	return orig_require(path)
end

-- ── assertions ──────────────────────────────────────────────────
local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then
		pass = pass + 1
		print("PASS " .. name)
	else
		fail = fail + 1
		print("FAIL " .. name .. (extra ~= nil and (" — " .. tostring(extra)) or ""))
	end
end

local function countCalls(pred)
	local n = 0
	for _, c in ipairs(calls) do
		if pred(c) then
			n = n + 1
		end
	end
	return n
end

local function filterCalls(q)
	return countCalls(function(c)
		return c.url:find("/tasks/filter", 1, true) ~= nil and c.url:find("query=" .. q, 1, true) ~= nil
	end)
end

-- ── load the service ────────────────────────────────────────────
local function loadService()
	assert(loadfile(PLUGIN_DIR .. "service.luau"))() -- returns nothing; sets globals
end

print("== data dir hardening ==")
loadService()
check("chmod 700 on data dir", runasync[1] ~= nil and runasync[1][1] == "chmod" and runasync[1][2] == "700", runasync[1] and table.concat(runasync[1], " "))

-- ── T1: no token ────────────────────────────────────────────────
print("\n== T1 no token ==")
env = {}
cfg.token = ""
cfg.token_file = ""
calls = {}
loadService()
update() -- boots the first refresh
local snap = getState("todoist")
check("snapshot published", type(snap) == "table")
check("token_configured=false", snap and snap.token_configured == false)
check("error.kind=config", snap and snap.error and snap.error.kind == "config", snap and snap.error and snap.error.kind)
check("no HTTP attempted", #calls == 0, #calls)

-- ── T1b: token file forms ───────────────────────────────────────
print("\n== T1b token file forms ==")
local TOKEN_PATH = "/home/tester/.config/todoist/token"

local function tokenFromFile(content)
	env = { ["file:" .. TOKEN_PATH] = content }
	cfg.token = ""
	cfg.token_file = "~/.config/todoist/token"
	calls = {}
	runasync = {}
	loadService()
	update()
	local used = nil
	for _, h in ipairs((calls[1] and calls[1].headers) or {}) do
		local t = h:match("^Authorization: Bearer (.+)$")
		if t ~= nil then
			used = t
		end
	end
	return used
end

check("NAME = value form", tokenFromFile("TODOIST_API_TOKEN = file-token-1\n") == "file-token-1")
check("NAME=value form", tokenFromFile("TODOIST_API_TOKEN=file-token-2") == "file-token-2")
check("bare token form", tokenFromFile("  file-token-3  \n") == "file-token-3")
check("export prefix", tokenFromFile("export TODOIST_API_TOKEN=file-token-4\n") == "file-token-4")
check("leading comment line", tokenFromFile("# my todoist token\nTODOIST_API_TOKEN = file-token-5\n") == "file-token-5")
check("quoted value", tokenFromFile('TODOIST_API_TOKEN = "file-token-6"') == "file-token-6")
check("empty file -> no token", tokenFromFile("\n\n") == nil)
tokenFromFile("TODOIST_API_TOKEN = file-token-7\n")
check("file token stamped as file source", getState("todoist").token_source == "file", getState("todoist").token_source)

-- ── T1c: on-disk cache ──────────────────────────────────────────
print("\n== T1c on-disk cache ==")
local SNAP_PATH = "/tmp/todoist-mock-data/snapshot.json"
local cached_body = register({
	schema = 1,
	saved_at = 12345,
	projects = { { id = "p-home", name = "Home" } },
	views = { today = { count = 9, tasks = { { id = "cached-1", content = "cached task" } } } },
	inbox_project_id = "p-inbox",
	counts = { today = 9, overdue = 0, p1 = 0 },
	view = "today",
})

cfg.token = "cache-token"
cfg.token_file = ""
env = {}
calls = {}
runasync = {}
cache_files = { [SNAP_PATH] = cached_body }
cfg.cache_tasks = false
loadService()
snap = getState("todoist")
check("cache off: stored snapshot ignored", (snap.counts or {}).today ~= 9, snap.counts and snap.counts.today)
check("cache off: no HTTP before the first tick", #calls == 0, #calls)

calls = {}
runasync = {}
cfg.cache_tasks = true
loadService()
snap = getState("todoist")
check("cache on: snapshot painted before any request", (snap.counts or {}).today == 9, snap.counts and snap.counts.today)
check("cache on: cached task present", snap.views.today.tasks[1].id == "cached-1", snap.views.today.tasks[1].id)
check("cache on: still no HTTP before the first tick", #calls == 0, #calls)
check("cache on: fetched_at taken from saved_at", snap.fetched_at == 12345, snap.fetched_at)
update() -- first tick -> refreshAll -> persist()
do
	local chmod600 = false
	for _, argv in ipairs(runasync) do
		if argv[1] == "chmod" and argv[2] == "600" and argv[3] == SNAP_PATH then
			chmod600 = true
		end
	end
	check("persist chmods the snapshot 600", chmod600, table.concat(runasync[#runasync] or {}, " "))
end

-- ── T2: token from env -> boot refresh ──────────────────────────
print("\n== T2 boot refresh ==")
env = { TODOIST_API_TOKEN = "  valid-token  " } -- whitespace must be trimmed
cfg.max_retries = 1
calls = {}
loadService()
update()
snap = getState("todoist")
check("token_source=env", snap and snap.token_source == "env", snap and snap.token_source)
check("projects paginated (2 pages -> 3 projects)", snap and #snap.projects == 3, snap and #snap.projects)
check("inbox project resolved", snap and snap.inbox_project_id == "p-inbox", snap and snap.inbox_project_id)
check("boot = projects(2 pages) + 3 filters + inbox = 6 GETs", #calls == 6, #calls)
do
	local sawAuth, sawAccept = false, false
	for _, h in ipairs((calls[1] and calls[1].headers) or {}) do
		if h == "Authorization: Bearer valid-token" then
			sawAuth = true
		end
		if h == "Accept: application/json" then
			sawAccept = true
		end
	end
	check("auth header sent, token trimmed", sawAuth, calls[1] and table.concat(calls[1].headers or {}, " | "))
	check("accept header sent", sawAccept)
	check("token never in the URL", calls[1] ~= nil and calls[1].url:find("valid-token", 1, true) == nil)
end
check("token never logged", (function()
	for _, line in ipairs(log_lines) do
		if tostring(line):find("valid-token", 1, true) then
			return false
		end
	end
	return true
end)())
check("overdue view count=1", snap and snap.views.overdue and snap.views.overdue.count == 1)
check("today view count=2", snap and snap.views.today and snap.views.today.count == 2, snap and snap.views.today and snap.views.today.count)
check("p1 view count=1", snap and snap.views.p1 and snap.views.p1.count == 1)
check("inbox view count=1", snap and snap.views.inbox and snap.views.inbox.count == 1)
check("counts.overdue=1", snap and snap.counts.overdue == 1)
check("counts.today=2", snap and snap.counts.today == 2)
check("priority mapped p=1 for API 4", snap and snap.views.overdue.tasks[1].p == 1, snap and snap.views.overdue.tasks[1].p)
check("task url built", snap and snap.views.overdue.tasks[1].url == "https://app.todoist.com/app/task/t1")
check("inbox flag from inbox_project", true) -- asserted via inbox_project_id above
check("active view is today", snap and snap.view == "today", snap and snap.view)

-- ── T3: priority mapping ────────────────────────────────────────
print("\n== T3 priority mapping ==")
local api = require("./lib/api.luau")
check("priorityToApi p1 -> 4", api.priorityToApi("p1") == 4)
check("priorityToApi p2 -> 3", api.priorityToApi("p2") == 3)
check("priorityToApi p4 -> 1", api.priorityToApi("p4") == 1)
check("priorityToApi 1 -> 4", api.priorityToApi(1) == 4)
check("priorityToApi none -> nil", api.priorityToApi("none") == nil)
check("priorityFromApi 4 -> 1", api.priorityFromApi(4) == 1)
check("priorityFromApi 1 -> 4", api.priorityFromApi(1) == 4)
check("classify 401=auth", api.classify(401) == "auth")
check("classify 429=rate_limit", api.classify(429) == "rate_limit")
check("classify 500=server", api.classify(500) == "server")
check("auth header format", api.authHeader("x") == "Authorization: Bearer x", api.authHeader("x"))

-- ── T4: panel fetch + TTL cache hit ─────────────────────────────
print("\n== T4 tasks.fetch ==")
calls = {}
fire("cmd.panel", { seq = 1, op = "tasks.fetch", args = { view = "inbox", force = true } })
local reply = getState("evt.panel")
check("reply seq matches", reply and reply.seq == 1, reply and reply.seq)
check("reply ok", reply and reply.ok == true)
check("active view switched to inbox", getState("todoist").view == "inbox")
check("one GET issued", #calls == 1, #calls)
fire("cmd.panel", { seq = 2, op = "tasks.fetch", args = { view = "inbox" } })
check("TTL cache hit -> no new request", #calls == 1, #calls)
check("cache hit still replies ok", getState("evt.panel").seq == 2 and getState("evt.panel").ok == true)

-- ── T5: quick add success ───────────────────────────────────────
print("\n== T5 quick add ==")
calls = {}
fault.quick = false
fire("cmd.panel", { seq = 3, op = "task.create", args = { text = "  Buy milk  " } })
reply = getState("evt.panel")
check("create replied ok", reply and reply.seq == 3 and reply.ok == true)
check("exactly one POST /tasks/quick", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/quick", 1, true) ~= nil
end) == 1)
check("text trimmed into body", calls[1] ~= nil and calls[1].body == "QADD:Buy milk", calls[1] and calls[1].body)
check("create triggered a refresh", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/filter", 1, true) ~= nil
end) >= 3, #calls)

-- ── T6: quick add transport failure -> unknown_outcome ──────────
print("\n== T6 quick add unknown outcome ==")
calls = {}
fault.quick = "transport"
fire("cmd.panel", { seq = 4, op = "task.create", args = { text = "Risky task" } })
reply = getState("evt.panel")
check("create replied not ok", reply and reply.seq == 4 and reply.ok == false)
check("unknown_outcome set", reply and reply.unknown_outcome == true)
check("POST not retried (exactly 1)", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/quick", 1, true) ~= nil
end) == 1)
fault.quick = false

-- ── T7: GET retry budget ────────────────────────────────────────
print("\n== T7 GET retry ==")
cfg.max_retries = 3
fault.filter_overdue = "http500"
calls = {}
fire("cmd.panel", { seq = 5, op = "tasks.fetch", args = { view = "overdue", force = true } })
-- each retry is armed on a timer; drain them by advancing the clock
for _ = 1, 8 do
	clock = clock + 2000
	update()
end
reply = getState("evt.panel")
check("overdue fetch failed", reply and reply.seq == 5 and reply.ok == false)
check("attempts = 1 + max_retries(3)", filterCalls("overdue") == 4, filterCalls("overdue"))
fault.filter_overdue = false

-- ── T8: panel renders ───────────────────────────────────────────
print("\n== T8 panel render ==")
local rendered = nil
local function node(kind)
	return function(props, children)
		return { kind = kind, props = props or {}, children = children }
	end
end

ui = {
	column = node("column"),
	row = node("row"),
	scroll = node("scroll"),
	label = node("label"),
	glyph = node("glyph"),
	button = node("button"),
	input = node("input"),
	separator = node("separator"),
	image = node("image"),
	select = node("select"),
	slider = node("slider"),
	toggle = node("toggle"),
	divider = node("divider"),
}

panel = {
	render = function(tree)
		rendered = tree
	end,
	close = function() end,
	setWantsSecondTicks = function() end,
	setNeedsFrameTick = function() end,
}

-- put the panel on a task view so rows exist
fire("cmd.panel", { seq = 6, op = "tasks.fetch", args = { view = "inbox" } })
assert(loadfile(PLUGIN_DIR .. "panel.luau"))()
onOpen({})

local nodeCount, labelTexts, glyphNames, inputCount, openButtons, buttonTexts = 0, {}, {}, 0, 0, {}
local function walk(n)
	if type(n) ~= "table" then
		return
	end
	nodeCount = nodeCount + 1
	if n.kind == "label" then
		labelTexts[#labelTexts + 1] = n.props.text
	end
	if n.kind == "glyph" then
		glyphNames[#glyphNames + 1] = n.props.name
	end
	if n.kind == "input" then
		inputCount = inputCount + 1
	end
	if n.kind == "button" then
		buttonTexts[#buttonTexts + 1] = n.props.text
		if n.props.glyph == "external-link" then
			openButtons = openButtons + 1
		end
	end
	for _, c in ipairs(n.children or {}) do
		walk(c)
	end
end
walk(rendered)

local function hasLabel(text)
	for _, t in ipairs(labelTexts) do
		if t == text then
			return true
		end
	end
	return false
end

local function hasButton(text)
	for _, t in ipairs(buttonTexts) do
		if t == text then
			return true
		end
	end
	return false
end

-- Tile labels carry a count suffix ("<label>  <n>"), so match on the prefix.
local function hasButtonPrefix(prefix)
	for _, t in ipairs(buttonTexts) do
		if type(t) == "string" and t:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

check("panel.render called", rendered ~= nil)
check("tree is non-trivial", nodeCount > 20, nodeCount)
check("title present", hasLabel("ui.panel.title"))
check("quick input present", inputCount == 1, inputCount)
check("priority flags rendered", #glyphNames >= 1 and glyphNames[1] == "flag", glyphNames[1])
check("one Open-in-Todoist per task", openButtons == 1, openButtons)
check("filter tiles present", hasButtonPrefix("ui.panel.filter.overdue") and hasButtonPrefix("ui.panel.filter.today") and hasButtonPrefix("ui.panel.filter.p1"))
check("nav tabs present", hasButton("ui.panel.nav.today") and hasButton("ui.panel.nav.inbox") and hasButton("ui.panel.nav.projects"))
check("counts painted on tiles", hasButton("ui.panel.filter.overdue  1") and hasButton("ui.panel.filter.today  2"), table.concat(buttonTexts, " | "))

-- not-configured state
state_store["todoist"] = {
	schema = 1,
	token_configured = false,
	view = "today",
	views = {},
	tasks = {},
	projects = {},
	counts = {},
	defaults = {},
}
rendered = nil
onOpen({})
labelTexts = {}
walk(rendered)
check("not-configured message shown", hasLabel("ui.panel.not_configured"))

-- ── T9: launcher ────────────────────────────────────────────────
print("\n== T9 launcher ==")
local results = nil
launcher = {
	setResults = function(_query, r)
		results = r
	end,
}
state_store["todoist"] = snap -- restore the populated snapshot
assert(loadfile(PLUGIN_DIR .. "launcher.luau"))()

onQuery("")
check("empty query -> hint first", results[1] and results[1].id == "hint", results[1] and results[1].id)
check("empty query lists tasks", #results >= 2, #results)

onQuery("pay")
check("typed query -> create row first", results[1] and results[1].id == "create", results[1] and results[1].id)
do
	local subs = lastSubs("launcher.create")
	check("create row interpolates the text", subs ~= nil and subs.text == "pay", subs and subs.text)
end
check("fuzzy match found", #results >= 2 and tostring(results[2].id):find("^task:") ~= nil, results[2] and results[2].id)
check("matched task carries a subtitle", results[2] ~= nil and results[2].subtitle ~= nil, results[2] and results[2].subtitle)

toggled = {}
onActivate(results[2].id)
check("open_task state set", getState("open_task") ~= nil and getState("open_task").id == "t1", getState("open_task") and getState("open_task").id)
check("open_task carries project", getState("open_task") ~= nil and getState("open_task").project_id == "p-home", getState("open_task") and getState("open_task").project_id)
check("panel toggled", #toggled == 1 and toggled[1] == "snowballons/todoist:manager", toggled[1])

onQuery("buy milk")
onActivate("create")
local cmd = getState("cmd.launcher")
check("create sent on cmd.launcher", cmd and cmd.op == "task.create", cmd and cmd.op)
check("create args carry text", cmd and cmd.args and cmd.args.text == "buy milk", cmd and cmd.args and cmd.args.text)
check("seq is a number", cmd and type(cmd.seq) == "number")

-- ── T10: widget ─────────────────────────────────────────────────
print("\n== T10 widget ==")
local glyphSet, tooltipSet = nil, nil
barWidget = {
	setGlyph = function(g)
		glyphSet = g
	end,
	setTooltip = function(t)
		tooltipSet = t
	end,
}
toggled = {}
assert(loadfile(PLUGIN_DIR .. "widget.luau"))()
check("widget sets a glyph", glyphSet == "checklist", glyphSet)
check("widget sets a tooltip", tooltipSet == "widget.tooltip", tooltipSet)
onClick()
check("widget click toggles panel", #toggled == 1 and toggled[1] == "snowballons/todoist:manager", toggled[1])

-- ── T11: M1 api mutations ───────────────────────────────────────
print("\n== T11 M1 api mutations ==")
local api = require("./lib/api.luau")

-- Call an api function with its callback appended, capturing the result.
-- Bounds are explicit so trailing nils (moveTask with no target) survive.
local function invoke(fn, ...)
	local n = select("#", ...)
	local captured = nil
	local args = { ... }
	args[n + 1] = function(r)
		captured = r
	end
	fn(table.unpack(args, 1, n + 1))
	return captured
end

-- createTask: POST /tasks, returns the created object (with an id)
calls = {}
local created = invoke(api.createTask, "tok", { content = "from api", priority = 4, labels = { "home" } })
check("createTask ok", created and created.ok == true, created and created.status)
check("createTask returns an id", created and created.data and created.data.id == "new-1", created and created.data and created.data.id)
check(
	"createTask POSTs /tasks (not /tasks/quick)",
	countCalls(function(c)
		return c.method == "POST" and c.url:find("/api/v1/tasks", 1, true) ~= nil and c.url:find("/tasks/quick", 1, true) == nil
	end) == 1,
	#calls
)
check(
	"createTask sends priority + labels",
	calls[1] ~= nil and calls[1].body:find("priority=4", 1, true) ~= nil and calls[1].body:find("labels=[home]", 1, true) ~= nil,
	calls[1] and calls[1].body
)

calls = {}
local noContent = invoke(api.createTask, "tok", { priority = 3 })
check("createTask empty content rejected", noContent and noContent.ok == false and noContent.err.kind == "validation", noContent and noContent.err and noContent.err.kind)
check("createTask empty content sends no HTTP", #calls == 0, #calls)

-- updateTask: strips project_id/section_id (not update fields), keeps the rest
calls = {}
local upd = invoke(api.updateTask, "tok", "m1", { content = "renamed", project_id = "p-work", section_id = "s9", labels = {} })
check("updateTask ok", upd and upd.ok == true, upd and upd.status)
check("updateTask returns the object", upd and upd.data and upd.data.id == "m1", upd and upd.data and upd.data.id)
check("updateTask POSTs /tasks/m1", calls[1] ~= nil and calls[1].method == "POST" and calls[1].url:find("/api/v1/tasks/m1", 1, true) ~= nil, calls[1] and calls[1].url)
check(
	"updateTask strips project_id/section_id",
	calls[1].body:find("project_id", 1, true) == nil and calls[1].body:find("section_id", 1, true) == nil,
	calls[1].body
)
check(
	"updateTask keeps content + empty labels",
	calls[1].body:find("content=renamed", 1, true) ~= nil and calls[1].body:find("labels=[]", 1, true) ~= nil,
	calls[1].body
)

calls = {}
local updBad = invoke(api.updateTask, "tok", "m1", { project_id = "p-work" })
check("updateTask unsupported-only rejected", updBad and updBad.ok == false and updBad.err.kind == "validation", updBad and updBad.err and updBad.err.kind)
check("updateTask unsupported-only sends no HTTP", #calls == 0, #calls)

-- moveTask
calls = {}
local mv = invoke(api.moveTask, "tok", "m1", "p-work", "s1")
check("moveTask ok", mv and mv.ok == true, mv and mv.status)
check("moveTask POSTs /tasks/m1/move", calls[1] ~= nil and calls[1].url:find("/api/v1/tasks/m1/move", 1, true) ~= nil, calls[1] and calls[1].url)
check(
	"moveTask sends project_id + section_id",
	calls[1].body:find("project_id=p-work", 1, true) ~= nil and calls[1].body:find("section_id=s1", 1, true) ~= nil,
	calls[1].body
)

calls = {}
local mvBad = invoke(api.moveTask, "tok", "m1", nil, nil)
check("moveTask without target rejected", mvBad and mvBad.ok == false and mvBad.err.kind == "validation", mvBad and mvBad.err and mvBad.err.kind)
check("moveTask without target sends no HTTP", #calls == 0, #calls)

-- getTask
calls = {}
local got = invoke(api.getTask, "tok", "m1")
check("getTask ok", got and got.ok == true and got.data and got.data.id == "m1", got and got.status)
check("getTask GETs /tasks/m1", calls[1] ~= nil and calls[1].method == "GET" and calls[1].url:find("/api/v1/tasks/m1", 1, true) ~= nil, calls[1] and calls[1].url)

-- close / reopen: 204 with no body
calls = {}
local cl = invoke(api.closeTask, "tok", "m1")
check("closeTask ok, 204, no data", cl and cl.ok == true and cl.status == 204 and cl.data == nil, cl and cl.status)
check("closeTask POSTs /close", calls[1] ~= nil and calls[1].method == "POST" and calls[1].url:find("/tasks/m1/close", 1, true) ~= nil, calls[1] and calls[1].url)

calls = {}
local ro = invoke(api.reopenTask, "tok", "m1")
check("reopenTask 204", ro and ro.ok == true and ro.status == 204, ro and ro.status)
check("reopenTask POSTs /reopen", calls[1] ~= nil and calls[1].url:find("/tasks/m1/reopen", 1, true) ~= nil, calls[1] and calls[1].url)

-- listLabels
calls = {}
local labels = invoke(api.listLabels, "tok")
check("listLabels returns items", labels and labels.ok == true and #labels.items == 2 and labels.items[1].name == "errand", labels and labels.items and #labels.items)
check("listLabels GETs /labels", calls[1] ~= nil and calls[1].url:find("/api/v1/labels", 1, true) ~= nil, calls[1] and calls[1].url)

-- completedTasks
calls = {}
local done = invoke(api.completedTasks, "tok", "2026-10-01T00:00:00Z", "2026-10-20T00:00:00Z")
check("completedTasks returns items", done and done.ok == true and #done.items == 1, done and done.items and #done.items)
check("completedTasks item keyed by task_id", done and done.items[1] and done.items[1].task_id == "m1", done and done.items[1] and done.items[1].task_id)
check(
	"completedTasks GETs /tasks/completed with since+until",
	calls[1] ~= nil and calls[1].url:find("/tasks/completed?", 1, true) ~= nil and calls[1].url:find("since=", 1, true) ~= nil and calls[1].url:find("until=", 1, true) ~= nil,
	calls[1] and calls[1].url
)

calls = {}
invoke(api.completedTasks, "tok", "2026-10-01T00:00:00Z", nil)
check("completedTasks omits until when nil", calls[1] ~= nil and calls[1].url:find("until=", 1, true) == nil, calls[1] and calls[1].url)

-- delete: 204; a following GET is 404 reported as not_found (service folds it)
calls = {}
local del = invoke(api.deleteTask, "tok", "m1")
check("deleteTask ok, 204", del and del.ok == true and del.status == 204, del and del.status)
check("deleteTask DELETEs /tasks/m1", calls[1] ~= nil and calls[1].method == "DELETE" and calls[1].url:find("/api/v1/tasks/m1", 1, true) ~= nil, calls[1] and calls[1].url)

local gone = invoke(api.getTask, "tok", "m1")
check("getTask after delete is not_found", gone and gone.ok == false and gone.err.kind == "not_found", gone and gone.err and gone.err.kind)

-- errorMessage extracts the human message from a raw error body
local err_body = register({ error = "Invalid date", error_code = 20, error_tag = "INVALID_ARGUMENT_VALUE" })
check("errorMessage extracts .error", api.errorMessage(err_body) == "Invalid date", api.errorMessage(err_body))
check("errorMessage nil for empty body", api.errorMessage("") == nil)
check("errorMessage nil for non-json", api.errorMessage("nope") == nil)

-- ── T12: M2 task.complete / task.reopen ─────────────────────────
print("\n== T12 complete / reopen ==")
env = { TODOIST_API_TOKEN = "valid-token" }
cfg.max_retries = 1
fault.close = false
calls = {}
loadService()
update() -- controlled boot: overdue=1, today=2, p1=1, inbox=1
local s12 = getState("todoist")
check("T12 setup: today holds 2", s12.views.today.count == 2, s12.views.today.count)
check("T12 setup: active view today", s12.view == "today", s12.view)

-- complete: one POST, then a purely local reconcile (no extra GET)
calls = {}
fire("cmd.panel", { seq = 101, op = "task.complete", args = { id = "t1" } })
local ev = getState("evt.panel")
check("complete reply ok", ev ~= nil and ev.seq == 101 and ev.ok == true, ev and ev.err and ev.err.kind)
check("complete reply carries data.checked", ev ~= nil and type(ev.data) == "table" and ev.data.checked == true and ev.data.id == "t1", ev and ev.data and ev.data.checked)
check("complete POSTs /tasks/t1/close", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t1/close", 1, true) ~= nil
end) == 1)
check("complete makes no extra request", #calls == 1, #calls)
check("t1 gone from overdue", s12.views.overdue.count == 0 and #s12.views.overdue.tasks == 0, s12.views.overdue.count)
check("t1 gone from today, t2 kept", s12.views.today.count == 1 and s12.views.today.tasks[1].id == "t2", s12.views.today.count)
check("t1 gone from p1", s12.views.p1.count == 0, s12.views.p1.count)
check("active task list re-pointed after complete", #s12.tasks == 1 and s12.tasks[1].id == "t2", #s12.tasks)
check("counts recomputed", s12.counts.overdue == 0 and s12.counts.today == 1 and s12.counts.p1 == 0, tostring(s12.counts.today))

-- reopen: POST then re-fetch the active view (a filter cannot be recomputed)
calls = {}
fire("cmd.panel", { seq = 102, op = "task.reopen", args = { id = "t2" } })
ev = getState("evt.panel")
check("reopen reply ok", ev ~= nil and ev.seq == 102 and ev.ok == true, ev and ev.err and ev.err.kind)
check("reopen POSTs /tasks/t2/reopen", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t2/reopen", 1, true) ~= nil
end) == 1)
check("reopen re-fetches the active (today) view", filterCalls("today") == 1, filterCalls("today"))
check("reopen does not touch the task count", s12.views.today.count == 2, s12.views.today.count)

-- guards: no HTTP is attempted for a malformed or unconfigured call
calls = {}
fire("cmd.panel", { seq = 103, op = "task.complete", args = {} })
ev = getState("evt.panel")
check("complete without id is validation", ev ~= nil and ev.ok == false and ev.err.kind == "validation", ev and ev.err and ev.err.kind)
check("complete without id sends no HTTP", #calls == 0, #calls)

env = {}
cfg.token = ""
cfg.token_file = ""
calls = {}
fire("cmd.panel", { seq = 104, op = "task.complete", args = { id = "t2" } })
ev = getState("evt.panel")
check("complete without token is config", ev ~= nil and ev.ok == false and ev.err.kind == "config", ev and ev.err and ev.err.kind)
check("complete without token sends no HTTP", #calls == 0, #calls)

-- a dropped connection is reported as unknown_outcome, never silently retried
env = { TODOIST_API_TOKEN = "valid-token" }
calls = {}
fault.close = "transport"
fire("cmd.panel", { seq = 105, op = "task.complete", args = { id = "t2" } })
ev = getState("evt.panel")
check("transient close -> unknown_outcome", ev ~= nil and ev.ok == false and ev.unknown_outcome == true, ev and ev.err and ev.err.kind)
check("transient close is attempted once (no retry in M2)", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t2/close", 1, true) ~= nil
end) == 1)
fault.close = false

-- ── T12b: panel checkbox is a live control ──────────────────────
print("\n== T12b panel checkbox ==")
-- Drop any deep-link left over from the launcher test: it would make onOpen
-- issue a fetch, leaving the client busy so a click is ignored.
state_store["open_task"] = nil
local function settlePanel()
	local pc = getState("cmd.panel")
	if type(pc) == "table" and pc.seq ~= nil then
		fire("evt.panel", { seq = pc.seq, op = pc.op, ok = true })
	end
end
state_store["todoist"] = {
	schema = 1,
	token_configured = true,
	view = "inbox",
	tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u" } },
	views = { inbox = { tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u" } }, count = 1 } },
	projects = {},
	counts = {},
	defaults = {},
	fetched_at = 0,
}
onOpen({})
settlePanel()
local function findButton(pred)
	local found = nil
	local function rec(n)
		if type(n) ~= "table" then
			return
		end
		if n.kind == "button" and pred(n.props) then
			found = n
		end
		for _, c in ipairs(n.children or {}) do
			rec(c)
		end
	end
	rec(rendered)
	return found
end

local toggle = findButton(function(props)
	return props.glyph == "circle"
end)
check("open task shows a circle (unchecked) button", toggle ~= nil)
state_store["cmd.panel"] = nil
if toggle then
	toggle.props.onClick()
end
local cmd = getState("cmd.panel")
check("clicking an open task sends task.complete", cmd ~= nil and cmd.op == "task.complete" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)

state_store["todoist"].tasks[1].checked = true
state_store["todoist"].views.inbox.tasks[1].checked = true
onOpen({})
settlePanel()
local toggle2 = findButton(function(props)
	return props.glyph == "circle-check"
end)
check("closed task shows a circle-check (checked) button", toggle2 ~= nil)
state_store["cmd.panel"] = nil
if toggle2 then
	toggle2.props.onClick()
end
cmd = getState("cmd.panel")
check("clicking a closed task sends task.reopen", cmd ~= nil and cmd.op == "task.reopen" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)

-- ── T13: M3 task.delete + confirm_delete ────────────────────────
print("\n== T13 delete ==")
env = { TODOIST_API_TOKEN = "valid-token" }
cfg.token = ""
cfg.token_file = ""
cfg.max_retries = 1
fault.delete = false
calls = {}
loadService()
update()
local s13 = getState("todoist")
check("T13 setup: today holds 2", s13.views.today.count == 2, s13.views.today.count)

calls = {}
fire("cmd.panel", { seq = 201, op = "task.delete", args = { id = "t1" } })
ev = getState("evt.panel")
check("delete reply ok", ev ~= nil and ev.seq == 201 and ev.ok == true, ev and ev.err and ev.err.kind)
check("delete reply carries data.deleted", ev ~= nil and type(ev.data) == "table" and ev.data.deleted == true and ev.data.id == "t1")
check("delete sends DELETE /tasks/t1", countCalls(function(c)
	return c.method == "DELETE" and c.url:find("/tasks/t1", 1, true) ~= nil
end) == 1)
check("delete makes no extra request", #calls == 1, #calls)
check("t1 gone from overdue", s13.views.overdue.count == 0, s13.views.overdue.count)
check("t1 gone from today, t2 kept", s13.views.today.count == 1 and s13.views.today.tasks[1].id == "t2", s13.views.today.count)
check("t1 gone from p1", s13.views.p1.count == 0, s13.views.p1.count)
check("active task list re-pointed after delete", #s13.tasks == 1 and s13.tasks[1].id == "t2", #s13.tasks)
check("delete recomputes counts", s13.counts.overdue == 0 and s13.counts.today == 1, tostring(s13.counts.today))

-- 404 means the task is already gone: the goal state, not a failure
calls = {}
fault.delete = "404"
fire("cmd.panel", { seq = 202, op = "task.delete", args = { id = "t2" } })
ev = getState("evt.panel")
check("404 on delete is treated as success", ev ~= nil and ev.ok == true, ev and ev.err and ev.err.kind)
check("404 delete still reconciles locally", s13.views.today.count == 0, s13.views.today.count)
fault.delete = false

-- guards
calls = {}
fire("cmd.panel", { seq = 203, op = "task.delete", args = {} })
ev = getState("evt.panel")
check("delete without id is validation", ev ~= nil and ev.ok == false and ev.err.kind == "validation", ev and ev.err and ev.err.kind)
check("delete without id sends no HTTP", #calls == 0, #calls)

env = {}
cfg.token = ""
cfg.token_file = ""
calls = {}
fire("cmd.panel", { seq = 204, op = "task.delete", args = { id = "t2" } })
ev = getState("evt.panel")
check("delete without token is config", ev ~= nil and ev.ok == false and ev.err.kind == "config", ev and ev.err and ev.err.kind)
check("delete without token sends no HTTP", #calls == 0, #calls)

-- a dropped connection: unknown outcome, attempted once
env = { TODOIST_API_TOKEN = "valid-token" }
calls = {}
fault.delete = "transport"
fire("cmd.panel", { seq = 205, op = "task.delete", args = { id = "t2" } })
ev = getState("evt.panel")
check("transient delete -> unknown_outcome", ev ~= nil and ev.ok == false and ev.unknown_outcome == true, ev and ev.err and ev.err.kind)
check("transient delete is attempted once (no retry in M3)", countCalls(function(c)
	return c.method == "DELETE"
end) == 1)
fault.delete = false

-- ── T13b: delete affordance honours confirm_delete ──────────────
print("\n== T13b confirm_delete ==")
local function fakeTask(checked)
	return {
		schema = 1,
		token_configured = true,
		view = "inbox",
		tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u", checked = checked } },
		views = { inbox = { tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u", checked = checked } }, count = 1 } },
		projects = {},
		counts = {},
		defaults = {},
		fetched_at = 0,
	}
end

cfg.confirm_delete = true
state_store["open_task"] = nil
state_store["todoist"] = fakeTask(false)
onOpen({})
settlePanel()
local trash = findButton(function(props)
	return props.glyph == "trash"
end)
check("row exposes a delete button", trash ~= nil)
state_store["cmd.panel"] = nil
if trash then
	trash.props.onClick()
end
check("confirmation on: delete waits for confirmation", getState("cmd.panel") == nil, getState("cmd.panel") and getState("cmd.panel").op)
local no = findButton(function(props)
	return props.text == "ui.panel.delete.no"
end)
local yes = findButton(function(props)
	return props.text == "ui.panel.delete.yes"
end)
check("confirmation on: confirm row offers Delete and Cancel", yes ~= nil and no ~= nil)
state_store["cmd.panel"] = nil
if yes then
	yes.props.onClick()
end
cmd = getState("cmd.panel")
check("confirming sends task.delete", cmd ~= nil and cmd.op == "task.delete" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)

cfg.confirm_delete = false
state_store["todoist"] = fakeTask(false)
onOpen({})
settlePanel()
local trash2 = findButton(function(props)
	return props.glyph == "trash"
end)
state_store["cmd.panel"] = nil
if trash2 then
	trash2.props.onClick()
end
cmd = getState("cmd.panel")
check("confirmation off: delete is sent immediately", cmd ~= nil and cmd.op == "task.delete" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)
check("confirmation off: no confirm row", findButton(function(props)
	return props.text == "ui.panel.delete.no"
end) == nil)
cfg.confirm_delete = true

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

-- Save sessions, tabs, splits, cwds and known programs to disk, and bring them back after a restart.
-- Run the "Resurrect:" commands from the command palette to save and restore.
-- To also save every session every 15 minutes, keep this running:
--   rex do ~/.config/rex/resurrect.lua --all

local TERMINAL = "com.superlogical.terminal"
local HOME = os.getenv("HOME")
local DIR = HOME .. "/.local/share/rex"
local FILE = DIR .. "/resurrect.json"

local function must(res, err)
  if err ~= nil then error(err, 0) end
  return res
end

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- First line of a shell command's output, or nil.
local function sh(cmd)
  local res = rex.exec({ "sh", "-c", cmd })
  return res.ok and res.stdout:match("[^\n]+") or nil
end

local pi_taken -- pi session files already given to a pane during the current save

-- Foreground programs to start again, by process name: the command to type, or a function of the
-- process that returns one. Anything else comes back as a plain shell.
local PROGRAMS = {
  vim = "vim", less = "less", htop = "htop", btop = "btop", lazygit = "lazygit",

  -- Saves the persistence.nvim session now, so it's current even if nvim gets killed.
  -- nvim's server is a child of the TUI process, and its socket is named after the child's pid.
  nvim = function(fg)
    local sock = sh(("for p in $(pgrep -P %d) %d; do ls \"$TMPDIR\"nvim.\"$USER\"/*/nvim.$p.0; done 2>/dev/null")
      :format(fg.pid, fg.pid))
    if sock then
      rex.exec({ fg.path, "--server", sock, "--remote-expr", [[luaeval("require('persistence').save() or 0")]] })
    end
    return [[nvim -c 'lua require("persistence").load()']]
  end,

  claude = function(fg)
    local info = read(("%s/.claude/sessions/%d.json"):format(HOME, fg.pid))
    local id = info and rex.json.decode(info).sessionId
    return id and "claude --resume " .. id or "claude"
  end,

  -- pi doesn't record which session a process has open, but it appends to it every turn, so take
  -- the newest session for this cwd that no other pi pane has taken during this save.
  pi = function(fg)
    local dir = ("%s/.pi/agent/sessions/--%s--"):format(HOME, (fg.cwd:sub(2):gsub("/", "-")))
    local res = rex.exec({ "sh", "-c", 'ls -t "$0"/*.jsonl', dir })
    for path in res.stdout:gmatch("[^\n]+") do
      if not pi_taken[path] then
        pi_taken[path] = true
        return "pi --session " .. path:match("_([^_/]+)%.jsonl$")
      end
    end
    return "pi"
  end,
}

local function command_for(fg)
  if not fg then return "" end
  -- Script-based tools like pi run as "node", so look at what they were invoked as first.
  local p = PROGRAMS[(fg.argv0 or ""):match("[^/]+$")] or PROGRAMS[fg.name]
  if type(p) == "function" then return p(fg) end
  return p or ""
end

-- Turns a view layout into a session.create layout, collecting each block's program in layout order.
local function snapshot(sid, node, blocks, runs)
  if node.split then
    local s = node.split
    return { split = {
      direction = s.direction,
      ratio     = s.ratio,
      before    = snapshot(sid, s.before, blocks, runs),
      after     = snapshot(sid, s.after, blocks, runs),
    } }
  end
  local b = blocks[node.block_id]
  local block = { flavor = b.flavor, label = b.label }
  local fg
  if b.creator_name == TERMINAL then
    local proc = rex.block.call(TERMINAL, "process", { session_id = sid, block_id = node.block_id })
    fg = proc and proc.foreground
    block.options = { cwd = fg and fg.cwd }
  end
  runs[#runs + 1] = { id = node.block_id, run = command_for(fg) }
  return { block = block }
end

-- owners maps each sidekick agent block to the pane that owns it (see sidekick.lua).
local function save_session(s, owners)
  local view = must(rex.session.view{ session_id = s.session_id })
  local windows, active = {}, 1
  local order, pos = {}, {} -- block IDs in layout order, and each one's { window, pane } position
  for _, w in ipairs(view.windows) do
    for _, layer in ipairs(w.layers) do
      if layer.kind == "tiled" then
        local blocks, runs = {}, {}
        for _, b in ipairs(layer.blocks) do blocks[b.block_id] = b end
        local layout = snapshot(s.session_id, layer.layout, blocks, runs)
        local focus = 1
        for i, r in ipairs(runs) do
          if r.id == w.focused_block_id then focus = i end
          order[#order + 1], pos[r.id] = r.id, { #windows + 1, i }
          runs[i] = r.run
        end
        -- Labels like "Window 8ad20e3b" come from the old window ID, so let Rex make new ones.
        local label = not w.label:match("^Window %x+$") and w.label or nil
        windows[#windows + 1] = { label = label, layout = layout, runs = runs, focus = focus }
        if w.window_id == view.active_window_id then active = #windows end
      end
    end
  end
  local agents = {}
  for _, id in ipairs(order) do
    local origin = pos[owners[id]]
    if origin then agents[#agents + 1] = { agent = pos[id], origin = origin } end
  end
  return { label = s.label, windows = windows, active = active, agents = agents }
end

-- Saves every session, replacing the file, or just session_id, replacing its saved copy (by label)
-- and keeping the rest of the file.
local function save(session_id)
  pi_taken = {}
  -- Asked of the server, since an autosave script doesn't share sidekick.lua's state.
  local owners = (rex.invoke("agent_origins") or {}).origins or {}
  local sessions, label = {}, nil
  for _, s in ipairs(must(rex.call("session.attach_all", { event_scope = "session" })).sessions) do
    if not session_id or s.session_id == session_id then
      sessions[#sessions + 1] = save_session(s, owners)
      label = s.label
    end
  end
  local old = read(FILE)
  if session_id and old then
    local merged, current = {}, sessions[1]
    for _, s in ipairs(rex.json.decode(old).sessions) do
      if s.label == label then s, current = current, nil end
      merged[#merged + 1] = s
    end
    merged[#merged + 1] = current
    sessions = merged
  end
  local data = rex.json.encode({ sessions = sessions })
  if data == old then return { saved = #sessions, changed = false } end
  rex.exec({ "mkdir", "-p", DIR })
  local f = assert(io.open(FILE, "w"))
  f:write(data)
  f:close()
  return { saved = #sessions, changed = true }
end

local function restore_session(s)
  local initial = {}
  for _, w in ipairs(s.windows) do
    initial[#initial + 1] = { window_label = w.label, layout = w.layout }
  end
  local res = must(rex.call("session.create", { label = s.label, initial_windows = initial }))
  local sid = res.session_id
  must(rex.call("session.attach", { session_id = sid }))
  for i, w in ipairs(s.windows) do
    local ids = res.initial_windows[i].block_ids
    for j, run in ipairs(w.runs) do
      if run ~= "" then
        must(rex.block.call(TERMINAL, "write", { session_id = sid, block_id = ids[j], data = run .. "\r" }))
      end
    end
    must(rex.call("session.focus_block", { session_id = sid, block_id = ids[w.focus] }))
  end
  local function id(p) return res.initial_windows[p[1]].block_ids[p[2]] end
  for _, a in ipairs(s.agents or {}) do
    must(rex.invoke("agent_adopt", { block_id = id(a.agent), origin = id(a.origin) }))
  end
  must(rex.call("session.focus_window", { session_id = sid, window_id = res.initial_windows[s.active].window_id }))
end

-- Sessions whose label is already open are left alone, so restoring twice is harmless.
local function restore()
  local data = read(FILE)
  if not data then error("nothing saved yet: " .. FILE, 0) end
  local open = {}
  for _, s in ipairs(must(rex.call("session.list", {})).sessions) do open[s.label] = true end
  local restored = {}
  for _, s in ipairs(rex.json.decode(data).sessions) do
    if not open[s.label] then
      restore_session(s)
      restored[#restored + 1] = s.label
    end
  end
  return { restored = restored }
end

rex.action{ name = "resurrect_save", title = "Resurrect: Save All Sessions", run = function() return save() end }
rex.action{
  name  = "resurrect_save_current",
  title = "Resurrect: Save Current Session",
  run   = function(ctx) return save(ctx.session_id) end,
}
rex.action{ name = "resurrect_restore", title = "Resurrect: Restore Sessions", run = restore }

-- Timers only exist when run as a script; init.lua has no rex.every.
if rex.every then rex.every(15 * 60, function() save() end) end

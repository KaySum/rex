-- Agent splits: agent TUIs (claude, pi, ...) in a pane labeled "agent:<name>".
-- nvim's sidekick drives these through ~/.config/nvim/lua/sidekick_rex.lua.

local TERMINAL = "com.superlogical.terminal"
local origins = {} -- agent block -> { block = pane it was opened from, nvim = { progpath, servername } }

local function must(res, err)
  if err ~= nil then error(err, 0) end
  return res
end

local function blocks()
  local ret = {}
  for _, w in ipairs(must(rex.session.view{}).windows) do
    for _, layer in ipairs(w.layers) do
      for _, b in ipairs(layer.blocks) do
        ret[#ret + 1] = { window = w, block = b, agent = (b.label or ""):match("^agent:(.+)") }
      end
    end
  end
  return ret
end

local function find(block_id)
  for _, e in ipairs(blocks()) do
    if e.block.block_id == block_id then return e end
  end
end

local function agent_in(window_id)
  for _, e in ipairs(blocks()) do
    if e.agent and e.window.window_id == window_id then return e.block.block_id end
  end
end

-- The pane the agent was opened from, or another pane in its tab if that one is gone.
local function origin_of(agent)
  local window_id = find(agent).window.window_id
  local origin = origins[agent] and find(origins[agent].block)
  if origin and origin.window.window_id == window_id then return origin.block.block_id end
  for _, e in ipairs(blocks()) do
    if not e.agent and e.window.window_id == window_id then return e.block.block_id end
  end
end

-- The nvim pane that owns the agent, while nvim still runs there. Others can't attach to it.
local function owner_of(agent)
  local o = origins[agent]
  local proc = o and find(o.block) and rex.block.call(TERMINAL, "process", { block_id = o.block })
  local name = proc and proc.foreground and proc.foreground.name or ""
  if name:find("nvim", 1, true) then return o.block end
end

local function blur(agent)
  local target = origin_of(agent)
  if target then must(rex.session.focus_block{ block_id = target }) end
end

rex.action{
  name  = "agent_open",
  title = "Open Agent Split",
  args  = { name = "string", cmd = "array", cwd = "string?", nvim = "array?" },
  run   = function(ctx, args)
    local res = must(rex.session.new_split{
      anchor_id = ctx.block_id,
      direction = "horizontal",
      side      = "after",
      ratio     = 0.6,
      focus     = true,
      layout    = { block = {
        flavor  = TERMINAL .. ".shell",
        label   = "agent:" .. args.name,
        options = { command = args.cmd, cwd = args.cwd },
      } },
    })
    local agent = res.block_ids[1]
    origins[agent] = { block = ctx.block_id, nvim = args.nvim }
    return { block_id = agent }
  end,
}

-- Brings a running agent beside the calling pane (moving it from another tab if needed) and focuses it.
rex.action{
  name  = "agent_attach",
  title = "Attach Agent Split",
  args  = { block_id = "string", nvim = "array?" },
  run   = function(ctx, args)
    local agent, here = find(args.block_id), find(ctx.block_id)
    if not (agent and here) then error("agent or calling pane not found", 0) end
    local owner = owner_of(args.block_id)
    if owner and owner ~= ctx.block_id then error("agent belongs to another nvim", 0) end
    if agent.window.window_id ~= here.window.window_id then
      must(rex.session.move_block{
        block_id        = args.block_id,
        anchor_block_id = ctx.block_id,
        direction       = "horizontal",
        side            = "after",
        ratio           = 0.6,
      })
    end
    must(rex.session.focus_block{ block_id = args.block_id })
    origins[args.block_id] = { block = ctx.block_id, nvim = args.nvim }
  end,
}

rex.action{
  name  = "agent_list",
  title = "List Agent Splits",
  run   = function()
    local agents = {}
    for _, e in ipairs(blocks()) do
      if e.agent then
        local id = e.block.block_id
        local proc = rex.block.call(TERMINAL, "process", { block_id = id })
        local cwd = proc and proc.foreground and proc.foreground.cwd
        agents[#agents + 1] = {
          block_id = id, name = e.agent, cwd = cwd, window_id = e.window.window_id, owner = owner_of(id),
        }
      end
    end
    return { agents = agents }
  end,
}

rex.action{
  name  = "agent_send",
  title = "Send Text to Agent",
  args  = { block_id = "string", text = "string", paste = "boolean?" },
  run   = function(_, args)
    local text = args.text
    if args.paste then
      local modes = rex.block.call(TERMINAL, "modes", { block_id = args.block_id })
      for _, m in ipairs(modes and modes.modes or {}) do
        if m.name == "bracketed_paste" and m.set then text = "\27[200~" .. text .. "\27[201~" end
      end
    end
    must(rex.session.focus_block{ block_id = args.block_id })
    must(rex.block.call(TERMINAL, "write", { block_id = args.block_id, data = text }))
  end,
}

-- From the agent: zoom the pane it came from (hides the agent). Elsewhere: focus the tab's agent.
rex.action{
  name  = "agent_toggle",
  title = "Toggle Agent Split",
  run   = function(ctx)
    local here = find(ctx.block_id)
    local agent = here and agent_in(here.window.window_id)
    if not agent then return { agent = false } end
    if ctx.block_id == agent then
      local target = origin_of(agent)
      if target then must(rex.session.zoom_block{ block_id = target, zoom = true }) end
    else
      must(rex.session.focus_block{ block_id = agent })
    end
    return { agent = true }
  end,
}

-- Closes the agent agent_toggle would switch to, and returns focus to the pane it came from.
rex.action{
  name  = "agent_close",
  title = "Close Agent Split",
  run   = function(ctx)
    local here = find(ctx.block_id)
    local agent = here and agent_in(here.window.window_id)
    if not agent then return { agent = false } end
    blur(agent)
    must(rex.call("block.close", { session_id = ctx.session_id, block_id = agent }))
    origins[agent] = nil
    return { agent = true, block_id = agent }
  end,
}

-- Opens a sidekick picker in the agent's nvim; the picked items are sent back to the agent.
local function nvim_picker(source)
  return function(ctx)
    local origin = origins[ctx.block_id]
    if not (origin and origin.nvim) then return false end
    blur(ctx.block_id)
    local lua = ("require('sidekick.cli.picker').open(%q, { filter = { session = %q } })"):format(source, "rex: " .. ctx.block_id)
    rex.exec({ origin.nvim[1], "--server", origin.nvim[2], "--remote-send", "<cmd>lua " .. lua .. "<cr>" })
    return true
  end
end

-- nvim panes that turned the override off (:SidekickRex off). Rex leaves keys alone in them and in
-- the agents they own, as if none of this existed.
local paused = {}

rex.action{
  name  = "agent_override",
  title = "Set Agent Override",
  args  = { enabled = "boolean" },
  run   = function(ctx, args)
    paused[ctx.block_id] = not args.enabled or nil
  end,
}

local function is_paused(block_id)
  local o = origins[block_id]
  return paused[block_id] or (o ~= nil and paused[o.block]) or false
end

-- Keys that only apply while an agent pane has focus, like sidekick's terminal keymaps.
local function in_agent(fn)
  return function(ctx, ev)
    local e = find(ctx.block_id)
    if not (e and e.agent) or is_paused(ctx.block_id) then return false end
    return fn(ctx, ev) ~= false
  end
end

-- With no agent in the tab, ctrl+. falls through to nvim, which shows the agent picker.
rex.bind("ctrl+.", function(ctx)
  if is_paused(ctx.block_id) then return false end
  local res = rex.invoke("agent_toggle")
  return res ~= nil and res.agent
end)
rex.bind("ctrl+z", in_agent(function(ctx) blur(ctx.block_id) end))
rex.bind("ctrl+h", in_agent(function(ctx) blur(ctx.block_id) end))
rex.bind("ctrl+f", in_agent(nvim_picker("files")))
rex.bind("ctrl+b", in_agent(nvim_picker("buffers")))

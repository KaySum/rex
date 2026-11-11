-- cmd+t opens the new tab right after the current one instead of at the end.

local TERMINAL = "com.superlogical.terminal"

local function must(res, err)
  if err ~= nil then error(err, 0) end
  return res
end

rex.bind("cmd+t", function(ctx)
  local windows = must(rex.session.view{}).windows
  local next_id
  for i, w in ipairs(windows) do
    for _, layer in ipairs(w.layers) do
      for _, b in ipairs(layer.blocks) do
        if b.block_id == ctx.block_id then next_id = windows[i + 1] and windows[i + 1].window_id end
      end
    end
  end

  local proc = ctx.block_id and rex.block.call(TERMINAL, "process", { block_id = ctx.block_id })
  local cwd = proc and proc.foreground and proc.foreground.cwd
  local res = must(rex.session.new_window{
    layout = { block = { flavor = TERMINAL .. ".shell", options = { cwd = cwd } } },
  })
  if next_id then
    must(rex.session.move_window{ window_id = res.window_id, before_window_id = next_id })
  end
end)

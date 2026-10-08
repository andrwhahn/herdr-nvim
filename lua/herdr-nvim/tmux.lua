-- tmux backend: find agent panes and deliver text to them when nvim runs
-- inside tmux instead of herdr. Mirrors the shape of herdr-nvim.agents /
-- herdr-nvim.dispatch so init.lua does not need to know which one is active.
local M = {}
local exec_mod = require("herdr-nvim.exec")

-- Process basenames recognized as coding agents.
M.known_agents = { "claude", "codex", "opencode", "gemini", "aider", "cursor-agent", "pi" }

-- Use tmux only outside herdr: a herdr pane may itself run under tmux, and
-- herdr's own agent API knows more (status, sessions) than a process scan.
function M.active()
  return vim.env.HERDR_ENV ~= "1" and (vim.env.TMUX or "") ~= ""
end

local function fail(what, r)
  return what .. " failed: " .. ((r.stderr or "") ~= "" and vim.trim(r.stderr) or ("exit " .. r.code))
end

-- The agent an argv belongs to, or nil. Checks the first two tokens so both
-- `claude --resume x` and `node /…/@anthropic-ai/claude-code/cli.js` match.
-- (Claude renames its process title to its version, so tmux's
-- #{pane_current_command} cannot be used.)
function M.agent_kind(args)
  local i = 0
  for token in args:gmatch("%S+") do
    i = i + 1
    if i > 2 then break end
    local lower = token:lower()
    if lower:match("claude%-code") then return "claude" end
    local base = vim.fn.fnamemodify(lower, ":t"):gsub("%.[cm]?js$", "")
    for _, kind in ipairs(M.known_agents) do
      if base == kind then return kind end
    end
  end
  return nil
end

-- tty (as ps prints it, e.g. "ttys003" or "pts/3") -> agent kind.
local function agent_ttys(exec)
  local r = exec({ "ps", "-ax", "-o", "tty=,args=" })
  if r.code ~= 0 then return nil, fail("ps", r) end
  local out = {}
  for line in r.stdout:gmatch("[^\n]+") do
    local tty, args = line:match("^%s*(%S+)%s+(.*)$")
    if tty and tty ~= "?" and tty ~= "??" and not out[tty] then
      out[tty] = M.agent_kind(args)
    end
  end
  return out
end

local FIELDS = "#{pane_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_tty}\t#{pane_current_path}"

function M.list(exec)
  exec = exec or exec_mod.default_exec
  local r = exec({ "tmux", "list-panes", "-a", "-F", FIELDS })
  if r.code ~= 0 then return nil, fail("tmux list-panes", r) end
  local ttys, err = agent_ttys(exec)
  if not ttys then return nil, err end
  local out = {}
  for line in r.stdout:gmatch("[^\n]+") do
    local pane, session, window, index, name, tty, cwd =
      line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    local kind = tty and ttys[(tty:gsub("^/dev/", ""))]
    if kind and pane ~= vim.env.TMUX_PANE then
      table.insert(out, {
        pane_id = pane,
        workspace_id = session,
        tab_id = window,
        kind = kind,
        status = "unknown", -- tmux has no agent state; skip the "working" warning
        cwd = cwd,
        title = string.format("%s:%s %s", session, index, name),
      })
    end
  end
  table.sort(out, function(x, y) return x.title < y.title end)
  return out
end

-- The tmux window nvim itself runs in, so the sibling agent wins without a picker.
function M.current_tab(exec)
  exec = exec or exec_mod.default_exec
  local pane = vim.env.TMUX_PANE
  if not pane or pane == "" then return nil end
  local r = exec({ "tmux", "display-message", "-p", "-t", pane, "#{window_id}" })
  if r.code ~= 0 then return nil end
  local id = vim.trim(r.stdout)
  return id ~= "" and id or nil
end

-- Paste through a named buffer with -p (bracketed paste), so a multi-line
-- message lands as one paste and its newlines do not submit it early.
function M.send(pane_id, text, opts, exec)
  opts = opts or {}
  exec = exec or exec_mod.default_exec
  local buffer = "herdr-nvim-" .. vim.fn.getpid()
  local r = exec({ "tmux", "load-buffer", "-b", buffer, "-" }, { stdin = text })
  if r.code ~= 0 then return false, fail("tmux load-buffer", r) end
  r = exec({ "tmux", "paste-buffer", "-p", "-d", "-b", buffer, "-t", pane_id })
  if r.code ~= 0 then return false, fail("tmux paste-buffer", r) end
  if opts.submit then
    -- Give the agent a moment to finish taking the paste before Enter.
    if not opts.no_delay then vim.uv.sleep(150) end
    r = exec({ "tmux", "send-keys", "-t", pane_id, "Enter" })
    if r.code ~= 0 then return false, fail("tmux send-keys", r) end
  end
  return true
end

return M

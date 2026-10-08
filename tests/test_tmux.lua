local tmux = require("herdr-nvim.tmux")
local agents = require("herdr-nvim.agents")
local dispatch = require("herdr-nvim.dispatch")

-- Run `fn` as if nvim were inside tmux (not herdr), restoring the env after.
local function in_tmux(fn)
  local saved = { TMUX = vim.env.TMUX, TMUX_PANE = vim.env.TMUX_PANE, HERDR_ENV = vim.env.HERDR_ENV }
  vim.env.TMUX = "/tmp/tmux-501/default,1,0"
  vim.env.TMUX_PANE = "%1"
  vim.env.HERDR_ENV = nil
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do vim.env[k] = v end
  if not ok then error(err, 0) end
end

local panes = table.concat({
  "%1\twork\t@1\t1\tnvim\t/dev/ttys001\t/repo",
  "%2\twork\t@1\t1\tnvim\t/dev/ttys002\t/repo",
  "%3\twork\t@2\t2\tshell\t/dev/ttys003\t/repo",
  "%4\tother\t@3\t1\tapi\t/dev/pts/4\t/srv/api",
}, "\n")
local ps = table.concat({
  "ttys001  nvim lua/x.lua",
  "ttys002  /opt/homebrew/Caskroom/claude-code/2.1.285/claude --resume abc",
  "ttys003  -zsh",
  "pts/4    node /usr/lib/node_modules/@openai/codex/bin/codex.js",
  "??       /Users/me/.codex/bin/codex app-server daemon",
}, "\n")

local function fake_exec(window)
  local calls = {}
  return calls, function(argv, opts)
    table.insert(calls, { argv = argv, stdin = opts and opts.stdin })
    if argv[1] == "tmux" and argv[2] == "list-panes" then return { code = 0, stdout = panes, stderr = "" } end
    if argv[1] == "ps" then return { code = 0, stdout = ps, stderr = "" } end
    if argv[2] == "display-message" then return { code = 0, stdout = (window or "@1") .. "\n", stderr = "" } end
    return { code = 0, stdout = "", stderr = "" }
  end
end

T.test("tmux: active only inside tmux and outside herdr", function()
  in_tmux(function()
    T.ok(tmux.active())
    vim.env.HERDR_ENV = "1"
    T.eq(tmux.active(), false)
    vim.env.HERDR_ENV = nil
    vim.env.TMUX = nil
    T.eq(tmux.active(), false)
  end)
end)

T.test("tmux: agent_kind recognizes binaries and node entry points", function()
  T.eq(tmux.agent_kind("/opt/homebrew/Caskroom/claude-code/2.1.285/claude --resume x"), "claude")
  T.eq(tmux.agent_kind("claude"), "claude")
  T.eq(tmux.agent_kind("node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "claude")
  T.eq(tmux.agent_kind("node /usr/lib/node_modules/@openai/codex/bin/codex.js"), "codex")
  T.eq(tmux.agent_kind("-zsh"), nil)
  T.eq(tmux.agent_kind("nvim notes/claude.md"), nil) -- only argv0/argv1 count
end)

T.test("tmux: list finds agent panes across sessions, skips nvim's own pane", function()
  in_tmux(function()
    local _, exec = fake_exec()
    local list, err = agents.list(exec)
    T.eq(err, nil)
    T.eq(#list, 2)
    local by_pane = {}
    for _, a in ipairs(list) do by_pane[a.pane_id] = a end
    T.eq(by_pane["%2"].kind, "claude")
    T.eq(by_pane["%2"].tab_id, "@1")
    T.eq(by_pane["%2"].cwd, "/repo")
    T.eq(by_pane["%4"].kind, "codex") -- Linux pts/N tty
    T.eq(by_pane["%4"].title, "other:1 api")
    T.eq(by_pane["%1"], nil)
  end)
end)

T.test("tmux: resolve prefers the lone agent in nvim's window", function()
  in_tmux(function()
    local _, exec = fake_exec("@1")
    local list = agents.list(exec)
    T.eq(agents.resolve(list, exec).pane_id, "%2")
    local _, exec_elsewhere = fake_exec("@9")
    T.eq(agents.resolve(list, exec_elsewhere), nil) -- ambiguous: picker
  end)
end)

T.test("tmux: paste uses a bracketed paste buffer and no Enter", function()
  in_tmux(function()
    local calls, exec = fake_exec()
    T.ok(dispatch.send("%2", "line1\nline2", { submit = false }, exec))
    T.eq(#calls, 2)
    T.eq(calls[1].argv[2], "load-buffer")
    T.eq(calls[1].stdin, "line1\nline2")
    T.eq({ calls[2].argv[2], calls[2].argv[3], calls[2].argv[#calls[2].argv] }, { "paste-buffer", "-p", "%2" })
  end)
end)

T.test("tmux: submit pastes then presses Enter", function()
  in_tmux(function()
    local calls, exec = fake_exec()
    T.ok(dispatch.send("%2", "hi", { submit = true, no_delay = true }, exec))
    T.eq(#calls, 3)
    T.eq(calls[3].argv, { "tmux", "send-keys", "-t", "%2", "Enter" })
  end)
end)

T.test("tmux: failed paste reports the tmux error", function()
  in_tmux(function()
    local ok, err = dispatch.send("%2", "hi", {}, function(argv)
      if argv[2] == "paste-buffer" then return { code = 1, stdout = "", stderr = "can't find pane: %2" } end
      return { code = 0, stdout = "", stderr = "" }
    end)
    T.eq(ok, false)
    T.ok(err:match("can't find pane"))
  end)
end)

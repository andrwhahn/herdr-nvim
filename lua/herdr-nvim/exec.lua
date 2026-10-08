local M = {}

function M.default_exec(argv, opts)
  local r = vim.system(argv, { text = true, stdin = opts and opts.stdin }):wait()
  return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "" }
end

return M

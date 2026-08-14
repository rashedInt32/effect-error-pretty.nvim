-- effect-error-pretty.nvim
-- Effect-first TypeScript diagnostic formatter for Neovim.

local parse = require("effect-error-pretty.parse")
local render = require("effect-error-pretty.render")

local M = {}

M.parse = parse.parse
M.is_ts_source = parse.is_ts_source

---@class EffectErrorPretty.Config
---@field effect? boolean          Enable Effect<A,E,R> / Stream / Layer parsing. Default: true.
---@field sources? table<string, boolean>  Diagnostic sources to format. Merged with the defaults ({ typescript, ts, vtsls, effect }); set one to false to drop it.
---@field format_ts_errors_fallback? boolean  Use format-ts-errors when no pattern matches. Default: true.
---@field extra_patterns? (fun(msg: string): table|nil)[]  User-defined parsers, run after builtins.
---@field float? boolean           Patch vim.diagnostic.config({ float = { format } }) in setup. Default: false.

---@type EffectErrorPretty.Config
local defaults = {
  effect = true,
  sources = parse.default_sources,
  format_ts_errors_fallback = true,
  extra_patterns = nil,
  float = false,
}

local state = { opts = vim.deepcopy(defaults) }

-- A formatter crash must not take the float down with it: vim.diagnostic calls
-- `format` for every diagnostic in the window, so one error blanks the whole
-- float — including diagnostics from other sources entirely.
local notified = {}
local function guard(fn, diagnostic, opts)
  local ok, result = pcall(fn, diagnostic, opts)
  if ok then
    return result
  end
  local err = tostring(result)
  if not notified[err] then
    notified[err] = true
    vim.schedule(function()
      vim.notify("[effect-error-pretty] formatter error: " .. err, vim.log.levels.WARN)
    end)
  end
  return nil
end

local function parse_opts()
  return {
    effect = state.opts.effect,
    extra_patterns = state.opts.extra_patterns,
  }
end

local function source_allowed(source)
  local allowed = state.opts.sources or parse.default_sources
  return parse.is_ts_source(source, allowed)
end

local function ts_errors_fallback(diagnostic)
  if not state.opts.format_ts_errors_fallback then
    return nil
  end
  local ok, formatter = pcall(require, "format-ts-errors")
  if not ok or not diagnostic.code then
    return nil
  end
  local fn = formatter[diagnostic.code]
  if type(fn) ~= "function" then
    return nil
  end
  local called, msg = pcall(fn, diagnostic.message)
  if not called or not msg or msg == "" then
    return nil
  end
  return render.strip_fences(msg)
end

-- Returns the multi-line "artistic" box for `vim.diagnostic.config.float.format`.
-- If no pattern matches and no fallback applies, returns nil so the caller can
-- use the diagnostic's original message.
---@param diagnostic vim.Diagnostic
---@return string|nil
function M.float_format(diagnostic)
  if not source_allowed(diagnostic.source) then
    return nil
  end
  local artistic = guard(render.artistic, diagnostic, parse_opts())
  if artistic then
    return artistic
  end
  return guard(ts_errors_fallback, diagnostic)
end

-- Returns the one-line formatted message for inline-virtual-text plugins
-- (e.g. tiny-inline-diagnostic's `options.format`). nil -> caller falls back
-- to the raw message.
---@param diagnostic vim.Diagnostic
---@return string|nil
function M.inline_format(diagnostic)
  if not source_allowed(diagnostic.source) then
    return nil
  end
  local short = guard(render.short, diagnostic, parse_opts())
  if short then
    return short
  end
  local fallback = guard(ts_errors_fallback, diagnostic)
  if fallback then
    -- format-ts-errors is a multi-line pretty-printer; keeping only its first
    -- line leaves a dangling fragment ("Type"), so flatten the whole thing.
    fallback = vim.trim(fallback:gsub("%s+", " "))
    if fallback == "" then
      return nil
    end
    return render.truncate(fallback, 80)
  end
  return nil
end

-- Our float.format, chaining to whatever format was configured before us.
local function build_format(prev_format)
  local fn = function(diagnostic)
    local rendered = M.float_format(diagnostic)
    if rendered then
      return rendered
    end
    if prev_format then
      local ok, res = pcall(prev_format, diagnostic)
      if ok and res then
        return res
      end
    end
    return diagnostic.message
  end
  state.format_fn = fn
  return fn
end

-- Install our format into vim.diagnostic's float config.  Idempotent.
local function patch_float()
  local prev = (vim.diagnostic.config() or {}).float

  -- `float` may also be a function returning the opts table (a documented
  -- Neovim shape).  Wrap it rather than dropping the user's config.
  if type(prev) == "function" then
    if state.wrapped_float == prev then
      return
    end
    local user_fn = prev
    local wrapper = function(namespace, bufnr)
      local resolved = user_fn(namespace, bufnr) or {}
      -- user_fn may hand back the same table each call; never chain onto self.
      if resolved.format ~= state.format_fn then
        resolved.format = build_format(resolved.format)
      end
      return resolved
    end
    state.wrapped_float = wrapper
    vim.diagnostic.config({ float = wrapper })
    return
  end

  local base = type(prev) == "table" and prev or {}
  if base.format ~= nil and base.format == state.format_fn then
    return
  end
  vim.diagnostic.config({
    float = vim.tbl_deep_extend("force", base, { format = build_format(base.format) }),
  })
end

---@param opts? EffectErrorPretty.Config
function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  if not state.opts.float then
    return
  end

  patch_float()

  -- vim.diagnostic.config() shallow-assigns top-level keys, so any later
  -- `config({ float = ... })` — LazyVim's lspconfig spec does exactly this —
  -- replaces the whole float table and drops our format. Re-install once the
  -- other plugins have had their say.
  vim.api.nvim_create_autocmd({ "VimEnter", "LspAttach" }, {
    group = vim.api.nvim_create_augroup("EffectErrorPretty", { clear = true }),
    callback = patch_float,
  })
end

return M

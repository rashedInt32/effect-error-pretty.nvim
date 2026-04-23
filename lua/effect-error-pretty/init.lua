-- effect-error-pretty.nvim
-- Effect-first TypeScript diagnostic formatter for Neovim.

local parse = require("effect-error-pretty.parse")
local render = require("effect-error-pretty.render")

local M = {}

M.parse = parse.parse
M.is_ts_source = parse.is_ts_source

---@class EffectErrorPretty.Config
---@field effect? boolean          Enable Effect<A,E,R> / Stream / Layer parsing. Default: true.
---@field sources? table<string, boolean>  Diagnostic sources to format. Default: { typescript, ts, vtsls }.
---@field format_ts_errors_fallback? boolean  Use format-ts-errors when no pattern matches. Default: true.
---@field extra_patterns? fun(msg: string): table|nil[]  User-defined parsers, run after builtins.
---@field float? boolean           Patch vim.diagnostic.config({ float = { format } }) in setup. Default: false.

---@type EffectErrorPretty.Config
local defaults = {
  effect = true,
  sources = nil, -- nil -> use parse.default_sources
  format_ts_errors_fallback = true,
  extra_patterns = nil,
  float = false,
}

local state = { opts = vim.deepcopy(defaults) }

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
  local msg = fn(diagnostic.message)
  if not msg or msg == "" then
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
  local artistic = render.artistic(diagnostic, parse_opts())
  if artistic then
    return artistic
  end
  return ts_errors_fallback(diagnostic)
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
  local short = render.short(diagnostic, parse_opts())
  if short then
    return short
  end
  local fallback = ts_errors_fallback(diagnostic)
  if fallback then
    fallback = fallback:gsub("\n.*", "")
    if #fallback > 80 then
      fallback = fallback:sub(1, 77) .. "…"
    end
    return fallback
  end
  return nil
end

---@param opts? EffectErrorPretty.Config
function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  if state.opts.float then
    local prev = (vim.diagnostic.config() or {}).float or {}
    local prev_format = type(prev) == "table" and prev.format or nil
    vim.diagnostic.config({
      float = vim.tbl_deep_extend("force", type(prev) == "table" and prev or {}, {
        format = function(diagnostic)
          local rendered = M.float_format(diagnostic)
          if rendered then
            return rendered
          end
          if prev_format then
            return prev_format(diagnostic)
          end
          return diagnostic.message
        end,
      }),
    })
  end
end

return M

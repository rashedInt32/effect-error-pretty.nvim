-- Hints: the seam through which an external judge (jury.nvim, or anything
-- else) turns a generic `⚡ Hint:` into a concrete one.
--
-- This module knows Effect. It classifies a parsed result into a hint family
-- and owns the fix templates. It knows nothing about any model or network:
-- a resolver is registered from outside, and when none is registered, or the
-- registered one returns nil, every box renders exactly as it always has.

local M = {}

-- ── families ──────────────────────────────────────────────────────────────

--- Which hint family a parsed result belongs to, and the names involved.
--- Only families with a concrete fix shape are returned. Scope-only results
--- are excluded on purpose: `Effect.scoped` needs no judgment. A Layer's
--- missing RIn is "services" too; `parsed.tag == "layer"` tells the
--- resolver that the fix is Layer.provide inside the layer, not a pipe.
---@param parsed table  result of parse.parse
---@return "services"|"errors"|nil family, string[]|nil names
function M.family(parsed)
  if type(parsed) ~= "table" then
    return nil
  end
  if parsed.kind == "effect_mismatch" then
    if parsed.missing_services and #parsed.missing_services > 0 and not parsed.scope_required then
      return "services", parsed.missing_services
    end
    if parsed.unhandled_errors and #parsed.unhandled_errors > 0 then
      return "errors", parsed.unhandled_errors
    end
  elseif parsed.kind == "missing_context" and not parsed.scope_required then
    return "services", parsed.services
  elseif parsed.kind == "missing_errors" then
    return "errors", parsed.errors
  end
  return nil
end

-- ── templates ─────────────────────────────────────────────────────────────

M.templates = {}

--- Concrete hint for missing services.
---@param layer string        the layer to provide
---@param names string[]      the missing services
---@param where "here"|"caller"|"layer"|nil
---@return string
function M.templates.provide(layer, names, where)
  if where == "caller" then
    return ("keep %s in R; provide %s higher up"):format(table.concat(names, " | "), layer)
  end
  if where == "layer" then
    return ("Layer.provide(%s) inside this layer"):format(layer)
  end
  return (".pipe(Effect.provide(%s))"):format(layer)
end

--- Concrete hint for unhandled errors.
---@param fix "declare"|"catch_tag"|"or_die"|"map_error"
---@param names string[]      the unhandled error tags
---@param target string|nil   domain error class for map_error
---@return string|nil
function M.templates.unhandled(fix, names, target)
  if fix == "catch_tag" then
    if #names == 1 then
      return ('.pipe(Effect.catchTag("%s", () => Effect.succeed(fallback)))'):format(names[1])
    end
    local entries = {}
    for _, n in ipairs(names) do
      entries[#entries + 1] = n .. ": () => Effect.succeed(fallback)"
    end
    return (".pipe(Effect.catchTags({ %s }))"):format(table.concat(entries, ", "))
  elseif fix == "or_die" then
    return ".pipe(Effect.orDie)  — treat as a defect here"
  elseif fix == "declare" then
    return ("declare %s in this function's E channel; let the caller handle it"):format(table.concat(names, " | "))
  elseif fix == "map_error" then
    return (".pipe(Effect.mapError((e) => new %s({ cause: e })))"):format(target or "DomainError")
  end
  return nil
end

-- ── the seam ──────────────────────────────────────────────────────────────

---@class EffectErrorPretty.Hint
---@field label? string   what to print instead of "Hint" (default "Hint")
---@field line? string    the concrete hint; replaces the generic line
---@field detail? string  one short line under it (confidence, picks)
---@field lean? string    when no `line`: printed under the generic hint

---@alias EffectErrorPretty.HintResolver fun(parsed: table, family: string, names: string[], diagnostic: vim.Diagnostic): EffectErrorPretty.Hint|nil

local resolver = nil
local overload_picker = nil

--- Register the function that turns a parsed result into a concrete hint.
--- Must be synchronous and fast: it runs inside vim.diagnostic's formatter.
---@param fn EffectErrorPretty.HintResolver|nil
function M.set_resolver(fn)
  resolver = fn
end

--- Register the overload selector handed to parse.parse as `pick_overload`.
--- Same contract as before: `(msg, candidates) -> index|nil`, synchronous.
---@param fn (fun(msg: string, candidates: table[]): integer|nil)|nil
function M.set_overload_picker(fn)
  overload_picker = fn
end

function M.overload_picker()
  return overload_picker
end

--- Ask the resolver, guarded. A resolver failure is a generic hint, never a
--- missing box.
---@param parsed table
---@param diagnostic vim.Diagnostic|nil
---@return EffectErrorPretty.Hint|nil
function M.resolve(parsed, diagnostic)
  if not resolver or not diagnostic then
    return nil
  end
  local family, names = M.family(parsed)
  if not family then
    return nil
  end
  local ok, hint = pcall(resolver, parsed, family, names, diagnostic)
  if not ok or type(hint) ~= "table" then
    return nil
  end
  if hint.line == nil and hint.lean == nil then
    return nil
  end
  return hint
end

--- Lines that replace or follow the generic hint line. Used by render.
---@param hint EffectErrorPretty.Hint|nil
---@param generic string  the generic hint text
---@return string[] lines  full box lines including the gutter
function M.lines(hint, generic)
  if not hint or not hint.line then
    local out = { "│  ⚡ Hint: " .. generic }
    if hint and hint.lean then
      out[#out + 1] = "│     ↳ " .. hint.lean
    end
    return out
  end
  local label = hint.label or "Hint"
  local out = { ("│  ⚡ %s: %s"):format(label, hint.line) }
  if hint.detail then
    out[#out + 1] = "│     ↳ " .. hint.detail
  end
  return out
end

return M

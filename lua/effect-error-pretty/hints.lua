-- Hints: the seam through which an external judge (jury.nvim, or anything
-- else) turns a generic `⚡ Hint:` into a concrete one.
--
-- This module knows Effect. It classifies a parsed result into a hint family
-- and owns the fix templates. It knows nothing about any model or network:
-- a resolver is registered from outside, and when none is registered, or the
-- registered one returns nil, every box renders exactly as it always has.

local M = {}

-- ── families ──────────────────────────────────────────────────────────────

local function is_uninferred(name)
  return name == "unknown" or name == "any"
end

--- True when a channel holds nothing but `unknown`/`any`: inference gave up
--- upstream and there is no service or error to name.
---@param names string[]|nil
---@return boolean
function M.all_uninferred(names)
  if type(names) ~= "table" or #names == 0 then
    return false
  end
  for _, n in ipairs(names) do
    if not is_uninferred(n) then
      return false
    end
  end
  return true
end

--- Which hint family a parsed result belongs to, and the names involved.
--- Only families with a concrete fix shape are returned. Scope-only results
--- are excluded on purpose: `Effect.scoped` needs no judgment. A Layer's
--- missing RIn is "services" too; `parsed.tag == "layer"` tells the
--- resolver that the fix is Layer.provide inside the layer, not a pipe.
--- A channel that is only `unknown`/`any` is "widened": `names` is then the
--- channel label (R, RIn or E) and the resolver's job is to say where
--- upstream the type was lost.
---@param parsed table  result of parse.parse
---@return "services"|"errors"|"widened"|nil family, string[]|nil names
function M.family(parsed)
  if type(parsed) ~= "table" then
    return nil
  end
  if parsed.kind == "effect_mismatch" then
    -- Only the single-channel boxes carry a hint line; the tri-channel
    -- view and the identical-signature box do not, so asking is waste.
    if parsed.diff_count ~= 1 then
      return nil
    end
    local labels = parsed.labels or { "A", "E", "R" }
    if parsed.missing_services and #parsed.missing_services > 0 then
      if M.all_uninferred(parsed.missing_services) then
        return "widened", { labels[3] }
      end
      if not parsed.scope_required then
        return "services", parsed.missing_services
      end
      return nil
    end
    if parsed.unhandled_errors and #parsed.unhandled_errors > 0 then
      if M.all_uninferred(parsed.unhandled_errors) then
        return "widened", { labels[2] }
      end
      return "errors", parsed.unhandled_errors
    end
  elseif parsed.kind == "missing_context" then
    if M.all_uninferred(parsed.services) then
      return "widened", { parsed.tag == "layer" and "RIn" or "R" }
    end
    if not parsed.scope_required then
      return "services", parsed.services
    end
  elseif parsed.kind == "missing_errors" then
    if M.all_uninferred(parsed.errors) then
      return "widened", { "E" }
    end
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

--- Concrete hint for a widened channel: name the definition to annotate.
---@param label string        R, RIn or E
---@param name string         the identifier that most likely lost its type
---@param file string|nil
---@param line integer|nil
---@return string
function M.templates.widened(label, name, file, line)
  local where = file and (line and (" (%s:%d)"):format(file, line) or (" (%s)"):format(file)) or ""
  return ("annotate %s%s, where %s widened"):format(name, where, label)
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

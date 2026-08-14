-- Renderers: take a parsed result and produce string output.
--   * artistic(): multi-line boxed output for the float.
--   * short():    one-line output for inline virtual-text plugins.

local parse = require("effect-error-pretty.parse")

local M = {}

-- ── helpers ────────────────────────────────────────────────────────────────

local function prettify_type(s)
  if not s then
    return s
  end
  s = s:gsub('import%("[^"]+/node_modules/[^"]+"%)%.', "")
  s = s:gsub('import%("[^"]+"%)%.([%w_]+)', "%1")
  s = s:gsub("ParseResult%.", "")
  return s
end

-- Truncate to `n` characters rather than bytes.  Type strings carry non-ASCII
-- (template-literal types, unicode identifiers), and a byte-wise cut lands
-- mid-codepoint and renders as a replacement glyph.
local function truncate(s, n)
  if not s then
    return s
  end
  if vim.fn.strchars(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, n) .. "…"
end
M.truncate = truncate

-- The box gutter.  `│` is an East-Asian *ambiguous* width character: it is one
-- cell normally but two under `set ambiwidth=double`, so never assume 1.
local GUTTER = "│"

-- Target width of a rendered box line, gutter included.
local BOX_WIDTH = 70

-- Continuation lines sit directly under the first character of `prefix`, so
-- wrapped types stay aligned with the label that introduces them.
local function indent_for(prefix)
  local pad = vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(GUTTER)
  return GUTTER .. string.rep(" ", math.max(pad, 0))
end
M.indent_for = indent_for

-- How much room a wrapped line has left for content once its prefix is drawn.
local function content_budget(indent)
  return math.max(30, BOX_WIDTH - vim.fn.strdisplaywidth(indent))
end

-- Wrap long type strings onto multiple lines at semicolons (object members)
-- and soft whitespace boundaries.  Returns a list of display lines where the
-- first line is bare and continuations carry `indent` as a prefix.
local function format_type_multiline(type_str, indent)
  indent = indent or "│     "
  type_str = prettify_type(type_str)
  if not type_str then
    return {}
  end

  -- Budget the content, not the whole line: the old fixed 70 ignored the
  -- prefix, so an indented line could run ~85 columns wide.  Measure display
  -- cells too — `#s` counts bytes, which overshoots for non-ASCII types.
  local max_line_len = content_budget(indent)
  if vim.fn.strdisplaywidth(type_str) <= max_line_len then
    return { type_str }
  end

  local lines = {}
  local brace_depth = 0
  local current = ""
  local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  for i = 1, #type_str do
    local char = type_str:sub(i, i)
    current = current .. char
    if char == "{" then
      brace_depth = brace_depth + 1
    elseif char == "}" then
      brace_depth = brace_depth - 1
    end
    if char == ";" and brace_depth == 1 then
      table.insert(lines, trim(current))
      current = ""
    elseif char == " " and brace_depth == 0 and vim.fn.strdisplaywidth(current) >= max_line_len then
      -- Soft-wrap only outside braces.  Inside an object the `;` above is the
      -- semantic break; wrapping mid-member on a space just orphans the `};`.
      table.insert(lines, trim(current))
      current = ""
    end
  end
  if #trim(current) > 0 then
    table.insert(lines, trim(current))
  end

  if #lines <= 1 then
    return { type_str }
  end

  local result = {}
  for idx, line in ipairs(lines) do
    if idx == 1 then
      table.insert(result, line)
    else
      table.insert(result, indent .. line)
    end
  end
  return result
end
M.format_type_multiline = format_type_multiline

local function display_name(tag)
  if tag == "layer" then
    return "Layer"
  elseif tag == "stream" then
    return "Stream"
  end
  return "Effect"
end

local function strip_fences(s)
  return (s:gsub("```typescript\n", ""):gsub("```ts\n", ""):gsub("\n```", ""))
end
M.strip_fences = strip_fences

-- Append `prefix .. value` to `lines`, wrapping long values onto continuation
-- lines that align under the prefix.
local function push_wrapped(lines, prefix, value)
  local chunks = format_type_multiline(value, indent_for(prefix))
  table.insert(lines, prefix .. (chunks[1] or ""))
  for i = 2, #chunks do
    table.insert(lines, chunks[i])
  end
end

-- Hard-wrap without prettifying.  `push_wrapped` runs prettify_type, which
-- strips `import("…").` — exactly the text the identical-signatures box exists
-- to show.  Import paths have no good break points, so wrap on width.
local function push_raw_wrapped(lines, prefix, value)
  local indent = indent_for(prefix)
  local budget = content_budget(indent)
  if vim.fn.strdisplaywidth(value) <= budget then
    table.insert(lines, prefix .. value)
    return
  end

  local first, current = true, ""
  local function flush()
    if current ~= "" then
      table.insert(lines, (first and prefix or indent) .. current)
      first, current = false, ""
    end
  end

  -- Break after `/` so a path stays readable; hard-cut only a run that is
  -- itself wider than the budget.
  local pos = 1
  while pos <= #value do
    local slash = value:find("/", pos, true)
    local seg
    if slash then
      seg, pos = value:sub(pos, slash), slash + 1
    else
      seg, pos = value:sub(pos), #value + 1
    end
    if current ~= "" and vim.fn.strdisplaywidth(current .. seg) > budget then
      flush()
    end
    current = current .. seg
    while vim.fn.strdisplaywidth(current) > budget do
      table.insert(lines, (first and prefix or indent) .. vim.fn.strcharpart(current, 0, budget))
      first = false
      current = vim.fn.strcharpart(current, budget)
    end
  end
  flush()
end

-- Only a bare Scope counts.  A prefix match also catches services like
-- ScopeManager, which then get a Scope title over an Effect.provide hint.
local function scope_only(parsed, services)
  if not parsed.scope_required or #services ~= 1 then
    return false
  end
  local svc = services[1]
  return svc == "Scope" or svc == "Scope.Scope"
end

local function is_scope_only(parsed)
  return scope_only(parsed, parsed.missing_services)
end

-- `unknown` / `any` is not a service you can provide: it is TypeScript saying
-- it never resolved the channel at all.  "Forgot to provide: unknown" sends the
-- reader hunting for a layer that does not exist, so these get their own box.
local function is_uninferred(type_str)
  return type_str == "unknown" or type_str == "any"
end

-- Split a channel's members into ones you can act on and ones that only mean
-- "inference gave up here".
local function partition_uninferred(members)
  local real, unresolved = {}, {}
  for _, m in ipairs(members) do
    table.insert(is_uninferred(m) and unresolved or real, m)
  end
  return real, unresolved
end

M.is_uninferred = is_uninferred

-- Why a channel came out `unknown`, and what to do about it.  Deliberately
-- names no service: there isn't one to name.
local function uninferred_lines(name, label, found)
  return {
    "╭─ ⚠ " .. name .. " — " .. label .. " Not Inferred",
    "│",
    "│  ⚠ " .. label .. " is `" .. found .. "`, which is not a service",
    "│  ⚡ Hint: something upstream is untyped — an `any`, a missing",
    "│     annotation, or a generic that never got inferred",
    "│  ⚡ Hint: annotate the effect to find where " .. label .. " widened",
  }
end

-- The "you forgot to provide something" box, shared by the type-diff path
-- (TS2345/TS2322) and @effect/language-service, which reports the same fact
-- with no types to diff.  Returns the lines above the closing `╰─`.
local function missing_services_lines(name, services, is_layer, only_scope, scope_required)
  local label = is_layer and "RIn" or "R"
  local real, unresolved = partition_uninferred(services)

  -- Nothing actionable in the channel: the whole box would be a lie.
  if #real == 0 and #unresolved > 0 then
    return uninferred_lines(name, label, unresolved[1])
  end

  local title
  if only_scope then
    title = name .. " — Scope Required"
  elseif is_layer then
    title = name .. " — Missing RIn"
  else
    title = name .. " — Missing Services"
  end

  local lines = {
    "╭─ ◈ " .. title,
    "│",
    "│  ◈ Forgot to provide: " .. table.concat(real, " | "),
  }
  -- A real service alongside an `unknown` still deserves its provide hint, but
  -- providing it will not clear the error on its own.
  if #unresolved > 0 then
    table.insert(lines, "│  ⚠ " .. label .. " also holds `" .. unresolved[1] .. "` — that half never inferred")
  end
  if only_scope then
    table.insert(lines, "│  ⚡ Hint: wrap in Effect.scoped(...) — Scope is required")
  elseif is_layer then
    table.insert(lines, "│  ⚡ Hint: compose with Layer.provide(...) or Layer.merge(...)")
  else
    table.insert(lines, "│  ⚡ Hint: .pipe(Effect.provide(SomeLayer))")
    -- Scope rides along with real services: provide handles them, but Scope
    -- still needs Effect.scoped, so don't leave that half unsaid.
    if scope_required then
      table.insert(lines, "│  ⚡ Hint: Scope also needs Effect.scoped(...)")
    end
  end
  return lines
end

local function unhandled_errors_lines(name, errors)
  local real, unresolved = partition_uninferred(errors)
  if #real == 0 and #unresolved > 0 then
    return uninferred_lines(name, "E", unresolved[1])
  end

  local lines = {
    "╭─ ⚠ " .. name .. " — Unhandled Errors",
    "│",
    "│  ⚠ Not in E channel: " .. table.concat(real, " | "),
    "│  ⚡ Hint: .pipe(Effect.catchTags({...})) or Effect.orDie",
  }
  if #unresolved > 0 then
    table.insert(lines, "│  ⚠ E also holds `" .. unresolved[1] .. "` — that half never inferred")
  end
  return lines
end

-- Inline forms of the two boxes above.  Same rule: a channel that never
-- inferred must not read as a service you could have provided.
local function short_channel(label, members, provide_form)
  local real, unresolved = partition_uninferred(members)
  if #real == 0 and #unresolved > 0 then
    return "⚠ " .. label .. " never inferred (`" .. unresolved[1] .. "`)"
  end
  local out = provide_form .. table.concat(real, " | ")
  if #unresolved > 0 then
    out = out .. "  ⚠ + `" .. unresolved[1] .. "`"
  end
  return out
end

-- ── artistic (float) renderer ──────────────────────────────────────────────

local function render_effect_mismatch(parsed)
  local g, e = parsed.got, parsed.expected
  local name = display_name(parsed.tag)
  local labels = parsed.labels
  local is_layer = parsed.tag == "layer"
  local lines = {}

  local function push_multiline(first_prefix, value)
    push_wrapped(lines, first_prefix, value)
  end

  local function signature(shape)
    return name .. "<" .. shape.A .. ", " .. shape.E .. ", " .. shape.R .. ">"
  end

  local function push_signatures()
    table.insert(lines, "│")
    push_multiline("│  Got:      ", signature(g))
    push_multiline("│  Expected: ", signature(e))
  end

  -- Both sides normalize to the same signature, so a Got/Expected diff would
  -- print two identical lines.  What actually differs is the import path.
  if parsed.diff_count == 0 then
    table.insert(lines, "╭─ ⊘ " .. name .. " — Identical Signatures")
    table.insert(lines, "│")
    push_multiline("│  ⚠ Both sides are: ", signature(g))
    table.insert(lines, "│  ⚡ Hint: usually two copies of the same package")
    if parsed.raw and parsed.raw.got ~= parsed.raw.expected then
      table.insert(lines, "│")
      push_raw_wrapped(lines, "│  Got:      ", parsed.raw.got)
      push_raw_wrapped(lines, "│  Expected: ", parsed.raw.expected)
    end
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  end

  -- Compact single-channel-diff mode.
  if parsed.diff_count == 1 then
    if #parsed.missing_services > 0 then
      vim.list_extend(
        lines,
        missing_services_lines(name, parsed.missing_services, is_layer, is_scope_only(parsed), parsed.scope_required)
      )
      push_signatures()
      table.insert(lines, "╰─")
      return table.concat(lines, "\n")
    end

    if #parsed.unhandled_errors > 0 then
      vim.list_extend(lines, unhandled_errors_lines(name, parsed.unhandled_errors))
      push_signatures()
      table.insert(lines, "╰─")
      return table.concat(lines, "\n")
    end

    if parsed.success_differs then
      local a_label = labels[1]
      table.insert(lines, "╭─ ⊘ " .. name .. " — " .. a_label .. " Mismatch")
      table.insert(lines, "│")
      push_multiline("│  ✗ Got " .. a_label .. ":    ", g.A)
      push_multiline("│  ✓ Expected: ", e.A)
      push_signatures()
      table.insert(lines, "╰─")
      return table.concat(lines, "\n")
    end
  end

  -- Multi-channel diff: full tri-channel view.
  table.insert(lines, "╭─ ⊘ " .. name .. " Mismatch")
  table.insert(lines, "│")
  table.insert(lines, "│  ✗ Got:")
  push_multiline("│     " .. labels[1] .. ": ", g.A)
  push_multiline("│     " .. labels[2] .. ": ", g.E)
  push_multiline("│     " .. labels[3] .. ": ", g.R)
  table.insert(lines, "│")
  table.insert(lines, "│  ✓ Expected:")
  push_multiline("│     " .. labels[1] .. ": ", e.A)
  push_multiline("│     " .. labels[2] .. ": ", e.E)
  push_multiline("│     " .. labels[3] .. ": ", e.R)
  if #parsed.missing_services > 0 then
    table.insert(lines, "│")
    table.insert(lines, "│  ◈ Forgot to provide: " .. table.concat(parsed.missing_services, " | "))
  end
  if #parsed.unhandled_errors > 0 then
    table.insert(lines, "│  ⚠ Unhandled errors: " .. table.concat(parsed.unhandled_errors, " | "))
  end
  if parsed.scope_required then
    table.insert(lines, "│  ⚡ Hint: wrap in Effect.scoped(...)")
  end
  table.insert(lines, "╰─")
  return table.concat(lines, "\n")
end

function M.artistic(diagnostic, opts)
  opts = opts or {}
  local parsed = parse.parse(diagnostic.message, opts)
  if not parsed then
    return nil
  end

  local lines = {}

  if parsed.kind == "effect_mismatch" then
    return render_effect_mismatch(parsed)
  elseif parsed.kind == "missing_context" then
    local name = display_name(parsed.tag)
    lines = missing_services_lines(
      name,
      parsed.services,
      parsed.tag == "layer",
      scope_only(parsed, parsed.services),
      parsed.scope_required
    )
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "missing_errors" then
    lines = unhandled_errors_lines(display_name(parsed.tag), parsed.errors)
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "type_mismatch" then
    table.insert(lines, "╭─ ⊘ Type Mismatch")
    table.insert(lines, "│")
    push_wrapped(lines, "│  ✗ Got:      ", parsed.got)
    push_wrapped(lines, "│  ✓ Expected: ", parsed.expected)
    if parsed.missing then
      table.insert(lines, "│")
      table.insert(lines, "│  ◈ Missing:  '" .. parsed.missing .. "'")
    end
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "missing_property" then
    table.insert(lines, "╭─ ◈ Missing Property")
    table.insert(lines, "│")
    table.insert(lines, "│  ◈ Property:  '" .. parsed.prop .. "'")
    push_wrapped(lines, "│  ◇ In:        ", parsed.in_type)
    push_wrapped(lines, "│  ◆ Required:  ", parsed.required)
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "unknown_property" then
    table.insert(lines, "╭─ ❓ Unknown Property")
    table.insert(lines, "│")
    table.insert(lines, "│  ✗ '" .. parsed.prop .. "' not found")
    push_wrapped(lines, "│  ◇ on type: ", parsed.on_type)
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "undefined" then
    return "╭─ ❓ Undefined Reference\n│\n│  ✗ '" .. parsed.name .. "' is not defined\n╰─"
  elseif parsed.kind == "module_not_found" then
    return "╭─ 🔗 Module Not Found\n│\n│  ✗ '"
      .. parsed.path
      .. "'\n│  ⚡ Check path or install types\n╰─"
  elseif parsed.kind == "export_not_found" then
    return ("╭─ 🔗 Export Not Found\n│\n│  ✗ '%s'\n│  ◇ not exported from '%s'\n╰─"):format(
      parsed.member,
      parsed.module:gsub(".*/", "")
    )
  elseif parsed.kind == "implicit_any" then
    return "╭─ 📝 Implicit Any\n│\n│  ⚠ '" .. parsed.name .. "' needs type annotation\n╰─"
  elseif parsed.kind == "used_before_assigned" then
    return "╭─ ⚠ Uninitialized Variable\n│\n│  ✗ '" .. parsed.name .. "' used before assignment\n╰─"
  elseif parsed.kind == "nullish" then
    local subject = parsed.name and ("'" .. parsed.name .. "'") or "Object"
    return "╭─ ❓ Nullish Reference\n│\n│  ⚠ "
      .. subject
      .. " may be "
      .. parsed.value
      .. "\n│  ⚡ Add optional chaining (?.) or null check\n╰─"
  elseif parsed.kind == "arg_count" then
    return ("╭─ 🔢 Argument Count\n│\n│  ✗ Got %s args, expected %s\n╰─"):format(
      parsed.got,
      parsed.expected
    )
  elseif parsed.kind == "const_assign" then
    return "╭─ 🔒 Constant Assignment\n│\n│  ✗ '" .. parsed.name .. "' is readonly\n╰─"
  elseif parsed.kind == "deprecated" then
    return "╭─ ⚠ Deprecated\n│\n│  ⚠ '" .. parsed.name .. "' is deprecated\n╰─"
  elseif parsed.kind == "not_callable" then
    table.insert(lines, "╭─ ⊘ Not Callable")
    table.insert(lines, "│")
    push_wrapped(lines, "│  ✗ ", parsed.type or "Expression")
    table.insert(lines, "│    is not a function")
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  end

  return nil
end

-- ── short (inline) renderer ───────────────────────────────────────────────

function M.short(diagnostic, opts)
  opts = opts or {}
  local parsed = parse.parse(diagnostic.message, opts)
  if not parsed then
    return nil
  end

  if parsed.kind == "effect_mismatch" then
    local function a_diff()
      return "✗ "
        .. parsed.labels[1]
        .. ": "
        .. truncate(parsed.got.A, 30)
        .. " → ✓ "
        .. truncate(parsed.expected.A, 30)
    end

    if parsed.diff_count == 0 then
      return "⊘ " .. display_name(parsed.tag) .. ": identical signatures (duplicate package?)"
    end

    -- Compact forms are only honest when exactly one channel diverges, which is
    -- the same gate `artistic` uses.  Without it a multi-channel error reports
    -- just the R diff inline, and the E diff the float shows disappears.
    if parsed.diff_count == 1 then
      if is_scope_only(parsed) then
        return "◈ Needs Effect.scoped"
      end
      if #parsed.missing_services > 0 then
        return short_channel(parsed.labels[3], parsed.missing_services, "◈ Missing provide: ")
      end
      if #parsed.unhandled_errors > 0 then
        return short_channel(parsed.labels[2], parsed.unhandled_errors, "⚠ Unhandled: ")
      end
      if parsed.success_differs then
        return a_diff()
      end
      return "⊘ " .. display_name(parsed.tag) .. " mismatch"
    end

    local segs = {}
    if #parsed.missing_services > 0 then
      table.insert(segs, short_channel(parsed.labels[3], parsed.missing_services, "◈ Missing provide: "))
    elseif parsed.got.R ~= parsed.expected.R then
      table.insert(segs, "◈ " .. parsed.labels[3] .. " differs")
    end
    if #parsed.unhandled_errors > 0 then
      table.insert(segs, short_channel(parsed.labels[2], parsed.unhandled_errors, "⚠ Unhandled: "))
    elseif parsed.got.E ~= parsed.expected.E then
      table.insert(segs, "⚠ " .. parsed.labels[2] .. " differs")
    end
    if parsed.success_differs then
      table.insert(segs, a_diff())
    end
    if #segs == 0 then
      return "⊘ " .. display_name(parsed.tag) .. " mismatch"
    end
    return table.concat(segs, "  ")
  elseif parsed.kind == "missing_context" then
    if scope_only(parsed, parsed.services) then
      return "◈ Needs Effect.scoped"
    end
    return short_channel(parsed.tag == "layer" and "RIn" or "R", parsed.services, "◈ Missing provide: ")
  elseif parsed.kind == "missing_errors" then
    return short_channel("E", parsed.errors, "⚠ Unhandled: ")
  elseif parsed.kind == "type_mismatch" then
    local got = truncate((parsed.got:gsub("import%([^)]+%)%.", "")), 50)
    local expected = truncate((parsed.expected:gsub("import%([^)]+%)%.", "")), 50)
    return "✗ " .. got .. " → ✓ " .. expected
  elseif parsed.kind == "missing_property" then
    return "◈ Missing: '" .. parsed.prop .. "'"
  elseif parsed.kind == "unknown_property" then
    return "✗ Unknown: '" .. parsed.prop .. "'"
  elseif parsed.kind == "undefined" then
    return "✗ Undefined: '" .. parsed.name .. "'"
  elseif parsed.kind == "module_not_found" then
    return "✗ Module: '" .. parsed.path:gsub(".*/", "") .. "'"
  elseif parsed.kind == "export_not_found" then
    return "✗ No export: '" .. parsed.member .. "'"
  elseif parsed.kind == "implicit_any" then
    return "⚠ Needs type: '" .. parsed.name .. "'"
  elseif parsed.kind == "used_before_assigned" then
    return "⚠ '" .. parsed.name .. "' used before assignment"
  elseif parsed.kind == "nullish" then
    local subject = parsed.name and ("'" .. parsed.name .. "'") or "Object"
    return "⚠ " .. subject .. " may be " .. parsed.value
  elseif parsed.kind == "arg_count" then
    return "✗ Expected " .. parsed.expected .. " args, got " .. parsed.got
  elseif parsed.kind == "const_assign" then
    return "✗ '" .. parsed.name .. "' is readonly"
  elseif parsed.kind == "not_callable" then
    return "✗ Not callable" .. (parsed.type and (": " .. truncate(parsed.type, 30)) or "")
  elseif parsed.kind == "deprecated" then
    return "⚠ Deprecated: '" .. parsed.name .. "'"
  end

  return nil
end

return M

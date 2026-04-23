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

-- Wrap long type strings onto multiple lines at semicolons (object members)
-- and soft whitespace boundaries.  Returns a list of display lines where the
-- first line is bare and continuations carry `indent` as a prefix.
local function format_type_multiline(type_str, indent)
  indent = indent or "│     "
  type_str = prettify_type(type_str)
  if not type_str then
    return {}
  end

  local max_line_len = 70
  if #type_str <= max_line_len then
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
    elseif #current >= max_line_len and char == " " then
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

-- ── artistic (float) renderer ──────────────────────────────────────────────

local function render_effect_mismatch(parsed)
  local g, e = parsed.got, parsed.expected
  local name = display_name(parsed.tag)
  local labels = parsed.labels
  local is_layer = parsed.tag == "layer"
  local lines = {}

  local function push_multiline(indent_prefix, first_prefix, value)
    local chunks = format_type_multiline(value, indent_prefix)
    table.insert(lines, first_prefix .. (chunks[1] or ""))
    for i = 2, #chunks do
      table.insert(lines, chunks[i])
    end
  end

  local function signature(shape)
    return name .. "<" .. shape.A .. ", " .. shape.E .. ", " .. shape.R .. ">"
  end

  local function push_signatures()
    table.insert(lines, "│")
    push_multiline("│              ", "│  Got:      ", signature(g))
    push_multiline("│              ", "│  Expected: ", signature(e))
  end

  -- Compact single-channel-diff mode.
  if parsed.diff_count == 1 then
    if #parsed.missing_services > 0 then
      local only_scope = #parsed.missing_services == 1 and parsed.missing_services[1]:match("^Scope")
      local title
      if only_scope then
        title = name .. " — Scope Required"
      elseif is_layer then
        title = name .. " — Missing RIn"
      else
        title = name .. " — Missing Services"
      end
      table.insert(lines, "╭─ ◈ " .. title)
      table.insert(lines, "│")
      table.insert(lines, "│  ◈ Forgot to provide: " .. table.concat(parsed.missing_services, " | "))
      if parsed.scope_required then
        table.insert(lines, "│  ⚡ Hint: wrap in Effect.scoped(...) — Scope is required")
      elseif is_layer then
        table.insert(lines, "│  ⚡ Hint: compose with Layer.provide(...) or Layer.merge(...)")
      else
        table.insert(lines, "│  ⚡ Hint: .pipe(Effect.provide(SomeLayer))")
      end
      push_signatures()
      table.insert(lines, "╰─")
      return table.concat(lines, "\n")
    end

    if #parsed.unhandled_errors > 0 then
      table.insert(lines, "╭─ ⚠ " .. name .. " — Unhandled Errors")
      table.insert(lines, "│")
      table.insert(lines, "│  ⚠ Not in E channel: " .. table.concat(parsed.unhandled_errors, " | "))
      table.insert(lines, "│  ⚡ Hint: .pipe(Effect.catchTags({...})) or Effect.orDie")
      push_signatures()
      table.insert(lines, "╰─")
      return table.concat(lines, "\n")
    end

    if parsed.success_differs then
      local a_label = labels[1]
      table.insert(lines, "╭─ ⊘ " .. name .. " — " .. a_label .. " Mismatch")
      table.insert(lines, "│")
      push_multiline("│              ", "│  ✗ Got " .. a_label .. ":    ", g.A)
      push_multiline("│              ", "│  ✓ Expected: ", e.A)
      push_signatures()
      table.insert(lines, "╰─")
      return table.concat(lines, "\n")
    end
  end

  -- Multi-channel diff: full tri-channel view.
  table.insert(lines, "╭─ ⊘ " .. name .. " Mismatch")
  table.insert(lines, "│")
  table.insert(lines, "│  ✗ Got:")
  push_multiline("│        ", "│     " .. labels[1] .. ": ", g.A)
  push_multiline("│        ", "│     " .. labels[2] .. ": ", g.E)
  push_multiline("│        ", "│     " .. labels[3] .. ": ", g.R)
  table.insert(lines, "│")
  table.insert(lines, "│  ✓ Expected:")
  push_multiline("│        ", "│     " .. labels[1] .. ": ", e.A)
  push_multiline("│        ", "│     " .. labels[2] .. ": ", e.E)
  push_multiline("│        ", "│     " .. labels[3] .. ": ", e.R)
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
  elseif parsed.kind == "type_mismatch" then
    local got_lines = format_type_multiline(parsed.got, "│              ")
    local expected_lines = format_type_multiline(parsed.expected, "│              ")
    table.insert(lines, "╭─ ⊘ Type Mismatch")
    table.insert(lines, "│")
    table.insert(lines, "│  ✗ Got:      " .. (got_lines[1] or ""))
    for i = 2, #got_lines do
      table.insert(lines, got_lines[i])
    end
    table.insert(lines, "│  ✓ Expected: " .. (expected_lines[1] or ""))
    for i = 2, #expected_lines do
      table.insert(lines, expected_lines[i])
    end
    if parsed.missing then
      table.insert(lines, "│")
      table.insert(lines, "│  ◈ Missing:  '" .. parsed.missing .. "'")
    end
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "missing_property" then
    local in_lines = format_type_multiline(parsed.in_type, "│              ")
    local req_lines = format_type_multiline(parsed.required, "│              ")
    table.insert(lines, "╭─ ◈ Missing Property")
    table.insert(lines, "│")
    table.insert(lines, "│  ◈ Property:  '" .. parsed.prop .. "'")
    table.insert(lines, "│  ◇ In:        " .. (in_lines[1] or ""))
    for i = 2, #in_lines do
      table.insert(lines, in_lines[i])
    end
    table.insert(lines, "│  ◆ Required:  " .. (req_lines[1] or ""))
    for i = 2, #req_lines do
      table.insert(lines, req_lines[i])
    end
    table.insert(lines, "╰─")
    return table.concat(lines, "\n")
  elseif parsed.kind == "unknown_property" then
    local on_lines = format_type_multiline(parsed.on_type, "│             ")
    table.insert(lines, "╭─ ❓ Unknown Property")
    table.insert(lines, "│")
    table.insert(lines, "│  ✗ '" .. parsed.prop .. "' not found")
    table.insert(lines, "│  ◇ on type: " .. (on_lines[1] or ""))
    for i = 2, #on_lines do
      table.insert(lines, on_lines[i])
    end
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
    return "╭─ ❓ Nullish Reference\n│\n│  ⚠ Object may be "
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
    local type_lines = parsed.type and format_type_multiline(parsed.type, "│       ") or { "Expression" }
    table.insert(lines, "╭─ ⊘ Not Callable")
    table.insert(lines, "│")
    table.insert(lines, "│  ✗ " .. (type_lines[1] or ""))
    for i = 2, #type_lines do
      table.insert(lines, type_lines[i])
    end
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
    if parsed.scope_required and #parsed.missing_services == 1 and parsed.missing_services[1]:match("^Scope") then
      return "◈ Needs Effect.scoped"
    end
    if #parsed.missing_services > 0 then
      return "◈ Missing provide: " .. table.concat(parsed.missing_services, " | ")
    end
    if #parsed.unhandled_errors > 0 then
      return "⚠ Unhandled: " .. table.concat(parsed.unhandled_errors, " | ")
    end
    if parsed.success_differs then
      local label = parsed.labels[1]
      local g = parsed.got.A:sub(1, 30)
      local e = parsed.expected.A:sub(1, 30)
      if #parsed.got.A > 30 then
        g = g .. "…"
      end
      if #parsed.expected.A > 30 then
        e = e .. "…"
      end
      return "✗ " .. label .. ": " .. g .. " → ✓ " .. e
    end
    return "⊘ " .. display_name(parsed.tag) .. " mismatch"
  elseif parsed.kind == "type_mismatch" then
    local got = parsed.got:gsub("import%([^)]+%)%.", ""):sub(1, 50)
    local expected = parsed.expected:gsub("import%([^)]+%)%.", ""):sub(1, 50)
    if #parsed.got > 50 then
      got = got .. "…"
    end
    if #parsed.expected > 50 then
      expected = expected .. "…"
    end
    return "✗ " .. got .. " → ✓ " .. expected
  elseif parsed.kind == "missing_property" then
    return "◈ Missing: '" .. parsed.prop .. "'"
  elseif parsed.kind == "unknown_property" then
    return "✗ Unknown: '" .. parsed.prop .. "'"
  elseif parsed.kind == "undefined" then
    return "✗ Undefined: '" .. parsed.name .. "'"
  elseif parsed.kind == "module_not_found" then
    return "✗ Module: '" .. parsed.path:gsub(".*/", "") .. "'"
  elseif parsed.kind == "implicit_any" then
    return "⚠ Needs type: '" .. parsed.name .. "'"
  elseif parsed.kind == "nullish" then
    return "⚠ Possibly nullish"
  elseif parsed.kind == "deprecated" then
    return "⚠ Deprecated: '" .. parsed.name .. "'"
  end

  return nil
end

return M

-- Pure parser: TS diagnostic message -> structured `kind` table.
-- No side effects; safe to unit-test.

local M = {}

-- ── helpers ────────────────────────────────────────────────────────────────

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split `s` at top-level `sep`, respecting nested <>, [], (), {} depth.
-- "A, B<C, D>, E" -> { "A", "B<C, D>", "E" }.
--
-- The `=` guard matters: a `>` right after `=` is the tail of an arrow
-- (`(x: string) => void`), not a closing bracket.  Counting it drives depth
-- negative, and every top-level separator after it is then missed.
local function split_top_level(s, sep)
  local parts = {}
  local depth = 0
  local current = ""
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "<" or c == "[" or c == "(" or c == "{" then
      depth = depth + 1
      current = current .. c
    elseif c == ">" and s:sub(i - 1, i - 1) == "=" then
      current = current .. c
    elseif c == ">" or c == "]" or c == ")" or c == "}" then
      if depth > 0 then
        depth = depth - 1
      end
      current = current .. c
    elseif c == sep and depth == 0 then
      local t = trim(current)
      if t ~= "" then
        table.insert(parts, t)
      end
      current = ""
    else
      current = current .. c
    end
  end
  local t = trim(current)
  if t ~= "" then
    table.insert(parts, t)
  end
  return parts
end

local function split_generic_args(s)
  return split_top_level(s, ",")
end

local function split_union(s)
  return split_top_level(s, "|")
end
M.split_union = split_union

-- Inner text of `Name<...>`, but only when the angle bracket that opens after
-- `Name` closes at the very last character.  A greedy `^Name<(.+)>$` also
-- matches a top-level union like `Effect<A> | Effect<B>`, which then splits
-- into nonsense channels.
local function match_generic(s, name)
  local open = name .. "<"
  if s:sub(1, #open) ~= open or s:sub(-1) ~= ">" then
    return nil
  end
  local depth = 0
  for i = #open, #s do
    local c = s:sub(i, i)
    if c == "<" then
      depth = depth + 1
    elseif c == ">" and s:sub(i - 1, i - 1) ~= "=" then
      depth = depth - 1
      if depth == 0 then
        if i ~= #s then
          return nil
        end
        return trim(s:sub(#open + 1, #s - 1))
      end
    end
  end
  return nil
end
M.match_generic = match_generic

-- Strip common Effect-ecosystem noise before matching the outer shape.
-- Import qualifiers come off first: TS prints unimported types fully qualified
-- (`import("…/effect/Utils").YieldWrap<…>`), so the unwrap below has to be
-- looking at a bare name.
local function clean_effect_string(s)
  if not s then
    return s
  end
  s = trim(s:gsub('import%("[^"]+"%)%.', ""))
  return match_generic(s, "YieldWrap") or match_generic(s, "Utils.YieldWrap") or s
end

-- Unwrap Context.Tag<"Id", Service>  ->  Service.  Handles both the bare
-- form and the namespaced Context.Tag / Context.Reference variants.
local function unwrap_context_tag(member)
  local service = member:match('^Context%.Tag<"[^"]-",%s*(.-)>$')
    or member:match('^Context%.Reference<"[^"]-",%s*(.-)>$')
    or member:match('^Tag<"[^"]-",%s*(.-)>$')
  return service or member
end

local function unwrap_union_services(r)
  if not r or r == "never" then
    return r
  end
  local members = split_union(r)
  for i, m in ipairs(members) do
    members[i] = unwrap_context_tag(m)
  end
  return table.concat(members, " | ")
end

-- Parse Effect<A, E, R> / Stream<A, E, R> / Layer<ROut, E, RIn>. Returns
-- { tag, A, E, R, labels = {A,E,R|ROut,E,RIn} } or nil.
local function parse_effect_type(s)
  if not s then
    return nil
  end
  s = clean_effect_string(s)

  local tag, inner
  inner = match_generic(s, "Effect.Effect") or match_generic(s, "Effect")
  if inner then
    tag = "effect"
  else
    inner = match_generic(s, "Stream.Stream") or match_generic(s, "Stream")
    if inner then
      tag = "stream"
    else
      inner = match_generic(s, "Layer.Layer") or match_generic(s, "Layer")
      if inner then
        tag = "layer"
      end
    end
  end

  if not inner then
    return nil
  end

  local parts = split_generic_args(inner)
  local A, E, R = parts[1], parts[2] or "never", parts[3] or "never"
  if not A or A == "" then
    return nil
  end

  -- Context.Tag unwrapping applies to the requirements channel for Effect /
  -- Stream (and RIn for Layer).  E is untouched — errors aren't Tag-wrapped.
  R = unwrap_union_services(R)

  if tag == "layer" then
    return { tag = "layer", A = A, E = E, R = R, labels = { "ROut", "E", "RIn" } }
  end
  return { tag = tag, A = A, E = E, R = R, labels = { "A", "E", "R" } }
end
M.parse_effect_type = parse_effect_type

local function match_assignability(line)
  local got, expected = line:match("Argument of type '(.+)' is not assignable to parameter of type '(.+)'%.?$")
  if got then
    return got, expected
  end
  return line:match("Type '(.+)' is not assignable to type '(.+)'%.?$")
end

-- TS2769's headline ("No overload matches this call.") names no types at all:
-- one indented error per overload carries them.  Return the sub-report worth
-- parsing — the chosen line plus the lines nested under it — or nil.
--
-- Two orderings decide "worth parsing".  An Effect/Stream/Layer pair beats a
-- plain one, since that is the report the whole plugin exists to explain.  Then
-- shallower beats deeper: TS nests the narrowed "Type 'Scope' is not assignable
-- to type 'never'" *under* the argument-level line that still names both full
-- types, and only the latter has enough to diff.
local function pick_nested_report(msg)
  local lines = {}
  for line in msg:gmatch("[^\n]+") do
    table.insert(lines, { indent = #line:match("^%s*"), body = trim(line) })
  end

  local best, best_score
  for i = 2, #lines do
    local got, expected = match_assignability(lines[i].body)
    if got then
      local g, e = parse_effect_type(got), parse_effect_type(expected)
      local score = ((g and e and g.tag == e.tag) and 0 or 1000) + lines[i].indent
      if not best_score or score < best_score then
        best, best_score = i, score
      end
    end
  end
  if not best then
    return nil
  end

  -- Stop at the next sibling: a Property/narrowing line under *another*
  -- overload would otherwise be read as detail about the one we picked.
  local report = { lines[best].body }
  for i = best + 1, #lines do
    if lines[i].indent <= lines[best].indent then
      break
    end
    table.insert(report, lines[i].body)
  end
  return table.concat(report, "\n")
end

function M.has_scope(r)
  if not r then
    return false
  end
  for _, m in ipairs(split_union(r)) do
    if m == "Scope" or m == "Scope.Scope" then
      return true
    end
  end
  return false
end

-- Members of `a` that aren't in `b`. Both are top-level union strings.
function M.union_diff(a, b)
  if not a or a == "never" then
    return {}
  end
  local b_set = {}
  if b and b ~= "never" then
    for _, part in ipairs(split_union(b)) do
      b_set[part] = true
    end
  end
  local missing = {}
  for _, part in ipairs(split_union(a)) do
    if not b_set[part] then
      table.insert(missing, part)
    end
  end
  return missing
end

-- ── public API ────────────────────────────────────────────────────────────

-- Default set of diagnostic sources we format.  Tight, exact-match set —
-- extensible via setup({ sources = { ... } }).  `effect` is @effect/language-
-- service, which reports missing services and unhandled errors under its own
-- source rather than through tsserver.
M.default_sources = {
  typescript = true,
  ts = true,
  vtsls = true,
  effect = true,
}

function M.is_ts_source(source, allowed)
  if not source then
    return false
  end
  local set = allowed or M.default_sources
  return set[source] == true
end

-- Parse a TS diagnostic message into a structured kind + captures.
-- Returns nil if no pattern matched.
function M.parse(msg, opts)
  opts = opts or {}

  local headline = msg:match("^[^\n]*") or ""

  -- A headline that carries no types of its own is a wrapper around nested
  -- reports (TS2769).  Parse the best of those instead.  The recursion cannot
  -- run away: the promoted report always leads with an assignability sentence,
  -- which fails this guard.  A nil falls through, so the patterns below still
  -- get their shot at the headline.
  if not headline:find("is not assignable to", 1, true) then
    local nested = pick_nested_report(msg)
    if nested then
      local nested_result = M.parse(nested, opts)
      if nested_result then
        return nested_result
      end
    end
  end

  -- Capture details that live on a continuation line before we strip it.
  -- TS2741 puts "Property 'X' is missing" there, and TS2349 puts the only half
  -- that names the type ("Type 'X' has no call signatures").
  local missing_prop_full = msg:match("Property '([^']+)' is missing")

  -- TS2349's headline is "This expression is not callable."; the type only
  -- appears on the next line.  TS2769 ("No overload matches this call") nests
  -- the same "has no call signatures" text under an overload report, so the
  -- headline has to agree before we claim the expression isn't callable.
  local no_call_sigs = headline:match("is not callable") ~= nil and msg:match("has no call signatures") ~= nil
  local no_call_type = no_call_sigs and msg:match("Type '([^']+)' has no call signatures") or nil

  -- TS often appends follow-up sentences after the core error; strip them so
  -- the `$`-anchored patterns below can still match.
  msg = msg:gsub("\n.*", ""):gsub("%.%s+Property.-$", ""):gsub(" with '[^']+'.-$", "")

  local got, expected = msg:match("Type '(.+)' is not assignable to type '(.+)'%.?$")
  if not got then
    got, expected = msg:match("Argument of type '(.+)' is not assignable to parameter of type '(.+)'%.?$")
  end

  if got then
    if opts.effect ~= false then
      local got_eff = parse_effect_type(got)
      local exp_eff = parse_effect_type(expected)
      if got_eff and exp_eff and got_eff.tag == exp_eff.tag then
        local missing_services = M.union_diff(got_eff.R, exp_eff.R)
        local unhandled_errors = M.union_diff(got_eff.E, exp_eff.E)
        local success_differs = got_eff.A ~= exp_eff.A
        local scope_required = M.has_scope(got_eff.R) and not M.has_scope(exp_eff.R)
        local diff_count = 0
        if success_differs then
          diff_count = diff_count + 1
        end
        if got_eff.E ~= exp_eff.E then
          diff_count = diff_count + 1
        end
        if got_eff.R ~= exp_eff.R then
          diff_count = diff_count + 1
        end
        return {
          kind = "effect_mismatch",
          tag = got_eff.tag,
          labels = got_eff.labels,
          got = got_eff,
          expected = exp_eff,
          missing_services = missing_services,
          unhandled_errors = unhandled_errors,
          success_differs = success_differs,
          scope_required = scope_required,
          diff_count = diff_count,
          -- Pre-normalization types. When diff_count == 0 these are the only
          -- thing that still differs (duplicate package copies), so the
          -- renderer needs them to say anything useful.
          raw = { got = got, expected = expected },
        }
      end
    end

    local missing_prop = msg:match("Property '([^']+)' is missing") or missing_prop_full
    return { kind = "type_mismatch", got = got, expected = expected, missing = missing_prop }
  end

  -- @effect/language-service (source: "effect").  These name the missing pieces
  -- outright, so they reach the same boxes with no types to diff.  Services and
  -- errors arrive pre-joined with " | ".
  local ctx = msg:match("missing from the expected Effect context: `(.-)`")
  if ctx then
    return {
      kind = "missing_context",
      tag = "effect",
      services = split_union(ctx),
      scope_required = M.has_scope(ctx),
    }
  end

  local layer_ctx = msg:match("Missing '(.-)' in the expected Layer context")
  if layer_ctx then
    return {
      kind = "missing_context",
      tag = "layer",
      services = split_union(layer_ctx),
      scope_required = M.has_scope(layer_ctx),
    }
  end

  local unhandled = msg:match("Missing '(.-)' in the expected Effect errors")
  if unhandled then
    return { kind = "missing_errors", tag = "effect", errors = split_union(unhandled) }
  end

  local prop, in_type, req_type = msg:match("Property '(.-)' is missing in type '(.-)' but required in type '(.-)'")
  if prop then
    return { kind = "missing_property", prop = prop, in_type = in_type, required = req_type }
  end

  local mp, on_type = msg:match("Property '(.-)' does not exist on type '(.-)'")
  if mp then
    return { kind = "unknown_property", prop = mp, on_type = on_type }
  end

  local name = msg:match("Cannot find name '(.-)'")
  if name then
    return { kind = "undefined", name = name }
  end

  local module_path = msg:match("Cannot find module '(.-)' or its corresponding type declarations")
    or msg:match("Cannot find module '(.-)'")
  if module_path then
    return { kind = "module_not_found", path = module_path }
  end

  local no_mod, no_mem = msg:match("Module '\"(.-)\"' has no exported member '(.-)'")
  if not no_mod then
    no_mod, no_mem = msg:match("Module '(.-)' has no exported member '(.-)'")
  end
  if no_mod then
    return { kind = "export_not_found", module = no_mod, member = no_mem }
  end

  local implicit = msg:match("Parameter '(.-)' implicitly has an 'any' type")
  if implicit then
    return { kind = "implicit_any", name = implicit }
  end

  local used_before = msg:match("Variable '(.-)' is used before being assigned")
  if used_before then
    return { kind = "used_before_assigned", name = used_before }
  end

  -- TS2533 is "possibly 'null' or 'undefined'" — capture both halves, not just
  -- the first.  TS18048 names the expression instead of saying "Object".
  local null_a, null_b = msg:match("Object is possibly '(.-)' or '(.-)'")
  if null_a then
    return { kind = "nullish", value = null_a .. " or " .. null_b }
  end
  local nullish = msg:match("Object is possibly '(.-)'")
  if nullish then
    return { kind = "nullish", value = nullish }
  end
  -- Both-halves form first: the two-capture pattern below would stop at the
  -- first quote and silently drop the "or undefined".
  local nn_name, nn_a, nn_b = msg:match("'(.-)' is possibly '(.-)' or '(.-)'")
  if nn_name then
    return { kind = "nullish", name = nn_name, value = nn_a .. " or " .. nn_b }
  end
  local nullish_name, nullish_val = msg:match("'(.-)' is possibly '(.-)'")
  if nullish_name then
    return { kind = "nullish", name = nullish_name, value = nullish_val }
  end

  -- TS2554 is a plain count; TS2555 and overloads use "at least N" and "N-M".
  local exp_args, got_args = msg:match("Expected (%d+) arguments?, but got (%d+)")
  if not exp_args then
    exp_args, got_args = msg:match("Expected (at least %d+) arguments?, but got (%d+)")
  end
  if not exp_args then
    exp_args, got_args = msg:match("Expected (%d+%-%d+) arguments?, but got (%d+)")
  end
  if exp_args then
    return { kind = "arg_count", expected = exp_args, got = got_args }
  end

  local const_name = msg:match("Cannot assign to '(.-)' because it is a constant")
  if const_name then
    return { kind = "const_assign", name = const_name }
  end

  if no_call_sigs then
    return { kind = "not_callable", type = no_call_type }
  end

  local dep_sig, dep_name = msg:match("The signature '(.-)' of '(.-)' is deprecated")
  if dep_sig then
    return { kind = "deprecated", name = dep_name, signature = dep_sig }
  end
  local deprecated_name = msg:match("'(.-)' is deprecated")
  if deprecated_name then
    return { kind = "deprecated", name = deprecated_name }
  end

  -- User-provided extra parsers (setup opts.extra_patterns).  A bare function
  -- is accepted alongside a list, since that mistake is easy to make and the
  -- alternative is an `ipairs` error on every TS diagnostic.
  local extra = opts.extra_patterns
  if type(extra) == "function" then
    extra = { extra }
  end
  if type(extra) == "table" then
    for _, parser in ipairs(extra) do
      local result = parser(msg)
      if result then
        return result
      end
    end
  end

  return nil
end

return M

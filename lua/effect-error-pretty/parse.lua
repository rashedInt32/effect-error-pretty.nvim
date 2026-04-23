-- Pure parser: TS diagnostic message -> structured `kind` table.
-- No side effects; safe to unit-test.

local M = {}

-- ── helpers ────────────────────────────────────────────────────────────────

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split a generic argument list at top-level commas, respecting nested
-- <>, [], (), {} depth.  "A, B<C, D>, E" -> { "A", "B<C, D>", "E" }.
local function split_generic_args(s)
  local parts = {}
  local depth = 0
  local current = ""
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "<" or c == "[" or c == "(" or c == "{" then
      depth = depth + 1
      current = current .. c
    elseif c == ">" or c == "]" or c == ")" or c == "}" then
      depth = depth - 1
      current = current .. c
    elseif c == "," and depth == 0 then
      table.insert(parts, trim(current))
      current = ""
    else
      current = current .. c
    end
  end
  if #trim(current) > 0 then
    table.insert(parts, trim(current))
  end
  return parts
end

-- Split a top-level union "A | B | C<D | E>" into members, respecting depth.
local function split_union(s)
  local parts = {}
  local depth = 0
  local current = ""
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "<" or c == "[" or c == "(" or c == "{" then
      depth = depth + 1
      current = current .. c
    elseif c == ">" or c == "]" or c == ")" or c == "}" then
      depth = depth - 1
      current = current .. c
    elseif c == "|" and depth == 0 then
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
M.split_union = split_union

-- Strip common Effect-ecosystem noise before matching the outer shape.
local function clean_effect_string(s)
  if not s then
    return s
  end
  s = s:gsub("^YieldWrap<(.+)>$", "%1")
  s = s:gsub('import%("[^"]+"%)%.', "")
  return trim(s)
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
  inner = s:match("^Effect%.Effect<(.+)>$") or s:match("^Effect<(.+)>$")
  if inner then
    tag = "effect"
  else
    inner = s:match("^Stream%.Stream<(.+)>$") or s:match("^Stream<(.+)>$")
    if inner then
      tag = "stream"
    else
      inner = s:match("^Layer%.Layer<(.+)>$") or s:match("^Layer<(.+)>$")
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

-- Default set of diagnostic sources we treat as "TypeScript".  Tight,
-- exact-match set — extensible via setup({ sources = { ... } }).
M.default_sources = {
  typescript = true,
  ts = true,
  vtsls = true,
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

  -- Capture "Property 'X' is missing" before trimming, since TS often puts
  -- this detail on a continuation line we're about to strip.
  local missing_prop_full = msg:match("Property '([^']+)' is missing")

  -- TS often appends follow-up sentences after the core error; strip them so
  -- the `$`-anchored patterns below can still match.
  msg =
    msg:gsub("\n.*", ""):gsub("%.%s+Property.-$", ""):gsub(" with '[^']+': %w+%'.-$", ""):gsub(" with '[^']+'.-$", "")

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
        }
      end
    end

    local missing_prop = msg:match("Property '([^']+)' is missing") or missing_prop_full
    return { kind = "type_mismatch", got = got, expected = expected, missing = missing_prop }
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

  local nullish = msg:match("Object is possibly '(.-)'")
  if nullish then
    return { kind = "nullish", value = nullish }
  end

  local exp_args, got_args = msg:match("Expected (%d+) arguments?, but got (%d+)")
  if exp_args then
    return { kind = "arg_count", expected = exp_args, got = got_args }
  end

  local const_name = msg:match("Cannot assign to '(.-)' because it is a constant")
  if const_name then
    return { kind = "const_assign", name = const_name }
  end

  if msg:match("has no call signatures") then
    local t = msg:match("Type '(.-)' has no call signatures")
    return { kind = "not_callable", type = t }
  end

  local dep_sig, dep_name = msg:match("The signature '(.-)' of '(.-)' is deprecated")
  if dep_sig then
    return { kind = "deprecated", name = dep_name, signature = dep_sig }
  end
  local deprecated_name = msg:match("'(.-)' is deprecated")
  if deprecated_name then
    return { kind = "deprecated", name = deprecated_name }
  end

  -- User-provided extra parsers (setup opts.extra_patterns).
  if opts.extra_patterns then
    for _, parser in ipairs(opts.extra_patterns) do
      local result = parser(msg)
      if result then
        return result
      end
    end
  end

  return nil
end

return M

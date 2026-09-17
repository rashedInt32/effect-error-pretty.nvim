-- Optional Jev enrichment (TypeSafe System One).
--
-- The formatter this plugin installs is *synchronous*: vim.diagnostic calls
-- `format` in a plain loop for every diagnostic in the window, so nothing here
-- may block.  The deterministic parse therefore always renders first, and this
-- module only ever fills a cache out of band.  A hover that misses the cache
-- looks exactly like the plugin did before; the next hover is enriched.
--
-- Nothing here runs unless `setup({ typesafe = { enabled = true } })` and an
-- API key are both present.  Diagnostics carry your own type and service names,
-- so shipping them to a third party stays opt-in by design.

local M = {}

local ENDPOINT = "https://api.typesafe.ai/v1/systemone"

-- Long reports cost tokens and add nothing: the distinguishing part of an
-- overload report is its head, not the narrowing nested three levels down.
local MAX_OPTION_CHARS = 400

-- The escape hatch on every selection.  Without it the model must pick some
-- candidate even when none is the intended call.
local NONE = "none"

local defaults = {
  enabled = false,
  api_key = nil, -- falls back to $TYPESAFE_API_KEY
  model = "jev-latest",
  -- Below this, keep the deterministic heuristic.  It already works, so a
  -- coin-flip answer has nothing to beat.
  min_confidence = 0.6,
  timeout_ms = 5000,
}

local state = {
  opts = vim.deepcopy(defaults),
  cache = {}, -- key -> resolved index
  inflight = {}, -- key -> true
  notified = {},
}

---@param opts? table
function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  state.cache, state.inflight = {}, {}
end

local function api_key()
  return state.opts.api_key or vim.env.TYPESAFE_API_KEY
end

-- Enrichment is available only when switched on *and* keyed.  Callers use this
-- to stay silent rather than erroring on every diagnostic.
function M.available()
  return state.opts.enabled == true and api_key() ~= nil and api_key() ~= ""
end

local function warn_once(msg)
  if state.notified[msg] then
    return
  end
  state.notified[msg] = true
  vim.schedule(function()
    vim.notify("[effect-error-pretty] " .. msg, vim.log.levels.WARN)
  end)
end

local function truncate(s, n)
  if vim.fn.strchars(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, n) .. "…"
end

-- ── request shaping ───────────────────────────────────────────────────────

-- Build the System One request body.  Pure, so the wire format is unit-testable
-- without a key or a network.
---@param content string|table  the `state` the questions are asked about
---@param questions table
---@return table
function M.build_request(content, questions)
  return { state = content, model = state.opts.model, questions = questions }
end

-- A Choice whose options *are* the candidate reports code already enumerated.
-- The answer is therefore an index into that list: Jev can pick the wrong
-- report, but it cannot invent one, and it cannot reword the types.
---@param candidates table[]  from parse.candidate_reports
---@return table
function M.overload_question(candidates)
  local criteria = {}
  for i, candidate in ipairs(candidates) do
    criteria[tostring(i)] = truncate(candidate.report, MAX_OPTION_CHARS)
  end
  criteria[NONE] = "None of these reports describes the call the developer meant to write."

  return {
    type = "choice",
    instructions = table.concat({
      "A TypeScript TS2769 error reports one failure per candidate overload of the function being called.",
      "Exactly one of those reports describes the overload the developer actually intended to call.",
      "Select that report.",
      "Prefer the report that names the full argument and parameter types the developer wrote.",
      "Reject a report that only states a narrowed consequence, such as one type not being assignable to `never`.",
    }, " "),
    criteria = criteria,
  }
end

-- ── transport ─────────────────────────────────────────────────────────────

-- Send `body` and hand the decoded response to `cb`, or nil on any failure.
--
-- The key goes in a 0600 curl config file rather than on the command line:
-- argv is world-readable through `ps` on a shared machine.
---@param body table
---@param cb fun(decoded: table|nil)
function M.request(body, cb)
  local key = api_key()
  if not key then
    return cb(nil)
  end

  local ok, encoded = pcall(vim.json.encode, body)
  if not ok then
    return cb(nil)
  end

  local body_file = vim.fn.tempname()
  local config_file = vim.fn.tempname()
  vim.fn.writefile(vim.split(encoded, "\n"), body_file, "b")
  vim.fn.writefile({
    ('url = "%s"'):format(ENDPOINT),
    'request = "POST"',
    'header = "Content-Type: application/json"',
    ('header = "Authorization: Bearer %s"'):format(key),
    ('data-binary = "@%s"'):format(body_file),
    ("max-time = %d"):format(math.max(1, math.floor(state.opts.timeout_ms / 1000))),
    "silent",
    "show-error",
  }, config_file)
  vim.fn.setfperm(body_file, "rw-------")
  vim.fn.setfperm(config_file, "rw-------")

  local function cleanup()
    pcall(vim.fn.delete, body_file)
    pcall(vim.fn.delete, config_file)
  end

  vim.system({ "curl", "--config", config_file }, { text = true }, function(result)
    cleanup()
    if result.code ~= 0 then
      warn_once("TypeSafe request failed: " .. (result.stderr or "curl exited " .. result.code))
      return cb(nil)
    end
    local decoded_ok, decoded = pcall(vim.json.decode, result.stdout)
    if not decoded_ok or type(decoded) ~= "table" then
      return cb(nil)
    end
    -- The API reports 401/422/429 in the body, not the exit code.
    if decoded.answers == nil then
      warn_once("TypeSafe returned no answers: " .. truncate(result.stdout or "", 120))
      return cb(nil)
    end
    cb(decoded)
  end)
end

-- ── overload selection ────────────────────────────────────────────────────

local function cache_key(msg)
  return vim.fn.sha256(msg)
end

-- Synchronous selector handed to parse.parse via opts.pick_overload.
--
-- Returns a cached index when one exists, and otherwise nil, which keeps the
-- existing heuristic.  A miss also kicks off the request that will populate the
-- cache, so the answer is ready for the next hover.
---@param msg string
---@param candidates table[]
---@return integer|nil
function M.pick_overload(msg, candidates)
  if not M.available() or #candidates < 2 then
    return nil
  end

  local key = cache_key(msg)
  local cached = state.cache[key]
  if cached ~= nil then
    -- `false` records a resolved "keep the heuristic", so we stop re-asking.
    return cached or nil
  end
  if state.inflight[key] then
    return nil
  end
  state.inflight[key] = true

  local body = M.build_request({ diagnostic = msg }, { overload = M.overload_question(candidates) })

  vim.schedule(function()
    M.request(body, function(decoded)
      local answer = decoded and decoded.answers and decoded.answers.overload
      local resolved = false
      if answer and answer.choice and answer.choice ~= NONE then
        local index = tonumber(answer.choice)
        local confident = (answer.confidence or 0) >= state.opts.min_confidence
        if index and candidates[index] and confident then
          resolved = index
        end
      end
      vim.schedule(function()
        state.cache[key] = resolved
        state.inflight[key] = nil
        -- Let a config redraw the float; re-opening it from here would fight
        -- whatever the user is doing by the time the answer lands.
        vim.api.nvim_exec_autocmds("User", {
          pattern = "EffectErrorPrettyEnriched",
          data = { resolved = resolved },
        })
      end)
    end)
  end)

  return nil
end

-- Test and debug seam: force a resolved selection without a network round trip.
function M.prime_cache(msg, index)
  state.cache[cache_key(msg)] = index
end

function M.clear_cache()
  state.cache, state.inflight = {}, {}
end

return M

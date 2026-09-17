-- Offline tests for the Jev enrichment seam.
--
-- Nothing here touches the network.  The transport is exercised only through
-- `build_request` / `overload_question`, which are pure, and through a primed
-- cache standing in for an answer that already landed.
--
-- Run: nvim --headless --noplugin -u tests/minimal_init.lua \
--        -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local parse = require("effect-error-pretty.parse")
local typesafe = require("effect-error-pretty.typesafe")

-- The real thing, from `Effect.runFork(Effect.forkScoped(job))`.
local NO_OVERLOAD = table.concat({
  "No overload matches this call.",
  "  Overload 1 of 2, '(options?: { readonly teardown?: Teardown | undefined; } | undefined): <E, A>(effect: Effect<A, E, never>) => void', gave the following error.",
  "    Type 'Effect<Fiber<never, never>, never, Scope>' has no properties in common with type '{ readonly teardown?: Teardown | undefined; }'.",
  "  Overload 2 of 2, '(effect: Effect<Fiber<never, never>, never, never>, options?: undefined): void', gave the following error.",
  "    Argument of type 'Effect<Fiber<never, never>, never, Scope>' is not assignable to parameter of type 'Effect<Fiber<never, never>, never, never>'.",
  "      Type 'Scope' is not assignable to type 'never'.",
}, "\n")

describe("parse.candidate_reports", function()
  it("enumerates every assignability line, and only those", function()
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    -- "has no properties in common with" is not an assignability sentence, so
    -- overload 1 contributes nothing to diff.
    assert.are.equal(2, #candidates)
    assert.is_truthy(candidates[1].body:find("Argument of type", 1, true))
    assert.is_truthy(candidates[2].body:find("Type 'Scope' is not assignable", 1, true))
  end)

  it("marks which candidates are an Effect/Stream/Layer pair", function()
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    assert.is_true(candidates[1].effect_pair)
    assert.is_false(candidates[2].effect_pair)
  end)

  it("attaches the lines nested under a candidate to that candidate", function()
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    assert.is_truthy(candidates[1].report:find("Type 'Scope' is not assignable", 1, true))
  end)

  it("returns an empty list for a message with no nested reports", function()
    assert.are.same({}, parse.candidate_reports("Cannot find name 'foo'."))
  end)
end)

describe("parse.parse — overload selection seam", function()
  it("keeps the deterministic heuristic when no selector is given", function()
    local r = parse.parse(NO_OVERLOAD)
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.same({ "Scope" }, r.missing_services)
  end)

  it("lets a selector override the heuristic", function()
    -- Index 2 is the narrowed consequence the heuristic deliberately rejects.
    -- Forcing it proves the seam actually steers the parse.
    local r = parse.parse(NO_OVERLOAD, {
      pick_overload = function()
        return 2
      end,
    })
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("Scope", r.got)
    assert.are.equal("never", r.expected)
  end)

  it("ignores a selector that returns nil", function()
    local r = parse.parse(NO_OVERLOAD, {
      pick_overload = function()
        return nil
      end,
    })
    assert.are.equal("effect_mismatch", r.kind)
  end)

  it("ignores an out-of-range or non-numeric selection", function()
    for _, bad in ipairs({ 99, -1, "2", true }) do
      local r = parse.parse(NO_OVERLOAD, {
        pick_overload = function()
          return bad
        end,
      })
      assert.are.equal("effect_mismatch", r.kind)
    end
  end)

  it("survives a selector that throws", function()
    local r = parse.parse(NO_OVERLOAD, {
      pick_overload = function()
        error("boom")
      end,
    })
    assert.are.equal("effect_mismatch", r.kind)
  end)
end)

describe("typesafe.overload_question", function()
  it("offers the candidate reports verbatim, keyed by index", function()
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    local q = typesafe.overload_question(candidates)
    assert.are.equal("choice", q.type)
    assert.are.equal(candidates[1].report, q.criteria["1"])
    assert.are.equal(candidates[2].report, q.criteria["2"])
  end)

  it("always includes a no-match escape hatch", function()
    local q = typesafe.overload_question(parse.candidate_reports(NO_OVERLOAD))
    assert.is_truthy(q.criteria["none"])
  end)

  it("puts the judgment in instructions, not in the question id", function()
    local q = typesafe.overload_question(parse.candidate_reports(NO_OVERLOAD))
    assert.is_truthy(q.instructions:find("intended to call", 1, true))
  end)
end)

describe("typesafe.build_request", function()
  it("shapes a System One request body", function()
    local body = typesafe.build_request({ diagnostic = "x" }, { overload = { type = "choice" } })
    assert.are.same({ diagnostic = "x" }, body.state)
    assert.are.equal("jev-latest", body.model)
    assert.is_truthy(body.questions.overload)
  end)

  it("round-trips through vim.json", function()
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    local body = typesafe.build_request(
      { diagnostic = NO_OVERLOAD },
      { overload = typesafe.overload_question(candidates) }
    )
    local decoded = vim.json.decode(vim.json.encode(body))
    assert.are.equal("jev-latest", decoded.model)
    assert.are.equal("choice", decoded.questions.overload.type)
  end)
end)

describe("typesafe.available", function()
  before_each(function()
    typesafe.setup({})
    typesafe.clear_cache()
  end)

  it("is off until enabled, even with a key", function()
    typesafe.setup({ api_key = "sk-test" })
    assert.is_false(typesafe.available())
  end)

  it("is off when enabled without a key", function()
    typesafe.setup({ enabled = true, api_key = "" })
    -- Guard against a key leaking in from the developer's own environment.
    local saved = vim.env.TYPESAFE_API_KEY
    vim.env.TYPESAFE_API_KEY = nil
    assert.is_false(typesafe.available())
    vim.env.TYPESAFE_API_KEY = saved
  end)

  it("is on when both are present", function()
    typesafe.setup({ enabled = true, api_key = "sk-test" })
    assert.is_true(typesafe.available())
  end)
end)

describe("typesafe.pick_overload", function()
  before_each(function()
    typesafe.setup({ enabled = true, api_key = "sk-test" })
    typesafe.clear_cache()
  end)

  it("returns nil and fires nothing when enrichment is off", function()
    typesafe.setup({})
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    assert.is_nil(typesafe.pick_overload(NO_OVERLOAD, candidates))
  end)

  it("does not ask when there is only one candidate", function()
    assert.is_nil(typesafe.pick_overload(NO_OVERLOAD, { { report = "only one" } }))
  end)

  it("serves a resolved answer from the cache", function()
    typesafe.prime_cache(NO_OVERLOAD, 2)
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    assert.are.equal(2, typesafe.pick_overload(NO_OVERLOAD, candidates))
  end)

  it("treats a cached false as 'keep the heuristic' without re-asking", function()
    typesafe.prime_cache(NO_OVERLOAD, false)
    local candidates = parse.candidate_reports(NO_OVERLOAD)
    assert.is_nil(typesafe.pick_overload(NO_OVERLOAD, candidates))
  end)

  it("steers a real parse once the answer is cached", function()
    typesafe.prime_cache(NO_OVERLOAD, 2)
    local r = parse.parse(NO_OVERLOAD, { pick_overload = typesafe.pick_overload })
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("Scope", r.got)
  end)
end)

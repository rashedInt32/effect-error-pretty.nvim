-- The hint seam: families, templates, resolver injection, overload picker.
-- Nothing here touches the network; a resolver is a plain function.

local parse = require("effect-error-pretty.parse")
local render = require("effect-error-pretty.render")
local hints = require("effect-error-pretty.hints")

local SUFFIX = " with 'exactOptionalPropertyTypes: true'. Consider adding 'undefined' to the types of the target's properties."
local MISSING = "Argument of type 'Effect<string, NotFound, Greeter | Database>' is not assignable to parameter of type 'Effect<string, NotFound, never>'" .. SUFFIX
local UNHANDLED = "Type 'Effect<string, NotFound, Database>' is not assignable to type 'Effect<string, never, Database>'" .. SUFFIX
local LS_ERRORS = "Missing 'NotFound | Timeout' in the expected Effect errors."
local LS_CTX = "This Effect requires a service that is missing from the expected Effect context: `Greeter`."
local SCOPE = "Type 'Effect<string, never, Scope>' is not assignable to type 'Effect<string, never, never>'"
local LAYER_RIN = "Type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, Database>' is not assignable to type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, never>'."
local LS_LAYER = "Missing 'Database' in the expected Layer context."
local WIDE_R = "Argument of type 'Effect<string, never, unknown>' is not assignable to parameter of type 'Effect<string, never, never>'" .. SUFFIX
local WIDE_E = "Type 'Effect<string, unknown, never>' is not assignable to type 'Effect<string, never, never>'" .. SUFFIX
local LS_WIDE_E = "Missing 'unknown' in the expected Effect errors."
local LS_WIDE_RIN = "Missing 'any' in the expected Layer context."
local MULTI = "Type 'Effect<string, NotFound, Database>' is not assignable to type 'Effect<number, never, never>'" .. SUFFIX

local NO_OVERLOAD = table.concat({
  "No overload matches this call.",
  "  Overload 1 of 2, '(options?: { readonly teardown?: Teardown | undefined; } | undefined): <E, A>(effect: Effect<A, E, never>) => void', gave the following error.",
  "    Type 'Effect<Fiber<never, never>, never, Scope>' has no properties in common with type '{ readonly teardown?: Teardown | undefined; }'.",
  "  Overload 2 of 2, '(effect: Effect<Fiber<never, never>, never, never>, options?: undefined): void', gave the following error.",
  "    Argument of type 'Effect<Fiber<never, never>, never, Scope>' is not assignable to parameter of type 'Effect<Fiber<never, never>, never, never>'.",
  "      Type 'Scope' is not assignable to type 'never'.",
}, "\n")

local function diag(message, source)
  return { message = message, source = source or "typescript", lnum = 0, col = 0, severity = 1, bufnr = 0 }
end

describe("hints.family", function()
  it("classifies missing services from a type diff and from the language service", function()
    local f, names = hints.family(parse.parse(MISSING))
    assert.are.equal("services", f)
    assert.are.same({ "Greeter", "Database" }, names)
    f, names = hints.family(parse.parse(LS_CTX))
    assert.are.equal("services", f)
    assert.are.same({ "Greeter" }, names)
  end)

  it("classifies unhandled errors from both sources", function()
    local f, names = hints.family(parse.parse(UNHANDLED))
    assert.are.equal("errors", f)
    assert.are.same({ "NotFound" }, names)
    f, names = hints.family(parse.parse(LS_ERRORS))
    assert.are.equal("errors", f)
    assert.are.same({ "NotFound", "Timeout" }, names)
  end)

  it("classifies a Layer's missing RIn as services and marks the tag", function()
    local parsed = parse.parse(LAYER_RIN)
    local f, names = hints.family(parsed)
    assert.are.equal("services", f)
    assert.are.same({ "Database" }, names)
    assert.are.equal("layer", parsed.tag)
    parsed = parse.parse(LS_LAYER)
    f, names = hints.family(parsed)
    assert.are.equal("services", f)
    assert.are.same({ "Database" }, names)
    assert.are.equal("layer", parsed.tag)
  end)

  it("classifies a channel that is only unknown/any as widened, named by its label", function()
    local f, names = hints.family(parse.parse(WIDE_R))
    assert.are.equal("widened", f)
    assert.are.same({ "R" }, names)
    f, names = hints.family(parse.parse(WIDE_E))
    assert.are.equal("widened", f)
    assert.are.same({ "E" }, names)
    f, names = hints.family(parse.parse(LS_WIDE_E))
    assert.are.equal("widened", f)
    assert.are.same({ "E" }, names)
    f, names = hints.family(parse.parse(LS_WIDE_RIN))
    assert.are.equal("widened", f)
    assert.are.same({ "RIn" }, names)
  end)

  it("asks nothing when more than one channel differs", function()
    local parsed = parse.parse(MULTI)
    assert.is_true(parsed.diff_count > 1)
    assert.is_nil(hints.family(parsed))
  end)

  it("leaves scope-only results alone", function()
    assert.is_nil(hints.family(parse.parse(SCOPE)))
    assert.is_nil(hints.family(nil))
    assert.is_nil(hints.family(parse.parse("Cannot find name 'foo'.")))
  end)
end)

describe("hints.templates", function()
  it("renders provide for each placement", function()
    assert.are.equal(".pipe(Effect.provide(AppLive))", hints.templates.provide("AppLive", { "Greeter" }, "here"))
    assert.are.equal(".pipe(Effect.provide(AppLive))", hints.templates.provide("AppLive", { "Greeter" }, nil))
    assert.are.equal("keep Greeter | Database in R; provide AppLive higher up", hints.templates.provide("AppLive", { "Greeter", "Database" }, "caller"))
    assert.are.equal("Layer.provide(LoggerLive) inside this layer", hints.templates.provide("LoggerLive", { "Logger" }, "layer"))
  end)

  it("renders each unhandled-error fix", function()
    local t = hints.templates.unhandled
    assert.are.equal('.pipe(Effect.catchTag("NotFound", () => Effect.succeed(fallback)))', t("catch_tag", { "NotFound" }))
    assert.are.equal(".pipe(Effect.catchTags({ NotFound: () => Effect.succeed(fallback), Timeout: () => Effect.succeed(fallback) }))", t("catch_tag", { "NotFound", "Timeout" }))
    assert.are.equal(".pipe(Effect.orDie)  — treat as a defect here", t("or_die", { "NotFound" }))
    assert.are.equal("declare NotFound | Timeout in this function's E channel; let the caller handle it", t("declare", { "NotFound", "Timeout" }))
    assert.are.equal(".pipe(Effect.mapError((e) => new UserServiceError({ cause: e })))", t("map_error", { "NotFound" }, "UserServiceError"))
    assert.are.equal(".pipe(Effect.mapError((e) => new DomainError({ cause: e })))", t("map_error", { "NotFound" }))
    assert.is_nil(t("nope", { "NotFound" }))
  end)
end)

describe("hints resolver seam", function()
  after_each(function()
    hints.set_resolver(nil)
  end)

  it("renders the generic hint when no resolver is registered", function()
    local box = render.artistic(diag(MISSING), { effect = true })
    assert.is_truthy(box:find("⚡ Hint: .pipe(Effect.provide(SomeLayer))", 1, true))
    assert.is_falsy(box:find("↳", 1, true))
  end)

  it("replaces the generic line with the resolver's concrete hint and detail", function()
    hints.set_resolver(function(parsed, family, names, diagnostic)
      assert.are.equal("services", family)
      assert.are.same({ "Greeter", "Database" }, names)
      assert.are.equal(MISSING, diagnostic.message)
      return { label = "Jev", line = hints.templates.provide("AppLive", names, "here"), detail = "layer AppLive 0.99" }
    end)
    local box = render.artistic(diag(MISSING), { effect = true })
    assert.is_truthy(box:find("⚡ Jev: .pipe(Effect.provide(AppLive))", 1, true))
    assert.is_truthy(box:find("↳ layer AppLive 0.99", 1, true))
    assert.is_falsy(box:find("SomeLayer", 1, true))
  end)

  it("honors the resolver in the Layer RIn box, from a type diff and from the language service", function()
    hints.set_resolver(function(parsed, family, names)
      assert.are.equal("services", family)
      assert.are.equal("layer", parsed.tag)
      return { label = "Jev", line = hints.templates.provide("DatabaseLive", names, "layer"), detail = "layer DatabaseLive 0.93" }
    end)
    for _, case in ipairs({ { LAYER_RIN, "typescript" }, { LS_LAYER, "effect" } }) do
      local box = render.artistic(diag(case[1], case[2]), { effect = true })
      assert.is_truthy(box:find("Missing RIn", 1, true))
      assert.is_truthy(box:find("⚡ Jev: Layer.provide(DatabaseLive) inside this layer", 1, true))
      assert.is_truthy(box:find("↳ layer DatabaseLive 0.93", 1, true))
      assert.is_falsy(box:find("Layer.merge", 1, true))
    end
    hints.set_resolver(function()
      return { lean = "jev unsure: layer none 0.40" }
    end)
    local box = render.artistic(diag(LAYER_RIN), { effect = true })
    assert.is_truthy(box:find("⚡ Hint: compose with Layer.provide(...) or Layer.merge(...)", 1, true))
    assert.is_truthy(box:find("↳ jev unsure: layer none 0.40", 1, true))
  end)

  it("lets the resolver name where a widened channel lost its type", function()
    hints.set_resolver(function(_, family, names)
      assert.are.equal("widened", family)
      return { label = "Jev", line = hints.templates.widened(names[1], "fromRegistry", "app.ts", 12), detail = "widened fromRegistry 0.81" }
    end)
    local box = render.artistic(diag(WIDE_R), { effect = true })
    assert.is_truthy(box:find("R Not Inferred", 1, true))
    assert.is_truthy(box:find("⚡ Jev: annotate fromRegistry (app.ts:12), where R widened", 1, true))
    assert.is_truthy(box:find("↳ widened fromRegistry 0.81", 1, true))
    assert.is_falsy(box:find("annotate the effect to find where", 1, true))
    box = render.artistic(diag(LS_WIDE_E, "effect"), { effect = true })
    assert.is_truthy(box:find("E Not Inferred", 1, true))
    assert.is_truthy(box:find("where E widened", 1, true))
    hints.set_resolver(function()
      return { lean = "jev unsure: widened none 0.30" }
    end)
    box = render.artistic(diag(WIDE_E), { effect = true })
    assert.is_truthy(box:find("⚡ Hint: annotate the effect to find where E widened", 1, true))
    assert.is_truthy(box:find("↳ jev unsure: widened none 0.30", 1, true))
  end)

  it("keeps the generic line and adds a lean when the resolver is unsure", function()
    hints.set_resolver(function()
      return { lean = "jev unsure: fix declare 0.47" }
    end)
    local box = render.artistic(diag(UNHANDLED), { effect = true })
    assert.is_truthy(box:find("⚡ Hint: .pipe(Effect.catchTags({...})) or Effect.orDie", 1, true))
    assert.is_truthy(box:find("↳ jev unsure: fix declare 0.47", 1, true))
  end)

  it("works for language-service diagnostics too", function()
    hints.set_resolver(function(_, family, names)
      return { label = "Jev", line = hints.templates.unhandled("or_die", names) }
    end)
    local box = render.artistic(diag(LS_ERRORS, "effect"), { effect = true })
    assert.is_truthy(box:find("⚡ Jev: .pipe(Effect.orDie)", 1, true))
  end)

  it("survives a resolver that throws or returns garbage", function()
    hints.set_resolver(function()
      error("boom")
    end)
    local box = render.artistic(diag(MISSING), { effect = true })
    assert.is_truthy(box:find("SomeLayer", 1, true))
    hints.set_resolver(function()
      return "not a table"
    end)
    box = render.artistic(diag(MISSING), { effect = true })
    assert.is_truthy(box:find("SomeLayer", 1, true))
  end)

  it("is not consulted for families without a fix shape", function()
    local called = false
    hints.set_resolver(function()
      called = true
      return { line = "x" }
    end)
    render.artistic(diag(SCOPE), { effect = true })
    assert.is_false(called)
  end)
end)

describe("overload picker seam", function()
  after_each(function()
    hints.set_overload_picker(nil)
  end)

  it("keeps the deterministic heuristic when no picker is registered", function()
    local r = parse.parse(NO_OVERLOAD, { pick_overload = hints.overload_picker() })
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.same({ "Scope" }, r.missing_services)
  end)

  it("lets a registered picker steer the parse", function()
    hints.set_overload_picker(function()
      return 2
    end)
    local r = parse.parse(NO_OVERLOAD, { pick_overload = hints.overload_picker() })
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("Scope", r.got)
  end)

  it("ignores nil, out-of-range, non-numeric and throwing pickers", function()
    for _, bad in ipairs({ function() return nil end, function() return 99 end, function() return "2" end, function() error("boom") end }) do
      local r = parse.parse(NO_OVERLOAD, { pick_overload = bad })
      assert.are.equal("effect_mismatch", r.kind)
    end
  end)
end)

describe("setup", function()
  it("warns about the removed typesafe option and ignores it", function()
    local pretty = require("effect-error-pretty")
    local seen
    local saved = vim.notify
    vim.notify = function(msg)
      seen = msg
    end
    pretty.setup({ typesafe = { enabled = true } })
    vim.wait(50)
    vim.notify = saved
    assert.is_truthy(seen and seen:find("moved to jury.nvim", 1, true))
  end)
end)

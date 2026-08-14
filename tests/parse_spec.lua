-- Unit tests for the parser.  Run with plenary:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa!"

local parse = require("effect-error-pretty.parse")

describe("parse.is_ts_source", function()
  it("accepts typescript / ts / vtsls exactly", function()
    assert.is_true(parse.is_ts_source("typescript"))
    assert.is_true(parse.is_ts_source("ts"))
    assert.is_true(parse.is_ts_source("vtsls"))
  end)

  it("rejects loose substring matches like 'typos' or 'ts-standard'", function()
    assert.is_false(parse.is_ts_source("typos"))
    assert.is_false(parse.is_ts_source("ts-standard"))
    assert.is_false(parse.is_ts_source("eslint"))
    assert.is_false(parse.is_ts_source(nil))
  end)

  it("honors a custom allowed set", function()
    local allowed = { eslint = true }
    assert.is_true(parse.is_ts_source("eslint", allowed))
    assert.is_false(parse.is_ts_source("typescript", allowed))
  end)
end)

describe("parse.parse — TS core patterns", function()
  it("type_mismatch (TS2322)", function()
    local r = parse.parse("Type 'string' is not assignable to type 'number'.")
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("string", r.got)
    assert.are.equal("number", r.expected)
  end)

  it("type_mismatch with missing property", function()
    local r = parse.parse(
      "Type '{ x: number; y: number; }' is not assignable to type 'Point'.\n  Property 'z' is missing in type '{ x: number; y: number; }' but required in type 'Point'."
    )
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("z", r.missing)
  end)

  it("argument type mismatch (TS2345)", function()
    local r = parse.parse("Argument of type 'string' is not assignable to parameter of type 'number'.")
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("string", r.got)
    assert.are.equal("number", r.expected)
  end)

  it("unknown_property (TS2339)", function()
    local r = parse.parse("Property 'nonexistent' does not exist on type '{ a: number; b: number; }'.")
    assert.are.equal("unknown_property", r.kind)
    assert.are.equal("nonexistent", r.prop)
  end)

  it("undefined (TS2304)", function()
    local r = parse.parse("Cannot find name 'someUndeclaredIdentifier'.")
    assert.are.equal("undefined", r.kind)
    assert.are.equal("someUndeclaredIdentifier", r.name)
  end)

  it("module_not_found (TS2307)", function()
    local r = parse.parse("Cannot find module './totally/missing/module' or its corresponding type declarations.")
    assert.are.equal("module_not_found", r.kind)
    assert.are.equal("./totally/missing/module", r.path)
  end)

  it("export_not_found (TS2305)", function()
    local r = parse.parse("Module '\"fs\"' has no exported member 'nonExistentExport'.")
    assert.are.equal("export_not_found", r.kind)
    assert.are.equal("nonExistentExport", r.member)
  end)

  it("implicit_any (TS7006)", function()
    local r = parse.parse("Parameter 'x' implicitly has an 'any' type.")
    assert.are.equal("implicit_any", r.kind)
    assert.are.equal("x", r.name)
  end)

  it("nullish", function()
    local r = parse.parse("Object is possibly 'null'.")
    assert.are.equal("nullish", r.kind)
    assert.are.equal("null", r.value)
  end)

  it("arg_count (TS2554)", function()
    local r = parse.parse("Expected 2 arguments, but got 1.")
    assert.are.equal("arg_count", r.kind)
    assert.are.equal("1", r.got)
    assert.are.equal("2", r.expected)
  end)

  it("const_assign", function()
    local r = parse.parse("Cannot assign to 'PI' because it is a constant.")
    assert.are.equal("const_assign", r.kind)
    assert.are.equal("PI", r.name)
  end)

  it("deprecated", function()
    local r = parse.parse("The signature '(): number' of 'oldApi' is deprecated.")
    assert.are.equal("deprecated", r.kind)
    assert.are.equal("oldApi", r.name)
  end)
end)

describe("parse.parse — Effect patterns", function()
  it("effect_mismatch: missing services (R)", function()
    local r = parse.parse(
      "Type 'Effect<void, DbError, Database | Logger>' is not assignable to type 'Effect<void, DbError, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal("effect", r.tag)
    assert.are.equal(1, r.diff_count)
    assert.are.same({ "Database", "Logger" }, r.missing_services)
    assert.are.same({}, r.unhandled_errors)
    assert.is_false(r.success_differs)
  end)

  it("effect_mismatch: unhandled errors (E)", function()
    local r = parse.parse(
      "Type 'Effect<User, NetworkError | ParseError, Http>' is not assignable to type 'Effect<User, never, Http>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal(1, r.diff_count)
    assert.are.same({}, r.missing_services)
    assert.are.same({ "NetworkError", "ParseError" }, r.unhandled_errors)
    assert.is_false(r.success_differs)
  end)

  it("effect_mismatch: wrong success (A)", function()
    local r = parse.parse(
      "Type 'Effect<User, NetworkError | ParseError, Http>' is not assignable to type 'Effect<string, NetworkError | ParseError, Http>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal(1, r.diff_count)
    assert.is_true(r.success_differs)
    assert.are.equal("User", r.got.A)
    assert.are.equal("string", r.expected.A)
  end)

  it("effect_mismatch: scope required", function()
    local r =
      parse.parse("Type 'Effect<string, never, Scope>' is not assignable to type 'Effect<string, never, never>'.")
    assert.are.equal("effect_mismatch", r.kind)
    assert.is_true(r.scope_required)
    assert.are.same({ "Scope" }, r.missing_services)
  end)

  it("effect_mismatch: multi-channel diff", function()
    local r = parse.parse(
      "Type 'Effect<void, DbError | ConfigError, Database | Config>' is not assignable to type 'Effect<void, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal(2, r.diff_count)
  end)

  it("layer_mismatch: ROut widening", function()
    local r = parse.parse(
      "Type 'Layer<Database | Http, never, never>' is not assignable to type 'Layer<Database, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal("layer", r.tag)
    assert.are.same({ "ROut", "E", "RIn" }, r.labels)
    assert.is_true(r.success_differs)
  end)

  it("Effect.Effect namespaced form", function()
    local r = parse.parse(
      "Type 'Effect.Effect<void, never, Database>' is not assignable to type 'Effect.Effect<void, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.same({ "Database" }, r.missing_services)
  end)

  it("Stream.Stream namespaced form", function()
    local r = parse.parse(
      "Type 'Stream.Stream<number, never, Http>' is not assignable to type 'Stream.Stream<number, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal("stream", r.tag)
  end)

  it("YieldWrap unwrapping", function()
    local r = parse.parse(
      "Type 'YieldWrap<Effect<void, never, Database>>' is not assignable to type 'YieldWrap<Effect<void, never, never>>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.same({ "Database" }, r.missing_services)
  end)

  it("Context.Tag unwrapping in R channel", function()
    local r = parse.parse(
      "Type 'Effect<void, never, Context.Tag<\"Database\", Database>>' is not assignable to type 'Effect<void, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    -- The Tag wrapper is stripped so the diff surfaces the service name only.
    assert.are.same({ "Database" }, r.missing_services)
  end)

  it("short signature: Effect<A> defaults E and R to never", function()
    local r = parse.parse("Type 'Effect<number>' is not assignable to type 'Effect<string>'.")
    assert.are.equal("effect_mismatch", r.kind)
    assert.is_true(r.success_differs)
    assert.are.equal("never", r.got.E)
    assert.are.equal("never", r.got.R)
  end)

  it("disabled effect: falls back to type_mismatch", function()
    local r = parse.parse(
      "Type 'Effect<void, never, Database>' is not assignable to type 'Effect<void, never, never>'.",
      { effect = false }
    )
    assert.are.equal("type_mismatch", r.kind)
  end)

  it("splits channels correctly when A is a function type", function()
    local r = parse.parse(
      "Type 'Effect<(x: number) => string, never, Database>' is not assignable to type 'Effect<(x: number) => string, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal("(x: number) => string", r.got.A)
    assert.are.equal("never", r.got.E)
    assert.are.equal("Database", r.got.R)
    assert.are.same({ "Database" }, r.missing_services)
    assert.is_false(r.success_differs)
  end)

  it("splits channels correctly when A is an object with arrow-typed members", function()
    local r = parse.parse(
      "Type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, Database>' is not assignable to type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, never>'."
    )
    assert.are.equal("layer", r.tag)
    assert.are.same({ "Database" }, r.missing_services)
    assert.is_false(r.success_differs)
  end)

  it("does not shred a top-level union of Effects into fake channels", function()
    local r = parse.parse(
      "Type 'Effect<string, never, Database> | Effect<number, never, never>' is not assignable to type 'Effect<string, never, never>'."
    )
    -- The union is not a single Effect, so it must fall back rather than
    -- inventing a service called `Database> | Effect<number`.
    assert.are.equal("type_mismatch", r.kind)
  end)

  it("unwraps YieldWrap even when TS qualifies it with an import path", function()
    local r = parse.parse(
      "Type 'import(\"/p/node_modules/effect/Utils\").YieldWrap<Effect<void, never, Database>>' is not assignable to type 'import(\"/p/node_modules/effect/Utils\").YieldWrap<Effect<void, never, never>>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.same({ "Database" }, r.missing_services)
  end)

  it("reports diff_count 0 when both sides normalize to the same signature", function()
    local r = parse.parse(
      "Type 'Effect<import(\"/app/node_modules/a/node_modules/effect/User\").User, never, never>' is not assignable to type 'Effect<import(\"/app/node_modules/effect/User\").User, never, never>'."
    )
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.equal(0, r.diff_count)
    assert.is_not.equal(r.raw.got, r.raw.expected)
  end)
end)

describe("parse.parse — patterns that only appear on continuation lines", function()
  it("not_callable (TS2349)", function()
    local r = parse.parse("This expression is not callable.\n  Type 'String' has no call signatures.")
    assert.are.equal("not_callable", r.kind)
    assert.are.equal("String", r.type)
  end)

  it("nullish keeps both halves of TS2533", function()
    local r = parse.parse("Object is possibly 'null' or 'undefined'.")
    assert.are.equal("nullish", r.kind)
    assert.are.equal("null or undefined", r.value)
  end)

  it("nullish names the expression for TS18048", function()
    local r = parse.parse("'user.profile' is possibly 'undefined'.")
    assert.are.equal("nullish", r.kind)
    assert.are.equal("user.profile", r.name)
    assert.are.equal("undefined", r.value)
  end)

  it("nullish keeps both halves of the named form too (TS18049)", function()
    local r = parse.parse("'user.name' is possibly 'null' or 'undefined'.")
    assert.are.equal("nullish", r.kind)
    assert.are.equal("user.name", r.name)
    assert.are.equal("null or undefined", r.value)
  end)

  it("does not claim not_callable for a TS2769 overload error", function()
    -- TS2769 nests "has no call signatures" under its overload report, but the
    -- expression IS callable — the argument just doesn't match an overload.
    local r = parse.parse(
      "No overload matches this call.\n  Overload 1 of 2, '(x: string): void', gave the following error.\n    Type 'number' has no call signatures."
    )
    assert.is_true(r == nil or r.kind ~= "not_callable")
  end)

  it("arg_count handles the at-least form (TS2555)", function()
    local r = parse.parse("Expected at least 1 arguments, but got 0.")
    assert.are.equal("arg_count", r.kind)
    assert.are.equal("at least 1", r.expected)
    assert.are.equal("0", r.got)
  end)

  it("arg_count handles the overload range form", function()
    local r = parse.parse("Expected 1-2 arguments, but got 3.")
    assert.are.equal("arg_count", r.kind)
    assert.are.equal("1-2", r.expected)
    assert.are.equal("3", r.got)
  end)
end)

describe("parse.parse — nested overload reports (TS2769)", function()
  -- The real thing, from `Effect.runFork(Effect.forkScoped(job))`: the headline
  -- names no types at all and every one that matters is indented beneath it.
  local NO_OVERLOAD = table.concat({
    "No overload matches this call.",
    "  Overload 1 of 2, '(options?: { readonly disableErrorReporting?: boolean | undefined; readonly teardown?: Teardown | undefined; } | undefined): <E, A>(effect: Effect<A, E, never>) => void', gave the following error.",
    "    Type 'Effect<Fiber<never, never>, never, Scope>' has no properties in common with type '{ readonly disableErrorReporting?: boolean | undefined; readonly teardown?: Teardown | undefined; }'.",
    "  Overload 2 of 2, '(effect: Effect<Fiber<never, never>, never, never>, options?: { readonly disableErrorReporting?: boolean | undefined; } | undefined): void', gave the following error.",
    "    Argument of type 'Effect<Fiber<never, never>, never, Scope>' is not assignable to parameter of type 'Effect<Fiber<never, never>, never, never>'.",
    "      Type 'Scope' is not assignable to type 'never'.",
  }, "\n")

  it("parses the overload's Effect report instead of the empty headline", function()
    local r = parse.parse(NO_OVERLOAD)
    assert.are.equal("effect_mismatch", r.kind)
    assert.are.same({ "Scope" }, r.missing_services)
    assert.is_true(r.scope_required)
    assert.are.equal(1, r.diff_count)
  end)

  it("prefers the argument-level line over the narrowing nested under it", function()
    -- "Type 'Scope' is not assignable to type 'never'" is also an assignability
    -- sentence, and picking it would report a Scope → never type mismatch.
    local r = parse.parse(NO_OVERLOAD)
    assert.is_truthy(r.got.A:find("Fiber", 1, true))
  end)

  it("keeps a plain overload error when no side is an Effect", function()
    local r = parse.parse(
      "No overload matches this call.\n  Overload 1 of 2, '(x: string): void', gave the following error.\n    Argument of type 'number' is not assignable to parameter of type 'string'."
    )
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("number", r.got)
    assert.are.equal("string", r.expected)
  end)

  it("does not read a sibling overload's detail as detail about the one it picked", function()
    local r = parse.parse(table.concat({
      "No overload matches this call.",
      "  Overload 1 of 2, '(p: Point): void', gave the following error.",
      "    Argument of type '{ x: number; }' is not assignable to parameter of type 'Point'.",
      "  Overload 2 of 2, '(l: Line): void', gave the following error.",
      "    Argument of type '{ x: number; }' is not assignable to parameter of type 'Line'.",
      "      Property 'end' is missing in type '{ x: number; }' but required in type 'Line'.",
    }, "\n"))
    assert.are.equal("type_mismatch", r.kind)
    assert.are.equal("Point", r.expected)
    assert.is_nil(r.missing)
  end)
end)

describe("parse.parse — @effect/language-service", function()
  it("accepts the effect source", function()
    assert.is_true(parse.is_ts_source("effect"))
  end)

  it("missingEffectContext names the service", function()
    local r = parse.parse("This Effect requires a service that is missing from the expected Effect context: `Scope`.")
    assert.are.equal("missing_context", r.kind)
    assert.are.equal("effect", r.tag)
    assert.are.same({ "Scope" }, r.services)
    assert.is_true(r.scope_required)
  end)

  it("splits a multi-service context and flags Scope inside it", function()
    local r = parse.parse(
      "This Effect requires a service that is missing from the expected Effect context: `Database | Scope`."
    )
    assert.are.same({ "Database", "Scope" }, r.services)
    assert.is_true(r.scope_required)
  end)

  it("still parses with the rule suffix attached", function()
    -- Editors that don't lift `effect(rule)` into the code leave it on the
    -- message; the capture must not be anchored to the end of the line.
    local r = parse.parse(
      "This Effect requires a service that is missing from the expected Effect context: `Scope`.    effect(missingEffectContext)"
    )
    assert.are.equal("missing_context", r.kind)
    assert.are.same({ "Scope" }, r.services)
  end)

  it("reads the Layer context as a Layer, not an Effect", function()
    local r = parse.parse("Missing 'Database' in the expected Layer context.")
    assert.are.equal("missing_context", r.kind)
    assert.are.equal("layer", r.tag)
    assert.are.same({ "Database" }, r.services)
  end)

  it("missingEffectError lists the unhandled errors", function()
    local r = parse.parse("Missing 'NetworkError | ParseError' in the expected Effect errors.")
    assert.are.equal("missing_errors", r.kind)
    assert.are.same({ "NetworkError", "ParseError" }, r.errors)
  end)
end)

describe("parse.parse — extensibility", function()
  it("extra_patterns runs after builtins and wins on new shapes", function()
    local r = parse.parse("Custom lint: bad-foo at column 3", {
      extra_patterns = {
        function(msg)
          local bad = msg:match("Custom lint: ([%w-]+)")
          if bad then
            return { kind = "custom_lint", rule = bad }
          end
        end,
      },
    })
    assert.are.equal("custom_lint", r.kind)
    assert.are.equal("bad-foo", r.rule)
  end)
end)

describe("parse.union_diff", function()
  it("returns members of a not in b", function()
    assert.are.same({ "A", "C" }, parse.union_diff("A | B | C", "B"))
  end)

  it("treats never as empty", function()
    assert.are.same({}, parse.union_diff("never", "A"))
    assert.are.same({ "A" }, parse.union_diff("A", "never"))
  end)

  it("preserves generic-bracket depth when splitting", function()
    local diff = parse.union_diff("User<Id | Slug> | Admin", "Admin")
    assert.are.same({ "User<Id | Slug>" }, diff)
  end)
end)

describe("parse.has_scope", function()
  it("detects Scope in a union", function()
    assert.is_true(parse.has_scope("Scope"))
    assert.is_true(parse.has_scope("Database | Scope"))
    assert.is_true(parse.has_scope("Scope.Scope | Http"))
    assert.is_false(parse.has_scope("Database | Http"))
    assert.is_false(parse.has_scope("never"))
  end)
end)

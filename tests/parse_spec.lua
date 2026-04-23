-- Unit tests for the parser.  Run with plenary:
--   :PlenaryBustedFile tests/parse_spec.lua
-- or from the shell:
--   nvim --headless -c "PlenaryBustedDirectory tests/" -c "qa!"

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

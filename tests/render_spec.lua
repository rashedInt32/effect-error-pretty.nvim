-- Renderer tests.  Run with plenary:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa!"

local render = require("effect-error-pretty.render")

local EFFECT = { effect = true }

local function box(message)
  return render.artistic({ message = message }, EFFECT)
end

local function line(message)
  return render.short({ message = message }, EFFECT)
end

describe("render.artistic — Effect", function()
  it("names the missing service when A holds a function type", function()
    -- Regression: the `>` of `=>` used to be counted as a closing bracket, so
    -- E and R were swallowed into A and the service was never reported.
    local out = box(
      "Type 'Effect<(x: number) => string, never, Database>' is not assignable to type 'Effect<(x: number) => string, never, never>'."
    )
    assert.is_truthy(out:find("Missing Services", 1, true))
    assert.is_truthy(out:find("Forgot to provide: Database", 1, true))
    assert.is_nil(out:find("A Mismatch", 1, true))
  end)

  it("names the missing RIn for a Layer of a service interface", function()
    local out = box(
      "Type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, Database>' is not assignable to type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, never>'."
    )
    assert.is_truthy(out:find("Missing RIn", 1, true))
    assert.is_truthy(out:find("Forgot to provide: Database", 1, true))
  end)

  it("titles Scope Required only for a bare Scope", function()
    local out = box("Type 'Effect<string, never, Scope>' is not assignable to type 'Effect<string, never, never>'.")
    assert.is_truthy(out:find("Scope Required", 1, true))
    assert.is_truthy(out:find("Effect.scoped", 1, true))
  end)

  it("does not claim Scope Required for a service merely named Scope*", function()
    local out = box("Type 'Effect<void, never, ScopeManager>' is not assignable to type 'Effect<void, never, never>'.")
    assert.is_nil(out:find("Scope Required", 1, true))
    assert.is_truthy(out:find("Missing Services", 1, true))
    assert.is_truthy(out:find("Effect.provide", 1, true))
  end)

  it("explains identical signatures instead of diffing a type against itself", function()
    local out = box(
      "Type 'Effect<import(\"/app/node_modules/a/node_modules/effect/User\").User, never, never>' is not assignable to type 'Effect<import(\"/app/node_modules/effect/User\").User, never, never>'."
    )
    assert.is_truthy(out:find("Identical Signatures", 1, true))
    assert.is_truthy(out:find("two copies of the same package", 1, true))
  end)

  it("wraps the Got/Expected signature flush under its label", function()
    -- The signature block's indent used to be hardcoded two columns wider than
    -- the `│  Got:      ` prefix it was supposed to align under.
    local out = box(
      "Type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, Database>' is not assignable to type 'Layer<{ readonly get: (id: string) => Effect<User, DbError, never>; }, never, never>'."
    )
    local first, cont = out:match("(│  Got:      )[^\n]*\n(│ +)%S")
    assert.is_truthy(first)
    assert.are.equal(vim.fn.strdisplaywidth(first), vim.fn.strdisplaywidth(cont))
  end)
end)

describe("render.artistic — @effect/language-service", function()
  it("renders the Scope box without a signature diff it does not have", function()
    local out = box("This Effect requires a service that is missing from the expected Effect context: `Scope`.")
    assert.is_truthy(out:find("Scope Required", 1, true))
    assert.is_truthy(out:find("Effect.scoped", 1, true))
    assert.is_nil(out:find("Got:", 1, true))
  end)

  it("says provide, and scoped as well, when Scope rides along", function()
    local out =
      box("This Effect requires a service that is missing from the expected Effect context: `Database | Scope`.")
    assert.is_truthy(out:find("Missing Services", 1, true))
    assert.is_truthy(out:find("Forgot to provide: Database | Scope", 1, true))
    assert.is_truthy(out:find("Effect.provide", 1, true))
    assert.is_truthy(out:find("Effect.scoped", 1, true))
  end)

  it("titles the Layer context box as RIn and hints at Layer.provide", function()
    local out = box("Missing 'Database' in the expected Layer context.")
    assert.is_truthy(out:find("Missing RIn", 1, true))
    assert.is_truthy(out:find("Layer.provide", 1, true))
  end)

  it("renders unhandled errors with the catchTags hint", function()
    local out = box("Missing 'NetworkError' in the expected Effect errors.")
    assert.is_truthy(out:find("Unhandled Errors", 1, true))
    assert.is_truthy(out:find("Not in E channel: NetworkError", 1, true))
    assert.is_truthy(out:find("Effect.catchTags", 1, true))
  end)

  it("closes every box it opens", function()
    for _, msg in ipairs({
      "This Effect requires a service that is missing from the expected Effect context: `Scope`.",
      "Missing 'Database' in the expected Layer context.",
      "Missing 'NetworkError' in the expected Effect errors.",
    }) do
      local out = box(msg)
      assert.are.equal("╭", out:sub(1, #"╭"))
      assert.is_truthy(out:find("╰─", 1, true))
    end
  end)
end)

describe("render — TS2769 overload errors", function()
  local NO_OVERLOAD = table.concat({
    "No overload matches this call.",
    "  Overload 1 of 2, '(options?: { readonly teardown?: Teardown | undefined; } | undefined): <E, A>(effect: Effect<A, E, never>) => void', gave the following error.",
    "    Type 'Effect<Fiber<never, never>, never, Scope>' has no properties in common with type '{ readonly teardown?: Teardown | undefined; }'.",
    "  Overload 2 of 2, '(effect: Effect<Fiber<never, never>, never, never>, options?: undefined): void', gave the following error.",
    "    Argument of type 'Effect<Fiber<never, never>, never, Scope>' is not assignable to parameter of type 'Effect<Fiber<never, never>, never, never>'.",
    "      Type 'Scope' is not assignable to type 'never'.",
  }, "\n")

  it("boxes the buried Effect report", function()
    local out = box(NO_OVERLOAD)
    assert.is_truthy(out:find("Scope Required", 1, true))
    assert.is_truthy(out:find("Effect.scoped", 1, true))
  end)

  it("gives the inline line the same verdict", function()
    assert.are.equal("◈ Needs Effect.scoped", line(NO_OVERLOAD))
  end)
end)

describe("render.artistic — box alignment", function()
  -- A wrapped type's continuation lines must begin in the same column as the
  -- content of the label that introduced them.  Each of these indents was
  -- hardcoded per call site, and each was measured against the wrong prefix.
  local OBJ = "{ id: string; email: string; profile: { name: string; age: number; country: string; }; }"

  local function assert_first_continuation_aligns(out, label_pattern)
    local label, cont = out:match("(" .. label_pattern .. "%s+)%S[^\n]*\n(│ +)%S")
    assert.is_truthy(label, "no wrapped label found in:\n" .. out)
    assert.are.equal(
      vim.fn.strdisplaywidth(label),
      vim.fn.strdisplaywidth(cont),
      "continuation does not align under the label:\n" .. out
    )
  end

  it("aligns the missing_property box (indent was one column short)", function()
    local out = box("Property 'preferences' is missing in type '" .. OBJ .. "' but required in type 'User'.")
    assert_first_continuation_aligns(out, "│  ◇ In:")
  end)

  it("aligns the type_mismatch box", function()
    local out = box("Type '" .. OBJ .. "' is not assignable to type 'User'.")
    assert_first_continuation_aligns(out, "│  ✗ Got:")
  end)

  it("aligns the tri-channel view (the ROut indent was three columns short)", function()
    local out =
      box("Type 'Layer<" .. OBJ .. ", DbError, Database>' is not assignable to type 'Layer<void, never, never>'.")
    assert_first_continuation_aligns(out, "│     ROut:")
  end)

  it("budgets the wrap against the prefix so lines stay inside the box", function()
    -- The wrap budget used to be a flat 70 that ignored the prefix, so an
    -- indented continuation could run ~85 columns wide.
    local union =
      '"alpha" | "bravo" | "charlie" | "delta" | "echo" | "foxtrot" | "golf" | "hotel" | "india" | "juliett"'
    local out = box("Type '" .. union .. "' is not assignable to type 'number'.")
    for _, l in ipairs(vim.split(out, "\n")) do
      local w = vim.fn.strdisplaywidth(l)
      assert.is_true(w <= 80, ("line runs %d columns: %s"):format(w, l))
    end
  end)

  it("still aligns when the gutter glyph is double-width (ambiwidth=double)", function()
    -- `│` is East-Asian ambiguous: one cell normally, two under ambiwidth=double.
    local saved = vim.o.ambiwidth
    vim.o.ambiwidth = "double"
    local ok, err = pcall(function()
      local out = box("Type '" .. OBJ .. "' is not assignable to type 'User'.")
      assert_first_continuation_aligns(out, "│  ✗ Got:")
    end)
    vim.o.ambiwidth = saved
    assert.is_true(ok, tostring(err))
  end)
end)

describe("render.artistic — TypeScript", function()
  it("reports both halves of a null-or-undefined", function()
    assert.is_truthy(box("Object is possibly 'null' or 'undefined'."):find("null or undefined", 1, true))
  end)

  it("names the expression for TS18048", function()
    assert.is_truthy(box("'user.profile' is possibly 'undefined'."):find("'user.profile' may be undefined", 1, true))
  end)

  it("renders Not Callable from the continuation line (TS2349)", function()
    local out = box("This expression is not callable.\n  Type 'String' has no call signatures.")
    assert.is_truthy(out:find("Not Callable", 1, true))
    assert.is_truthy(out:find("String", 1, true))
  end)

  it("renders the at-least and range argument-count forms", function()
    assert.is_truthy(box("Expected at least 1 arguments, but got 0."):find("expected at least 1", 1, true))
    assert.is_truthy(box("Expected 1-2 arguments, but got 3."):find("expected 1-2", 1, true))
  end)
end)

describe("render.short", function()
  it("reports every diverging channel, not just the first", function()
    -- Regression: inline used to print only the R diff, so a user who followed
    -- it would provide the services and still be left with the E error.
    local out = line(
      "Type 'Effect<void, NetworkError | ParseError, Http | Database>' is not assignable to type 'Effect<void, never, never>'."
    )
    assert.is_truthy(out:find("Http | Database", 1, true))
    assert.is_truthy(out:find("NetworkError | ParseError", 1, true))
  end)

  it("keeps the compact form when a single channel diverges", function()
    local out = line("Type 'Effect<void, DbError, Database>' is not assignable to type 'Effect<void, DbError, never>'.")
    assert.are.equal("◈ Missing provide: Database", out)
  end)

  it("truncates on character boundaries, not bytes", function()
    -- `é` is the 50th character but occupies bytes 50-51, so a byte-wise
    -- :sub(1, 50) keeps only its lead byte and emits invalid UTF-8. If the cut
    -- is character-wise the `é` survives whole.
    local name = string.rep("A", 49) .. "é" .. string.rep("B", 10)
    local out = line("Type '" .. name .. "' is not assignable to type 'number'.")
    assert.is_truthy(out:find("é", 1, true), "é was cut in half: " .. out)
    assert.is_truthy(out:find("…", 1, true))
  end)

  it("does not append an ellipsis to a type that was never cut", function()
    local out =
      line("Type 'import(\"/a/b/c/node_modules/@org/pkg/dist/types\").ShortName' is not assignable to type 'number'.")
    assert.are.equal("✗ ShortName → ✓ number", out)
  end)

  it("covers the kinds the float covers", function()
    assert.is_truthy(line("Expected 2 arguments, but got 1."))
    assert.is_truthy(line("Cannot assign to 'PI' because it is a constant."))
    assert.is_truthy(line("Module '\"fs\"' has no exported member 'nope'."))
    assert.is_truthy(line("Variable 'x' is used before being assigned."))
    assert.is_truthy(line("This expression is not callable.\n  Type 'String' has no call signatures."))
  end)
end)

describe("hints agree with their titles", function()
  it("does not suggest Effect.scoped when Scope rides along with real services", function()
    local out =
      box("Type 'Effect<void, never, Scope | Database>' is not assignable to type 'Effect<void, never, never>'.")
    assert.is_truthy(out:find("Missing Services", 1, true))
    -- Provide handles Database; Scope still needs scoped. Both must be said.
    assert.is_truthy(out:find("Effect.provide", 1, true))
    assert.is_truthy(out:find("Effect.scoped", 1, true))
  end)

  it("keeps the import paths visible in the identical-signatures box", function()
    local out = box(
      "Type 'Effect<import(\"/app/node_modules/a/node_modules/effect/User\").User, never, never>' is not assignable to type 'Effect<import(\"/app/node_modules/effect/User\").User, never, never>'."
    )
    -- Prettifying these away would leave two lines that read identically. The
    -- nested copy is the whole tell, so it has to survive the wrap intact.
    assert.is_truthy(out:find("import(", 1, true))
    assert.is_truthy(out:find("node_modules/a/node_modules", 1, true))
    for _, l in ipairs(vim.split(out, "\n")) do
      assert.is_true(vim.fn.strdisplaywidth(l) <= 80)
    end
  end)
end)

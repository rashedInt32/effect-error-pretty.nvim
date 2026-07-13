-- Public API / setup tests.  Run with plenary:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/" -c "qa!"

local pretty = require("effect-error-pretty")

local function ts(message, code)
  return { source = "typescript", message = message, code = code }
end

describe("source gating", function()
  before_each(function()
    pretty.setup({})
  end)

  it("formats the default TS sources and ignores others", function()
    assert.is_truthy(pretty.float_format(ts("Cannot find name 'foo'.")))
    assert.is_nil(pretty.float_format({ source = "eslint", message = "Cannot find name 'foo'." }))
  end)

  it("merges a custom source with the documented defaults", function()
    pretty.setup({ sources = { deno = true } })
    assert.is_truthy(pretty.float_format({ source = "deno", message = "Cannot find name 'foo'." }))
    -- The defaults must survive the merge; they used to be replaced wholesale.
    assert.is_truthy(pretty.float_format(ts("Cannot find name 'foo'.")))
  end)

  it("lets a default source be switched off explicitly", function()
    pretty.setup({ sources = { typescript = false } })
    assert.is_nil(pretty.float_format(ts("Cannot find name 'foo'.")))
  end)
end)

describe("error isolation", function()
  before_each(function()
    pretty.setup({})
  end)

  it("degrades to nil when an extra_pattern throws, rather than killing the float", function()
    pretty.setup({
      extra_patterns = {
        function()
          error("boom")
        end,
      },
    })
    local ok, result = pcall(pretty.float_format, ts("Some message with no builtin pattern"))
    assert.is_true(ok)
    assert.is_nil(result)
  end)

  it("accepts a bare function for extra_patterns instead of erroring on every diagnostic", function()
    pretty.setup({
      extra_patterns = function(msg)
        if msg:match("^my%-lint:") then
          return { kind = "undefined", name = "custom" }
        end
      end,
    })
    local ok, result = pcall(pretty.float_format, ts("my-lint: something"))
    assert.is_true(ok)
    assert.is_truthy(result)
  end)
end)

describe("inline_format", function()
  before_each(function()
    pretty.setup({})
  end)

  it("returns a one-line box-free string", function()
    local out = pretty.inline_format(ts("Cannot find name 'foo'."))
    assert.are.equal("✗ Undefined: 'foo'", out)
    assert.is_nil(out:find("\n", 1, true))
  end)

  it("returns nil for an unhandled message when the fallback is off", function()
    pretty.setup({ format_ts_errors_fallback = false })
    assert.is_nil(pretty.inline_format(ts("Some message with no builtin pattern", 9999)))
  end)

  it("never emits a dangling fragment from the multi-line fallback", function()
    -- format-ts-errors is optional; only assert when it is actually installed.
    if not pcall(require, "format-ts-errors") then
      return
    end
    local out = pretty.inline_format(ts(
      "Type '{ a: number; }' is missing the following properties from type 'Point': b, c",
      2739
    ))
    if out then
      assert.is_nil(out:find("\n", 1, true))
      assert.is_true(#out > #"Type")
    end
  end)
end)

describe("setup({ float = true })", function()
  before_each(function()
    vim.diagnostic.config({ float = {} })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "EffectErrorPretty")
    vim.diagnostic.config({ float = {} })
  end)

  it("installs the formatter", function()
    pretty.setup({ float = true })
    assert.is_function(vim.diagnostic.config().float.format)
  end)

  it("reinstalls itself after another plugin replaces the float table", function()
    pretty.setup({ float = true })
    -- LazyVim's nvim-lspconfig spec does exactly this, and vim.diagnostic.config
    -- shallow-assigns, so the whole float table (format included) is replaced.
    vim.diagnostic.config({ float = { border = "single" } })
    assert.is_nil(vim.diagnostic.config().float.format)

    vim.api.nvim_exec_autocmds("LspAttach", {})
    assert.is_function(vim.diagnostic.config().float.format)
    assert.are.equal("single", vim.diagnostic.config().float.border)
  end)

  it("preserves a function-form float config instead of discarding it", function()
    vim.diagnostic.config({
      float = function()
        return { border = "double" }
      end,
    })
    pretty.setup({ float = true })

    local resolved = vim.diagnostic.config().float
    assert.is_function(resolved)
    local opts = resolved(nil, 0)
    assert.are.equal("double", opts.border)
    assert.is_function(opts.format)
  end)

  it("falls back to the raw message for a diagnostic it does not handle", function()
    pretty.setup({ float = true, format_ts_errors_fallback = false })
    local format = vim.diagnostic.config().float.format
    local d = { source = "eslint", message = "no-unused-vars" }
    assert.are.equal("no-unused-vars", format(d))
  end)
end)

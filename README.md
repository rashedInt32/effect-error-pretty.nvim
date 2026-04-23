# effect-error-pretty.nvim

Effect-first TypeScript diagnostic formatter for Neovim. Turns walls of `Effect<A, E, R>` assignability errors into something you can actually read — with dedicated handling for the Effect ecosystem's pain points.

TypeScript errors in general also get the treatment, but Effect is the headline act.

## Why

When you're learning Effect, half the type errors look like this:

```
Type 'Effect<void, DbError, Database | Logger>' is not assignable to type 'Effect<void, DbError, never>'.
```

VSCode and Zed render that as one wrapped line in a tooltip. The actual information — "you forgot to provide `Database | Logger`" — is buried.

This plugin parses the error, figures out which channel (A, E, or R) actually diverged, and renders:

```
╭─ ◈ Effect — Missing Services
│
│  ◈ Forgot to provide: Database | Logger
│  ⚡ Hint: .pipe(Effect.provide(SomeLayer))
│
│  Got:      Effect<void, DbError, Database | Logger>
│  Expected: Effect<void, DbError, never>
╰─
```

## Preview

More scenarios the plugin recognizes, shown as they render in the float.

### Unhandled errors (forgot `Effect.catchAll` / `catchTags` / `orDie`)

```
╭─ ⚠ Effect — Unhandled Errors
│
│  ⚠ Not in E channel: NetworkError | ParseError
│  ⚡ Hint: .pipe(Effect.catchTags({...})) or Effect.orDie
│
│  Got:      Effect<User, NetworkError | ParseError, Http>
│  Expected: Effect<User, never, Http>
╰─
```

### Wrong success type (A)

```
╭─ ⊘ Effect — A Mismatch
│
│  ✗ Got A:    User
│  ✓ Expected: string
│
│  Got:      Effect<User, NetworkError | ParseError, Http>
│  Expected: Effect<string, NetworkError | ParseError, Http>
╰─
```

### Scope required

`Scope` is detected specifically so the hint suggests `Effect.scoped` instead of a generic `Effect.provide`.

```
╭─ ◈ Effect — Scope Required
│
│  ◈ Forgot to provide: Scope
│  ⚡ Hint: wrap in Effect.scoped(...) — Scope is required
│
│  Got:      Effect<string, never, Scope>
│  Expected: Effect<string, never, never>
╰─
```

### Multi-channel diff

When two or more channels diverge at once, the compact boxes step aside for a full tri-channel view with all annotations stacked at the bottom.

```
╭─ ⊘ Effect Mismatch
│
│  ✗ Got:
│     A: void
│     E: NetworkError | ParseError | DbError
│     R: Http | Database | Logger
│
│  ✓ Expected:
│     A: void
│     E: never
│     R: never
│
│  ◈ Forgot to provide: Http | Database | Logger
│  ⚠ Unhandled errors: NetworkError | ParseError | DbError
╰─
```

### Layer — ROut widening

Layer mismatches get their own channel labels (`ROut / E / RIn`) and a `Layer.provide` / `Layer.merge` hint.

```
╭─ ⊘ Layer — ROut Mismatch
│
│  ✗ Got ROut:    Database | Http
│  ✓ Expected: Database
│
│  Got:      Layer<Database | Http, never, never>
│  Expected: Layer<Database, never, never>
╰─
```

## Features

**Effect-specific**
- `Effect<A, E, R>` / `Effect.Effect<A, E, R>` / `Stream<A, E, R>` / `Layer<ROut, E, RIn>` — all parsed, channel-labeled, and diffed
- **Missing services** (forgot `Effect.provide`) — compact box naming the exact services
- **Unhandled errors** (forgot `Effect.catchAll` / `catchTags` / `orDie`) — compact box listing the leftover `E` members
- **Wrong success type** — compact box with Got/Expected for `A` (or `ROut` for Layer)
- **Scope-required** — detects `Scope` in got.R and suggests `Effect.scoped`
- **`Context.Tag<"Id", Service>` unwrapping** — shows just the service name in diffs
- **`YieldWrap<...>` unwrapping** — Effect.gen yields render as plain Effect mismatches
- **Short signatures** — `Effect<A>` and `Effect<A, E>` default missing params to `never`
- **Multi-channel view** — falls back to a full tri-channel table when 2+ channels diverge
- **Type signature at the bottom** of every compact box so you see the full `Effect<...>` context

**General TypeScript**
- Type mismatches (TS2322 / TS2345) with multi-line wrapping for big types
- Missing property (TS2741), Unknown property (TS2339)
- Cannot find name / module / exported member (TS2304 / TS2307 / TS2305)
- Implicit any (TS7006), Uninitialized variable (TS2454), Nullish (TS2531 / TS18048)
- Argument count (TS2554), Const reassignment, Not callable (TS2349)
- Deprecated symbol messages
- Optional fallback to [`format-ts-errors`](https://www.npmjs.com/package/@0no-co/format-ts-errors) when no pattern matches

## Install

Requires Neovim 0.10+.

### lazy.nvim

```lua
{
  "rashedInt32/effect-error-pretty.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = {
    float = true,          -- auto-patch vim.diagnostic.config.float.format
    effect = true,
    format_ts_errors_fallback = true,
  },
}
```

### Manual wiring

If you manage `vim.diagnostic.config` yourself, don't set `float = true`. Call the formatter directly:

```lua
local pretty = require("effect-error-pretty")
pretty.setup({ effect = true })

vim.diagnostic.config({
  float = {
    format = function(diagnostic)
      return pretty.float_format(diagnostic) or diagnostic.message
    end,
  },
})
```

### tiny-inline-diagnostic.nvim

```lua
{
  "rachartier/tiny-inline-diagnostic.nvim",
  opts = {
    options = {
      format = function(diagnostic)
        return require("effect-error-pretty").inline_format(diagnostic) or diagnostic.message
      end,
    },
  },
}
```

## Options

| Option                       | Default | Description                                                                                               |
|------------------------------|---------|-----------------------------------------------------------------------------------------------------------|
| `effect`                     | `true`  | Recognize `Effect` / `Stream` / `Layer` mismatches as first-class.                                        |
| `float`                      | `false` | Automatically patch `vim.diagnostic.config.float.format` on `setup()`.                                    |
| `sources`                    | `{ typescript=true, ts=true, vtsls=true }` | Diagnostic sources this plugin handles. Exact match only. |
| `format_ts_errors_fallback`  | `true`  | When no pattern matches, try `format-ts-errors` if installed.                                             |
| `extra_patterns`             | `nil`   | List of `function(msg) -> {kind, ...}` parsers run after builtins. Let you add custom shapes.              |

## Public API

```lua
local pretty = require("effect-error-pretty")

-- Float box (multi-line) — returns nil if unhandled; caller should fall back.
pretty.float_format(diagnostic)

-- Inline one-line — returns nil if unhandled.
pretty.inline_format(diagnostic)

-- Low-level: parse a raw TS diagnostic message into a structured kind.
-- Returns nil if no pattern matched.
require("effect-error-pretty.parse").parse(message, { effect = true })
```

## Extending

Add a parser for a custom rule you care about:

```lua
require("effect-error-pretty").setup({
  extra_patterns = {
    function(msg)
      local rule = msg:match("^eslint%-plugin%-effect: (.+)$")
      if rule then
        return { kind = "custom_lint", rule = rule }
      end
    end,
  },
})
```

Render logic for custom `kind`s isn't wired in yet — for now, `parse()` returns the structured result and you render it yourself. If there's demand, we'll expose a renderer registry.

## Tests

```sh
nvim --headless -c "PlenaryBustedDirectory tests/" -c "qa!"
```

Requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) on the runtimepath.

## License

MIT

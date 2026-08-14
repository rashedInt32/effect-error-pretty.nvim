# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`@effect/language-service` diagnostics are formatted.** Its source is
  `effect`, not `ts`, so every one of its reports used to fall straight through
  to the raw message. `missingEffectContext`, `missingEffectError` and the
  Layer-context report now reach the same boxes as the type-diff path — they
  name the missing pieces outright, so there is nothing to diff. `effect` is in
  the default `sources` set; pass `{ effect = false }` to opt out.

### Fixed

- **The box broke apart in a narrow window.** Neovim wraps a diagnostic float at
  the width of the window the cursor is in — not the editor width, and not
  `max_width` — and that wrap is a soft one, so the continuation carries no `│`.
  A 70-cell box in a 48-column split came apart. The box now measures the window
  at render time and shrinks to fit, hint lines included, and the type wrapper
  breaks *before* the budget instead of at the first space past it. New `width`
  option sets the target (default 70).
- **"Forgot to provide: unknown" was a dead end.** `unknown` / `any` in a
  channel is TypeScript reporting that it never resolved that channel — there is
  no layer to provide. Those now get their own box ("R Not Inferred") pointing at
  the widening instead of at `Effect.provide`. A real service alongside an
  `unknown` keeps its provide hint and gains a note that providing it won't
  clear the error on its own. Applies to `E` and to the language-service reports
  the same way.
- **Overload errors (TS2769) produced nothing.** The parser dropped everything
  after the first line, and that line — "No overload matches this call." — names
  no types. The overload report nested beneath it is now parsed instead,
  preferring an `Effect`/`Stream`/`Layer` report over a plain one, and the
  argument-level line over the narrowed comparison nested under it (which knows
  only that `Scope` isn't `never`). A report with no usable line falls through
  to the old behavior.

## [0.1.1] — 2026-07-13

Layout fixes. No API or behavior changes; nothing to migrate.

### Fixed

- **Wrapped lines could run past the box.** The wrap budget was a flat 70
  columns that ignored the prefix the line was drawn under, so an indented
  continuation could reach ~85 columns. The budget is now measured against the
  prefix, and in display cells rather than bytes (`#s` counts bytes, which
  overshoots for non-ASCII types).
- **Everything was off by one column under `set ambiwidth=double`.** The box
  gutter `│` is an East-Asian *ambiguous* width character — one cell normally,
  two under that option — and the indent assumed it was always one.
- Object members are no longer soft-wrapped mid-member: the `;` between members
  is the meaningful break, and wrapping on a space just orphaned the closing
  `};` onto a line of its own.
- The identical-signatures box now wraps long import paths at `/` boundaries
  instead of overflowing the box, so the duplicated `node_modules/…` segment
  that explains the error stays readable.

## [0.1.0] — 2026-07-13

First tagged release. Up to now the plugin has only been installable from
`main`; from here on you can pin a version.

If you are pinning for the first time, note the one breaking change below.

### Breaking

- **`sources` now merges with the defaults instead of replacing them.** The
  option was always *documented* as defaulting to
  `{ typescript = true, ts = true, vtsls = true }` and merged with your table,
  but the default was actually `nil`, so your table silently replaced the whole
  set. `setup({ sources = { deno = true } })` therefore stopped formatting
  TypeScript diagnostics altogether.

  It now behaves as documented, and `{ deno = true }` *adds* Deno. If you were
  relying on the old behavior to **restrict** which sources get formatted, turn
  the others off explicitly:

  ```lua
  -- before (accidentally worked as "only vtsls")
  require("effect-error-pretty").setup({ sources = { vtsls = true } })

  -- now
  require("effect-error-pretty").setup({
    sources = { vtsls = true, typescript = false, ts = false },
  })
  ```

### Fixed — parser

- **Effects with a function type in the `A` channel parsed into the wrong
  channels.** The `>` in an arrow type (`(id: string) => Effect<...>`) was
  counted as a closing bracket, driving the nesting depth negative so every
  top-level comma after it was missed. `E` and `R` were swallowed into `A`, and
  the headline "Missing Services" box never fired — on a service interface with
  methods, which is the common case.
- A top-level union of Effects (`Effect<A> | Effect<B>`, e.g. from
  `cond ? effectA : effectB`) matched the greedy `Effect<...>` pattern and was
  shredded into a fabricated service name. It now falls back to a plain type
  mismatch.
- `YieldWrap<...>` was unwrapped *before* `import("…").` prefixes were stripped,
  so the fully-qualified form TypeScript actually emits never unwrapped.
- **`Not callable` (TS2349) and nullish (TS18048) never fired at all.** The
  clause they match lives on a continuation line that the parser stripped before
  matching. Both are now read before the strip — while making sure a TS2769
  *overload* error is not misreported as "not callable", since it nests the same
  text.
- `Object is possibly 'null' or 'undefined'` (TS2533) reported only the `null`
  half, and the same bug applied to the named form (TS18049).
- Argument-count errors only matched a plain count; the `at least N` (TS2555)
  and `N-M` overload forms matched nothing and rendered no box.
- `extra_patterns` given as a bare function now works instead of erroring on
  every TypeScript diagnostic.

### Fixed — rendering

- A service whose name merely *starts with* `Scope` (e.g. `ScopeManager`) was
  titled "Scope Required" over a contradicting `Effect.provide` hint. When
  `Scope` genuinely rides along with other services, both hints are now shown.
- When both sides normalized to the same signature — two copies of a package in
  `node_modules` — the plugin rendered a "Mismatch" box whose Got and Expected
  were character-for-character identical. That case is now named, with the
  differing import paths kept visible.
- **Inline text hid diverging channels.** For a multi-channel error the float
  showed both the missing services and the unhandled errors, but the inline
  virtual text showed only the services — so following it left the error
  unresolved with no clue why. Every diverging channel is now reported.
- Truncation was byte-wise and could cut a multi-byte character in half; the
  ellipsis was decided from the pre-strip length, so short types got a `…` they
  had not earned.
- Wrapped types did not line up under their labels (the continuation indents
  were hardcoded and measured against the wrong prefixes), so the output did not
  match the screenshots in the README.
- Five diagnostic kinds rendered a float box but returned nothing inline.

### Fixed — API and setup

- **A formatter error no longer takes down the whole diagnostic float.** There
  was no `pcall` in the format path, so one throwing `extra_pattern` blanked the
  entire float — including diagnostics from unrelated sources on the same line —
  and threw on every `CursorHold`.
- **`float = true` no longer gets silently wiped.** `vim.diagnostic.config()`
  shallow-assigns top-level keys, so any later `config({ float = ... })`
  replaced the whole table and dropped the formatter. LazyVim's `nvim-lspconfig`
  spec does exactly this, on the same event the README's own install snippet
  uses. The formatter now reinstalls itself on `VimEnter` / `LspAttach`.
- A function-form `float` config (a documented Neovim shape) was discarded
  wholesale, taking the user's border and their own `format` with it.
- `inline_format` kept only the first line of `format-ts-errors`' deliberately
  multi-line output, rendering the literal word `Type` as the virtual text.

### Fixed — docs and tests

- The documented test command loaded your personal Neovim config instead of
  `tests/minimal_init.lua`: `PlenaryBustedDirectory` spawns a child process per
  spec file, and those children ignore the parent's `-u`.
- `format_ts_errors_fallback` linked to an npm package; the code requires the
  Lua plugin
  [`format-ts-errors.nvim`](https://github.com/davidosomething/format-ts-errors.nvim).
- `tests/minimal_init.lua` hardcoded the XDG default path for plenary, so it
  silently no-opped under `NVIM_APPNAME` or a custom `XDG_DATA_HOME`.
- Test coverage went from 32 to 76 cases. `render.lua` and `init.lua` previously
  had none at all, which is why most of the above shipped.

[0.1.1]: https://github.com/rashedInt32/effect-error-pretty.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/rashedInt32/effect-error-pretty.nvim/releases/tag/v0.1.0

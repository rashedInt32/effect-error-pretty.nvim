// Showcase file for the README's "General TypeScript" preview section.
// Each block below is self-contained and produces one intentional error on the
// line marked `// ← error`. Open this file in Neovim with your TS LSP attached,
// hover the red line, and screenshot the float.

// ─── 1. Type mismatch with long wrapped signature (TS2741) ──────────────────

type User = {
  id: string
  email: string
  profile: { name: string; age: number; country: string }
  preferences: { theme: "light" | "dark"; notifications: boolean }
}

const u: User = {
  // ← error: Property 'preferences' is missing …
  id: "1",
  email: "a@b.c",
  profile: { name: "Ada", age: 37, country: "UK" },
}

// ─── 2. Not callable on a complex type (TS2349) ─────────────────────────────

type Middleware = {
  run(ctx: { path: string }): void
  name: string
  priority: number
}

const auth: Middleware = {
  run: (ctx) => console.log(ctx.path),
  name: "auth",
  priority: 1,
}

auth({ path: "/login" }) // ← error: This expression is not callable.

// ─── 3. Unknown property (TS2339) ───────────────────────────────────────────

type Session = { userId: string; expiresAt: Date; rolls: string[] }

function hasAdmin(s: Session) {
  return s.roles.includes("admin") // ← error: Property 'roles' does not exist …
}

// ─── 4. Argument type mismatch into a function (TS2345) ─────────────────────

type Logger = { level: "debug" | "info" | "warn" | "error"; tag: string }

function log(l: Logger, msg: string) {
  console.log(`[${l.level}] ${l.tag}: ${msg}`)
}

log({ level: "verbose", tag: "db" }, "connected") // ← error on "verbose"

// ─── silence unused-symbol noise ────────────────────────────────────────────
void u
void hasAdmin

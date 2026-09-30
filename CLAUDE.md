# Agent instructions

Start with [`AGENTS.md`](AGENTS.md) — mob_deliver_server orientation and rules.
**Then read mob_deliver's [`decisions/2026-09-19-scope-and-wire-format.md`](../mob_deliver/decisions/2026-09-19-scope-and-wire-format.md)** — the wire contract this server implements. Everything wire-adjacent defers to it.

Hard rule: never depend on mob_deliver at runtime. It's a test-only dependency for the interop tests; the client and this server are peers across the wire.

Pre-commit checklist:

```bash
mix test
mix format
mix credo --strict   # includes ExSlop + jump_credo_checks
mix compile --warnings-as-errors
```

Git-local repo; not on GitHub or Hex yet. Do NOT bump versions without explicit permission.

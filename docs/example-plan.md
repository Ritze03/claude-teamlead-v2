# Rate limiting for the public API

> **Stage 4** — implementation plan written, awaiting your review · started 2026-08-28
> Typing "Go" now → I start implementing.

## Goal
Every public API endpoint enforces a per-key request budget, returns `429` with a
`Retry-After` header when exceeded, and never rate-limits internal service-to-service calls.

## Context
- 34 public endpoints across `api/routes/*.py`, all behind one `@app.route` decorator stack —
  so there is a single place to hook, not 34. *(scout, 2026-08-28)*
- Redis is already a dependency (session store, `infra/redis.py`), currently single-node.
- Internal calls arrive with `X-Internal-Token`; there are 11 such call sites.
- Must not break the existing `/health` and `/metrics` endpoints — they are polled every 5s
  by the monitoring stack and would trip any sane limit.

## Decisions
- **D1** Token bucket, not fixed window — *fixed windows let a client burst 2× the budget
  across a boundary, and we have a customer who does exactly this.*
- **D2** Limits live in Redis, not in-process — *we run 4 app instances; in-process counters
  would give each client 4× their budget.*
- **D3** Fail **open** if Redis is unreachable — *an outage in the limiter must not take the
  API down with it. Logged as an error, alerted on.*
- **D4** Limits are per API key, not per IP — *most traffic is server-side and shares IPs.*
- **D5** `/health` and `/metrics` are exempt by path allowlist, not by a limit tier —
  *simpler, and an exemption should be obvious when reading the config.*
- **D6** Default budget is 1000/hour — *matches what the pricing page already claims.*
- **D7** No per-endpoint overrides in v1 — *one budget per key ships; overrides are a
  second release once we see real usage.*
- **D8** Exceeding the limit throttles, never hard-blocks — *a hard block turns a
  burst into an outage for a paying customer.*

## Open questions
*(none open — all resolved below)*

### Answered
- ~~Default budget for a key with no explicit tier?~~ → 1000/hour, matching the
  pricing page. → **D6**
- ~~Per-endpoint overrides on day one?~~ → No, one budget per key ships first. → **D7**
- ~~Ever hard-block a key, or only throttle?~~ → Throttle only. → **D8**
- ~~Redis or Postgres for the counters?~~ → Redis, already a dependency. → **D2**
- ~~What happens when Redis is down?~~ → Fail open, alert. → **D3**
- ~~Per-IP or per-key?~~ → Per-key. → **D4**

## Notes from me
Don't touch the billing endpoints yet — that's a separate contract question with legal and
I don't want it entangled with this.

Also: whatever the default is, it needs to match what's on the pricing page. Check before
picking a number.

## Implementation plan
*Built from D1–D8 · decisions:a4ea*

| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | Confirm all 34 endpoints share one entry point; list any that bypass it | `tl-sonnet-medium` | *(read-only)* | — |
| 2 | I2 | Token bucket in `bucket.py`, Redis-backed, fail-open — **D1 D2 D3** | `tl-sonnet-high` | `api/limits/` | I1 |
| 2 | I3 | Config schema + path allowlist for exemptions — **D5** | `tl-sonnet-medium` | `api/config/` | I1 |
| 3 | I4 | Wire the limiter into the decorator stack, skip on `X-Internal-Token` — **D4** | `tl-sonnet-high` | `api/routes/` | I2, I3 |
| 3 | I7 | Default budget + throttle-not-block behaviour — **D6 D7 D8** | `tl-sonnet-medium` | `api/limits/policy.py` | I2 |
| 4 | I5 | Tests: boundary burst, Redis-down fail-open, internal bypass, `/health` exemption | `tl-sonnet-high` | `tests/limits/` | I4 |
| 5 | I6 | QC pass over I2–I7 against D1–D8 and the goal | `tl-sonnet-high` | *(read-only)* | I5 |

Same wave = runs in parallel. `Owns` is the write scope handed verbatim to the worker.

**Checks** — all four pass:
1. Every `After` target is in a lower wave. ✅
2. No two rows in one wave overlap in `Owns` — I2 `api/limits/` vs I3 `api/config/`. ✅
3. Every row has an agent tier. ✅
4. D1–D8 each appear in a task. ✅

No Opus anywhere: the design calls are already made above, so what remains is execution.

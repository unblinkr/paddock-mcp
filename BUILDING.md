# Build on Paddock — free API for agent-commerce data

> **Canonical source.** This file is mirrored to `BUILDING.md` in the public
> [`unblinkr/paddock-mcp`](https://github.com/unblinkr/paddock-mcp) repo, which is
> where builders read it. Edit here, then mirror — the same relationship
> `openapi.json` has. `free-tier-surface-drift.test.ts` asserts the tool list and
> the daily limit in this file against `src/lib/paddock/tool-access.ts`, so it
> cannot drift from what the gate actually enforces.

Paddock is the independent data layer for AI agent commerce. We track x402
settlement on-chain every day — who's live, what categories are active, where the
volume goes — and publish it through a free API and MCP server. This is what you
can build without paying anything.

## Get started in 60 seconds

1. **No key needed to start.** `get_market_summary` is open to anyone — current
   market volume, USDC spend, active buyer agents, live providers, top
   categories. Hit it and you're reading live data. No key, no signup, no rate
   limit; it's the citation surface.
2. **Want more? Mint a free key.** Self-serve and instant: enter your address on
   [paddock.finance/api-access](https://paddock.finance/api-access), or POST it to
   the endpoint below, and a `pk_free_` key comes straight back in the response —
   a copy is emailed to you as well. **Nobody approves it and there is nothing to
   wait for**; you are not emailing us to ask. That unlocks five more tools,
   sharing 10 calls/day between them — `verify_before_pay` among them.
3. **Connect it.** Works as a plain REST API or as an MCP server
   (`https://paddock.finance/api/mcp/mcp`) — drop it into Claude, Cursor, or any
   agent that speaks MCP.

```bash
# 1. Read live data right now, no key:
curl -s https://paddock.finance/api/mcp/summary

# 2. Mint a key — this returns it immediately, no approval step:
curl -X POST https://paddock.finance/api/keys/free \
  -H "Content-Type: application/json" \
  -d '{"email":"you@example.com"}'
# => { "ok": true, "key": "pk_free_…", "daily_limit": 10, "tools": [ … ] }

# 3. Use it:
curl -s -H "X-Paddock-Key: pk_free_YOUR_KEY" \
  'https://paddock.finance/api/mcp/category?name=llm'
```

Requesting again with the same address returns **the same key** rather than
minting a second one, so a lost key is one command away. `hello@paddock.finance`
is for questions and commercial licensing — not for requesting a key.

Endpoint: `https://paddock.finance` · MCP: `https://paddock.finance/api/mcp/mcp` ·
Questions: hello@paddock.finance

## What's free

| Tool | What it answers | Access |
|---|---|---|
| `verify_before_pay` | Should your agent pay this endpoint? Probes the target at query time for its 402, checks the decoded contract against what you expected and against the seller's own published config, then adds settlement recency, circular-cluster signal, and a price comparison. Returns `route` true / false / `"inconclusive"` with dated evidence | Free key — 10/day |
| `get_market_summary` | Market-wide daily overview: total volume, USDC spend, buyer agents, live providers, top categories | Free, no key, no limit |
| `get_category_detail` | One category's providers, their daily transactions, USDC volume, unique buyers, and reliability scores | Free key — 10/day |
| `get_niche_gaps` | Categories with high volume but few providers — where demand outruns supply | Free key — 10/day |
| `get_token_metrics` | Paddock's own daily time series, queryable by metric and date range: `spend_share_over_time`, `daily_transactions`, `category_concentration`, `new_services`, `liveness_score`, and the monthly Agent Commerce Index (`aci`) | Free key — 10/day |
| `get_liveness` | Whether a service is up, from real probe data — success rate, latency p50/p95, sample count, last-probe time — for **any probed domain**, including ones with no x402 volume | Free key — 10/day |

The five keyed tools share one 10-calls/day budget. `get_market_summary` doesn't
count against it.

**Two things to know about the data before you build on it.**

*It's a daily series, not a live feed — with exactly one exception.* Every tool
above reads the most recent nightly snapshot (the writer runs at 23:30 UTC).
`get_liveness` returns TrustBench's probe results as of that snapshot — real
probes, aggregated over 7 days, but not re-probed when you call. Polling any of
those tools more than once a day returns the same numbers. Build daily cadence,
not polling loops.

`verify_before_pay` is the exception, and it is the reason it exists: it sends an
unpaid request to the endpoint you name at the moment you call, so its liveness
and contract answers are as of `checked_at` and nothing else in the response is.
The historical parts of that same response — settlement recency, the circular
signal — are still snapshot-dated, and each block says which it is. If the probe
can't read a 402, `route` comes back `"inconclusive"` no matter how good the
history looks: test it with `route === true`, because the string `"inconclusive"`
is truthy and it is the one case where you must not pay on our say-so.

*There is no success-rate field on `verify_before_pay`, on purpose.* Paddock
observes settlements, not attempted calls — a payment that failed leaves no row
in our record, so any rate computed from it could only ever be 100%. You get
recency and frequency instead, which are things we can actually see.

*`get_token_metrics` is our series, not token prices.* It serves the same
first-party chart data the site renders — transaction and concentration trends,
not spot prices for agent tokens. Third-party token market data is deliberately
not resold through this API.

## Things you can build today

**Pre-flight check before your agent pays a provider.**
Before your agent routes a spend, check the provider's standing. `get_liveness`
gives you an up/down read backed by real probe data — success rate, latency,
sample count — for any probed domain; `get_category_detail` shows you the
alternatives in that category if it's down. Cache the answer for the day rather
than calling per routing decision: the underlying figures only change when the
nightly snapshot does, and a cached read costs you nothing against your quota.

**A daily health check on your own service.**
Running an API on x402? Pull `get_liveness` on your own domain once a day and
alert on a drop in `success_rate_7d` or a latency climb. That's 1 call a day, and
it's the honest cadence — the probe data behind it refreshes nightly, so a
tighter loop tells you nothing new. If you need sub-day downtime detection, run
your own uptime check; this tells you how the ecosystem's prober sees you.

**A "where's the open lane?" scout.**
Deciding what agent service to build next? `get_niche_gaps` surfaces categories
with real volume but few providers — demand outrunning supply — and
`get_category_detail` shows you who's already there and how much they're moving.
4–8 calls when you're researching.

**A dashboard for your category.**
Track the category you operate in: providers, daily transactions, USDC volume,
unique buyers, plus the market-wide context from `get_market_summary`. 2–4 calls
a day keeps it current.

**A trend check on today's number.**
Is today's activity in your category a real move or ordinary noise? Pull
`get_token_metrics?metric=daily_transactions&days=90` (or
`category_concentration`) and compare the trend against what
`get_market_summary` reports today. 2–3 calls, and it's the difference between
reporting a spike and reporting a Tuesday.

## Metering yourself

Every successful free-key response carries a `usage` object, so you never have to
guess how much quota is left:

```json
{
  "tool": "get_category_detail",
  "tier": "free_key",
  "usage": {
    "used": 3,
    "limit": 10,
    "remaining": 7,
    "resets_at": "2026-08-12T00:00:00.000Z"
  }
}
```

Quotas reset at 00:00 UTC. Past the limit you get a `429` that tells you exactly
when you're back and what the paid paths cost:

```json
{
  "tool": "get_liveness",
  "status": "rate_limited",
  "error": "free_tier_daily_limit_reached",
  "usage": { "used": 11, "limit": 10, "remaining": 0,
             "resets_at": "2026-08-12T00:00:00.000Z" },
  "upgrade": {
    "pay_per_query": "Settle the tool's USDC price via x402 at call time — no subscription, no key.",
    "builder": "Builder — $99/mo, 10,000 calls/day, every paid tool.",
    "url": "https://paddock.finance/api-access"
  }
}
```

Calling a **premium** tool with a free key returns a `402` naming the price — and
that refusal is **not** counted against your daily limit.

## When you outgrow the free tier

If you're running a production agent making hundreds of routing calls, need
history and change-tracking, or want the deeper intelligence — cheapest-provider
routing, wash/circular signals, revenue leaderboards, the full monthly dataset —
those run on per-call x402 payment or a builder key with higher limits.

| Tool | Per-call |
|---|---|
| `get_best_value_provider` — providers ranked by reliability + reputation + price | $0.02 |
| `get_changes` — diff today against any past date: new services, retired services, movers | $0.10 |
| `get_circular_signal` — wash / circular-settlement signal, per facilitator | $0.99 |
| `get_whale_activity` — large settlements and movers, aggregate | $0.99 |
| `get_provider_revenue` — which services earn the most, and how much of the market that answer can see | $0.99 |
| `get_report_data` — the full monthly State of Agent Commerce dataset | $0.99 |

Pay per call with x402 and no subscription, or take a Builder key at $99/mo for
10,000 calls/day across everything. Full reference at
[paddock.finance/docs](https://paddock.finance/docs), or email
hello@paddock.finance and we'll help you find the right fit.

---

Free for development and internal use. Redistribution, resale, or serving Paddock
data to your end users requires a commercial license — see
[paddock.finance/api-access](https://paddock.finance/api-access) or contact
hello@paddock.finance.

*Every number Paddock publishes carries its methodology. We track x402, MPP, and
other observable rails. Independent, neutral, and yours to query.*

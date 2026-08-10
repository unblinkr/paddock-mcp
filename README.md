# Paddock

Paddock is the neutral, citable data layer for AI agent commerce on x402, across Base and Solana. It snapshots the live agent economy — transaction volume, spend, buyers, providers, category share, and reliability — and serves it through a set of MCP tools and an HTTP API that agents can call directly, paying per query with x402 or with a subscription key.

> **Note on `openapi.json`:** The `openapi.json` in this repository is a byte-for-byte mirror of the live specification served at `paddock.finance/openapi.json`, which is generated from the site's route and is the source of truth. Both declare the same `info.version` (currently `3.2.0`); if they ever disagree, the live specification is correct and this file is stale. Use either for tool discovery and client generation.

## Why agents call it

- **Find the best live provider.** Rank providers in a category by a composite of reliability (7-day success rate), reputation (unique buyers), and price — so an agent can route to the strongest option, not just the cheapest.
- **Is this service still up?** Per-domain liveness lookup — up/down, 7-day success rate, and latency — before an agent commits a paid call to a provider.
- **Where's demand moving?** Diff today's snapshot against a past date to see new services, retired services, category share movements, and top movers — so an agent knows where spend is shifting.

## The MCP tools

Eleven tools are live, across three access tiers. `get_market_summary` needs no authentication at all. Four tools are covered by a **free key** — 20 calls per UTC day, shared across all four, issued instantly from an email address. The rest are premium: a Paddock API key, an x402/MPP per-query payment, or one free trial call per day (where noted).

| Tool | Price | Description |
| --- | --- | --- |
| `get_market_summary` | Free | Current AI agent commerce market overview — total daily transaction volume, USDC spend, unique buyer agents, live service providers, and the top spending categories with their share of volume. |
| `get_category_detail` | Free key | All services in a specific category (`llm`, `data`, `search`, `infra`, `content`, `markets`, `payments`, `comms`; aliases accepted) with transaction counts, pricing, provider count, and reliability scores. |
| `get_niche_gaps` | Free key, or $0.01 USDC / query | Ranks every category by `opportunity_score` (high volume, few providers) with share, top-provider concentration, and an Open/Tightening/Consolidating/Mature signal. Answers "where should I build an x402 service?" |
| `get_best_value_provider` | $0.02 USDC / query | Ranks providers in one category by a composite of reliability (7-day success rate), reputation (unique buyers), and price. |
| `get_liveness` | Free key, or $0.001 USDC / query | Per-domain liveness for **any domain TrustBench probes**, with full probe detail — up/down (7-day success rate >= 0.95), score, latency p50/p95, sample count, endpoint count, and last-probe time. Reads the same nightly rollup as `get_category_detail`; the difference is reach and depth, not freshness — it answers for domains that have no x402 volume at all, which the category tool cannot. |
| `get_changes` | $0.10 USDC / query | Diffs today's market snapshot against a past date (up to 90 days back): new services, retired services, category share movements, and top movers. |
| `get_circular_signal` | $0.99 USDC / query | Wash/circular-settlement signal, aggregate per facilitator: cluster count, cluster volume (30d/7d), self-funding %, external-payer count, flagged share of settlement, and trend. Aggregate only — no wallet addresses or operator identity. |
| `get_whale_activity` | $0.99 USDC / query | Large settlements and movers over a window, aggregate by facilitator, category, and size band: amounts, counts, and per-category mover counts. Describes size and where, never who. |
| `get_token_metrics` | Free key, or $0.01 USDC / query | First-party chart/time-series data by metric and date range — spend share over time, daily transactions, category concentration, new services, liveness score, and the Agent Commerce Index (ACI). |
| `get_provider_revenue` | $0.99 USDC / query | Which providers earn the most over a window of daily snapshots, and how much of the market that answer can see. Attributed universe only — facilitator pass-through and circular-flagged wallets are excluded, and unresolved wallets are not dropped but surface as one explicit `unattributed` row (transaction share only; no dollar figure exists for them). Reports whether the recipient list was complete on every aggregated day. |
| `get_report_data` | Free metadata + $0.99 USDC / query for full data | Free metadata (title, table of contents, executive summary excerpt) at the unauthenticated `/api/paddock/mcp/report-data` route; full structured JSON of the monthly State of Agent Commerce report — ecosystem trends, category breakdowns, the Agent Commerce Index (ACI) with component decomposition, protocol comparison, and reliability data — via the x402-hardened `/api/paddock/mcp/report-data/paid` route. |

The paid tools (`get_niche_gaps`, `get_best_value_provider`, `get_liveness`, `get_changes`, `get_circular_signal`, `get_whale_activity`, `get_token_metrics`, `get_provider_revenue`) each allow one free trial call per day per IP. `get_report_data` has no free trial on the full-data route; only its metadata is free.

> `get_report_data` is published with two paths. The free-metadata route (`/api/paddock/mcp/report-data`) is declared with `security: []` and is deliberately excluded from x402scan indexing; the full-data route (`/api/paddock/mcp/report-data/paid`) carries the x402 payment scheme. Both are visible in `openapi.json`.

## Connecting from Claude Desktop

In Claude Desktop, open **Settings → Connectors → Add custom connector**, then paste the Paddock MCP URL below. Claude discovers the tools automatically.

```
https://paddock.finance/api/mcp/mcp
```

The free tools work over the connector with no authentication. The paid tools work over the connector too: pass your Paddock API key as the `api_key` argument on the tool call and the server forwards it as the `X-Paddock-Key` header, billing the call against your subscription. Omit `api_key` to use the once-per-day free trial, or to settle the tool's USDC price via x402 pay-per-query.

## Connecting from other MCP clients

Paddock exposes a standard MCP HTTP transport at the same URL — point any MCP-compatible client at it:

```
https://paddock.finance/api/mcp/mcp
```

For tool discovery, schemas, and the full route map, see [`openapi.json`](./openapi.json) in this repository (mirrored to `paddock.finance/openapi.json`).

## The free key

`get_market_summary` is open to everyone with no key and no signup.

Four more tools — `get_category_detail`, `get_niche_gaps`, `get_token_metrics`, `get_liveness` — are covered by a free key. One request gets you one:

```bash
curl -X POST https://paddock.finance/api/keys/free \
  -H "Content-Type: application/json" \
  -d '{"email":"you@example.com"}'
```

The key is returned in the response and emailed to you. Pass it as the `X-Paddock-Key` header, or as the `api_key` argument over the MCP connector.

- **20 calls per UTC day, shared across all four tools** — one counter, not 20 each.
- Every successful response carries a `usage` object (`used`, `limit`, `remaining`, `resets_at`) so you can meter yourself.
- Over the limit returns a structured 429 naming the reset time and both paid paths.
- Premium tools are never on a free key. Calling one returns a structured 402 naming the price — and that refusal is **not** counted against your daily limit.

**Free trial and free key are different.** The free trial is 1 call per IP per day with no key at all, shared across the paid tools — a zero-friction taste, and it still works. The free key is the workflow tier above it, tied to your key rather than your IP.

> Free for development and internal use. Redistribution, resale, or serving Paddock data to your end users requires a commercial license — see [paddock.finance/api-access](https://paddock.finance/api-access) or contact hello@paddock.finance.

## Pricing

| Plan | Price | Limit |
| --- | --- | --- |
| Keyless | Free | `get_market_summary`, at 1,000 queries/day per IP |
| Free key | Free | Four tools at 20 queries/day, shared — see [The free key](#the-free-key) |
| Builder | $99/mo | 10,000 queries/day |
| Pro Agent | $499/mo | Unlimited |
| x402 per-query | Pay per pull | Agent-native, no subscription — pay the per-tool USDC price at call time |

The x402 per-query option is for agent-native, pay-per-pull access with no subscription: an agent settles the tool's USDC price at call time. To subscribe to Builder or Pro Agent and obtain an API key, see [`paddock.finance/api-access`](https://paddock.finance/api-access).

## Authentication

Keys come in three classes and all travel the same way, in the `X-Paddock-Key` header: `pk_free_` (free tier, four tools, 20/day shared), `pk_builder_` ($99/mo) and `pk_proagent_` ($499/mo). Paid tools accept a Builder or Pro Agent key; Send the key with each request and the call is billed against your subscription's daily quota. Over the MCP connector (e.g. in Claude), pass the key as the `api_key` tool argument instead — the server forwards it as `X-Paddock-Key`. Alternatively, agents can pay per query with x402: omit the key and settle the tool's USDC price via the x402 payment flow at call time. Free tools require neither.

## Docs & contact

- Canonical documentation: [`paddock.finance/docs`](https://paddock.finance/docs)
- Questions: `hello@paddock.finance`
- On X: [@PaddockFinance](https://x.com/PaddockFinance)

## Status

Production. Snapshots written daily at 23:30 UTC.

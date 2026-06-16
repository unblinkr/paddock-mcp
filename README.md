# Paddock

Paddock is the neutral, citable data layer for AI agent commerce on x402, across Base and Solana. It snapshots the live agent economy — transaction volume, spend, buyers, providers, category share, and reliability — and serves it through a set of MCP tools and an HTTP API that agents can call directly, paying per query with x402 or with a subscription key.

> **Note on `openapi.json`:** The `openapi.json` in this repository is authoritative. The live specification at `paddock.finance/openapi.json` is mirrored from it, so the two match exactly. Use this file for tool discovery and client generation.

## Why agents call it

- **Find the best live provider.** Rank providers in a category by a composite of reliability (TrustBench 7-day success rate), reputation (unique buyers), and price — so an agent can route to the strongest option, not just the cheapest.
- **Is this service still up?** Per-domain liveness lookup against TrustBench probe data — up/down, success rate, and latency — before an agent commits a paid call to a provider.
- **Where's demand moving?** Diff today's snapshot against a past date to see new services, retired services, category share movements, and top movers — so an agent knows where spend is shifting.

## The MCP tools

Seven tools are live. Free tools require no authentication; paid tools accept a Paddock API key, an x402 per-query payment, or one free trial call per day (where noted).

| Tool | Price | Description |
| --- | --- | --- |
| `get_market_summary` | Free | Current AI agent commerce market overview — total daily transaction volume, USDC spend, unique buyer agents, live service providers, and the top spending categories with their share of volume. |
| `get_category_detail` | Free | All services in a specific category (`llm`, `data`, `search`, `infra`, `content`, `markets`, `payments`, `comms`; aliases accepted) with transaction counts, pricing, provider count, and reliability scores. |
| `get_niche_gaps` | $0.01 USDC / query | Ranks every category by `opportunity_score` (high volume, few providers) with share, top-provider concentration, and an Open/Tightening/Consolidating/Mature signal. Answers "where should I build an x402 service?" |
| `get_best_value_provider` | $0.02 USDC / query | Ranks providers in one category by a composite of reliability (TrustBench 7-day success rate), reputation (unique buyers), and price. |
| `get_liveness` | $0.001 USDC / query | Per-domain liveness lookup against TrustBench probe data: up/down (7-day success rate >= 0.95), score, latency p50/p95, and sample count. |
| `get_changes` | $0.10 USDC / query | Diffs today's market snapshot against a past date (up to 90 days back): new services, retired services, category share movements, and top movers. |
| `get_report_data` | Free metadata + $0.99 USDC / query for full data | Free metadata (title, table of contents, executive summary excerpt) at the unauthenticated `/api/paddock/mcp/report-data` route; full structured JSON of the monthly State of Agent Commerce report — ecosystem trends, category breakdowns, the Agent Commerce Index (ACI) with component decomposition, protocol comparison, and reliability data — via the x402-hardened `/api/paddock/mcp/report-data/paid` route. |

The paid tools (`get_niche_gaps`, `get_best_value_provider`, `get_liveness`, `get_changes`) each allow one free trial call per day per IP. `get_report_data` has no free trial on the full-data route; only its metadata is free.

> `get_report_data` is published with two paths. The free-metadata route (`/api/paddock/mcp/report-data`) is declared with `security: []` and is deliberately excluded from x402scan indexing; the full-data route (`/api/paddock/mcp/report-data/paid`) carries the x402 payment scheme. Both are visible in `openapi.json`.

## Connecting from Claude Desktop

In Claude Desktop, open **Settings → Connectors → Add custom connector**, then paste the Paddock MCP URL below. Claude will discover the tools automatically and prompt for payment or an API key on the paid tools.

```
https://paddock.finance/api/mcp/mcp
```

## Connecting from other MCP clients

Paddock exposes a standard MCP HTTP transport at the same URL — point any MCP-compatible client at it:

```
https://paddock.finance/api/mcp/mcp
```

For tool discovery, schemas, and the full route map, see [`openapi.json`](./openapi.json) in this repository (mirrored to `paddock.finance/openapi.json`).

## Pricing

| Plan | Price | Limit |
| --- | --- | --- |
| Free MCP tier | Free | Two tools (`get_market_summary`, `get_category_detail`) at 1,000 queries/day per IP |
| Builder | $99/mo | 10,000 queries/day |
| Pro Agent | $499/mo | Unlimited |
| x402 per-query | Pay per pull | Agent-native, no subscription — pay the per-tool USDC price at call time |

The x402 per-query option is for agent-native, pay-per-pull access with no subscription: an agent settles the tool's USDC price at call time. To subscribe to Builder or Pro Agent and obtain an API key, see [`paddock.finance/api-access`](https://paddock.finance/api-access).

## Authentication

Paid tools accept a Paddock API key passed in the `X-Paddock-Key` header. Send the key with each request and the call is billed against your subscription's daily quota. Alternatively, agents can pay per query with x402: omit the key and settle the tool's USDC price via the x402 payment flow at call time. Free tools require neither.

## Docs & contact

- Canonical documentation: [`paddock.finance/docs`](https://paddock.finance/docs)
- Questions: `hello@paddock.finance`
- On X: [@PaddockFinance](https://x.com/PaddockFinance)

## Status

Production. Snapshots written daily at 23:30 UTC.

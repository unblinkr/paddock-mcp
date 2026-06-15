#!/usr/bin/env bash
# Paddock — calling a paid MCP tool over HTTP.
# Example tool: get_best_value_provider ($0.02 USDC per query).
# Two ways to pay: (1) a Paddock API key, or (2) an x402 per-query micropayment.
set -euo pipefail

BASE="https://paddock.finance"
# Required query param: category = llm | data | search | infra | content | markets | payments | comms
ENDPOINT="$BASE/api/paddock/mcp/best-value?category=llm"

# ---------------------------------------------------------------------------
# Option 1 — Paddock API key (Builder $99/mo · 10k/day, or Pro Agent $499/mo).
# Pass your key in the X-Paddock-Key header. Subscribe at:
#   https://paddock.finance/api-access
# ---------------------------------------------------------------------------
curl -s -H "X-Paddock-Key: ${PADDOCK_API_KEY:?set PADDOCK_API_KEY first}" "$ENDPOINT"
# Expected shape:
# {
#   "tool": "get_best_value_provider",
#   "date": "2026-06-15",
#   "category": "llm",
#   "category_label": "LLM Inference",
#   "paid_via": "api_key",
#   "providers": [
#     { "domain": "api.example.com", "title": "Example LLM", "price_usdc": 0.004,
#       "success_rate_7d": 0.991, "composite_score": 0.87, "rank": 1 }
#   ],
#   "formula": { ... }
# }

# ---------------------------------------------------------------------------
# Option 2 — x402 per-query (no subscription, pay-per-pull with USDC on Base).
# Calling with no key returns HTTP 402 with the x402 v2 payment challenge:
curl -s -o /dev/null -w "%{http_code}\n" "$ENDPOINT"   # -> 402
# The 402 body lists the accepted payment (scheme, network eip155:8453, amount,
# asset, payTo). Settle it with an x402-capable wallet, then retry the request
# with the resulting payment receipt header. The full x402 flow and header
# format are documented at: https://paddock.finance/docs

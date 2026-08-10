#!/usr/bin/env bash
# Paddock — free-tier MCP tools over HTTP.
# get_market_summary is keyless. get_category_detail needs a FREE KEY:
#   curl -X POST https://paddock.finance/api/keys/free \
#     -H "Content-Type: application/json" -d '{"email":"you@example.com"}'
# The free key covers get_category_detail, get_niche_gaps, get_token_metrics
# and get_liveness at 20 calls/UTC-day, shared across all four.
#
# Free for development and internal use. Redistribution, resale, or serving
# Paddock data to your end users requires a commercial license — see
# paddock.finance/api-access or contact hello@paddock.finance.
set -euo pipefail

BASE="https://paddock.finance"

# get_market_summary — current AI agent commerce market overview.
# No parameters. Returns daily volume, spend, buyers, providers, top categories.
curl -s "$BASE/api/paddock/mcp/summary"
# Expected shape:
# {
#   "date": "2026-06-15",
#   "summary": {
#     "daily_transactions": 12345,
#     "daily_volume_usdc": "48210.50",
#     "unique_buyer_agents": 870,
#     "live_service_providers": 142
#   },
#   "top_categories": [
#     { "category": "llm", "daily_transactions": 5000, "providers": 30, "share_of_volume": "41%" }
#   ],
#   "insight": "...",
#   "subscription_url": "https://paddock.finance/api-access"
# }

# get_category_detail — all services in one category. FREE KEY REQUIRED.
# Required query param: name = llm | data | search | infra | content | markets | payments | comms
# Every successful response also carries a `usage` object: used, limit,
# remaining, resets_at — so you can meter yourself without guessing.
curl -s -H "X-Paddock-Key: ${PADDOCK_API_KEY:?set PADDOCK_API_KEY to your pk_free_ key}" \
  "$BASE/api/paddock/mcp/category?name=llm"
# Expected shape:
# {
#   "category": "llm",
#   "summary": { "total_daily_transactions": 5000, "provider_count": 30, "market_status": "..." },
#   "services": [
#     { "service": "Example LLM", "domain": "api.example.com",
#       "daily_transactions": 1200, "unique_buyers": 210 }
#   ]
# }

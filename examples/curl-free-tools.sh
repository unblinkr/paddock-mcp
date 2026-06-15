#!/usr/bin/env bash
# Paddock — free MCP tools over HTTP.
# Both tools below are free: no API key, no payment, no headers.
# Free tier: 1,000 requests/day per IP across the two free tools.
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

# get_category_detail — all services in one category.
# Required query param: name = llm | data | search | infra | content | markets | payments | comms
curl -s "$BASE/api/paddock/mcp/category?name=llm"
# Expected shape:
# {
#   "category": "llm",
#   "summary": { "total_daily_transactions": 5000, "provider_count": 30, "market_status": "..." },
#   "services": [
#     { "service": "Example LLM", "domain": "api.example.com",
#       "daily_transactions": 1200, "unique_buyers": 210 }
#   ]
# }

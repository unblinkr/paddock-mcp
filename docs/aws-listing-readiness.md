# AWS Marketplace listing readiness

> **Note:** the build spec referred to this file as an existing document to be
> updated. No such file existed in this repository (or anywhere in its history) —
> it was created here on 2026-09-14. If a readiness doc exists elsewhere, this
> should be reconciled with it rather than kept in parallel.

## Status: shipped to limited visibility

| | |
| --- | --- |
| **Listing status** | **Published — limited visibility** |
| Published | 2026-09-14 |
| Product created | 2026-09-09 |
| Product ID | `prod-wvxzqaqoxgane` |
| Product code | `es8jj45gpn2jd9o5wl3p7v08j` |
| Seller account | 462783693864 (us-east-1) |
| Pricing model | Usage-based (pay-as-you-go) |
| Current prices | **Test prices, $0.00000001/unit** |
| Integration | AWS Marketplace **Concurrent Agreements** (mandatory — product created after 2026-06-01) |

## Dimensions

| Dimension | Test price | Real price |
| --- | --- | --- |
| `verify_before_pay` | $0.00000001 | $0.25 |
| `premium_query` | $0.00000001 | $0.99 |
| `standard_query` | $0.00000001 | $0.05 |

## What is done

- [x] Product created in the Marketplace Management Portal.
- [x] Listing published to **limited visibility**.
- [x] Three metering dimensions defined.
- [x] Test prices set for integration testing.
- [x] Fulfillment method set to "Redirect to your website",
      URL `https://paddock.finance/aws`.
- [x] Integration requirements verified against live AWS docs
      (see [`aws-integration-findings.md`](./aws-integration-findings.md)) —
      confirmed we are on Concurrent Agreements, and that several assumptions in
      the original build spec were based on the superseded pre-June-2026 flow.
- [x] Full integration specified end to end in
      [`aws-billing-integration.md`](./aws-billing-integration.md).

## What is not done

Blocking a public listing:

- [ ] `POST /aws` fulfillment route (token exchange + key minting).
- [ ] EventBridge rule + SQS queue in the seller account.
- [ ] Subscription lifecycle consumer.
- [ ] Hourly metering job and metering ledger.
- [ ] `aws_metered` tier wired into the shared key resolver.
- [ ] Tests.
- [ ] IAM user created and the two env vars set in Vercel
      (founder steps are written; not yet executed).
- [ ] Manual test purchase walkthrough completed.
- [ ] Real prices restored.
- [ ] AWS Marketplace Seller Operations notified for final verification —
      **they independently confirm `BatchMeterUsage` records are landing before
      a public listing is permitted.**

None of the application code exists yet. It belongs in the paddock.finance
Next.js app, not in this repository — see
[Implementation status](./aws-billing-integration.md#implementation-status).

## Why limited visibility is the right place to sit

The listing can be subscribed to only by accounts we allow, so the seller
account can run the full test purchase at test prices without exposing a
half-built billing path to real buyers. The listing cannot go public until the
metering integration is live and AWS has verified it — so there is no deadline
pressure to ship the code before it is correct.

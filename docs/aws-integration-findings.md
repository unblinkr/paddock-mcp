# Finding note — where the live AWS docs contradict our build spec

**Date checked:** 2026-09-14. **Verified against:** AWS Marketplace Seller Guide,
AWS Marketplace Metering Service API Reference, and the AWS Marketplace blog.
House rule: live docs win. Every item below is a place where the original task
spec reflects the pre-June-2026 SaaS integration and would have shipped a
billing bug.

Paddock's SaaS product was created **2026-09-09**, i.e. after the **2026-06-01**
cutover. Concurrent Agreements is therefore **enabled by default and mandatory**,
and the legacy `ResolveCustomer`-plus-SNS tutorials do not apply to us.

---

## 1. Notifications are EventBridge, not SNS — the SNS topic is the wrong input

**Spec said:** subscribe an SQS queue to
`arn:aws:sns:us-east-1:287250355862:aws-mp-subscription-notification-es8jj45gpn2jd9o5wl3p7v08j`.

**Docs say:** SNS notifications for SaaS products are being replaced by
EventBridge. Critically, **SNS does not carry `LicenseArn`**, which is what makes
concurrent subscriptions distinguishable. A product on Concurrent Agreements
cannot tell two simultaneous agreements apart from SNS payloads.

**What we do instead:** an EventBridge rule on the **default event bus** in the
seller account, source `aws.agreement-marketplace`, target an SQS queue we own.
We keep the queue (durable, replayable, no public webhook to secure — the right
shape for Vercel), we just feed it from EventBridge rather than SNS.

## 2. `subscribe-success` / `unsubscribe-pending` / `unsubscribe-success` do not exist here

Those are SNS notification names. The EventBridge equivalents for a seller who
lists a public offer directly (so Paddock is **both manufacturer and proposer**)
are:

| Old SNS notification | EventBridge replacement |
| --- | --- |
| `subscribe-success` | `Purchase Agreement Created - Proposer` |
| `unsubscribe-pending` | `License Deprovisioned - Manufacturer` (opens the 1-hour final metering window) |
| `unsubscribe-success` | `Purchase Agreement Ended - Proposer`, and the close of the 1-hour window |
| `subscribe-fail` | no direct analogue; an agreement that never completes simply never emits *Created* |

Note the ordering difference that matters: under SNS, `unsubscribe-pending` was
the cue to flush final usage. Under EventBridge that cue is
`License Deprovisioned - Manufacturer`, and we get **exactly one hour** from it.
After that `BatchMeterUsage` rejects the records and the revenue is unbillable.

## 3. `BatchMeterUsage` must NOT be called with our product code

**Spec said:** submit `BatchMeterUsage` against product code
`es8jj45gpn2jd9o5wl3p7v08j`.

**Docs say:** for new integrations `LicenseArn` replaces `ProductCode`.
`ProductCode` is required *only* for legacy integrations keyed on
`CustomerIdentifier`. For Concurrent Agreements products, do **not** send
`ProductCode` at the request level — the per-record `LicenseArn` identifies both
the product and the specific agreement.

> **Double-billing hazard, quoted from the API reference:** "Sending metering
> records with both `ProductCode` and `LicenseArn` for the same customer within
> the same hour will result in duplicate billing."

The product code stays useful as an assertion — we check that the `ProductCode`
returned by `ResolveCustomer` equals ours before minting a key — but it never
goes into a metering call.

## 4. `CustomerIdentifier` comes back empty — identity keys on `LicenseArn`

**Spec said:** exchange the token for "the customer identifier", and populate the
holder record with "the AWS customer identifier".

**Docs say:** "For new SaaS product integrations, the `CustomerIdentifier` field
is not populated in the `ResolveCustomer` API response. New integrations must use
`CustomerAWSAccountId` and `LicenseArn` to identify customers."

So the field the spec wants to store is, for us, an empty string. Identity is
`LicenseArn` (primary) plus `CustomerAWSAccountId` (the buyer's AWS account).

## 5. Consequence: "one key per customer" is the wrong grain for idempotency

This one follows from Concurrent Agreements rather than from a single doc line,
and it changes a requirement we were given.

**Spec said:** "Idempotent: a returning subscriber gets their existing key, never
a silent second key."

The whole point of Concurrent Agreements is that **one AWS account can hold
several simultaneous active agreements for the same product**. If we make the key
unique per `CustomerAWSAccountId`, then a buyer with two legitimate concurrent
agreements collapses onto one key, and we have no way to attribute usage to the
right `LicenseArn` — every metering call for that buyer would be charged to
whichever agreement we happened to store. That is a billing correctness bug, not
a tidiness issue.

**Correct grain:** one Paddock key per **`LicenseArn`**. Idempotency is "same
`LicenseArn` re-presents its token → same key, every time". A second *concurrent
agreement* from the same AWS account is a genuinely new key, and that is not a
"silent second key" — it is a second thing the buyer is paying for. The
fulfillment page should say so plainly when it happens, so the buyer is not
confused by receiving a second key.

> **Decision (2026-09-14, accepted):** key grain is per-`LicenseArn`. A second
> concurrent agreement is a new key with its own holder record. Holder identity
> is `CustomerAWSAccountId` + `LicenseArn`, channel `aws-marketplace`. This
> supersedes the "one key per customer" wording in the original build spec.

## 6. Events the spec does not mention but a usage-based product receives

Beyond subscribe/unsubscribe we are sent, and should at minimum record:

- `Purchase Agreement Amended - Proposer` — agreement terms changed.
- `License Updated - Manufacturer` — entitlement changed.
- `Purchase Agreement Advisory Issued - Manufacturer` — AWS suspects buyer
  account closure, compromise, abuse, or fraud. **Billing-relevant:** AWS is
  telling us the agreement may be invalid. Worth alerting on rather than logging.
- `Purchase Agreement Advisory Resolved - Manufacturer` — cleared.
- `Spend Threshold Reached` / `Spend Threshold Vet Succeeded` /
  `Spend Threshold Vet Failed` — **pay-as-you-go products only, so ours.** AWS is
  card-verifying the buyer as their spend accumulates. Informational, but a
  `Vet Failed` is an early warning that revenue we are accruing may not collect.

## 7. Things the spec got right, confirmed

- **Hourly metering is correct.** Docs: "you must send metering records hourly",
  records are cumulative, deduplicated on the hour, and AWS explicitly
  recommends sending a record with quantity `0` even in an hour with no usage.
- The redirect is an HTTP **POST** carrying `x-amzn-marketplace-token`.
- `ResolveCustomer` is still the token-exchange call — it was extended, not
  replaced. It must be called **from the account that published the product**
  (462783693864), and the token must be redeemed immediately; it expires quickly
  and is single-use.

## 8. Hard limits worth designing against

- `BatchMeterUsage`: max **25 `UsageRecords`** per call, request under **1 MB**,
  one product per call.
- Usage records are **rejected 24 hours or more after the event**. Unreported
  usage older than a day is permanently unbillable — this is why the metering
  job must alert loudly rather than fail quietly.
- Month-end: records for the previous billing month are accepted only until
  **06:00 UTC on the 1st**, then `TimestampOutOfBoundsException`.
- If **any** record in a batch is out of range, **the entire batch is rejected**.
  Filter before sending.

## Sources

- [Integrating your SaaS subscription or Pay-As-You-Go product with AWS Marketplace](https://docs.aws.amazon.com/marketplace/latest/userguide/saas-integrate-subscription.html)
- [Managing SaaS subscription events with Amazon EventBridge](https://docs.aws.amazon.com/marketplace/latest/userguide/saas-eventbridge-integration.html)
- [BatchMeterUsage API reference](https://docs.aws.amazon.com/marketplacemetering/latest/APIReference/API_BatchMeterUsage.html)
- [ResolveCustomer API reference](https://docs.aws.amazon.com/marketplacemetering/latest/APIReference/API_ResolveCustomer.html)
- [Seller notifications for AWS Marketplace events](https://docs.aws.amazon.com/marketplace/latest/userguide/notifications.html)
- [Complete guide to upgrading your SaaS product to AWS Marketplace Concurrent Agreements](https://aws.amazon.com/blogs/awsmarketplace/complete-guide-to-upgrading-your-saas-product-to-aws-marketplace-concurrent-agreements/)
- [Integration for Concurrent Agreements (AWS seller workshop)](https://catalog.workshops.aws/mpseller/en-US/saas/integration-for-concurrent-agreements)

# AWS Marketplace billing integration

How a buyer who subscribes to Paddock on AWS Marketplace gets an API key, how we
bill them per call, and how we turn their access off when they leave.

> **Status: specification, not yet implemented.**
> This document is complete and verified against the live AWS docs as of
> 2026-09-14. The application code it describes (`/aws`, the event consumer, the
> metering job) lives in the paddock.finance Next.js app, which is **not** this
> repository — `unblinkr/paddock-mcp` is the public MCP mirror. See
> [Implementation status](#implementation-status) at the end.

> **Read [`aws-integration-findings.md`](./aws-integration-findings.md) first.**
> Our product was created 2026-09-09, which puts it on AWS's **Concurrent
> Agreements** integration (mandatory for SaaS products created after
> 2026-06-01). Several widely-copied tutorials — and our own original build
> spec — describe the older flow and would ship a double-billing bug.

---

## Product identifiers

| Field | Value |
| --- | --- |
| Product ID | `prod-wvxzqaqoxgane` |
| Product code | `es8jj45gpn2jd9o5wl3p7v08j` |
| Product ARN | `arn:aws:aws-marketplace:us-east-1:462783693864:AWSMarketplace/SaaSProduct/prod-wvxzqaqoxgane` |
| Seller AWS account | `462783693864` |
| Region | `us-east-1` (all Marketplace metering calls go here) |
| Fulfillment | Redirect to `https://paddock.finance/aws` |
| Pricing model | Usage-based (pay-as-you-go) |

The product code is used **only** to assert that an inbound token belongs to our
product. It is never sent in a metering call — see finding #3.

---

## The three flows

### 1. Registration — buyer lands on `/aws`

AWS redirects the buyer's browser to `https://paddock.finance/aws` as an **HTTP
POST** with a form field `x-amzn-marketplace-token`.

```
POST /aws
Content-Type: application/x-www-form-urlencoded

x-amzn-marketplace-token=<opaque, single-use, short-lived>
```

Handler steps:

1. **Redeem the token immediately.** Call `ResolveCustomer` with the token. It
   must be called with credentials from the publishing account (462783693864).
   The token is single-use and expires fast — do not queue it, do not round-trip
   it through the browser again.

   Response (Concurrent Agreements shape):

   ```json
   {
     "CustomerAWSAccountId": "111122223333",
     "CustomerIdentifier": "",
     "LicenseArn": "arn:aws:license-manager::111122223333:license/l-abc123...",
     "ProductCode": "es8jj45gpn2jd9o5wl3p7v08j"
   }
   ```

   `CustomerIdentifier` is **empty** for our product. Do not key on it.

2. **Assert `ProductCode` matches ours.** If it does not, this token is not for
   Paddock — refuse, log, do not mint anything.

3. **Look up by `LicenseArn`.** This is the idempotency key (finding #5).
   - Known `LicenseArn` → return the existing key's holder record. Never mint a
     second key for the same agreement, and never rotate the key on a revisit.
   - Unknown `LicenseArn` → mint one key, in a transaction, with a unique
     constraint on `LicenseArn` so two concurrent POSTs cannot race two keys into
     existence.

4. **Mint the key** on tier `aws_metered`, with the holder record carrying:

   | Field | Value |
   | --- | --- |
   | `channel` | `aws-marketplace` |
   | `aws_license_arn` | `LicenseArn` — the identity, unique, indexed |
   | `aws_customer_account_id` | `CustomerAWSAccountId` |
   | `aws_product_code` | `es8jj45gpn2jd9o5wl3p7v08j` |
   | `aws_customer_identifier` | `CustomerIdentifier` — empty for us; stored only so a legacy row and a new row have the same shape |
   | `status` | `pending` until the agreement-created event arrives, then `active` |

   **Holder identity is `CustomerAWSAccountId` + `LicenseArn`**, channel
   `aws-marketplace`. `LicenseArn` alone is the uniqueness constraint; the
   account id is carried for reporting and for answering "what does this buyer
   have with us". Confirmed decision, 2026-09-14 — see finding #5.

5. **Show the key exactly once**, with the same quickstart links the
   design-partner emails use.

6. **Do not meter yet.** AWS is explicit: usage reported before the
   subscription-confirmation event is not metered. Keys start `pending` and are
   flipped to `active` by `Purchase Agreement Created - Proposer`. Calls made
   while `pending` should be served and logged, but held unreported until the key
   goes active — see [Metering](#3-metering) for how the ledger handles that.

#### Error paths

All of these render a human-readable page, never a stack trace, and never a raw
AWS error string.

| Condition | Page |
| --- | --- |
| `GET /aws` with no token (buyer bookmarked it, or arrived by hand) | Explain this page is reached by subscribing on AWS Marketplace; link to the listing. Not an error state — it is the common case for a curious visitor. |
| POST with a missing or empty token field | Same as above, plus "if you arrived here from AWS Marketplace, start the subscription again from the listing". |
| `ExpiredTokenException` | "That registration link has expired — they are only valid for a few minutes. Go back to AWS Marketplace and choose **Set up your account** again." Include the listing link. |
| `InvalidTokenException` | Same copy as expired; the buyer's remedy is identical and the distinction is not useful to them. Log the difference for us. |
| `ProductCode` mismatch | Generic "we could not match that subscription to Paddock" + support email. Log loudly; this should never happen. |
| `ThrottlingException` / `InternalServiceErrorException` | "AWS is having trouble confirming your subscription. Try again in a minute." The token is probably still live, so retry is genuinely useful. |
| Credentials missing (see [fail-safe](#failing-loud-but-safe)) | "Billing setup is incomplete on our side — email support and we will sort it out." Alert us. **Never** mint an unbilled key to paper over it. |

### 2. Subscription lifecycle — EventBridge → SQS

Events arrive on the **default event bus** in the seller account, source
`aws.agreement-marketplace`. We route them to an SQS queue we own and poll it
from Vercel. (Queue rather than a public webhook: durable, replayable, and
nothing inbound to authenticate.)

Events we handle. Paddock lists a public offer directly, so we are **both
manufacturer and proposer** — where both variants exist AWS sends only the
*Proposer* one.

| detail-type | What we do |
| --- | --- |
| `Purchase Agreement Created - Proposer` | Flip the key for this `LicenseArn` to `active`. Metering may now begin, including for calls logged while `pending`. |
| `License Deprovisioned - Manufacturer` | **Starts a 1-hour final reporting window.** Immediately run an out-of-band metering flush for this `LicenseArn` — do not wait for the next hourly tick. Then revoke. |
| `Purchase Agreement Ended - Proposer` | Revoke the key: status flip to `revoked`, ledger rows survive untouched. Same semantics as design-partner revocation. |
| `Purchase Agreement Amended - Proposer` | Record on the holder. No access change. |
| `License Updated - Manufacturer` | Record. No access change for a usage-based product (we have no entitlement quantities to re-read). |
| `Purchase Agreement Advisory Issued - Manufacturer` | **Alert a human.** AWS suspects buyer account closure, compromise, abuse, or fraud. Do not auto-revoke; flag for review. |
| `Purchase Agreement Advisory Resolved - Manufacturer` | Clear the flag. |
| `Spend Threshold Reached` | Record. Informational. |
| `Spend Threshold Vet Succeeded` | Record. Informational. |
| `Spend Threshold Vet Failed` | **Alert.** AWS could not verify the buyer's card. Revenue we are accruing may not collect. |

Revocation is a status flip only. Metering ledger rows, and the call log they
were built from, are never deleted — they are the evidence behind an invoice.

**Ordering is not guaranteed.** Two rules:
- Process by `LicenseArn` and make each handler idempotent (SQS is
  at-least-once; the same event will arrive twice sooner or later).
- Never let a late-arriving `Purchase Agreement Created` un-revoke a key that a
  later-timestamped `Ended` already closed. Compare event timestamps, not
  arrival order.

### 3. Metering

An hourly job (`0 * * * *`) aggregates settled calls per `LicenseArn` per
dimension and submits `BatchMeterUsage`.

Hourly is confirmed correct by the docs: records are cumulative, deduplicated on
the hour, and AWS explicitly recommends sending quantity `0` in an hour with no
usage.

#### Dimension mapping

| Dimension | Price | Tools |
| --- | --- | --- |
| `verify_before_pay` | $0.25 | `verify_before_pay` |
| `premium_query` | $0.99 | `get_circular_signal`, `get_whale_activity`, `get_provider_revenue`, `get_report_data`, `get_token_metrics` |
| `standard_query` | $0.05 | `get_category_detail`, `get_changes`, `get_niche_gaps`, `get_liveness`, `get_best_value_provider` |

`get_market_summary` is unauthenticated and free. It is billed under no dimension
and must not appear in a metering call.

The mapping lives in one table in code with an **exhaustive** switch: a tool with
no dimension is a hard error at the aggregation step, not a silent zero. When we
add a tool, the build breaks until someone decides what it costs.

> Note: `get_token_metrics` is a free-key tool on x402 but maps to
> `premium_query` here. AWS Marketplace pricing is set independently of our x402
> per-query prices; this is intentional, per the listing.

#### What is billable

A call is billable when it was authenticated against an `aws_metered` key **and**
served a successful result. Explicitly **not** billable:

- anything that failed authentication,
- anything that returned 402,
- free/unauthenticated tools,
- calls served while the key was `pending` **and** the agreement never completed.

#### The request

```jsonc
// No ProductCode at the request level — finding #3. Sending both ProductCode
// and LicenseArn for the same customer in the same hour double-bills.
{
  "UsageRecords": [
    {
      "LicenseArn": "arn:aws:license-manager::111122223333:license/l-abc123...",
      "CustomerAWSAccountId": "111122223333",
      "Dimension": "premium_query",
      "Quantity": 42,
      "Timestamp": 1757808000
    }
  ]
}
```

Constraints to respect: **25 records max per call**, request under 1 MB, one
product per call. Chunk by 25.

#### The ledger

Every metering attempt writes a row **before** the call and is updated with the
outcome. This is what makes double-reporting impossible and disputes answerable.

| Column | Purpose |
| --- | --- |
| `id` | PK |
| `license_arn` | Who |
| `customer_aws_account_id` | Who, denormalised for reporting |
| `dimension` | What |
| `quantity` | How much |
| `period_start` / `period_end` | The hour this aggregates; **`UNIQUE (license_arn, dimension, period_start)`** |
| `timestamp_sent` | The `Timestamp` we put in the record |
| `status` | `pending` → `reported` \| `rejected` \| `unprocessed` |
| `aws_metering_record_id` | `MeteringRecordId` from `Results[]` |
| `aws_response` | Full response JSON, including any error |
| `attempts` | Retry count |
| `created_at` / `updated_at` | |

**The unique constraint is the guarantee.** An hour that already has a row for a
`(license_arn, dimension)` pair cannot be re-aggregated into a second submission,
whatever happens to the job — a duplicate cron fire, a retry after a timeout, a
redeploy mid-run. The insert fails and the job moves on.

Reconciliation, in order:

1. Insert ledger rows for the closed hour (`status = pending`). Conflict → that
   hour is already accounted for; skip.
2. Submit in chunks of 25.
3. `Results[]` → mark `reported`, store `MeteringRecordId`. A result can still be
   an *invalid* record; store the status AWS returns rather than assuming success.
4. `UnprocessedRecords[]` → leave `pending`, bump `attempts`, retry next tick.
   These are service-side failures and are safe to retry — the API is idempotent
   for identical records.
5. `TimestampOutOfBoundsException` → **the whole batch was rejected.** Filter the
   out-of-range records out, mark them `rejected`, resubmit the rest.

Anything still `pending` after **20 hours** is escalated to a human, because at
24 hours it becomes permanently unbillable.

#### Deadlines that lose money

- Records are rejected **24 hours or more** after the event.
- Previous month's records are accepted only until **06:00 UTC on the 1st**.
- `License Deprovisioned` gives **one hour** to flush final usage.

All three are alert-worthy, not log-worthy.

---

## Gating

`aws_metered` keys resolve through the existing shared key resolver on every paid
route, exactly like every other tier. Differences:

- **No local daily cap.** AWS bills per call; we do not also ration.
- **Every call is logged for metering**, with the `LicenseArn` and the resolved
  dimension, at the point the call is settled successfully.
- A `revoked` key fails the resolver like any other revoked key.

---

## Operations

Everything in this section is a thing that costs money when it goes unnoticed.
All of it is **alert-worthy, not log-worthy** — it needs to reach a human, not a
dashboard nobody opens.

### Deadlines that lose money

These are hard AWS limits. Past them the revenue is simply unbillable; there is
no appeal and no retroactive submission.

| Deadline | Limit | What the metering job must do |
| --- | --- | --- |
| **Record expiry** | Usage records are rejected **24 hours or more** after the event | Escalate any ledger row still `pending` at **20 hours**. Four hours of headroom to fix a credential or a bug by hand. |
| **Month-end close** | Previous month's records accepted only until **06:00 UTC on the 1st**, then `TimestampOutOfBoundsException` | On the 1st, run the aggregation early and treat any `pending` row for the prior month as **critical** from 03:00 UTC. |
| **Deprovision flush** | **One hour** from `License Deprovisioned - Manufacturer` | Flush that `LicenseArn` immediately on the event — out of band, not at the next hourly tick. Alert if the flush fails; there is no second chance. |

Design consequence: the metering job must never treat "nothing reported" as
success. A tick that reports zero rows when the call log has billable calls in
it is a failure, and should say so.

### Warning events (pay-as-you-go only)

Our product is usage-based, so we receive AWS's spend-verification events. These
are the earliest signal that revenue we are accruing may not collect.

| Event | Severity | Response |
| --- | --- | --- |
| `Spend Threshold Vet Failed` | **Alert** | AWS could not verify the buyer's card. Keep serving — AWS retries — but flag the account. If it repeats, the receivable is at risk and someone should look at the exposure. |
| `Purchase Agreement Advisory Issued - Manufacturer` | **Alert** | AWS suspects buyer account closure, compromise, abuse, or fraud. **Do not auto-revoke** — AWS has not ended the agreement. Flag for human review. |
| `Spend Threshold Reached` | Record | Informational. AWS is starting a verification. |
| `Spend Threshold Vet Succeeded` | Record | Informational. Clears a prior `Reached`. |
| `Purchase Agreement Advisory Resolved - Manufacturer` | Record | Clears the advisory flag. |

### Alert routing

| Condition | Severity |
| --- | --- |
| Ledger row `pending` at 20h | Critical |
| Prior-month row `pending` after 03:00 UTC on the 1st | Critical |
| Deprovision flush failed | Critical |
| `PADDOCK_AWS_*` credentials absent in production | Critical |
| Metering job did not run for a scheduled hour | High |
| `Spend Threshold Vet Failed` | High |
| `Purchase Agreement Advisory Issued` | High |
| `BatchMeterUsage` returned `UnprocessedRecords` two ticks running | High |
| Any `rejected` ledger row | High — it is unbillable revenue; find out why |
| SQS queue depth non-zero for over an hour | Medium — the consumer is stuck |

### Routine checks

- **Weekly:** ledger total per dimension vs. the Marketplace Management Portal's
  usage report. They should match exactly. A drift is either a bug or a dispute
  waiting to happen.
- **Monthly, after the 1st:** confirm nothing was lost to the 06:00 UTC cutoff.
- **On any deploy touching metering:** confirm the next hourly tick produced
  ledger rows, rather than assuming it did.

---

## Environment variables

Two secrets, set in Vercel:

| Variable | Value |
| --- | --- |
| `PADDOCK_AWS_ACCESS_KEY_ID` | Access key ID for the `paddock-marketplace-billing` IAM user |
| `PADDOCK_AWS_SECRET_ACCESS_KEY` | Its secret access key |

> Deliberately **not** named `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. Those
> names collide with the serverless runtime's own credentials and the SDK's
> default provider chain, which has bitten people on Vercel. Construct the
> Marketplace clients with these values passed explicitly.

Non-secret config, checked into code rather than set as env vars:

```
region       us-east-1
productCode  es8jj45gpn2jd9o5wl3p7v08j
queueUrl     https://sqs.us-east-1.amazonaws.com/462783693864/paddock-aws-marketplace-events
```

### Failing loud but safe

If either variable is absent:

- `/aws` serves the "billing setup incomplete" page and alerts. It **does not**
  mint a key — an unbilled key is worse than a delayed one, and the buyer can
  retry from the listing once we fix it.
- The metering job **refuses to start** and alerts. It must not report zero usage
  for everyone, and must not mark ledger rows `reported` without a response.
- The event poller refuses to start and alerts. Events stay in SQS (14-day
  retention by default) and drain once credentials return.
- Paid routes for other tiers are unaffected. Missing AWS credentials must never
  take down x402 or design-partner traffic.

Check at the entry point of each of the three components, not at module load —
a throw at import time on Vercel takes out the whole route bundle.

---

## IAM policy

Minimal. `aws-marketplace` metering actions are service-level and do not support
resource-level permissions, so they take `"Resource": "*"`; the SQS statement is
scoped to the one queue.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "MarketplaceRegistrationAndMetering",
      "Effect": "Allow",
      "Action": [
        "aws-marketplace:ResolveCustomer",
        "aws-marketplace:BatchMeterUsage"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadSubscriptionEventQueue",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:us-east-1:462783693864:paddock-aws-marketplace-events"
    }
  ]
}
```

Deliberately **excluded**:

- `aws-marketplace:MeterUsage` and `RegisterUsage` — AMI/container actions, not SaaS.
- `aws-marketplace:GetEntitlements` — the docs state plainly that pay-as-you-go
  SaaS products "do not use entitlement SNS topics or the GetEntitlements API".
  Ours is pure usage-based. If we ever add a contract component, this comes back.
- `aws-marketplace:DescribeAgreement` — only needed to detect free trials on
  agreement-created. We have no free trial on the AWS listing. Add it if that
  changes.
- `sqs:SendMessage` — EventBridge writes to the queue under its own service
  principal via the queue policy, not as our user.

---

## Founder console steps

Exact click paths. Everything happens in the **seller account, 462783693864**,
region **US East (N. Virginia) / us-east-1**. Check the account number in the top
right of the console before starting — if it is not 462783693864, sign out and
sign back in with the Paddock seller account.

### Part 1 — Create the SQS queue (5 min)

1. Sign in to the AWS Console. Top right, confirm account **462783693864** and
   region **N. Virginia**.
2. In the search bar at the top, type `SQS` and click **Simple Queue Service**.
3. Click the orange **Create queue** button.
4. **Type**: leave it on **Standard**.
5. **Name**: type exactly `paddock-aws-marketplace-events`
6. Scroll down to **Message retention period** and set it to **14 days** (the
   maximum). This is our safety net if the app is down.
7. Leave everything else alone. Scroll to the bottom, click **Create queue**.
8. On the next screen, copy the **URL** shown near the top (it looks like
   `https://sqs.us-east-1.amazonaws.com/462783693864/paddock-aws-marketplace-events`)
   and paste it somewhere — you may be asked for it.

### Part 2 — Turn on Marketplace events and point them at the queue (10 min)

1. In the search bar, type `EventBridge` and click **Amazon EventBridge**.
2. In the left sidebar, click **Rules**.
3. Make sure the **Event bus** dropdown at the top says **default**.
4. Click **Create rule**.
5. **Name**: `paddock-marketplace-agreement-events`
6. **Rule type**: leave on **Rule with an event pattern**. Click **Next**.
7. Under **Event source**, leave **AWS events or EventBridge partner events**.
8. Scroll down to **Creation method** and choose **Custom pattern (JSON editor)**.
9. Paste this in, exactly:

   ```json
   {
     "source": ["aws.agreement-marketplace"]
   }
   ```

   This catches every agreement and license event for our products. Click **Next**.
10. **Target 1**: from the **Select a target** dropdown choose **SQS queue**.
11. In the **Queue** dropdown, pick `paddock-aws-marketplace-events`.
12. Click **Next**, then **Next** again (skip tags), then **Create rule**.

> AWS will offer to set the queue's permissions for you so EventBridge can write
> to it. Accept that. If it does not offer, tell your engineer — the queue needs
> a policy allowing `events.amazonaws.com` to `sqs:SendMessage`.

### Part 3 — Create the IAM user (10 min)

1. In the search bar, type `IAM` and click **IAM**.
2. Left sidebar → **Policies** → **Create policy**.
3. Click the **JSON** tab. Delete what is in the box and paste the policy from
   [IAM policy](#iam-policy) above.
4. Click **Next**. **Policy name**: `paddock-marketplace-billing`
5. Click **Create policy**.
6. Left sidebar → **Users** → **Create user**.
7. **User name**: `paddock-marketplace-billing`
8. Do **not** tick "Provide user access to the AWS Management Console". This user
   is for the app only and should never be able to sign in. Click **Next**.
9. **Permissions options**: choose **Attach policies directly**.
10. In the search box type `paddock-marketplace-billing` and tick the policy you
    just made. Click **Next**, then **Create user**.
11. Click into the new user → **Security credentials** tab → scroll to **Access
    keys** → **Create access key**.
12. **Use case**: choose **Application running outside AWS**. Click **Next**, then
    **Create access key**.
13. You now see **Access key** and **Secret access key**. The secret is shown
    **once only** — keep this tab open for the next part.

> Never paste these two values into email, chat, a document, or a support ticket.
> They go straight into Vercel and nowhere else. If you think one has leaked,
> come back to this screen and click **Deactivate**, then make a new one — it
> takes two minutes and costs nothing.

### Part 4 — Paste the two values into Vercel (5 min)

1. Go to <https://vercel.com>, open the Paddock project.
2. Top nav → **Settings** → left sidebar → **Environment Variables**.
3. Add the first one:
   - **Key**: `PADDOCK_AWS_ACCESS_KEY_ID`
   - **Value**: paste the **Access key** from the AWS tab
   - **Environments**: tick **Production**, **Preview**, and **Development**
   - Click **Save**.
4. Add the second one:
   - **Key**: `PADDOCK_AWS_SECRET_ACCESS_KEY`
   - **Value**: paste the **Secret access key**
   - **Environments**: same three
   - Click **Save**.
5. Go to the **Deployments** tab, find the most recent deployment, click the
   **⋯** menu on the right, and choose **Redeploy**. Environment variables only
   take effect on a new deployment.
6. Close the AWS tab. You will not need those values again.

### Part 5 — Tell your engineer

Send one message saying: queue created, EventBridge rule created, IAM user
created, both env vars set in Vercel, redeployed. **Do not include the key
values.**

---

## Manual test checklist — AWS test purchase

Run end to end against the limited-visibility listing while test prices
($0.00000001/unit) are in effect. Subscribe from the seller account
(462783693864) — AWS allows the seller account to buy its own limited listing.

Tick each line; note the timestamp and paste the evidence next to it.

**Registration**

- [ ] Open the limited listing URL while signed in as 462783693864.
- [ ] Click **Subscribe**, then **Set up your account**.
- [ ] Browser lands on `https://paddock.finance/aws`.
- [ ] Confirm in the network tab it was a **POST** carrying `x-amzn-marketplace-token`.
- [ ] The page shows a Paddock API key, once, with the quickstart links.
- [ ] Holder record exists with `channel = aws-marketplace`, tier `aws_metered`,
      a populated `aws_license_arn`, and `aws_customer_account_id = 462783693864`.
- [ ] `aws_customer_identifier` is empty — this is expected, not a bug (finding #4).

**Idempotency**

- [ ] Return to AWS Marketplace and click **Set up your account** again.
- [ ] The page shows the **same** key. No second key row exists for that `LicenseArn`.
- [ ] Confirm in the database: exactly one key row for that `LicenseArn`.

**Error paths**

- [ ] `GET https://paddock.finance/aws` in a fresh tab → friendly explainer page,
      no stack trace, links to the listing.
- [ ] POST with a junk token → "expired or invalid" copy, no key minted, no crash.
- [ ] Re-POST the *same* real token a second time → expired-token page (the token
      is single-use), and still no second key.

**Lifecycle**

- [ ] `Purchase Agreement Created - Proposer` arrives in the SQS queue within a
      few minutes. (Check: SQS console → queue → **Send and receive messages** →
      **Poll for messages**.)
- [ ] Key flips from `pending` to `active`.

**Gating and metering**

- [ ] Call `verify_before_pay` once with the new key. 200.
- [ ] Call a premium tool (e.g. `get_circular_signal`) twice. Both 200.
- [ ] Call a standard tool (e.g. `get_liveness`) three times. All 200.
- [ ] Call a paid route with a deliberately wrong key → 401/403, and **no**
      metering row is created.
- [ ] Wait for the top of the hour.
- [ ] Ledger has exactly three rows for that hour: `verify_before_pay` qty 1,
      `premium_query` qty 2, `standard_query` qty 3.
- [ ] Each row is `status = reported` with an `aws_metering_record_id`.
- [ ] Confirm the stored request JSON contains **no** `ProductCode` field
      (finding #3 — this is the double-billing check).

**No double-reporting**

- [ ] Trigger the hourly job again manually for the same hour.
- [ ] No new ledger rows. No second `BatchMeterUsage` call for that hour.
- [ ] The unique constraint rejected the re-insert (check the job's log line).

**Revocation**

- [ ] Unsubscribe from the product in the AWS Marketplace console.
- [ ] `License Deprovisioned - Manufacturer` lands in the queue.
- [ ] A final metering flush runs immediately — not at the next hourly tick.
- [ ] `Purchase Agreement Ended - Proposer` lands in the queue.
- [ ] Key status is `revoked`.
- [ ] A call with that key now fails the resolver.
- [ ] **All ledger rows still exist**, untouched.

**Billing confirmation**

- [ ] 24–48h later, the usage appears in the Marketplace Management Portal under
      the seller's usage/disbursement reporting, with quantities matching the
      ledger exactly.

**Fail-safe**

- [ ] In a preview deployment, unset `PADDOCK_AWS_SECRET_ACCESS_KEY`.
- [ ] `/aws` shows the "billing setup incomplete" page and does **not** mint a key.
- [ ] The metering job refuses to run and alerts, rather than reporting zeros.
- [ ] x402 and design-partner paid routes still work normally.

**Before going public**

- [ ] Restore real prices ($0.25 / $0.99 / $0.05) in the Marketplace Management
      Portal.
- [ ] Re-run one registration and one metered call at real prices.
- [ ] Notify AWS Marketplace Seller Operations that integration testing is
      complete — they run their own final verification that `BatchMeterUsage`
      records are landing before a public listing is allowed.

---

## Implementation status

Verified and written down here: the AWS-side contract in full — flow, event
types, API shapes, dimension mapping, ledger design, IAM policy, founder console
steps, test checklist, and the findings note.

**Not yet written: the code.** It belongs in the paddock.finance Next.js app.
This repository (`unblinkr/paddock-mcp`) is the public MCP mirror — it has no
app, no key infrastructure, and no `docs/design-partner-keys.md` to match
conventions against.

To finish, someone with access to the app repo needs to build, against the
existing key infrastructure:

| Component | What it is |
| --- | --- |
| `POST /aws` route | Token exchange, `LicenseArn`-keyed idempotent key minting, error pages |
| Event consumer | SQS poller (Vercel cron), idempotent per-event handlers, status flips |
| Metering job | Hourly cron, aggregation, chunked `BatchMeterUsage`, ledger reconciliation |
| Schema | `aws_metered` tier, holder columns above, metering ledger table with `UNIQUE (license_arn, dimension, period_start)` |
| Resolver change | `aws_metered` bypasses the daily cap, logs every settled call with its dimension |
| Tests | Token exchange, dimension mapping, idempotent reuse, revoke-on-unsubscribe, no-double-reporting |

### Confirmed decisions to carry into the build (2026-09-14)

1. **Key grain is per-`LicenseArn`.** A second concurrent agreement is a new key
   with its own holder record. Holder identity is `CustomerAWSAccountId` +
   `LicenseArn`, channel `aws-marketplace`. Easy to get wrong; see finding #5.
2. **The EventBridge event table above replaces the SNS instruction** in the
   original build spec. The SNS topic is not used.
3. **`BatchMeterUsage` carries `LicenseArn` only, never `ProductCode`.** Sending
   both for the same customer in the same hour double-bills.
4. **Ledger uniqueness is `(license_arn, dimension, period_start)`.** That
   constraint is the no-double-reporting guarantee.
5. **The [Operations](#operations) section is part of the contract**, not
   commentary — the money-losing deadlines and the PAYG warning events belong in
   the metering job's design, not just in a runbook.

These two documents, plus
[`aws-integration-findings.md`](./aws-integration-findings.md), are the contract
for the build.

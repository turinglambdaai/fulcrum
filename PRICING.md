# Fulcrum product and pricing plan

**English** · [简体中文](PRICING.zh-CN.md)

## Launch status and implementation boundaries

- Policy version: `2026-10-v2`, 2026-10-23. The owner confirmed that every product is still in development and has no actual users. This document replaces conflicting previous pricing, early-bird and Pro proposals; there is no existing customer cohort to migrate. **Prices are launch targets, not live offers or claims that the listed features are implemented.**
- Entitlements cover delivered platforms only. New commercial plans do not change the LICENSE of released source. Source use, modification and redistribution rights are separate from official products, updates and services.
- Security fixes and reading, backing up or exporting your own data must not require another purchase. BYOK keys, payment-provider secrets and issuer private keys have different owners. Native hosts do not collect payment or issue credentials directly.

## Decision

**Free launcher with a purchase for new workflow Pro features**

Launch target: **¥128 / US$19; optional 12-month update renewal: ¥48 / US$7**. CNY and USD are independently set regional targets, not a live exchange-rate conversion.

Free launchers are well established. Paid features must demonstrate useful automation, rather than charging a monthly fee for an AI label. Team SSO and a private store are not initial priorities.

## Free and paid scope

Free / evaluation: Existing launching, search, calculation, clipboard history, snippets, window management, FPP plugins, BYOK AI and BYO-folder sync remain free. Do not relabel them as Pro.

Paid: Only new multi-step workflow authoring/debugging, conditions and failure branches, reusable batch transformations and officially maintained complex workflow packs are paid candidates. One named user covers the three desktop platforms actually delivered. Running ordinary plugins or writing your own scripts remains free.

## Purchase, trial and updates

A purchase includes 12 months of new-version eligibility. Versions obtained within that update window remain usable afterwards. Optional renewal adds 12 months from `max(payment time, current updates_through)`, with no back-billing for a gap and no automatic charge. Team renewals apply to the purchased number of named seats. There is no lifetime-all-future-updates plan. One named user can use their own computers; no hardware fingerprint is collected. Offline seat limits are contractual, not real-time concurrency enforcement. A team purchase combines seats; it does not imply a collaboration cloud.

A new paid tier has a full 14-day trial, then returns to the free tier. For a complete paid product, trial expiry preserves reading/search/backup/export. Offline trial state is a convenience and an agreement, not advertised as rollback-proof or impossible to reset. Do not presell codes before technical and platform gates pass. After a successful payment, Commerce issues Permit credentials idempotently. Use release time and `updates_through` for update eligibility; the current date must not suddenly invalidate an acquired version. Do not promise prompt offline refund/revocation enforcement that cannot be implemented.

The target price includes no custom development, hardware procurement, certification or response-time SLA. Support is asynchronous issue handling for the purchased version, supported platforms and validated combinations; a solo maintainer must not promise round-the-clock responses. Before sales, publish refund/cancellation rules, currency/tax totals, privacy terms and support scope, and confirm them at checkout. This plan is not a substitute for final checkout terms.

## Next gate before sales

Complete the real interaction and installation/update gates in #88, then deliver one workflow verified from input through an external action and failure recovery. A paid editor must not break free FPP plugins. Pro is not implemented; a 1.0 version number does not replace delivery evidence.

Execution entry: [issue #88](https://github.com/turinglambdaai/fulcrum/issues/88). Complete this bounded slice before expanding commercial features.

Portfolio role and shared boundaries: [PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md).

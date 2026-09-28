# Fulcrum (支点) — Business Model Plan

**Publisher:** TuringLambda AI (`turinglambdaai`) · **Status:** draft 0.1, 2026-09-28 · **Language:** English (canonical) · 中文版: [business.zh-CN.md](business.zh-CN.md)

Fulcrum is a keyboard-first launcher (Raycast-style command palette) for macOS, Windows, and Linux, built on [Rivet](https://github.com/turinglambdaai/rivet): one shared Racket backend embedded per app, first-party native UI per platform (SwiftUI / WinUI 3 / GTK4). No Electron, no WebView.

Everything marked **(S)** is sourced (see [Sources](#13-sources)); everything marked **(E)** is estimated for planning and is not a measurement. Where data is unavailable, we say so.

---

## 1. Executive summary

| Question | Answer |
|---|---|
| What | Cross-platform, native-UI, local-first command launcher with a language-agnostic plugin protocol (FPP1) |
| Wedge | No launcher today offers Raycast-grade polish on **all three** desktops with **native** UI. Raycast is macOS-stable and Windows-**beta** as of Sep 2026 (S); nobody credible ships Linux |
| Who pays | Pro $8/user/mo (or $72/yr) for AI + sync + extras; Teams $12/user/mo for shared snippets and admin licensing. Everything local stays free, unlimited |
| Model | Open-core: core repo source-available BUSL-1.1 (→ MIT after 4 years), plugin SDK + FPP1 spec MIT |
| AI | Phase 1 BYOK only — zero inference cost to us. Phase 2 bundled inference behind a per-user cost guardrail |
| 3-year model | Base case ≈ $0.7M revenue in year 3 at ~8k paid users; conservative ≈ $0.2M; optimistic ≈ $2.6M — all modeled, not measured (E) |
| Biggest risk | Raycast ships a stable Windows 1.0 and its extension ecosystem lands there. Its 2.0 public beta (May 2026) already runs on Windows (S) |
| Decision requested | Approve: pricing tiers, BUSL licensing, Paddle as initial MoR, lifetime tier cap, and the 18-month roadmap in §12 |

The plan is deliberately conservative on numbers and deliberately explicit about the ways this fails. If you read nothing else: §4 (competition), §5 (pricing), §11 (risks).

### What this document is not

Not a pitch deck, and not a forecast we will defend with money. It is the working plan the product is built against: pricing, licensing, sequencing, and the risk register. Any number here can be challenged with better data; the (S)/(E) labels tell you which kind it is.

---

## 2. Market & problem

### Why launchers matter

A launcher is the highest-frequency utility on a desktop: it sits on the app-switch, search, clipboard, snippet, and quick-action paths, dozens of times a day. That frequency is why users tolerate subscriptions for it, and why the category supports paid products (Raycast Pro, Alfred Powerpack, uTools membership — all evidence below).

### Demand validation

We do not need to prove that people pay for launchers; Raycast has proven it on macOS (S):

- ~$48M raised across 3 rounds, including a $30M Series B (Sep 2024) explicitly aimed at cross-platform expansion and AI (S).
- 2,500+ open-source extensions in its store, growing by dozens per week (32 added in one July 2026 week) (S).
- Pro tiers at $8–10/mo and up to $50/mo for Max — a demonstrated willingness to pay $96–600/yr for this surface (S).

**TAM framing (explicitly bottom-up, no authoritative figure exists):** we found no credible public TAM number for the desktop launcher category, and we are not going to invent one. The honest framing is a wedge, not a TAM:

1. **Anchor band:** paid launcher users today pay roughly $46–600/yr (Alfred one-time £34–79 ≈ 3–4 years of Pro; uTools ≈ ¥228–328/yr equivalents; Raycast Pro $96/yr) (S). Fulcrum Pro at $72/yr sits inside the proven band.
2. **Expansion:** the launcher is the trust surface for everything we might add later (snippets sync, AI commands, team libraries). The category is small; the retention surface is not.
3. **The gap:** the wedge exists because each platform's default (Spotlight, Start menu/Command Palette, GNOME Do-era leftovers) is either closed or mediocre at plugins, and no cross-platform product is good on all three.

### Who the customer is

Three overlapping personas, in priority order:

1. **Developers and engineers** — the beachhead. They already use launchers daily, tolerate CLI-adjacent tools, and write plugins. Raycast's extension ecosystem is developer-built for developer workflows (S); we start where they are.
2. **Cross-platform power users** — people who live on two or three OSes (consultants, sysadmins, Linux-at-home/Mac-at-work). Today they run different launchers per machine or settle for worse ones. This is the persona no competitor serves at all, and it is the wedge stated as a person.
3. **Chinese technical users** — the V2EX/sspai/linux.do audiences raised on uTools, price-sensitive, and sensitive to the Electron/local-first trade-off.

Product decision rule that follows: every v0.x feature must serve persona 1 or 2; persona 3 monetization waits for phase 2 (§5).

### The three-platform gap

| Platform | Best current option | Gap |
|---|---|---|
| macOS | Raycast (stable, S) | Closed source, Mac-only, subscription with bundled AI |
| Windows | PowerToys Command Palette / Flow Launcher (S) | Free and decent, but no cross-platform parity, no premium AI/sync layer, MS priorities ≠ power users' priorities |
| Linux | Ulauncher / rofi-adjacent tools | Little visible 2026 activity around Ulauncher (S); no Raycast-grade product at all |

Cross-platform is the wedge: one purchase, one snippet library, one muscle memory, three operating systems. That is the product's reason to exist, and it is also the pitch that survives every competitor comparison.

---

## 3. Product & wedge

What Fulcrum is, concretely:

- **Keyboard-first command palette** — app fuzzy search, clipboard history, snippets, calculator, web-search bangs, system commands in v0.1.0.
- **First-party native UI per platform** — SwiftUI on macOS, WinUI 3 on Windows, GTK4 on Linux. The Windows app is a Windows app; the macOS app is a macOS app. Not a WebView, not a widget kit pretending.
- **One shared Racket backend** — the same embedded Racket CS backend logic per platform, bridged by Rivet's protocol with generated typed native clients. Business logic is written once.
- **Privacy / local-first** — search index, clipboard history, and snippets stay on-device. Cloud sync and AI are opt-in services on top, never requirements.
- **Language-agnostic plugins** — FPP1: JSON over stdio, one external process per plugin. A plugin can be Python, Rust, Go, Node, or a shell script. No JavaScript monoculture required.

Why this beats the alternatives on the only axis users feel: native UI is faster and behaves like the OS; local-first is a privacy posture users can verify (no account required for the core); and FPP1 lowers the barrier for plugin authors relative to a proprietary JS API.

### Why this could fail (honest paragraph)

Distribution beats polish in habit products, and we are starting with none. Raycast has $48M, 2,500+ extensions, a Windows beta already in users' hands, and a brand that owns this exact search query (S). Our Linux strength addresses the smallest of the three markets, and Microsoft could make Command Palette good enough for most Windows users at any time. Our paid features (sync, AI) are undifferentiated — people already buy them from Raycast. Racket is a delivery and hiring risk: excellent for the backend we wrote, terrible for recruiting. And the wedge itself can invert: if Raycast ships stable Windows before our 1.0, our headline becomes "the Linux one", which is a smaller business. We think the odds still favor trying, because a cross-platform native launcher with a free local core has no incumbent — but this paragraph is the honest version of that sentence.

### Honest gaps

- **No Linux host in Rivet today.** Rivet 0.2 targets WinUI 3 and SwiftUI only; Fulcrum Linux requires a GTK4 host in Rivet that does not exist yet. It is scheduled (§12), not shipped, and 0.1 is macOS + Windows.
- **v0.1.0 has no AI, no sync, no store.** The MVP is deliberately boring: search, clipboard, snippets, calculator, bangs, system commands, FPP1.
- **No users, no revenue, no measured conversion data.** Every number in §9 is a modeled assumption, labeled (E).
- **We have not yet done trademark or domain clearance** (§11).

---

## 4. Competitive landscape

| | Fulcrum | Raycast | Alfred | PowerToys Cmd Palette | Flow Launcher | Ulauncher | uTools | Listary |
|---|---|---|---|---|---|---|---|---|
| Platforms | macOS, Windows, Linux | macOS (GA), Windows (beta, S) | macOS only | Windows | Windows | Linux | Win/mac/Linux | Windows |
| Price | Free / Pro $8/mo or $72/yr / Teams $12/user/mo | Free; Pro $8–10/mo; +Advanced AI $16–20/mo; Max $50/mo; Teams $12–25/user/mo (S) | Free; Powerpack one-time ~£34–39, Mega ~£59–79 w/ lifetime upgrades (S, sources vary) | Free, OSS | Free, OSS | Free, OSS | Free core; membership ~¥19/mo, ¥328 lifetime promo (S, community-reported) | Free; Pro one-time (price not re-verified) |
| Plugin model | FPP1: JSON/stdio, any language | 2,500+ open-source extensions, JS/TS API (S) | Workflows (paid tier), community gallery | OSS plugins, C# modules | OSS plugin store | Python extensions | Marketplace, 2,000+ plugins, some paid/membership-gated (S) | Minimal third-party extensibility |
| Native UI | SwiftUI / WinUI 3 / GTK4 | Native on macOS; Windows stack not publicly detailed (S) | Native (Cocoa) | WinUI (PowerToys) | .NET/WPF | GTK | Electron-based | Native |
| AI | Phase 1 BYOK; phase 2 bundled | Raycast AI bundled; Advanced AI add-on; AI no longer free during Windows beta (S) | None native | None | None | None | Plugin-dependent | None |
| Status, Sep 2026 | v0.1.0 MVP, pre-launch | 2.0 public beta (May 2026) spans macOS+Windows; no Windows stable 1.0 (S) | Mature, stable | MS integrating deeper into Win 11 Run dialog (S) | Very active (v2.1.4, Sep 20 2026, S) | Quiet; long-running v6 rewrite unreleased (S) | Dominant in CN; paywall-expansion backlash documented (S) | Active v6.3.x line (S) |

### What we do not compete on

Honesty about scope; these are deliberate non-goals:

- **Raycast's extension depth.** 2,500+ extensions is a five-year moat of accumulated community work (S). We will not match it in year one; FPP1 + AI-assisted porting is the mitigation, not a claim of parity.
- **OS-native integration on macOS.** Spotlight and Raycast will always be more macOS-native than we are. We compete on cross-platform identity, not on Mac depth.
- **File-search supremacy on Windows.** Everything/Listary own NTFS instant search; we index apps and content, not the whole disk.
- **Frontier AI quality.** Raycast Advanced AI bundles top models; our phase-2 bundled inference will be small-model-first with BYOK for everything else. We are not selling the best chatbot.
- **Enterprise MDM/device management.** Teams tier is licensing + shared snippets, not an MDM platform.
- **A one-time price on a service product.** Alfred's one-time Powerpack is a great deal for a Mac-only utility with no server costs; sync and AI have recurring costs we cannot honestly sell as perpetual.

### New entrants and adjacent moves

- **Sol** and other open-source Mac launchers keep appearing (S); none is cross-platform with native UI, which is the bar that matters for our wedge.
- **Raycast Glaze** (AI tooling for building native desktop apps, S) is a signal Raycast is doubling down on native desktop. Watch it: it could become competitor or channel, and either way it validates the native-UI thesis.
- **OS-native defaults keep improving** (Spotlight, Command Palette). They converge on "good enough" for the median user about as fast as we add depth for power users. This is the structural reason the free tier must be the complete local product, not a demo.

---

## 5. Business model — open-core

### Licensing (recommendation)

| Component | License | Rationale |
|---|---|---|
| Core repo (`fulcrum`) | **BUSL-1.1**, converting to MIT 4 years after each change | Users can read, audit, patch, and self-build — which a privacy product must allow — while a competitor cannot put our core into a competing product during the exclusivity window |
| Plugin SDK + FPP1 spec | **MIT** | The ecosystem layer must be frictionless; protocol adoption is worth more than control |

Alternatives considered: **pure MIT** — maximum adoption and goodwill, zero protection while we are small; **AGPL-3.0** — awkward for desktop software and scares plugin authors; **closed proprietary** — kills the local-first trust story that is the product. BUSL with a 4-year MIT conversion is the standard open-source-adjacent compromise; we state the conversion date prominently so nobody feels trapped.

### Tiers and exact feature splits

| | Free $0 | Pro $8/user/mo, or $72/user/yr (E) | Teams $12/user/mo |
|---|---|---|---|
| Local features | **Everything local, unlimited, forever**: app search, clipboard history, snippets, calculator, bangs, system commands, FPP1 plugins | same | same |
| Clipboard history | local, unlimited | local, unlimited | local, unlimited |
| AI commands | BYOK only (phase 1) — no cost to us | Bundled inference (phase 2) with fair-use guardrail + BYOK option | Bundled + BYOK |
| Cloud sync | — | Settings + snippets sync | Team-shared snippet libraries |
| Themes | a few built-ins | full theme set + custom | full theme set |
| Early features | — | beta channel of new features first | beta channel |
| Admin | — | — | seat management, centralized billing/licensing, SSO later |
| Support | community | email, best effort | priority support |

The free tier is the entire local product. The paywall sits only on services that cost us money (sync, bundled AI) and conveniences (themes, early access). This line is published on the pricing page to preempt the "变相收费" backlash pattern documented for uTools (S).

### Pricing rationale

- **Why $8/$12:** Pro lands at or below Raycast Pro's $8–10/mo band (S) on annual billing while staying a real paid product; Teams uses the standard ~1.5× seat multiplier without enterprise features we would then owe support for.
- **Why not cheaper:** a $3–4 tier would double the support surface for a rounding error of revenue; sync and bundled AI have real unit costs (§6, §9).
- **Trial and refunds:** 14-day Pro trial, no card required; 30-day refund, no questions; fraud bounded by license revocation.
- **Deliberately deferred:** purchasing-power-parity regional pricing (China — see the phase-2 note above), education discounts, and fallback perpetual licenses — all revisited at 1.1 with real data instead of opinions.

### One-time Lifetime tier — analysis and recommendation

A $150 early-bird lifetime license, capped at the first 1,000 purchases, sold only during the 1.0 window:

- **Math (E):** Pro annual is $72 with ~75% assumed year-over-year paid retention → expected 3-year Pro revenue ≈ $167. $150 lifetime is roughly break-even against 3-year Pro revenue, front-loads cash at launch, and rewards earliest adopters.
- **Cost safety:** lifetime **excludes bundled AI inference** (BYOK works forever). Sync storage for an individual is trivial (~$0.1–0.5/user/yr, E). Marginal cost of a lifetime holder is therefore near zero.
- **Alternatives:** (a) no lifetime tier — cleaner recurring revenue, weaker 1.0 spike, loses the Alfred/uTools-buyer psychology; (b) lifetime including AI — unbounded inference liability, rejected.
- **Recommendation:** offer it, capped, 1.0 window only, AI excluded, clearly labeled "supporter license". Revisit after the cap sells out.

### Payment rails

| | Stripe | Paddle (merchant of record) |
|---|---|---|
| Fee | ~2.9% + $0.30 (E) | ~5% + $0.50 (E) |
| Global VAT/GST/sales tax | we must handle (Stripe Tax etc.) | MoR handles |
| Checkout/UX | build our own | provided |
| Fit | later, at volume | **launch**, small team |

**Recommendation:** Paddle at launch — as a small team we should buy tax compliance, not build it. Revisit Stripe when monthly revenue justifies the tooling overhead. Fees are modeled at 5% of revenue in §9 (E).

**China, phase 2.** Domestic rails require WeChat Pay / Alipay via a domestic acquirer or aggregator (Stripe does not cover domestic CN acceptance). Any China-facing site needs an ICP filing (备案), and app distribution in China now also involves app filing under MIIT rules; plan for weeks of lead time before, not during, a CN launch. Note the price anchor problem: uTools' ¥328 lifetime promo (S) is ~$46 — CN pricing will need regional adjustment, decided at phase 2, not before.

---

## 6. AI strategy

**Phase 1 (0.3) — BYOK only.** User supplies an OpenAI/Anthropic/local-Ollama key; requests go from the app to the provider; our cost is zero and our privacy posture stays clean. AI features ship gated on the user's own key, so AI is never a reason to delay a release.

**Phase 2 (1.0+) — bundled inference** for Pro, with guardrails: small/default model first, prompt caching, a per-user monthly cost budget (~$1/user/mo, E), visible quota meter, downgrade to BYOK when exceeded. Never bundle frontier models at flat price (Raycast's Advanced AI add-on pricing at $16–20/mo, S, tells us what that must cost).

Concretely, what AI ships at each phase:

| Feature | Phase | Shape |
|---|---|---|
| Natural-language system command ("mute for an hour") | 0.3 | local intent match first, model fallback |
| Clipboard transformation (summarize, clean, translate) | 0.3 | user's model via BYOK |
| Snippet generation from examples | 0.3 | BYOK |
| Quick AI ask with selected-context injection | 1.0 | bundled small model, guardrailed |
| Plugin scaffolding (`fulcrum new plugin` + describe) | 1.1 | BYOK or bundled; feeds §7 supply |

**Per-active-user cost estimate (E — all four inputs are assumptions):**

| Assumption | Value | Basis |
|---|---|---|
| Tokens per AI command | ~600 in + ~300 out | launcher prompts are short; system prompt cached (E) |
| Median usage | 20 commands/mo | habit-tier estimate (E) |
| Heavy usage | 200 commands/mo | p95 estimate (E) |
| Small-model API price | ~$0.15/M in, ~$0.60/M out | small fast models, order-of-magnitude (E) |
| Mid-tier API price | ~$3/M in, ~$15/M out | mainstream hosted model (E) |

| Scenario | Cost/user/mo |
|---|---|
| Small model, median (20 cmds) | ≈ $0.005 |
| Small model, heavy (200 cmds) | ≈ $0.05 |
| Mid model, median | ≈ $0.13 |
| Mid model, heavy | ≈ $1.26 |

Conclusion: bundled AI is affordable only with a small model default and a hard fair-use cap; the mid-model heavy case (~$1.26/mo) is exactly the guardrail boundary. Phase-2 AI spend is modeled in §9 at ~$0.30–0.40/paid-user/mo blended (E).

---

## 7. Plugin & marketplace strategy

Sequencing, with explicit gates — the store is a later revenue line, not a launch feature:

1. **FPP1 is free and open (MIT), always.** No exclusive APIs, no paywalled protocol features. The protocol spec ships in v0.1.0.
2. **Manual gallery at launch (0.2):** a static, reviewed directory of first-party + community plugins; install via the UI; no payments. First-party plugins cover the top use cases (GitHub issues, Jira search, Docker control, package managers) so the directory is never empty.
3. **Curated store with 70/30 revenue share — later.** Paid plugins only after: (a) ≥300 gallery entries, (b) ≥10k WAU, (c) billing rails proven on our own Pro sales, (d) automated plugin review (permissions manifest, sandbox defaults, malware scan) exists. 70/30 favors developers vs the usual 85/15 flips the incentive toward supply.

Gating criteria are the product's honesty mechanism: a paid store before there is an audience is a ghost town that poisons the ecosystem story.

First-party plugins planned for the 0.2 gallery — each one is also a protocol reference implementation, which is how FPP1 documentation gets written:

| Plugin | Why it is first |
|---|---|
| GitHub (issues/PR search) | developer beachhead |
| Docker control | top-requested launcher capability |
| Package managers (winget / Homebrew / cargo) | cross-platform by construction |
| Password managers (read-only, local vault APIs) | trust surface; no vault contents in our cloud |
| Unit / regex / time-zone converters | near-zero cost, proves FPP1 ergonomics |

Permissions model for the store: plugins declare capabilities (network hosts, shell exec, clipboard read, keychain access) in a manifest; the UI shows them at install; capabilities gate behind user consent. Declared-not-proven is acceptable at gallery stage; enforced sandboxing is a store gate (§7, item 3d).

---

## 8. Go-to-market

Launch sequence:

1. **GitHub public** — core repo source-available (BUSL), SDK MIT, docs in English + Chinese, monthly changelog posts in the Rivet voice: what shipped, what broke, what we did not do.
2. **Show HN** at 0.2, when the plugin gallery + sync beta + two platforms + Linux beta exist. The post leads with the honest gap table and the native-UI argument.
3. **Product Hunt** at 1.0 with the Pro launch.
4. **Community subreddits and forums:** r/linux, r/commandline, r/sysadmin, V2EX, 少数派 (sspai), linux.do — cross-platform native + local-first is unusually well matched to these audiences; post as maintainers, not as marketers.
5. **SEO:** comparison pages targeting the searches the market already makes — "raycast alternative for windows", "raycast for linux", "flow launcher alternative", "utools alternative" — plus honest benchmark posts (cold start, memory, search latency vs the incumbents).
6. **Community program:** plugin author spotlight in each changelog, a bug-bounty once the store exists, and a small set of maintainers-recognized contributors with early feature access.
7. **Changelog-driven marketing** as the default motion: a product this technical earns trust by shipping visibly. Every release is the marketing.

China is phase 2 (§5 rails note): V2EX/sspai presence starts at 0.2, monetization after ICP/app-filing.

Launch-week checklist (Show HN at 0.2):

- [ ] Installers for macOS (notarized DMG) and Windows (signed) — one click, no account
- [ ] The honest-gaps table from §3 rendered on the site, kept current
- [ ] Ten first-party plugins installable from the gallery
- [ ] Benchmark post: cold start, memory, search latency vs. incumbents, methodology published
- [ ] Maintainers answering every thread for 72h; complaints converted into public issues

---

## 9. Financial model

**All numbers below are modeled, not measured — (E) throughout.** People costs are excluded (founder + small team; this model shows direct-cost viability, not salaries).

### Assumptions (state-all-the-assumptions section)

| Assumption | Value | Label |
|---|---|---|
| Visitor → install | 25–35% of site visitors activate a download | (E) |
| Install → active (MAU) | 35% of an install cohort active; 65% of prior MAU retained/yr (≈3%/mo churn) | (E) |
| Free → paid conversion | 1.5–2% (Y1) ramping to 3–5% (Y3); **base 2.5–3%** | (E) |
| Blended ARPU | $60–90/yr (annual-dominant mix, some Teams at $144/user/yr) | (E) |
| Infra | $50–200/mo early (site, sync, gallery, telemetry); ~$500–1,500/mo at 250k+ MAU | (E) |
| AI inference | $0 in Y1 (BYOK); ~$0.30–0.40/paid-user/mo from phase 2 | (E, see §6) |
| Payment fees | 5% of revenue (Paddle MoR) | (E) |
| Apple Developer | $99/yr | (S, published rate) |
| Windows code signing | ~$300–600/yr OV/EV cert + hardware token | (E) |
| Trademark (US + EU, 2 classes) | ~$1–2k one-time | (E) |

### 3-year scenarios

| | Conservative | | | Base | | | Optimistic | | |
|---|---|---|---|---|---|---|---|---|---|
| **Year** | 1 | 2 | 3 | 1 | 2 | 3 | 1 | 2 | 3 |
| Installs (cum-yr) | 60k | 150k | 250k | 120k | 300k | 550k | 200k | 600k | 1.2M |
| Year-end MAU | 21k | 65k | 127k | 42k | 130k | 270k | 70k | 252k | 571k |
| Free→paid conv. | 1.2% | 1.8% | 2.0% | 1.5% | 2.5% | 3.0% | 2.5% | 4.0% | 5.0% |
| Paid users (EOL) | 252 | 1,170 | 2,532 | 630 | 3,250 | 8,115 | 1,750 | 10,080 | 28,550 |
| Blended ARPU/yr | $60 | $70 | $75 | $60 | $80 | $85 | $70 | $85 | $90 |
| **Revenue** | **$15k** | **$82k** | **$190k** | **$38k** | **$260k** | **$690k** | **$123k** | **$857k** | **$2.57M** |
| Infra + AI + fees + certs | $5k | $12k | $22k | $8k | $35k | $95k | $12k | $90k | $310k |
| **Direct-cost margin** | $10k | $70k | $168k | $30k | $225k | $595k | $111k | $767k | $2.26M |

Reading: even the conservative case covers direct costs from year 1 — because direct costs are tiny — and none of these scenarios pay a team. The decision this model actually informs is *not* "will this be huge", it is: the product can sustain itself on ~2.5% conversion at ~$72–80 ARPU before any team cost, which is the threshold at which continuing is rational.

Sensitivity: revenue is roughly linear in each of {installs, conversion, ARPU}; a 1-point drop in base conversion (3.0→2.0) cuts Y3 base revenue by a third. Churn assumptions dominate MAU compounding and are the least-validated numbers here.

### Unit economics per paid user (base, E)

| Line | Annual |
|---|---|
| Revenue (Pro annual) | $72 |
| Sync + infra share | −$1–3 |
| Bundled AI (phase 2, guardrailed) | −$4–5 |
| Payment fees (5% MoR) | −$4 |
| **Contribution margin** | **≈ $60–63 (≈ 85%)** |

At these margins the failure mode is volume, not unit cost — which is why §10 tracks WAU, not CAC.

---

## 10. Metrics

Opt-in instrumentation only, off by default, with a pre-install screen stating exactly what is sent and a public schema. Local-first products do not get to be quiet about telemetry; they get to be *voluntary* about it.

| Metric | Definition | Target |
|---|---|---|
| Activation | first successful search within 5 min of install | ≥ 80% (E) |
| WAU / MAU | weekly actives over monthly actives | ≥ 0.6 — a launcher should be a daily-habit tool (E) |
| No-result rate | searches returning nothing | < 10% and falling per release (E) |
| Plugin installs | plugins per active user | ≥ 1.5 (E) |
| Free → Pro conversion | paid ÷ MAU | 2–4% base case (E) |
| Sync opt-in rate | Pro users enabling sync | ≥ 50% of Pro (E) |
| AI usage (phase 2) | AI commands per active Pro user | tracks cost model in §6 |

North-star: **WAU**. A launcher lives or dies on habit frequency; everything else is diagnostic.

Implementation notes: events batch locally and leave the device only after opt-in; the schema is versioned and published; a CLI flag (`--telemetry=off`) beats a buried checkbox; no file paths, query text, or clipboard content ever leave the device — counts and durations only.

---

## 11. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Raycast ships stable Windows 1.0** — biggest risk. Its 2.0 public beta (May 2026) already spans macOS+Windows, the $30M Series B (2024) was earmarked for cross-platform + AI, and it is shipping Windows betas monthly (S) | High within 18mo | High | Move fast to 1.0; own Linux natively (they have no Linux and no announced plan we found); compete on native WinUI 3, price (Pro $72/yr vs Pro $96/yr + AI add-on), BYOK AI, and a free local core; FPP1 + porting guides to narrow the extension gap |
| Microsoft bundles Command Palette deeper into Windows | Med–High (Run-dialog integration already happening, S) | Medium | Serve power users MS will not: snippets, cross-platform identity, plugins in any language; de-emphasize commodity app-launch |
| Plugin cold-start (empty ecosystem kills the product) | High | High | FPP1 MIT from day one; 10+ first-party plugins at 0.2; AI-assisted porting guides for popular Raycast/Alfred workflows; manual gallery is curated so it is never empty |
| Racket talent/delivery risk | Medium | High | Racket surface stays small (backend only; UI is mainstream Swift/C++/C#); Rivet 0.2 already solves embedding, signing, updater, release engineering; codegen replaces boilerplate; AI-assisted development; worst case, a backend port is bounded by the RVT1/FPP1 contracts |
| "Fulcrum" trademark/domain clearance | Unknown until searched | Medium | Knockout search + counsel before 1.0; file in classes 9/42; check fulcrum.app/getfulcrum.com availability (not yet verified). Alternatives if blocked: **Ballast, Keel, Truss, Gimbal** (支点 stays the CN name only if clearance allows) |
| Pricing backlash ("变相收费" pattern seen with uTools, S) | Medium | Medium | Free tier is the complete local product, forever, stated on the pricing page; paywall only on costed services (sync, bundled AI); BUSL→MIT 4-year conversion published up front |
| Solo/small-team bus factor | Medium | Medium | Docs as deliverables; changelog discipline; the SDK/protocol outliving the company is an explicit design goal |

---

## 12. 18-month roadmap

| Version | Months | Scope |
|---|---|---|
| **0.1 MVP** | M0–M2 | macOS + Windows: app fuzzy search, clipboard history, snippets, calculator, web-search bangs, system commands, FPP1 (JSON/stdio) plugin protocol; BUSL public repo; winget + Homebrew packaging |
| **0.2** | M3–M6 | Plugin **gallery** (manual, curated); **sync beta** (settings + snippets); **Linux GTK4 host beta** (the Rivet Linux work lands here — this is the largest engineering risk in the plan); FPP1 docs + 10 first-party plugins; Show HN |
| **0.3** | M7–M10 | **AI / BYOK**: AI commands with user keys (zero inference cost), snippet editor, theme engine, clipboard rules; CN community presence (V2EX, 少数派); Paddle billing integration behind a flag |
| **1.0** | M11–M14 | **Pro launch**: Pro + Teams tiers live via Paddle; **Lifetime early-bird window opens (capped, AI excluded)**; curated store groundwork (permissions manifest, review pipeline); Product Hunt |
| **1.1+** | M15–M18 | Teams GA (shared snippet libraries, admin licensing); store with **70/30** paid plugins if gates in §7 are met; ARM64 macOS/Windows; China phase-2 prep: ICP + app filing, WeChat/Alipay rails, regional pricing decision |

Sequencing rule: platform completeness before AI, AI before store, store before China. Revenue starts at 1.0; everything before that optimizes for installable credibility.

Exit criteria per milestone — the definition of done:

- **0.1:** both platforms installable via winget/Homebrew; FPP1 hello-world plugin documented in Python and Rust; crash-free sessions ≥ 99% on our machines.
- **0.2:** gallery live with the ten first-party plugins; sync beta survives a wipe-and-restore; Linux GTK4 host boots and runs the full 0.1 feature set.
- **0.3:** BYOK AI works against OpenAI, Anthropic, and a local Ollama endpoint; zero server-side inference by us, verified.
- **1.0:** Pro purchasable end-to-end via Paddle (tax handled, invoice delivered); lifetime cap enforced in licensing logic, not in prose.
- **1.1:** the §7 store gates are either met, or visibly missed and re-planned — the roadmap states which before the quarter starts.

---

## 13. Sources

Sourced facts and figures (accessed Sep 2026):

- [Raycast — pricing page](https://www.raycast.com/pricing) — Pro/Advanced AI/Max/Teams tier prices (verified against third-party summaries, mid-2026).
- [Raycast — Series A announcement](https://www.raycast.com/blog/series-a) and [Raycast — Series B ($30M, Atomico, Sep 2024)](https://www.raycast.com/blog/series-b); funding totals per [StartupIntros coverage](https://startupintros.com) (third-party).
- [AlternativeTo — Raycast 2.0 public beta](https://alternativeto.net) — macOS + Windows support, Liquid Glass UI, AI voice dictation (May 2026).
- [WindowsForum — Raycast vs Command Palette comparison](https://www.windowsforum.com) — Windows beta status; AI no longer free during the Windows beta (Sep 17, 2026).
- [XDA — Raycast for Windows review](https://www.xda-developers.com) — Windows client lags macOS features in beta.
- [bearliu.com — Raycast analysis](https://bearliu.com) — 2,500+ open-source extensions.
- [Raycast changelog](https://www.raycast.com/changelog) — Windows beta release cadence.
- [Alfred app](https://www.alfredapp.com/pricing) (official pricing) and [Brow — Mac launcher comparison, Aug 2026](https://brow-app.com) — Powerpack one-time pricing; third-party figures vary (£34–39 / £59–79), GBP-native.
- [Microsoft Learn — PowerToys Command Palette overview](https://learn.microsoft.com/en-us/windows/powertoys/command-palette/overview) and [PowerToys Run page](https://learn.microsoft.com/en-us/windows/powertoys/run) — Run → Command Palette transition.
- [XDA — Command Palette in Windows 11 Run dialog](https://www.xda-developers.com/microsoft-powertoys-command-palette-windows-11-run).
- [Flow Launcher](https://www.flowlauncher.com/) and [Flow Launcher releases](https://github.com/Flow-Launcher/Flow.Launcher/releases) — v2.1.4, Sep 20, 2026.
- [Ulauncher on GitHub](https://github.com/Ulauncher/Ulauncher) — Linux launcher; no major 2026 release news found.
- [Listary forum — v5→v6 discussion](https://discussion.listary.com/t/updating-from-version-5-to-version-6/7908) — v6.3.x line, mixed community sentiment.
- [uTools](https://u.tools/) (official) and [linux.do community threads](https://linux.do) — membership model, ¥328 lifetime promo (618, June 2025), paywall-expansion backlash. Exact current CN prices are app-gated; treat community figures as indicative.
- [OpenAlternative — Sol](https://openalternative.co) — open-source Raycast/Alfred alternative (Mac); new-entrant signal.
- [Sitepoint — Local LLMs guide 2026](https://www.sitepoint.com) — local-model trend context.

Explicitly **not** found / not asserted anywhere in this document: Raycast user counts, ARR, or valuation; total market size for desktop launchers; Ulauncher 2026 release dates; current official uTools price list; Fulcrum trademark/domain status.

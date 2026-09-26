# Ask: a model on the deployed site

**Date:** 2026-08-16
**Status:** implemented

## The problem

On the deployed site, every Ask answer carried the footer
`· matched by keyword, no model`. The keyword router is good — it scores 100%
on the test corpus — but it only fires on phrasings it recognises, and the
deployed app was never reaching a model even for the ones it doesn't.

`netlify.toml` passed only `SUPABASE_URL` and `SUPABASE_ANON_KEY` to
`flutter build web`. `ASK_LLM_URL` was never defined, so the compile-time
default in `lib/core/config.dart` won: `http://localhost:11434/v1`. That made
`AskConfig.enabled` true, so the deployed app built a real LLM client and
posted every unfamiliar question to `localhost:11434` — an address belonging to
whoever opened the site, over http from an https page, so blocked as mixed
content before it left the browser. `AskService` caught the resulting
`LlmUnavailable`, fell back to the router, and printed "no model".

The local build was never broken; Ollama answers there correctly. Only the
deployed one was, and it was failing in the most quiet way available.

## The shape of the fix

A Flutter web bundle is public — every `--dart-define` is readable in
`main.dart.js` — so the app cannot hold a provider key. It needs a server that
does. The smallest such server that fits this repo is one Netlify Function,
deployed by the same build that ships the app.

```
Ask screen → AskService → OpenAiCompatibleClient
                              │
        local dev  ──────────►│ http://localhost:11434/v1/chat/completions   (Ollama)
        deployed   ──────────►│ /api/chat/completions  →  netlify/functions/ask-llm
                                                            │ + GROQ_API_KEY
                                                            ▼
                                    https://api.groq.com/openai/v1/chat/completions
```

Groq serves the OpenAI `/chat/completions` shape, which is the shape
`OpenAiCompatibleClient` already speaks, so the function is a pass-through
rather than a translation and the Dart client needed no changes at all. Local
versus deployed is one base URL and nothing else.

`llama-3.1-8b-instant` on Groq's free tier is the model. Routing asks for one
tool name off a list — roughly ten tokens out — which is well inside the free
limits and far below what an 8B model finds difficult.

## The function

`netlify/functions/ask-llm.mjs`, plain ESM JavaScript on the Netlify v2
signature, no dependencies and no TypeScript toolchain added to a repo that
has neither.

It is a public URL, so it is written as a guard first and a proxy second:

| Guard | Response |
|---|---|
| Method not POST | 405 |
| `Origin` host ≠ request host | 403 |
| Body over 16 KB | 413 |
| Over 4 messages, bad role, non-string or over-long content | 400 |
| `GROQ_API_KEY` unset | 503 |
| Provider unreachable, erroring, or slower than 10s | 502 |

The forwarded body is rebuilt field by field rather than spread from the
caller's: only `messages` survive, and `model`, `temperature: 0`,
`max_tokens: 40` and `stream: false` are imposed by the server. Rebuilding
matters more than it looks — a spread forwards whatever a future provider
decides to bill for.

So the worst a stranger who finds the endpoint and forges an `Origin` header
can extract is one 8B call capped at forty tokens. The origin check is a lock
on the front door, not a vault: browsers set `Origin` on every POST and page
script cannot suppress it, so it costs an honest caller nothing and stops the
casual case, while the token cap is what actually bounds the bill.

The request body is never logged.

## Failure behaviour

Every guard returns a non-200, which `OpenAiCompatibleClient` already converts
to `LlmUnavailable`, which `AskService` already catches by falling back to
keyword routing. A deploy with no `GROQ_API_KEY`, a Groq outage and a
rate-limit therefore all degrade to exactly the behaviour that prompted this
work — no error bubble, no dead feature. Questions the router is confident
about still never touch the network.

## Wiring

- **`netlify.toml`** — a `[functions]` directory; `ASK_LLM_URL` (default
  `/api`) and an empty `ASK_LLM_MODEL` added to the build command; an
  `/api/*` → `/.netlify/functions/ask-llm` 200-rewrite placed **above** the SPA
  catch-all, because the first matching rule wins and `/*` matches everything.
- **`web/_redirects`** — the same rule in the same order, so the two files
  cannot disagree.
- **`lib/core/config.dart`** — defaults unchanged; the doc comment corrected.
  It previously implied a deployed build leaves the URL empty, which is the
  assumption that produced the bug.
- **`lib/services/ask/llm_client.dart`, `ask_service.dart`** — comments only.
- **`tool/build_web.sh`** — unchanged. A local production build still reads
  `supabase.env`, so setting `ASK_LLM_URL=https://<site>/api` there points a
  local build at the deployed proxy for testing.

`prewarm()` already returns early for any URL that is not local Ollama, so the
proxy path skips it with no change.

### The relative URL

`/api` resolves against whatever host serves the page, which follows deploy
previews and custom domains for free — but only in a browser. An iOS or
Android build must pass an absolute `https://<site>/api`; `IOS_BUILD.md` now
says so, and says why `ASK_LLM_KEY` must never be added there.

## Every question goes to the model

Two changes came out of running this on the deployed site.

**The footer lied.** `AskService` short-circuited whenever the keyword router
was certain, and the footer printed `matched by keyword, no model` for that
case and for "no model is configured" alike. All four suggestion chips on the
Ask screen are keyword-confident, so a working model reported itself missing on
every answer. `routedBy` now has three distinct values — `model`, `rules` (no
model configured), `fallback` (configured but unreachable) — and the footer
says which.

**The short-circuit is gone.** It existed because a local Ollama spends seconds
agreeing with a router that scores 100% on the corpus. A hosted model answers
in a fraction of a second, so the saving no longer justifies routing two
different ways depending on phrasing — and "certain" only ever meant a keyword
someone thought of matched, not that the answer was right. The router is still
computed on every question; it is what answers when there is no model or the
model cannot be reached.

The cost is that local development against Ollama now waits on the model for
every question. `classify`'s `confident` flag is still there, and is where to
reach if that fast path is ever wanted back.

Two tests were passing for the wrong reason and are fixed here: both
`with the model down it still answers` and `an unreachable model falls back to
rules` asked keyword-confident questions, so the model was never called and
the `LlmUnavailable` they injected was never reached. They assert `calls == 1`
now.

## Two answers that were wrong

Found by asking the deployed app real questions.

**"What is my net worth" had no tool.** It routed to `income_vs_expense` for
the year, or to `account_balances` — bank balances only, ignoring investments,
savings and debts. `FinanceMath.dashboard` has computed net worth all along for
the dashboard, so the new `net_worth` tool calls that rather than defining the
figure a second time: two answers to "what am I worth" that disagree would be
worse than not answering.

Its breakdown rows are the exact terms of the total, so they add up. That ruled
out `credit_worth`, which folds in bills that `net_worth` does not subtract, and
required exposing `loans_total` from `FinanceMath.dashboard` — net worth
subtracts loans, but no key reported them, so an itemised answer could not
reconcile. The app's existing definition of net worth is unchanged, bills
excluded and all; only the reporting of it is new.

**"Last month" resolved to this month.** Asked on 16 August, the model answered
`period=august`, so a question about last month returned this month's figures.
Sometimes it emitted `period` twice. Two fixes, because the prompt alone was
not enough — measured against the live model, renaming the prompt's example
month changed nothing, and an explicit rule fixed two of three phrasings:

- The prompt now says to prefer `last_month`/`this_month` over naming a month,
  and to give each argument once.
- `AskService.pinPeriod` overrules the model whenever the question states a
  relative period outright. It also clears any `from`/`to` the model invented,
  since `resolveRange` gives explicit dates precedence and the pin would
  otherwise be decorative. Only unambiguous phrases are pinned: "since july"
  stays with the model, whose from/to span reads it better than the router's
  bare month.

`"compare last month income and expenses"` still returns `period=august` from
the model today. The pin is what makes the answer right anyway.

## Privacy

The app's standing claim is that no transaction, balance or holding is ever
sent anywhere, and that remains true: the model receives a question and a tool
list, chooses a tool name, and every figure is computed on the device from
local rows.

What changes is that the question itself now reaches a third party when the
router is unsure. "How much did I pay Anand last month" names a payee. Against
local Ollama nothing left the machine at all; against the proxy the wording
does. The class comment on `AskService` now says this rather than implying
otherwise.

## Testing

- `node --test 'netlify/functions/*.test.mjs'` — 26 tests, covering each guard
  and the pass-through. The interesting ones assert what a caller *cannot* do:
  raise `max_tokens`, swap the model, add billable fields, or call from another
  origin.
- `node tool/check_ask_proxy.mjs` — drives the real function against the real
  provider with the key from `supabase.env`, and reports routing and latency.
  Five colloquial questions, all correct, 150–400 ms each: five to ten times
  faster than local Ollama.

  It dumps the app's own system prompt out of the Dart code
  (`test/ask_prompt_test.dart`, `DUMP_TO=`) rather than paraphrasing one. That
  is not fastidiousness — the first version of the script paraphrased, dropped
  the prompt's worked examples, and reported two failures on questions the app
  routes correctly. One of its answers was the literal format template,
  `tool; money_owed_to_me`, which is what a small model does when shown rules
  and no examples.

- The same live run is what caught the body cap: a real request is 3,080 bytes
  against a first cut that allowed 4,096, so two or three new tools would have
  started rejecting honest questions with a 413 — and the symptom would have
  been Ask silently reverting to keyword routing, the very bug this work
  removes. The cap is now 16 KB.

- `test/ask_prompt_test.dart` — the prompt is assembled, not written, so these
  check the assembly: today's date is stated, every registered tool is
  mentioned, the examples are present, and computing dates is forbidden.
- `test/ask_service_test.dart` — three added tests: a relative base URL posts
  to `/api/chat/completions`, `prewarm()` never wakes a proxy, and a 503 reads
  as `LlmUnavailable` so the fallback holds.
- Manual: a deploy preview, asking a phrasing the router is not confident
  about, and confirming the footer reads `from <tool>` with no keyword suffix.

## Where the key lives

`GROQ_API_KEY` exists in two places and neither is the repository:

- **Netlify → Site settings → Environment variables**, which is the one the
  live site uses.
- **`supabase.env`** on the developer's machine, matched by the `*.env` rule in
  `.gitignore`, so that `tool/check_ask_proxy.mjs` can be run locally.

It must never be set as `ASK_LLM_KEY`. That variable is a `--dart-define`, and
every define is readable in `main.dart.js` by anyone who opens the site;
`tool/build_web.sh` refuses to build when it is set. The distinction between
the two names is the whole point of the proxy, so `supabase.env.example`
states it next to both.

## Not doing

- **Rate limiting.** The token cap bounds the damage, and a per-IP counter
  needs shared state a stateless function does not have.
- **Requiring a Supabase login.** It would be the strongest guard, but Ask
  works today without an account and that is worth keeping.
- **Streaming.** Forty tokens arrive in one piece.

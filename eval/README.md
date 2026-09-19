# Poker AI decision evaluation harness

Headless, pure-Dart tooling for measuring how well a decision provider plays,
and for isolating what each piece of context (engine facts, size presets,
decision guide, style guide length) does for a given model.

It reuses the app's engine and prompt builders through relative imports, so it
needs only the Dart SDK, not Flutter. Nothing here touches the Flutter UI.

## Layout

| Path | Purpose |
|---|---|
| `src/features.dart` | Engine-computed facts: hand class, draws/outs, Monte Carlo equity, pot odds, position, SPR, legal size presets. |
| `src/reference_policy.dart` | Equity-driven rule policy. Grades every legal action (`best` / `ok` / `mistake` / `blunder`) and flags oversized bets. |
| `src/prompt_variants.dart` | Named prompt treatments: `baseline`, `compact`, `facts`, `facts_compact`, `facts_guided`. |
| `src/llm_provider.dart` | OpenAI-compatible client (LiteLLM, OpenRouter) with strict parse, optional amount clamping and retries, token/latency capture. |
| `src/scenario.dart` | Scenario bank model and stratified generator. |
| `src/arena.dart` | Duplicate match runner: every policy plays the same seeded cards from every seat. |
| `bin/` | CLI entry points (below). |
| `scenarios/` | Frozen banks. `bank_v1.json` has 240 spots across all streets, facing and not. |
| `runs/` | JSONL decision logs, one record per (variant, model, scenario). Reruns skip cached records. |

## Setup

Install a Dart SDK (3.11+) and run from this directory:

```sh
cd eval
dart pub get
```

Model access is read from flags or environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `POKER_EVAL_BASE_URL` (or `LITELLM_BASE_URL`) | `http://localhost:4000/v1` | OpenAI-compatible base URL. Use `https://openrouter.ai/api/v1` for OpenRouter. |
| `POKER_EVAL_API_KEY` (or `LITELLM_API_KEY`, `OPENROUTER_API_KEY`) | empty | Bearer token. Never commit it. |
| `POKER_EVAL_MODEL` | `deepseek/deepseek-v4-flash` | Model id as the endpoint knows it (LiteLLM alias or OpenRouter id). |

## Commands

Generate a bank (deterministic for a seed):

```sh
dart run bin/gen_scenarios.dart --count 240 --seats 6 --seed 42 --out scenarios/bank_v1.json
```

Grade the built-in policies (no model needed):

```sh
dart run bin/decide_eval.dart --provider heuristic
dart run bin/decide_eval.dart --provider reference
```

Grade a model under several prompt variants, 4 requests in flight, with the
app's strict parsing (no clamping, no retries):

```sh
dart run bin/decide_eval.dart --variants baseline,compact,facts,facts_compact,facts_guided \
  --model deepseek-flash --base-url http://localhost:4000/v1 --concurrency 4
```

Same model with output repair, to separate "context" gains from "robustness" gains:

```sh
dart run bin/decide_eval.dart --variants baseline,facts_guided --model deepseek-flash --clamp --retries 1
```

Compare runs later without re-querying:

```sh
dart run bin/summarize.dart --dir runs
dart run bin/summarize.dart --runs runs/deepseek_flash.jsonl --worst   # lists every blunder with the model's thinking
```

Inspect exactly what a variant sends for one spot:

```sh
dart run bin/show_scenario.dart --id s017 --variant facts_guided --system
```

Play a duplicate match (bb/100 with a 95% interval). Policies: `heuristic`,
`reference`, `llm:<variant>`:

```sh
dart run bin/arena.dart --policies reference,heuristic --hands 200 --seed 1
dart run bin/arena.dart --policies llm:facts_guided,reference --hands 100 --clamp --retries 1
```

Smoke test the whole pipeline without a key:

```sh
dart run bin/mock_server.dart --port 4010 &
dart run bin/decide_eval.dart --base-url http://localhost:4010/v1 --api-key none --model mock --limit 30 --clamp
```

Other useful flags: `--limit N`, `--tags flop/facing,turn/facing`, `--fresh`
(discard cached records for the output file), `--no-tools` / `--no-force-tool`
for endpoints without function calling, `--temperature`, `--timeout`,
`--thinking off|on` (sends DeepSeek's `thinking.type`; the official API rejects
a forced tool call while thinking is on, so use `--thinking off` there to keep
the app's forced-tool contract, or `--thinking on --no-force-tool` to measure
the reasoning mode).

## Metrics

Decision eval (per variant and model):

- `usable`, `valid`, `clamped`, `invalid`, `error`: whether the model produced an action the engine can play. In the app an `invalid` or `error` decision silently falls back to the heuristic bot, so this is the first number to fix.
- `best` / `ok` / `mistake` / `blunder`: reference grade of the chosen action. `best` versus `ok` is noisy; `mistake + blunder` is the signal.
- `oversized`: bets or raises far above pot (or 6+ bb opens) that were downgraded.
- `avg ms`, `in tok`, `out tok`: latency and token usage per decision for cost planning.
- The per-street table shows where a variant loses accuracy.

Arena: `bb/100` per policy with a 95% interval, plus how often the model's
output was unusable and the reference had to act for it (`fallback`).

## Reference policy caveats

The grader is an equity-versus-random rule set, not a solver. It compares Monte
Carlo equity with pot odds, uses position-free preflop strength tiers, and
knows nothing about ranges, blockers or history. It reliably catches folding
strong hands, calling with no equity, shoving deep stacks with air and
pot-oblivious sizing. It will call some fine plays `ok` instead of `best`, and
it can be wrong in close spots. Treat it as a blunder detector and as a
baseline opponent, and verify surprising verdicts with `show_scenario`.

## Baseline numbers (bank_v1, 240 spots)

| policy | usable | best | ok | mistake | blunder | oversized |
|---|---:|---:|---:|---:|---:|---:|
| heuristic (the app's fallback bot) | 100% | 46% | 21% | 21% | 12% | 7% |
| reference | 100% | 96% | 4% | 0% | 0% | 0% |

Heads-up duplicate match, 200 hands x 2 rotations: reference beats heuristic
by roughly 500 bb/100 (±320). The heuristic bot sizes bets by stack instead of
pot and calls almost any price, so anything that falls back to it plays badly.

## DeepSeek results (2026-09-19, bank_v1, official API, forced tool call, thinking off)

Runs: `runs/deepseek_flash_strict.jsonl`, `runs/deepseek_flash_clamp.jsonl`.
Every variant parsed at 100% (`usable`), so clamping and retries changed
nothing for this model; the numbers below are the strict runs.

| variant | best | ok | mistake | blunder | mistake+blunder | avg ms | in tok |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline (app prompt as shipped) | 67.9% | 15.8% | 12.1% | 4.2% | 16.3% | 1603 | 2363 |
| compact | 69.6% | 13.8% | 13.3% | 3.3% | 16.6% | 1382 | 1773 |
| facts | 69.2% | 15.8% | 12.9% | 2.1% | 15.0% | 1319 | 2536 |
| facts_compact | 70.8% | 14.2% | 12.9% | 2.1% | 15.0% | 1317 | 1945 |
| facts_guided | 69.6% | 16.3% | 11.7% | 2.5% | 14.2% | 1339 | 2151 |
| facts_guided_v2 | 75.4% | 17.9% | 5.4% | 1.3% | 6.7% | 1399 | 2305 |
| heuristic (app fallback bot) | 46.3% | 20.8% | 21.3% | 11.7% | 33.0% | 0 | 0 |

What the data says:

- Engine facts halve blunders (4.2% to about 2%) and cost nothing in latency.
  Shrinking the style guide saves 25% input tokens with no accuracy change.
- The remaining errors under `facts_guided` were almost all folding to small
  bets with equity above the price, folding when already committed, and
  moving all-in with air at low SPR. `facts_guided_v2` states those three
  rules explicitly and cuts mistake+blunder from 14.2% to 6.7%. Its action
  mix stays sane (facing a bet: 108 folds / 29 calls / 12 raises or shoves,
  versus 125 / 18 / 6 for baseline), so it is not a calling station.
- Caveat: the grader is the equity-versus-pot-odds reference, so part of the
  v2 gain is agreeing with the grader's thresholds. Spot checks of the
  remaining "fold" mistakes include folds a range-aware player would make.

Thinking mode (`runs/deepseek_flash_think_strict.jsonl`, `--thinking on
--no-force-tool`): baseline 10.0% mistake+blunder, facts_guided_v2 4.6% with
zero blunders, but average latency 10-12 s, p90 29 s, max 94 s, and 12-15x
the output tokens. The app times out at 8 s, so thinking mode is not usable
for live play; prompt context gives most of the gain at 1.3 s.

Duplicate matches, 100 hands x 2 rotations, thinking off:

| match | bb/100 | ±95% |
|---|---:|---:|
| llm:facts_guided_v2 vs reference | +85 | 117 |
| llm:baseline vs reference | +65 | 97 |
| llm:facts_guided_v2 vs heuristic | +499 | 398 |

200 hands cannot separate the two prompts; both beat the reference and crush
the heuristic. `runs/openrouter_v4_flash_strict.jsonl` is the same strict
matrix through OpenRouter (`deepseek/deepseek-v4-flash`): same accuracy
profile but 8-13 s per decision, which alone explains frequent fallbacks to
the heuristic bot in the app.

## Adding a variant

Add an entry to `PromptVariant.all` in `src/prompt_variants.dart`. A variant
only changes the prompt text; keep parsing knobs (`--clamp`, `--retries`) as
flags so their effect stays measurable on its own.

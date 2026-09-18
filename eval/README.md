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
for endpoints without function calling, `--temperature`, `--timeout`.

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

## Adding a variant

Add an entry to `PromptVariant.all` in `src/prompt_variants.dart`. A variant
only changes the prompt text; keep parsing knobs (`--clamp`, `--retries`) as
flags so their effect stays measurable on its own.

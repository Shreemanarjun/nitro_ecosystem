# Benchmark baselines

One JSON file per platform (`macos.json`, `android.json`, `ios.json`, …),
each a `BenchReport` snapshot recorded on a known-good build. The regression
gate (`NITRO_BENCH_GATE=all`) fails the integration test when any latency
case's median exceeds its baseline by more than `NITRO_BENCH_TOLERANCE_PCT`
(default 35%).

Absolute timings are machine-specific — only compare/record baselines on the
same dedicated hardware. Shared CI runners should use the default
`NITRO_BENCH_GATE=relative` mode, which enforces cross-bridge ratios instead.

Record or refresh a baseline:

```sh
benchmark/tool/bench.sh -d macos --mode full --update-baseline
```

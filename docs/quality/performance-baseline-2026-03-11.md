# agentGui Performance Baseline

Last updated: 2026-03-11

## Baseline Scope

This baseline currently tracks smoke-level startup and focused regression runtime, not full profiling.

## Observed Focused Test Runtime

- UI smoke pack: `./scripts/run_quality_smoke.sh ui`
	- 5-run wall-clock summary: min 33.619s, median 34.227s, max 39.861s, avg 35.195s
	- 5-run observed `xcodebuild` elapsed summary: min 29.025s, median 29.148s, max 29.967s, avg 29.338s
	- Sample report: `docs/quality/samples/ui-baseline-2026-03-11-162844.md`
- Unit / integration smoke pack: `./scripts/run_quality_smoke.sh unit`
	- 5-run wall-clock summary: min 6.219s, median 6.351s, max 6.807s, avg 6.412s
	- 5-run observed `xcodebuild` elapsed summary: min 1.802s, median 1.812s, max 2.124s, avg 1.874s
	- Sample report: `docs/quality/samples/unit-baseline-2026-03-11-163206.md`

## Current Guardrails

- UI tests use in-memory SwiftData store to avoid startup variance from persisted local state.
- Focused smoke suites are split by user path so regressions can be isolated without running the entire test target.
- Scenario fixtures are deterministic and avoid network dependencies.

## Repeatable Sampling

Use the sampling script instead of manually copying timings from terminal output:

```bash
# Sample UI smoke 5 times and write a markdown report under docs/quality/samples/
./scripts/sample_quality_baseline.sh ui 5

# Sample unit/integration smoke 5 times
./scripts/sample_quality_baseline.sh unit 5
```

The script records wall-clock time for each run, extracts the final `xcodebuild` observed elapsed time when available, and writes a markdown report that includes min / median / max / average.

Generated reports are written to `docs/quality/samples/` by default and can be reviewed or committed when you want to refresh the published baseline.

## Next Recommended Baselines

- Add a tracked cold-launch metric for the UI test app in test mode.
- Add a build-only CI gate for `xcodebuild ... build` to separate compile regressions from runtime regressions.
- Refresh the sampled smoke baselines after meaningful UI test growth or major Xcode/macOS updates.
#!/bin/zsh

set -euo pipefail
zmodload zsh/datetime

cd "$(dirname "$0")/.."

MODE="${1:-ui}"
ITERATIONS="${2:-5}"
TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
OUTPUT_PATH="${3:-docs/quality/samples/${MODE}-baseline-${TIMESTAMP}.md}"

case "$MODE" in
  unit|ui|all)
    ;;
  *)
    echo "Usage: ./scripts/sample_quality_baseline.sh [unit|ui|all] [iterations] [output-path]" >&2
    exit 1
    ;;
esac

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -lt 1 ]]; then
  echo "iterations must be a positive integer" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

typeset -a wall_samples
typeset -a observed_samples
typeset -a report_rows

extract_last_elapsed() {
  local log_file="$1"
  grep ' elapsed -- Testing started completed\.' "$log_file" \
    | sed -E 's/.*IDETestOperationsObserverDebug: ([0-9]+\.[0-9]+|[0-9]+) elapsed -- Testing started completed.*/\1/' \
    | tail -n 1 || true
}

summarize_samples() {
  local values=("$@")
  if [[ ${#values[@]} -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "${values[@]}" | sort -n | awk '
    {
      count++
      nums[count] = $1
      sum += $1
    }
    END {
      if (count == 0) {
        exit 1
      }
      min = nums[1]
      max = nums[count]
      if (count % 2 == 1) {
        median = nums[(count + 1) / 2]
      } else {
        median = (nums[count / 2] + nums[(count / 2) + 1]) / 2
      }
      average = sum / count
      printf "count=%d min=%.3f median=%.3f max=%.3f avg=%.3f\n", count, min, median, max, average
    }
  '
}

echo "==> Sampling quality baseline: mode=$MODE iterations=$ITERATIONS"

for run in $(seq 1 "$ITERATIONS"); do
  log_file="$(mktemp -t quality-baseline)"
  start="$EPOCHREALTIME"
  ./scripts/run_quality_smoke.sh "$MODE" > "$log_file" 2>&1
  end="$EPOCHREALTIME"

  wall_seconds=$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", end - start }')
  observed_seconds="$(extract_last_elapsed "$log_file")"

  wall_samples+=("$wall_seconds")
  if [[ -n "$observed_seconds" ]]; then
    observed_samples+=("$observed_seconds")
  fi

  report_rows+=("| $run | $wall_seconds | ${observed_seconds:-n/a} |")
  echo "run $run/$ITERATIONS: wall=${wall_seconds}s observed=${observed_seconds:-n/a}s"
done

wall_summary="$(summarize_samples "${wall_samples[@]}")"
observed_summary=""
if [[ ${#observed_samples[@]} -gt 0 ]]; then
  observed_summary="$(summarize_samples "${observed_samples[@]}")"
fi

{
  echo "# Quality Baseline Sample"
  echo
  echo "- Timestamp: $TIMESTAMP"
  echo "- Mode: $MODE"
  echo "- Iterations: $ITERATIONS"
  echo "- Command: ./scripts/run_quality_smoke.sh $MODE"
  echo
  echo "## Samples"
  echo
  echo "| Run | Wall Seconds | Observed Test Seconds |"
  echo "| --- | ---: | ---: |"
  printf '%s\n' "${report_rows[@]}"
  echo
  echo "## Summary"
  echo
  echo "### Wall Clock"
  echo
  echo '```text'
  echo "$wall_summary"
  echo '```'
  if [[ -n "$observed_summary" ]]; then
    echo
    echo "### Observed xcodebuild Elapsed"
    echo
    echo '```text'
    echo "$observed_summary"
    echo '```'
  fi
} > "$OUTPUT_PATH"

echo "==> Baseline sample written to $OUTPUT_PATH"
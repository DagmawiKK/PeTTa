#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FACT_COUNT=
MATCH_ROUNDS=
SKIP_FFI=0

while (($#)); do
    case "$1" in
        --skip-ffi)
            SKIP_FFI=1
            shift
            ;;
        --help|-h)
            printf 'Usage: %s [--skip-ffi] [FACT_COUNT] [MATCH_ROUNDS]\n' "$0"
            exit 0
            ;;
        *)
            if [[ -z "${FACT_COUNT:-}" ]]; then
                FACT_COUNT=$1
            elif [[ -z "${MATCH_ROUNDS:-}" ]]; then
                MATCH_ROUNDS=$1
            else
                printf 'Unexpected argument: %s\n' "$1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

FACT_COUNT=${FACT_COUNT:-100000}
MATCH_ROUNDS=${MATCH_ROUNDS:-3}

if [[ "$FACT_COUNT" -le 42 ]]; then
    printf 'FACT_COUNT must be greater than 42 because the workload removes `(friend sam 42)`.\n' >&2
    exit 2
fi

if [[ "$MATCH_ROUNDS" -le 0 ]]; then
    printf 'MATCH_ROUNDS must be positive.\n' >&2
    exit 2
fi

if [[ ! -x "$SCRIPT_DIR/mork_ffi/target/release/examples/workload_suite_direct" ]]; then
    (
        cd "$SCRIPT_DIR/mork_ffi"
        RUSTFLAGS='-C target-cpu=native' cargo build --release --example workload_suite_direct >/dev/null 2>&1
    )
fi

if [[ "$SKIP_FFI" -eq 0 && ! -f "$SCRIPT_DIR/mork_ffi/target/release/libmork_ffi.so" ]]; then
    printf 'Missing %s\n' "$SCRIPT_DIR/mork_ffi/target/release/libmork_ffi.so" >&2
    printf 'Build the MORK FFI first, for example with `sh build.sh` or the mork_ffi build flow.\n' >&2
    exit 2
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

render_suite_case() {
    local space_name=$1
    local needs_mork_warmup=$2
    local output_file=$3

    {
        if [[ "$needs_mork_warmup" == "yes" ]]; then
            printf '!(mm2-exec &mork 1)\n'
        else
            printf '!(bind! &petta (new-space))\n'
        fi

        cat <<EOF
!(bind! t0 (new-state 0))
!(bind! t1 (new-state 0))
!(bind! metric (new-state 0))
!(bind! scan_rows_total (new-state 0))
!(bind! scan_secs_total (new-state 0))
!(bind! total_start (new-state 0))
!(bind! total_end (new-state 0))

(= (range \$K \$N)
   (if (< \$K \$N)
       (superpose (\$K (range (+ \$K 1) \$N)))
       (empty)))

!(change-state! total_start (current-time))
!(change-state! t0 (current-time))
!(let \$temp (let \$x (range 0 $FACT_COUNT)
                 (add-atom $space_name (friend sam \$x)))
      (empty))
!(change-state! t1 (current-time))
!(println! (bench insert_rows $FACT_COUNT))
!(println! (bench insert_seconds (- (get-state t1) (get-state t0))))

!(change-state! t0 (current-time))
!(change-state! metric (length (collapse (match $space_name (friend sam 42) (friend sam 42)))))
!(change-state! t1 (current-time))
!(println! (bench exact_hit_rows (get-state metric)))
!(println! (bench exact_hit_seconds (- (get-state t1) (get-state t0))))

!(change-state! t0 (current-time))
!(change-state! metric (length (collapse (match $space_name (friend sam $FACT_COUNT) (friend sam $FACT_COUNT)))))
!(change-state! t1 (current-time))
!(println! (bench exact_miss_rows (get-state metric)))
!(println! (bench exact_miss_seconds (- (get-state t1) (get-state t0))))
EOF

  # Use match-count for &mork, length(collapse(match)) for &petta
  if [[ "$space_name" == "&mork" ]]; then
    local full_scan_pattern="match-count $space_name (friend \$y \$x)"
    local post_count_pattern="match-count $space_name (friend \$y \$x)"
    local test_pattern="match-count $space_name"
  else
    local full_scan_pattern="length (collapse (match $space_name (friend \$y \$x) (friend \$y \$x)))"
    local post_count_pattern="length (collapse (match $space_name (friend \$y \$x) (friend \$y \$x)))"
    local test_pattern="length (collapse (match $space_name"
  fi

  local round
  for round in $(seq 1 "$MATCH_ROUNDS"); do
    cat <<EOF
!(change-state! t0 (current-time))
!(change-state! metric ($full_scan_pattern))
!(change-state! t1 (current-time))
!(change-state! scan_rows_total (+ (get-state scan_rows_total) (get-state metric)))
!(change-state! scan_secs_total (+ (get-state scan_secs_total) (- (get-state t1) (get-state t0))))
EOF
  done

  local expected_remaining=$((FACT_COUNT - 1))
  cat <<EOF

!(println! (bench full_scan_total_rows (get-state scan_rows_total)))
!(println! (bench full_scan_seconds (get-state scan_secs_total)))

!(change-state! t0 (current-time))
!(remove-atom $space_name (friend sam 42))
!(change-state! t1 (current-time))
!(println! (bench remove_rows 1))
!(println! (bench remove_seconds (- (get-state t1) (get-state t0))))

!(change-state! t0 (current-time))
!(change-state! metric (length (collapse (match $space_name (friend sam 42) (friend sam 42)))))
!(change-state! t1 (current-time))
!(println! (bench post_remove_exact_rows (get-state metric)))
!(println! (bench post_remove_exact_seconds (- (get-state t1) (get-state t0))))

!(change-state! t0 (current-time))
!(change-state! metric ($post_count_pattern))
!(change-state! t1 (current-time))
!(println! (bench post_remove_count_rows (get-state metric)))
!(println! (bench post_remove_count_seconds (- (get-state t1) (get-state t0))))

!(change-state! total_end (current-time))
!(println! (bench total_seconds (- (get-state total_end) (get-state total_start))))
EOF

  # Different validation for &mork vs &petta
  if [[ "$space_name" == "&mork" ]]; then
    cat <<EOF
!(test (length (collapse (match $space_name (friend sam 42) (friend sam 42)))) 0)
!(test (match-count $space_name (friend \$y \$x)) $expected_remaining)
EOF
  else
    cat <<EOF
!(test (length (collapse (match $space_name (friend sam 42) (friend sam 42)))) 0)
!(test (length (collapse (match $space_name (friend \$y \$x) (friend \$y \$x)))) $expected_remaining)
EOF
  fi
    } >"$output_file"
}

petta_suite_file="$tmp_dir/workload_suite_petta.metta"
render_suite_case "&petta" no "$petta_suite_file"

if [[ "$SKIP_FFI" -eq 0 ]]; then
    ffi_suite_file="$tmp_dir/workload_suite_mork.metta"
    render_suite_case "&mork" yes "$ffi_suite_file"
    ffi_log="$tmp_dir/ffi.log"
fi

direct_log="$tmp_dir/direct.log"
petta_log="$tmp_dir/petta.log"

"$SCRIPT_DIR/mork_ffi/target/release/examples/workload_suite_direct" \
    "$FACT_COUNT" "$MATCH_ROUNDS" >"$direct_log" 2>&1

if [[ "$SKIP_FFI" -eq 0 ]]; then
    sh "$SCRIPT_DIR/run.sh" "$ffi_suite_file" --silent >"$ffi_log" 2>&1
fi

sh "$SCRIPT_DIR/run.sh" "$petta_suite_file" --silent >"$petta_log" 2>&1

parse_bench_file() {
    local file=$1
    local map_name=$2
    declare -n metrics_ref="$map_name"
    while read -r key value; do
        metrics_ref["$key"]=$value
    done < <(awk '/^\(bench / { gsub(/[()]/, "", $0); print $2, $3 }' "$file")
}

log_file_for_map() {
    case "$1" in
        direct_metrics) printf '%s\n' "$direct_log" ;;
        ffi_metrics) printf '%s\n' "$ffi_log" ;;
        petta_metrics) printf '%s\n' "$petta_log" ;;
        *) return 1 ;;
    esac
}

label_for_map() {
    case "$1" in
        direct_metrics) printf '%s\n' "Direct Rust" ;;
        ffi_metrics) printf '%s\n' "PeTTa via MORK FFI" ;;
        petta_metrics) printf '%s\n' "Pure PeTTa" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

require_metric() {
    local key=$1
    local map_name=$2
    declare -n metrics_ref="$map_name"
    if [[ -z "${metrics_ref[$key]:-}" ]]; then
        printf 'Missing metric `%s` in %s.\n' "$key" "$(label_for_map "$map_name")" >&2
        printf '--- %s log ---\n' "$map_name" >&2
        cat "$(log_file_for_map "$map_name")" >&2
        exit 1
    fi
}

expect_metric() {
    local key=$1
    local expected=$2
    local map_name=$3
    declare -n metrics_ref="$map_name"
    if [[ "${metrics_ref[$key]:-}" != "$expected" ]]; then
        printf 'Unexpected `%s` for %s: expected %s, got %s.\n' \
            "$key" "$(label_for_map "$map_name")" "$expected" "${metrics_ref[$key]:-<missing>}" >&2
        printf '--- %s log ---\n' "$map_name" >&2
        cat "$(log_file_for_map "$map_name")" >&2
        exit 1
    fi
}

ratio_between_metric() {
    local key=$1
    local numerator_map=$2
    local denominator_map=$3
    declare -n numerator_ref="$numerator_map"
    declare -n denominator_ref="$denominator_map"
    awk -v numerator="${numerator_ref[$key]}" -v denominator="${denominator_ref[$key]}" 'BEGIN {
        if (denominator > 0) {
            printf "%.2fx", numerator / denominator
        }
    }'
}

declare -A direct_metrics=()
declare -A petta_metrics=()
declare -A ffi_metrics=()

parse_bench_file "$direct_log" direct_metrics
parse_bench_file "$petta_log" petta_metrics
if [[ "$SKIP_FFI" -eq 0 ]]; then
    parse_bench_file "$ffi_log" ffi_metrics
fi

metrics=(
    insert_rows
    insert_seconds
    exact_hit_rows
    exact_hit_seconds
    exact_miss_rows
    exact_miss_seconds
    full_scan_total_rows
    full_scan_seconds
    remove_rows
    remove_seconds
    post_remove_exact_rows
    post_remove_exact_seconds
    post_remove_count_rows
    post_remove_count_seconds
)

metric_maps=(direct_metrics petta_metrics)
if [[ "$SKIP_FFI" -eq 0 ]]; then
    metric_maps=(direct_metrics ffi_metrics petta_metrics)
fi

for map_name in "${metric_maps[@]}"; do
    for key in "${metrics[@]}" total_seconds; do
        require_metric "$key" "$map_name"
    done
done

expected_full_scan_rows=$((FACT_COUNT * MATCH_ROUNDS))
expected_remaining=$((FACT_COUNT - 1))
for map_name in "${metric_maps[@]}"; do
    expect_metric insert_rows "$FACT_COUNT" "$map_name"
    expect_metric exact_hit_rows "1" "$map_name"
    expect_metric exact_miss_rows "0" "$map_name"
    expect_metric full_scan_total_rows "$expected_full_scan_rows" "$map_name"
    expect_metric remove_rows "1" "$map_name"
    expect_metric post_remove_exact_rows "0" "$map_name"
    expect_metric post_remove_count_rows "$expected_remaining" "$map_name"
done

printf 'Workload suite: %s facts, %s repeated full scans\n' "$FACT_COUNT" "$MATCH_ROUNDS"
if [[ "$SKIP_FFI" -eq 0 ]]; then
    printf '%-26s %16s %16s %16s %14s %14s\n' \
        "Metric" "Direct Rust" "PeTTa via FFI" "Pure PeTTa" "FFI/Direct" "PeTTa/Direct"
else
    printf '%-26s %16s %16s %14s\n' \
        "Metric" "Direct Rust" "Pure PeTTa" "PeTTa/Direct"
fi

for key in "${metrics[@]}" total_seconds; do
    petta_ratio=""
    ffi_ratio=""
    if [[ "$key" == *_seconds ]]; then
        petta_ratio=$(ratio_between_metric "$key" petta_metrics direct_metrics)
        if [[ "$SKIP_FFI" -eq 0 ]]; then
            ffi_ratio=$(ratio_between_metric "$key" ffi_metrics direct_metrics)
        fi
    fi

    if [[ "$SKIP_FFI" -eq 0 ]]; then
        printf '%-26s %16s %16s %16s %14s %14s\n' \
            "$key" \
            "${direct_metrics[$key]}" \
            "${ffi_metrics[$key]}" \
            "${petta_metrics[$key]}" \
            "$ffi_ratio" \
            "$petta_ratio"
    else
        printf '%-26s %16s %16s %14s\n' \
            "$key" \
            "${direct_metrics[$key]}" \
            "${petta_metrics[$key]}" \
            "$petta_ratio"
    fi
done

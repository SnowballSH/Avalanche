#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATAGEN="$SCRIPT_DIR/datagen.sh"
CONFIG_FILE="$SCRIPT_DIR/datagen_a_lot.json"

threads_override=""
duration_override=""
delay_override=""
dry_run=0

default_threads=4
default_duration=1300
delay=1.2
default_engine_args=""

jobs=()
custom_job_specs=()
pids=()
field_sep=$'\037'
arg_sep=$'\036'
config_json=""

usage() {
    cat <<EOF
Usage: $0 [options]

Launch many datagen workers from a JSON config.

Options:
  -c, --config FILE     Datagen schedule JSON (default: $CONFIG_FILE)
  -t, --threads N       Override the config default threads per worker
  -d, --duration MIN    Override the config default duration in minutes
      --delay SEC       Override the config launch delay
  -j, --job SPEC        Add a custom job and replace the config jobs.
                        May be repeated.
  -n, --dry-run         Print the workers that would be launched.
  -h, --help            Show this help.

JSON shape:
  {
    "defaults": {
      "threads": 4,
      "duration": 1300,
      "delay": 1.2,
      "engine_args": ["format=viri", "plies=8-10", "bookplies=0-2", "randsee=-200", "ttmb=4"]
    },
    "jobs": [
      { "count": 9 },
      { "count": 3, "book": "books/UHO_4060_v4.epd" },
      { "count": 1, "threads": 2, "book": "books/hybrid_book_beta.epd", "engine_args": ["nodes=15000"] }
    ]
  }

Each job inherits missing threads, duration, and engine_args from defaults. A
missing book means datagen starts without an opening book. Job engine_args are
appended after default engine_args.

Job SPEC formats:
  COUNT
  COUNT:BOOK
  COUNT:THREADS:DURATION
  COUNT:THREADS:DURATION:BOOK

Examples:
  $0 --dry-run
  $0 --config scripts/datagen_experiment.json
  $0 --threads 6 --duration 720
  $0 --job 8 --job 2:books/UHO_4060_v4.epd
EOF
}

die() {
    echo "Error: $*" >&2
    exit 2
}

is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_nonnegative_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_nonnegative_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

add_job() {
    local count="$1"
    local threads="${2:-}"
    local duration="${3:-}"
    local book="${4:-}"
    local engine_args="${5:-}"

    is_positive_int "$count" || die "job count must be a positive integer: $count"

    if [[ -n "$threads" ]]; then
        is_positive_int "$threads" || die "job threads must be a positive integer: $threads"
    fi

    if [[ -n "$duration" ]]; then
        is_nonnegative_int "$duration" || die "job duration must be a nonnegative integer: $duration"
    fi

    jobs+=("${count}${field_sep}${threads}${field_sep}${duration}${field_sep}${book}${field_sep}${engine_args}")
}

load_config_defaults() {
    local defaults
    local config_threads
    local config_duration
    local config_delay
    local config_engine_args

    defaults="$(jq -er '
        def engine_args($args):
          if (($args | type) == "array") then
            ($args | map(tostring) | join("\u001e"))
          else
            error("defaults.engine_args must be an array")
          end;
        (.defaults // {}) as $defaults
        | [
            ($defaults.threads // 4),
            ($defaults.duration // 1300),
            ($defaults.delay // 1.2),
            engine_args($defaults.engine_args // [])
          ]
        | map(tostring)
        | join("\u001f")
    ' <<< "$config_json")" || die "failed to read defaults from $CONFIG_FILE"

    IFS="$field_sep" read -r config_threads config_duration config_delay config_engine_args <<< "$defaults"

    default_threads="${threads_override:-$config_threads}"
    default_duration="${duration_override:-$config_duration}"
    delay="${delay_override:-$config_delay}"
    default_engine_args="$config_engine_args"
}

load_config_jobs() {
    local job_lines
    local line
    local count
    local threads
    local duration
    local book
    local engine_args

    job_lines="$(jq -er '
        def engine_args($args):
          if (($args | type) == "array") then
            ($args | map(tostring) | join("\u001e"))
          else
            error("engine_args must be an array")
          end;
        (.defaults // {}) as $defaults
        | ($defaults.engine_args // []) as $default_engine_args
        | (.jobs // error("config must contain a jobs array")) as $jobs
        | if (($jobs | type) != "array") or (($jobs | length) == 0) then
            error("config jobs must be a non-empty array")
          else
            $jobs[]
            | [
                (.count // error("each job must have count")),
                (.threads // ""),
                (.duration // ""),
                (.book // ""),
                engine_args($default_engine_args + (.engine_args // []))
              ]
            | map(tostring)
            | join("\u001f")
          end
    ' <<< "$config_json")" || die "failed to read jobs from $CONFIG_FILE"

    while IFS= read -r line; do
        IFS="$field_sep" read -r count threads duration book engine_args <<< "$line"
        add_job "$count" "$threads" "$duration" "$book" "$engine_args"
    done <<< "$job_lines"
}

load_config() {
    command -v jq >/dev/null 2>&1 || die "jq is required to read $CONFIG_FILE"
    [[ -r "$CONFIG_FILE" ]] || die "config file not readable: $CONFIG_FILE"
    config_json="$(jq -c . "$CONFIG_FILE")" || die "failed to parse $CONFIG_FILE"

    load_config_defaults

    if (( ${#custom_job_specs[@]} == 0 )); then
        load_config_jobs
    fi
}

join_from_index() {
    local start="$1"
    shift
    local parts=("$@")
    local value="${parts[$start]}"
    local i

    for ((i = start + 1; i < ${#parts[@]}; i++)); do
        value+=":${parts[$i]}"
    done

    printf '%s' "$value"
}

parse_job_spec() {
    local spec="$1"
    local parts
    local count
    local threads
    local duration
    local book

    IFS=':' read -r -a parts <<< "$spec"

    case "${#parts[@]}" in
        1)
            count="${parts[0]}"
            threads=""
            duration=""
            book=""
            ;;
        2)
            count="${parts[0]}"
            threads=""
            duration=""
            book="${parts[1]}"
            ;;
        3)
            count="${parts[0]}"
            threads="${parts[1]}"
            duration="${parts[2]}"
            book=""
            ;;
        *)
            count="${parts[0]}"
            threads="${parts[1]}"
            duration="${parts[2]}"
            book="$(join_from_index 3 "${parts[@]}")"
            ;;
    esac

    add_job "$count" "$threads" "$duration" "$book" "$default_engine_args"
}

format_args() {
    local args=("$@")
    local arg

    for arg in "${args[@]}"; do
        printf '%q ' "$arg"
    done
}

stop_children() {
    if (( ${#pids[@]} > 0 )); then
        echo "Stopping ${#pids[@]} datagen workers..."
        kill "${pids[@]}" 2>/dev/null || true
    fi
    exit 130
}

trap stop_children INT TERM

while (( $# > 0 )); do
    case "$1" in
        -c|--config)
            (( $# >= 2 )) || die "$1 requires a value"
            CONFIG_FILE="$2"
            shift 2
            ;;
        -t|--threads)
            (( $# >= 2 )) || die "$1 requires a value"
            threads_override="$2"
            shift 2
            ;;
        -d|--duration)
            (( $# >= 2 )) || die "$1 requires a value"
            duration_override="$2"
            shift 2
            ;;
        --delay|--sleep)
            (( $# >= 2 )) || die "$1 requires a value"
            delay_override="$2"
            shift 2
            ;;
        -j|--job)
            (( $# >= 2 )) || die "$1 requires a value"
            custom_job_specs+=("$2")
            shift 2
            ;;
        -n|--dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

load_config

is_positive_int "$default_threads" || die "default threads must be a positive integer: $default_threads"
is_nonnegative_int "$default_duration" || die "default duration must be a nonnegative integer: $default_duration"
is_nonnegative_number "$delay" || die "delay must be a nonnegative number: $delay"

if (( ${#custom_job_specs[@]} > 0 )); then
    for spec in "${custom_job_specs[@]}"; do
        parse_job_spec "$spec"
    done
fi

total_workers=0
total_threads=0

echo "=== Avalanche Bulk Data Generation ==="
echo "Config:           $CONFIG_FILE"
echo "Default threads:  $default_threads"
echo "Default duration: $([ "$default_duration" = "0" ] && echo "infinite" || echo "${default_duration}m")"
echo "Launch delay:     ${delay}s"
echo "Schedule:"

for job in "${jobs[@]}"; do
    IFS="$field_sep" read -r count threads duration book engine_args <<< "$job"
    resolved_threads="${threads:-$default_threads}"
    resolved_duration="${duration:-$default_duration}"
    display_engine_args="${engine_args//$arg_sep/ }"
    total_workers=$((total_workers + count))
    total_threads=$((total_threads + count * resolved_threads))

    printf '  %2dx  %2s threads  %5s min  %s%s%s\n' \
        "$count" \
        "$resolved_threads" \
        "$resolved_duration" \
        "${book:-(no book)}" \
        "${display_engine_args:+  }" \
        "$display_engine_args"
done

echo "Total workers:    $total_workers"
echo "Total threads:    $total_threads"
echo "======================================="

launched=0

for job in "${jobs[@]}"; do
    IFS="$field_sep" read -r count threads duration book engine_args <<< "$job"
    resolved_threads="${threads:-$default_threads}"
    resolved_duration="${duration:-$default_duration}"

    for ((i = 1; i <= count; i++)); do
        args=("$DATAGEN" "$resolved_threads" "$resolved_duration")
        if [[ -n "$book" ]]; then
            args+=("$book")
        fi
        if [[ -n "$engine_args" ]]; then
            engine_args_array=()
            IFS="$arg_sep" read -r -a engine_args_array <<< "$engine_args"
            args+=("${engine_args_array[@]}")
        fi

        launched=$((launched + 1))
        printf 'Starting %d/%d: ' "$launched" "$total_workers"
        format_args "${args[@]}"
        echo

        if (( dry_run == 0 )); then
            "${args[@]}" &
            pids+=("$!")
        fi

        if (( dry_run == 0 && launched < total_workers )); then
            sleep "$delay"
        fi
    done
done

if (( dry_run == 1 )); then
    exit 0
fi

status=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        status=1
    fi
done

exit "$status"

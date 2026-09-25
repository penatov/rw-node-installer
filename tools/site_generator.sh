#!/usr/bin/env bash
# Native node entry point. Requires only Bash, POSIX awk and coreutils.
set -Eeuo pipefail
export LC_ALL=C
generator_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
seed='' seeded=false output="$generator_dir/index.html" audit=0 quiet=false print_dna=false
while (($#)); do
    case $1 in
        --seed|--output|--audit)
            (($# >= 2)) || { printf 'Missing value: %s\n' "$1" >&2; exit 2; }
            case $1 in --seed) seed=$2; seeded=true ;; --output) output=$2 ;; --audit) audit=$2 ;; esac
            shift 2 ;;
        --quiet) quiet=true; shift ;;
        --print-dna) print_dna=true; shift ;;
        -h|--help) printf 'Usage: site_generator.sh [--seed TEXT] [--output FILE] [--quiet] [--print-dna] [--audit N]\n'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ $audit =~ ^(0|[1-9][0-9]{0,4})$ && $audit != 1 ]] || { printf 'Audit count must be 2..99999.\n' >&2; exit 2; }
if [[ $seeded == false ]]; then seed=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n'); fi
seed_hash=$(printf '%s' "$seed" | sha256sum)
export RW_SITE_SEED_A=$((16#${seed_hash:0:8})) RW_SITE_SEED_B=$((16#${seed_hash:8:8})) RW_SITE_AUDIT=$audit
run_generator() {
    awk -f "$generator_dir/site-generator/runtime.awk" \
        -f "$generator_dir/site-generator/design.awk" \
        -f "$generator_dir/site-generator/check.awk" \
        -f "$generator_dir/site-generator/main.awk"
}
if ((audit)); then
    unset RW_SITE_DNA_FILE
    run_generator
    exit
fi
mkdir -p -- "$(dirname -- "$output")"
site_tmp=$(mktemp "$(dirname -- "$output")/.site-generator.XXXXXX")
dna_tmp=$(mktemp)
trap 'rm -f -- "$site_tmp" "$dna_tmp"' EXIT
export RW_SITE_DNA_FILE=$dna_tmp
run_generator >"$site_tmp"
chmod 0644 "$site_tmp"
mv -f -- "$site_tmp" "$output"
if [[ $quiet != true ]]; then printf 'Generated: %s\n' "$output"; fi
if [[ $print_dna == true ]]; then cat -- "$dna_tmp"; fi

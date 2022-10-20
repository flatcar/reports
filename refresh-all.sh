#!/bin/bash

set -euo pipefail

rerun=x

while [[ ${#} -gt 0 ]]; do
    flag="${1}"; shift
    case "${flag}" in
        --regenerate|-r)
            rerun=
            ;;
        *)
            echo "invalid flag ${flag}" >&2
            exit 1
            ;;
    esac
done

pd='-'
# This assumes that the glob will return paths from "oldest" to
# "newest".
for d in *; do
    if [[ ! "${d}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        continue
    fi
    # If you need custom paths to coreos-overlay, gentoo,
    # portage-stable or compare-flatcar-with-gentoo, pass them through
    # environment variables.
    echo "Refreshing reports for date ${d} (previous date: ${pd})"
    RERUN=${rerun} DATE="${d}" PREV_DATE="${pd}" ./run-reports.sh
    pd="${d}"
done

#!/bin/bash

set -euo pipefail

pd='-'
# This assumes that the glob will return paths from "oldest" to
# "newest".
for d in 2022-*; do
    # If you need custom paths to coreos-overlay, gentoo,
    # portage-stable or compare-flatcar-with-gentoo, pass them through
    # environment variables.
    echo "Refreshing reports for date ${d} (previous date: ${pd})"
    RERUN=x DATE="${d}" PREV_DATE="${pd}" ./run-reports.sh
    pd="${d}"
done

#!/bin/sh
# Prisma in discrepancy mode through the API (the escript has no --mode option yet):
#   bench/discrepancy.sh <ebin-dir>...
root=$(cd "$(dirname "$0")/.." && pwd)
exec erl -noshell -pa "$root/_build/default/lib/prisma/ebin" \
  -eval '{ok, _} = prisma:analyze_dirs(init:get_plain_arguments(), #{mode => discrepancy, oxbow => false}), halt().' \
  -extra "$@"

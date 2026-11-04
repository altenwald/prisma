#!/bin/sh
# The page in web/ is published as it is, so it carries its own copy of the logo and of the demo. They must be the ones of assets/
# (tools/make_demo.sh generates the GIF and copies it). Exits with 1 if one differs or is missing.
cd "$(dirname "$0")/.." || exit 1
status=0
for f in prisma.png prisma.svg prisma_demo.gif; do
  if ! cmp -s "assets/$f" "web/assets/$f"; then
    echo "web/assets/$f is not the same as assets/$f (copy it, or generate the demo again with: tools/make_demo.sh)" >&2
    status=1
  fi
done
exit $status

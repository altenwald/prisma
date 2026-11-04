#!/bin/sh
# Generates the demo GIF from the VHS tape and puts the copy that the page in web/ publishes next to it.
# The tape sources scripts/vhs_env.sh, which is local (scripts/ is in the global .gitignore), so this only runs where that exists.
# (VHS writes only one file per tape, and the page is published as it is, so the copy has to be made here.)
cd "$(dirname "$0")/.." || exit 1
vhs assets/prisma_demo.tape || exit 1
cp assets/prisma_demo.gif web/assets/prisma_demo.gif

#!/bin/sh
# Builds the CurseForge upload: PUG_social_CF_<version>.zip, beside the repo (outside it). From the
# committed tree only (git archive HEAD): nothing uncommitted gets in. The zip holds one folder,
# Pugger/, as WoW's AddOns folder wants it, without tools/. (After Guild Master Forever's.)
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

if [ -n "$(git status --porcelain)" ]; then
	echo "Uncommitted changes: commit them first (the zip is built from HEAD)." >&2
	git status --short >&2
	exit 1
fi
TOC_VERSION=$(sed -n 's/^## Version: *//p' Pugger.toc | tr -d '\r')
CORE_VERSION=$(sed -n 's/^ns\.VERSION = "\(.*\)".*/\1/p' Core.lua)
if [ "$TOC_VERSION" != "$CORE_VERSION" ]; then
	echo "Version mismatch: TOC $TOC_VERSION, Core.lua $CORE_VERSION." >&2
	exit 1
fi
grep -q '^ns.TEST_COPY = nil$' Core.lua || { echo "Core.lua: TEST_COPY is on: not for release." >&2; exit 1; }
grep -q '^ns.TEST_NET = nil$' Comm.lua || { echo "Comm.lua: TEST_NET is on: not for release." >&2; exit 1; }
grep -q '^## Interface: 16001$' Pugger.toc || { echo "Pugger.toc: not Forever's interface (16001)." >&2; exit 1; }
for f in $(git ls-files '*.lua'); do
	luajit -bl "$f" > /dev/null || { echo "Does not compile: $f" >&2; exit 1; }
done
luajit tools/sim.lua > /dev/null || { echo "tools/sim.lua fails: run it to see why." >&2; exit 1; }

OUT="$REPO/../PUG_social_CF_${TOC_VERSION}.zip"
rm -f "$OUT"
git archive --format=zip --prefix=Pugger/ -o "$OUT" HEAD -- . ':(exclude).gitignore' ':(exclude)tools'
echo "Built $OUT (version $TOC_VERSION, commit $(git rev-parse --short HEAD))"
unzip -l "$OUT" | tail -1

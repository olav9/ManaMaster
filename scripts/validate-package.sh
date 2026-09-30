#!/bin/sh
# Checks a packaged zip holds exactly the addon's files, all in a ManaMaster folder: nothing missing
# (e.g. a file left out of the package) and nothing extra (e.g. CLAUDE.md or the scripts).
# Usage: scripts/validate-package.sh path/to/ManaMaster.zip
set -eu

archive=${1:?usage: validate-package.sh <zip>}
actual=$(mktemp)
expected=$(mktemp)
trap 'rm -f "$actual" "$expected"' EXIT INT TERM

# Paths with backslashes (some Windows zip tools) count as slashes; folder entries are dropped.
unzip -Z1 "$archive" | tr '\\' '/' | sed '/\/$/d' | LC_ALL=C sort > "$actual"
printf '%s\n' \
    ManaMaster/CHANGELOG.md \
    ManaMaster/DetailsPlugin.lua \
    ManaMaster/HistoryPanel.lua \
    ManaMaster/LICENSE \
    ManaMaster/ManaMaster.lua \
    ManaMaster/ManaMaster_Camelot.toc \
    ManaMaster/ManaMaster_TBC.toc \
    ManaMaster/ManaMaster_Vanilla.toc \
    ManaMaster/Mana_Forever.lua \
    ManaMaster/Mana_TBC.lua \
    ManaMaster/MeterWindow.lua \
    ManaMaster/MinimapButton.lua | LC_ALL=C sort > "$expected"

if ! cmp -s "$actual" "$expected"; then
    echo "error: $archive has unexpected contents (- expected, + actual):" >&2
    diff "$expected" "$actual" >&2 || true
    exit 1
fi
# The packager must have filled in the version in every TOC. It only knows some TOC suffixes (not
# _Camelot, WoW Forever's), so check it did for all of them.
for toc in $(grep '\.toc$' "$actual"); do
    if unzip -p "$archive" "$toc" | grep -q '@project-version@'; then
        echo "error: $toc in $archive still has @project-version@" >&2
        exit 1
    fi
done
echo "package contents valid: $archive"

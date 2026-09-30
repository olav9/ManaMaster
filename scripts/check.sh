#!/bin/sh
# Checks the addon without the game: Lua syntax (Lua 5.1, as the game uses) and the TOC files.
# Usage: scripts/check.sh [tag]   With a tag (e.g. v0.2.4 or v0.3.0-beta1), also checks it's a valid
# release tag. Run by CI on every push and by the release workflow before packaging.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
tag=${1:-}
failed=0
fail() { echo "error: $*" >&2; failed=1; }

# --- Lua syntax -----------------------------------------------------------------------------------------
luac=$(command -v luac5.1 || command -v luac || true)
if [ -z "$luac" ]; then
    echo "error: luac (Lua 5.1) is required" >&2
    exit 1
fi
for file in *.lua; do
    "$luac" -p "$file" || fail "Lua syntax error in $file"
done

# --- TOC files ------------------------------------------------------------------------------------------
# Each client's TOC and the interface it must report.
check_interface() {
    toc=$1 expected=$2
    actual=$(sed -n 's/^## Interface: *//p' "$toc" | tr -d '\r')
    [ "$actual" = "$expected" ] || fail "$toc: ## Interface is '$actual', expected $expected"
}
check_interface ManaMaster.toc 16001         # WoW Forever
check_interface ManaMaster_TBC.toc 20506     # TBC Anniversary
check_interface ManaMaster_Vanilla.toc 11509 # Classic Era

# All TOCs share their headers (apart from ## Interface) and their file list (apart from the client's
# mana file, Mana_Forever.lua or Mana_TBC.lua).
normalized() {
    tr -d '\r' < "$1" | sed -e '/^## Interface:/d' -e 's/^Mana_\(Forever\|TBC\)\.lua$/Mana_<client>.lua/'
}
base=$(normalized ManaMaster.toc)
for toc in ManaMaster_TBC.toc ManaMaster_Vanilla.toc; do
    [ "$(normalized "$toc")" = "$base" ] || fail "$toc: headers or file list differ from ManaMaster.toc"
done

# The version comes from the release tag (the packager replaces @project-version@).
for toc in ManaMaster*.toc; do
    grep -qx '## Version: @project-version@' "$toc" || fail "$toc: ## Version must be @project-version@"
    # Every listed file exists.
    for file in $(tr -d '\r' < "$toc" | grep -v '^#' | grep -v '^$'); do
        [ -f "$file" ] || fail "$toc lists $file, which doesn't exist"
    done
done

# WoW Forever must never load the combat log file: registering the combat log there triggers the
# "blocked from an action" pop-up.
grep -qx 'Mana_TBC.lua' ManaMaster.toc && fail "ManaMaster.toc (WoW Forever) must not load Mana_TBC.lua"
grep -qx 'Mana_Forever.lua' ManaMaster.toc || fail "ManaMaster.toc (WoW Forever) must load Mana_Forever.lua"

# --- Release tag ----------------------------------------------------------------------------------------
# The packager only treats a version as a prerelease if it contains "alpha" or "beta".
if [ -n "$tag" ]; then
    echo "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)[0-9]*)?$' \
        || fail "release tag '$tag' must look like v1.2.3, v1.2.3-beta1 or v1.2.3-alpha1"
    grep -q "^## $tag\$" CHANGELOG.md || fail "CHANGELOG.md has no '## $tag' section"
fi

if [ "$failed" -ne 0 ]; then exit 1; fi
echo "check passed${tag:+ for $tag}"

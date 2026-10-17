#!/bin/sh
# Installs c1lut for Capture One:
#
#   curl -fsSL https://raw.githubusercontent.com/andriiryzhkov/c1lut/HEAD/install.sh | sh
#
# Downloads the latest release (one small program for Apple Silicon and Intel Macs) and runs
# `c1lut install`, which adds Scripts › Export Styles as LUTs to Capture One. Run the same
# command again to update. Run from a source checkout (./install.sh), it builds from source.
set -eu

REPO="andriiryzhkov/c1lut"
URL="https://github.com/$REPO/releases/latest/download/c1lut-macos.zip"

fail() {
    echo "c1lut: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "c1lut runs on macOS only."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ] || fail "c1lut needs macOS 13 or later."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -f "$0" ] && [ -f "$(dirname "$0")/Package.swift" ]; then
    src=$(cd "$(dirname "$0")" && pwd)
    echo "Building c1lut from source…"
    swift build --package-path "$src" -c release --product c1lut
    bin="$(swift build --package-path "$src" -c release --product c1lut --show-bin-path)/c1lut"
else
    echo "Downloading c1lut…"
    curl -fsSL "$URL" -o "$work/c1lut.zip" || fail "could not download $URL"
    unzip -q "$work/c1lut.zip" -d "$work"
    bin="$work/c1lut"
fi

"$bin" install

# Panasonic's V-Log → V-709 LUT is the starting point for V-Log LUTs. It comes from Panasonic,
# not from c1lut. Without it, c1lut asks for the file the first time it's needed.
if ! "$bin" setup --download-vlog-base --if-missing > /dev/null; then
    echo "c1lut will ask for Panasonic's LUT the first time you export for a V-Log target."
fi

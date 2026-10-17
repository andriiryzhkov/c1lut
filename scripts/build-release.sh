#!/bin/sh
# Builds c1lut for Apple Silicon and Intel, joins them into one binary and zips it:
#   dist/c1lut-macos.zip   (c1lut, LICENSE)
# The release workflow uploads that zip; install.sh downloads it.
set -eu
cd "$(dirname "$0")/.."

rm -rf dist
mkdir -p dist/stage

for arch in arm64 x86_64; do
    set -- -c release --product c1lut --triple "$arch-apple-macosx13.0" --scratch-path ".build/release-$arch"
    swift build "$@"
    cp "$(swift build "$@" --show-bin-path)/c1lut" "dist/stage/c1lut-$arch"
done

lipo -create -output dist/stage/c1lut dist/stage/c1lut-arm64 dist/stage/c1lut-x86_64
# Joining slices drops their signatures; Apple Silicon needs at least an ad-hoc one.
codesign --force --sign - dist/stage/c1lut
cp LICENSE dist/stage/

(cd dist/stage && zip -q ../c1lut-macos.zip c1lut LICENSE)
rm -rf dist/stage
echo "Built dist/c1lut-macos.zip"

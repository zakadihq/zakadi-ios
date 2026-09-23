#!/bin/sh
# Fetches the zakadi-protocol conformance vectors the tests run (spec 05 5.16) and
# unpacks vectors/framing and vectors/chain into vectors/, which git ignores. The
# archive is kept there and checked against its SHA-256 on every run, so a second run
# needs no network.
set -eu

tag=v0.1.0
sha256=de94fc3693659e0016d6eedb7e3b0e7fd688cc6e30247d387fb2eab4175759ba
url="https://github.com/zakadihq/zakadi-protocol/archive/refs/tags/$tag.tar.gz"

dest="$(cd "$(dirname "$0")/.." && pwd)/vectors"
archive="$dest/zakadi-protocol-$tag.tar.gz"
top="zakadi-protocol-${tag#v}"

digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

mkdir -p "$dest"
if [ ! -f "$archive" ] || [ "$(digest "$archive")" != "$sha256" ]; then
    curl --fail --silent --show-error --location --retry 3 --output "$archive.part" "$url"
    if [ "$(digest "$archive.part")" != "$sha256" ]; then
        rm -f "$archive.part"
        echo "fetch-vectors: $url does not match SHA-256 $sha256" >&2
        exit 1
    fi
    mv "$archive.part" "$archive"
fi

rm -rf "$dest/framing" "$dest/chain"
tar -xzf "$archive" -C "$dest" --strip-components 2 "$top/vectors/framing" "$top/vectors/chain"
echo "fetch-vectors: zakadi-protocol $tag framing and chain vectors unpacked into vectors/"

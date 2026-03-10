#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/../assets"

BASE_URL="https://vivid-test-assets.s3.us-east-1.amazonaws.com"

fetch() {
    local name="$1"
    local dest="$ASSETS_DIR/$name"

    if [ -d "$dest" ]; then
        echo "$name/ already exists, skipping"
        return
    fi

    local zip="/tmp/vivid-test-${name}.zip"
    echo "Downloading $name..."
    curl -fSL "$BASE_URL/vivid-test-${name}.zip" -o "$zip"

    echo "Extracting to $ASSETS_DIR/"
    mkdir -p "$ASSETS_DIR"
    unzip -qo "$zip" -d "$ASSETS_DIR"
    rm "$zip"
    echo "$name/ ready"
}

fetch audio
fetch sample_packs

echo "Done. All test assets are in $ASSETS_DIR/"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: build-bottle.sh VERSION COMMIT}"
COMMIT="${2:?Usage: build-bottle.sh VERSION COMMIT}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo 'Expected a numeric x.y.z version and full commit SHA.' >&2
    exit 1
fi
if brew list --versions loki >/dev/null 2>&1; then
    echo 'Loki is already installed. Build bottles on a clean runner.' >&2
    exit 1
fi

ROOT="$PWD"
TAP=lermatroid/loki
FORMULA="$TAP/loki"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
brew tap "$TAP" https://github.com/Lermatroid/Loki.git
TAP_DIR=$(brew --repository "$TAP")
if [[ -n "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
    echo 'The Homebrew tap has local changes; refusing to overwrite them.' >&2
    exit 1
fi

mkdir -p dist/bottles "$TAP_DIR/Formula"
SOURCE_URL="https://github.com/Lermatroid/Loki/archive/$COMMIT.tar.gz"
curl --fail --location --retry 3 "$SOURCE_URL" -o dist/source.tar.gz
SOURCE_SHA256=$(shasum -a 256 dist/source.tar.gz | cut -d ' ' -f 1)
sed -e "s|@SOURCE_URL@|$SOURCE_URL|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SOURCE_SHA256@|$SOURCE_SHA256|g" \
    scripts/homebrew/loki.rb.in > "$TAP_DIR/Formula/loki.rb"

brew install --build-bottle "$FORMULA"
brew test "$FORMULA"
cd dist/bottles
brew bottle --json --no-rebuild \
    --root-url="https://github.com/Lermatroid/Loki/releases/download/v$VERSION" "$FORMULA"
brew bottle --merge --write --no-commit ./*.bottle.json
cp "$TAP_DIR/Formula/loki.rb" "$ROOT/dist/loki.rb"

# Reinstall the bottled files to catch relocation and app-signature problems.
CACHE_PATH=$(brew --cache --bottle "$FORMULA")
mkdir -p "$(dirname "$CACHE_PATH")"
cp ./*.bottle.tar.gz "$CACHE_PATH"
brew uninstall "$FORMULA"
brew install --force-bottle "$FORMULA"
brew test "$FORMULA"

# Homebrew's local bottle filenames differ from their published download names.
python3 - <<'PY'
import json
from pathlib import Path

for metadata in Path('.').glob('*.bottle.json'):
    for formula in json.loads(metadata.read_text()).values():
        for bottle in formula['bottle']['tags'].values():
            Path(bottle['local_filename']).rename(bottle['filename'])
PY
shasum -a 256 ./*.bottle.tar.gz > SHA256SUMS

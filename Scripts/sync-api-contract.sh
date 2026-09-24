#!/bin/bash

# Copies Nineveh's app contract into the package and records where it came
# from. Run it after the server's `docs/app-openapi.json` changes, then run the
# package tests and review `git diff` on the Contract directory.

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
CONTRACT_DIRECTORY="$REPOSITORY_ROOT/Packages/NinevehReaderKit/Contract"
NINEVEH_CHECKOUT="${NINEVEH_CHECKOUT:-$REPOSITORY_ROOT/../nineveh}"
SOURCE_CONTRACT="$NINEVEH_CHECKOUT/docs/app-openapi.json"
VENDORED_CONTRACT="$CONTRACT_DIRECTORY/app-openapi.json"

if [[ ! -f "$SOURCE_CONTRACT" ]]; then
  echo "No contract at $SOURCE_CONTRACT; set NINEVEH_CHECKOUT to a Nineveh checkout." >&2
  exit 1
fi

COMMIT="$(git -C "$NINEVEH_CHECKOUT" rev-parse HEAD)"
# A slice edited since that commit is not the one the commit describes.
if ! git -C "$NINEVEH_CHECKOUT" diff --quiet HEAD -- docs/app-openapi.json; then
  COMMIT="$COMMIT+uncommitted"
fi

mkdir -p "$CONTRACT_DIRECTORY"
cp "$SOURCE_CONTRACT" "$VENDORED_CONTRACT"

VERSION="$(plutil -extract info.version raw -o - "$VENDORED_CONTRACT")"
SHA256="$(shasum -a 256 "$VENDORED_CONTRACT" | cut -d' ' -f1)"

cat >"$CONTRACT_DIRECTORY/SOURCE" <<EOF
source:   nineveh docs/app-openapi.json
commit:   $COMMIT
version:  $VERSION
sha256:   $SHA256
taken:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "Vendored $SOURCE_CONTRACT"
cat "$CONTRACT_DIRECTORY/SOURCE"

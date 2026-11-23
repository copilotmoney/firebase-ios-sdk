#!/bin/bash
# Packages the zip builder's FirebaseFirestoreInternal.xcframework for Package.swift's binary
# target, after checking it carries the watch-stream patch in every slice.
#
# USAGE: package_firestore_binary.sh <zip-builder output dir> <release dir>
# Writes <release dir>/FirebaseFirestoreInternal.zip and <release dir>/notes.md.
set -euo pipefail

zip_out="${1:?usage: package_firestore_binary.sh <zip-builder output dir> <release dir>}"
release="${2:?usage: package_firestore_binary.sh <zip-builder output dir> <release dir>}"
work="$(mktemp -d)"
mkdir -p "$release"

find "$zip_out" -maxdepth 2 -name '*.zip' -exec unzip -q -o -d "$work" {} \;
xcframework="$(find "$work" "$zip_out" -type d -name FirebaseFirestoreInternal.xcframework \
  -not -path '*/FirebaseFirestoreInternal.xcframework/*' | head -n 1)"
if [[ -z "$xcframework" ]]; then
  echo "error: no FirebaseFirestoreInternal.xcframework under $zip_out" >&2
  exit 1
fi

# The string only exists in the patched GrpcStream::NewCompletion.
marker='failed, continuing'
for slice in ios-arm64 ios-arm64_x86_64-simulator ios-arm64_x86_64-maccatalyst; do
  binary="$xcframework/$slice/FirebaseFirestoreInternal.framework/FirebaseFirestoreInternal"
  if [[ ! -f "$binary" ]]; then
    echo "error: missing slice $slice" >&2
    exit 1
  fi
  # Not `grep -q`: under pipefail its early exit fails `strings` with SIGPIPE.
  if ! strings -a "$binary" | grep "$marker" > /dev/null; then
    echo "error: $slice lacks the watch-stream patch" >&2
    exit 1
  fi
done

# Swift Package Manager wants the xcframework at the root of the zip.
(cd "$(dirname "$xcframework")" &&
  ditto -c -k --sequesterRsrc --keepParent FirebaseFirestoreInternal.xcframework \
    "$release/FirebaseFirestoreInternal.zip")
checksum="$(shasum -a 256 "$release/FirebaseFirestoreInternal.zip" | cut -d ' ' -f 1)"

cat > "$release/notes.md" <<EOF
FirebaseFirestoreInternal.xcframework built from \`${GITHUB_SHA:-$(git rev-parse HEAD)}\` with \
$(xcodebuild -version | head -n 1). Slices: iOS device, iOS simulator, Mac Catalyst.

\`\`\`swift
url: "https://github.com/${GITHUB_REPOSITORY:-copilotmoney/firebase-ios-sdk}/releases/download/${GITHUB_REF_NAME:-<tag>}/FirebaseFirestoreInternal.zip",
checksum: "$checksum"
\`\`\`
EOF
cat "$release/notes.md"

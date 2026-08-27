#!/usr/bin/env bash
# Cut a Noi release: bump the version, build + sign the updater artifact,
# write latest.json, and publish everything to a GitHub Release.
#
#   scripts/release.sh 0.2.0 notes.md            # normal
#   scripts/release.sh 0.2.0 notes.md --replace  # re-upload over an existing tag
#
# Needs: bun, gh (logged in, default repo BinhL3/noi), and the Tauri updater
# private key at ~/.tauri/noi.key (never committed; back it up — without it
# no shipped copy can update to the next version).
set -euo pipefail

VERSION="${1:?version, e.g. 0.2.0}"
NOTES="${2:?path to release notes markdown}"
REPLACE="${3:-}"
REPO="BinhL3/noi"
TAG="v$VERSION"
KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/noi.key}"

cd "$(dirname "$0")/.."
[ -f "$KEY" ] || { echo "missing updater key at $KEY"; exit 1; }

# 1. Version in the three places Tauri reads it.
sed -i '' "s/\"version\": \"[0-9.]*\"/\"version\": \"$VERSION\"/" src-tauri/tauri.conf.json package.json
sed -i '' "0,/^version = \"[0-9.]*\"/s//version = \"$VERSION\"/" src-tauri/Cargo.toml
if ! git diff --quiet; then
  git commit -qam "chore: version $VERSION"
fi

# 2. Build. createUpdaterArtifacts=true makes Noi.app.tar.gz + .sig next to the .app.
# The bundler wants the key's contents, not a path.
TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" \
  bun run tauri build

BUNDLE=src-tauri/target/release/bundle
DMG="$BUNDLE/dmg/Noi_${VERSION}_aarch64.dmg"
TGZ="$BUNDLE/macos/Noi.app.tar.gz"
SIG="$TGZ.sig"
for f in "$DMG" "$TGZ" "$SIG"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done

# 3. latest.json — what the in-app updater polls. The asset URL must be the
#    versioned file so old releases' JSON never points at a moving target.
UP_ASSET="Noi_${VERSION}_aarch64.app.tar.gz"
cp "$TGZ" "$BUNDLE/$UP_ASSET"
cp "$SIG" "$BUNDLE/$UP_ASSET.sig"
python3 - "$VERSION" "$SIG" "$NOTES" "$BUNDLE/latest.json" "$REPO" "$TAG" "$UP_ASSET" <<'EOF'
import json, sys, datetime
version, sig, notes, out, repo, tag, asset = sys.argv[1:]
json.dump({
    "version": version,
    "notes": open(notes).read().strip(),
    "pub_date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "platforms": {
        "darwin-aarch64": {
            "signature": open(sig).read().strip(),
            "url": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
        }
    },
}, open(out, "w"), indent=2)
EOF

# 4. Tag + publish.
git push -q origin HEAD
if [ "$REPLACE" = "--replace" ]; then
  git tag -fa "$TAG" -m "Noi $VERSION"
  git push -q -f origin "$TAG"
  gh release upload "$TAG" -R "$REPO" --clobber "$DMG" "$BUNDLE/$UP_ASSET" "$BUNDLE/$UP_ASSET.sig" "$BUNDLE/latest.json"
  gh release edit "$TAG" -R "$REPO" --notes-file "$NOTES"
else
  git tag -a "$TAG" -m "Noi $VERSION"
  git push -q origin "$TAG"
  gh release create "$TAG" -R "$REPO" --verify-tag --title "Noi $VERSION" --notes-file "$NOTES" \
    "$DMG" "$BUNDLE/$UP_ASSET" "$BUNDLE/$UP_ASSET.sig" "$BUNDLE/latest.json"
fi
echo "released $TAG: https://github.com/$REPO/releases/tag/$TAG"

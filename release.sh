#!/usr/bin/env bash
# release.sh — Build, sign, notarize, tag, and publish a ZedisUI release.
#
# Usage:
#   ./release.sh <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]
#
# Examples:
#   ./release.sh 0.1.2
#   ./release.sh 0.2.0 --prerelease beta
#   ./release.sh 0.2.0 --prerelease beta --notes-file CHANGELOG-0.2.0.md
#
# See docs/release.md for one-time setup (cert, notary profile, gh).

set -euo pipefail

# ── Project constants ───────────────────────────────────────────────
TEAM_ID="T8F5T6HKG8"
NOTARY_PROFILE="zedis-notary"
SCHEME="ZedisUI"
PROJECT="ZedisUI.xcodeproj"
PRODUCT="ZedisUI"
GH_REPO="xVanTuring/ZedisUI"
BUILD_DIR="build"
APPCAST="appcast.xml"
# Sparkle 2 ships its tools inside the SPM artifact bundle. Path is
# resolved after `xcodebuild -resolvePackageDependencies` runs (which
# happens implicitly via the Debug build below).
SPARKLE_BIN_DIR="DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

# ── Args ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]

  <version>          CFBundleShortVersionString, e.g. 0.1.2
  --prerelease X     Marks as pre-release; tag becomes v<version>-<X>.
  --notes-file PATH  File whose contents become the GitHub release body.
  --dry-run          Bump version + commit locally, but skip push / build / release.
EOF
    exit 1
}

VERSION=""
PRERELEASE=""
NOTES_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prerelease)  PRERELEASE="${2:?--prerelease needs a value}"; shift 2 ;;
        --notes-file)  NOTES_FILE="${2:?--notes-file needs a path}"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown flag: $1" >&2; usage ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
            else echo "Unexpected positional: $1" >&2; usage; fi
            ;;
    esac
done

[[ -z "$VERSION" ]] && usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "ERROR: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }

if [[ -n "$PRERELEASE" ]]; then
    TAG="v${VERSION}-${PRERELEASE}"
    TITLE="v${VERSION} ${PRERELEASE}"
    ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.zip"
    PRERELEASE_FLAG="--prerelease"
else
    TAG="v${VERSION}"
    TITLE="v${VERSION}"
    ASSET="${PRODUCT}-${VERSION}.zip"
    PRERELEASE_FLAG=""
fi

echo "==> Version $VERSION  •  Tag $TAG  •  Asset $ASSET"

# ── Pre-flight ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"

[[ -f project.yml ]] || { echo "ERROR: run from repo root (no project.yml here)" >&2; exit 1; }

command -v xcodegen >/dev/null \
    || { echo "ERROR: xcodegen not on PATH (brew install xcodegen)" >&2; exit 1; }
command -v gh >/dev/null \
    || { echo "ERROR: gh CLI not on PATH" >&2; exit 1; }

gh auth status >/dev/null 2>&1 \
    || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

security find-identity -v -p codesigning \
    | grep -q "Developer ID Application.*${TEAM_ID}" \
    || { echo "ERROR: no 'Developer ID Application' cert for team ${TEAM_ID} in keychain." >&2
         echo "       Get one from Xcode → Settings → Accounts → Manage Certificates." >&2
         exit 1; }

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "ERROR: notarytool profile '${NOTARY_PROFILE}' is missing or invalid." >&2
         echo "       See docs/release.md → 'Set up notarytool profile'." >&2
         exit 1; }

# Sparkle EdDSA private key must already be in the login keychain.
# `generate_keys -p` succeeds only when the key exists; this is a much
# cheaper failure than discovering it post-notarization.
if [[ -x "${SPARKLE_BIN_DIR}/generate_keys" ]]; then
    "${SPARKLE_BIN_DIR}/generate_keys" -p >/dev/null 2>&1 \
        || { echo "ERROR: Sparkle EdDSA signing key not found in keychain." >&2
             echo "       Generate it once with: ${SPARKLE_BIN_DIR}/generate_keys" >&2
             echo "       See docs/release.md → 'Sparkle EdDSA key'." >&2
             exit 1; }
fi

[[ -f "$APPCAST" ]] \
    || { echo "ERROR: $APPCAST missing — Sparkle needs it. Restore from git." >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] \
    || { echo "ERROR: working tree dirty. Commit or stash first." >&2; exit 1; }

if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "ERROR: tag ${TAG} already exists locally." >&2; exit 1
fi
if git ls-remote --tags origin "${TAG}" | grep -q "${TAG}"; then
    echo "ERROR: tag ${TAG} already exists on origin." >&2; exit 1
fi

# Validate notes file early — failing here is much cheaper than after archive.
if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "ERROR: --notes-file not found: $NOTES_FILE" >&2; exit 1; }
fi

# ── Bump version in project.yml ─────────────────────────────────────
current_short=$(grep -E 'CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
current_build=$(grep -E 'CFBundleVersion:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
next_build=$((current_build + 1))

echo "==> Version bump  ${current_short} (build ${current_build}) → ${VERSION} (build ${next_build})"

# BSD sed (macOS) wants a backup-suffix argument with -i; ".bak" is the
# convention, and we rm it right after.
sed -i.bak -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml
sed -i.bak -E "s/(CFBundleVersion: )\"[^\"]+\"/\\1\"${next_build}\"/" project.yml
rm -f project.yml.bak

xcodegen >/dev/null

# Verify the bumped sources actually build before committing. A failure here
# leaves no half-baked commit on the branch — we restore the two tracked files
# and exit cleanly. (.xcodeproj is gitignored, so a re-run of xcodegen rebuilds
# it; we don't have to track it here.)
echo "==> Verifying Debug build before commit"
if ! xcodebuild \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration Debug \
        -derivedDataPath DerivedData \
        build \
        | tail -40; then
    echo "ERROR: Debug build failed. Reverting version bump." >&2
    git checkout -- project.yml Resources/Info.plist
    xcodegen >/dev/null
    exit 1
fi

echo "==> Committing version bump"
git add project.yml Resources/Info.plist
git commit -m "Bump version to ${VERSION} (build ${next_build})"

# Belt-and-suspenders: the commit above should have captured every tracked
# change, but if anything else slipped in (e.g. a hook touched a file) we want
# to know before pushing.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty after version-bump commit. Resolve before push." >&2
    git status --short >&2
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [dry-run] stopping before push/build/release."
    echo "    To undo:  git reset --hard HEAD~1"
    exit 0
fi

# ── Push main ───────────────────────────────────────────────────────
echo "==> Pushing main"
git push origin main

# ── Archive ─────────────────────────────────────────────────────────
echo "==> Cleaning ${BUILD_DIR}/"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Archiving Release (this takes a minute)"
xcodebuild archive \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${BUILD_DIR}/${PRODUCT}.xcarchive" \
    -derivedDataPath DerivedData \
    | tail -40

# ── Export with Developer ID signing ────────────────────────────────
cat > "${BUILD_DIR}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>          <string>developer-id</string>
    <key>teamID</key>          <string>${TEAM_ID}</string>
    <key>signingStyle</key>    <string>automatic</string>
    <key>destination</key>     <string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting Developer ID signed app"
xcodebuild -exportArchive \
    -archivePath "${BUILD_DIR}/${PRODUCT}.xcarchive" \
    -exportPath "${BUILD_DIR}/Export" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    | tail -20

APP="${BUILD_DIR}/Export/${PRODUCT}.app"

echo "==> Verifying signature"
codesign -d --verbose=2 "${APP}" 2>&1 | grep -E "TeamIdentifier|Authority|Format"
codesign -v --strict "${APP}"

# ── Notarize ────────────────────────────────────────────────────────
echo "==> Zipping for notary upload"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${BUILD_DIR}/${ASSET}"

echo "==> Submitting to Apple notary (typically 1–5 min)"
xcrun notarytool submit "${BUILD_DIR}/${ASSET}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "==> Stapling notary ticket onto the app"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

echo "==> Gatekeeper assessment:"
spctl -a -t exec -vv "${APP}"

echo "==> Re-zipping (so the asset carries the stapled ticket)"
rm -f "${BUILD_DIR}/${ASSET}"
# --sequesterRsrc is load-bearing: without it, ditto stuffs AppleDouble
# metadata as `._File` siblings *inside* the bundle. Sparkle's installer
# (which uses ditto -x) merges them back into xattrs fine, but BSD
# `unzip` — which Finder's Archive Utility delegates to for manual zip
# downloads — leaves them as real files in `Contents/`, breaking the
# code-signature seal ("a sealed resource is missing or invalid").
# Result: "Apple could not verify..." Gatekeeper alert for anyone who
# unzips the asset by hand. With --sequesterRsrc the metadata goes into
# a `__MACOSX/` sibling that unzip ignores, and ditto -x still merges
# it. Don't remove this flag.
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${BUILD_DIR}/${ASSET}"

# ── Sparkle: sign the asset + update appcast.xml ────────────────────
# sign_update reads the EdDSA private key from the login keychain. Output
# format: `sparkle:edSignature="..." length="..."` — quote-delimited and
# we parse it with sed.
echo "==> Signing asset with Sparkle EdDSA key"
SIGN_LINE="$("${SPARKLE_BIN_DIR}/sign_update" "${BUILD_DIR}/${ASSET}")"
ED_SIG="$(echo "$SIGN_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
ASSET_LEN="$(echo "$SIGN_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [[ -z "$ED_SIG" || -z "$ASSET_LEN" || "$ED_SIG" == "$SIGN_LINE" ]]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_LINE" >&2
    exit 1
fi
echo "    edSignature ${ED_SIG:0:24}…  length ${ASSET_LEN}"

DOWNLOAD_URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${ASSET}"
RELEASE_NOTES_LINK="https://github.com/${GH_REPO}/releases/tag/${TAG}"

echo "==> Updating ${APPCAST}"
python3 - "$APPCAST" "$TAG" "$VERSION" "$next_build" "$ED_SIG" "$ASSET_LEN" "$DOWNLOAD_URL" "$RELEASE_NOTES_LINK" "$PRERELEASE" <<'PYEOF'
import sys
from datetime import datetime, timezone

appcast, tag, short_ver, build, ed_sig, length, dl_url, notes_link, prerelease = sys.argv[1:]

pub_date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
channel_line = f"      <sparkle:channel>{prerelease}</sparkle:channel>\n" if prerelease else ""

item = (
    "    <item>\n"
    f"      <title>{tag}</title>\n"
    f"      <pubDate>{pub_date}</pubDate>\n"
    f"      <sparkle:version>{build}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{short_ver}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n"
    f"{channel_line}"
    f"      <sparkle:releaseNotesLink>{notes_link}</sparkle:releaseNotesLink>\n"
    f"      <enclosure url=\"{dl_url}\" length=\"{length}\" "
    f"type=\"application/octet-stream\" sparkle:edSignature=\"{ed_sig}\" />\n"
    "    </item>\n"
)

with open(appcast, 'r', encoding='utf-8') as f:
    src = f.read()

marker = "<!-- BEGIN-ITEMS (release.sh inserts new entries here, newest first) -->\n"
if marker not in src:
    sys.exit(f"ERROR: marker line not found in {appcast}; refuse to mangle it.")

new_src = src.replace(marker, marker + item, 1)
with open(appcast, 'w', encoding='utf-8') as f:
    f.write(new_src)
PYEOF

# Sanity: re-verify the signature we just wrote by reading it back from
# the appcast. A mismatch here means the script raced or the file got
# stomped, and we should NOT push a bad feed.
APPCAST_SIG="$(grep -m1 "sparkle:edSignature=" "$APPCAST" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
[[ "$APPCAST_SIG" == "$ED_SIG" ]] \
    || { echo "ERROR: appcast.xml top sig does not match the signature we just generated." >&2; exit 1; }

# ── Tag + GitHub release ────────────────────────────────────────────
echo "==> Tagging ${TAG}"
git tag -a "${TAG}" -m "${TAG}"
git push origin "${TAG}"

echo "==> Creating GitHub release"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "${TAG}" ${PRERELEASE_FLAG} \
        --title "${TITLE}" \
        --notes-file "${NOTES_FILE}" \
        "${BUILD_DIR}/${ASSET}"
else
    # Auto-generate from commit messages since the previous tag.
    gh release create "${TAG}" ${PRERELEASE_FLAG} \
        --title "${TITLE}" \
        --generate-notes \
        "${BUILD_DIR}/${ASSET}"
fi

# ── Publish the updated appcast ─────────────────────────────────────
# The asset is now reachable at $DOWNLOAD_URL, so it's safe to push the
# new feed entry. Existing installs will pick it up from
# raw.githubusercontent.com on next Sparkle check.
echo "==> Publishing ${APPCAST} update"
git add "${APPCAST}"
git commit -m "Update appcast for ${TAG}"
git push origin main

echo
echo "==> Done"
echo "    https://github.com/${GH_REPO}/releases/tag/${TAG}"

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

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --limit 1 >/dev/null 2>&1 \
    || { echo "ERROR: notarytool profile '${NOTARY_PROFILE}' is missing or invalid." >&2
         echo "       See docs/release.md → 'Set up notarytool profile'." >&2
         exit 1; }

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

echo "==> Committing version bump"
git add project.yml
git commit -m "Bump version to ${VERSION} (build ${next_build})"

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
ditto -c -k --keepParent "${APP}" "${BUILD_DIR}/${ASSET}"

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
ditto -c -k --keepParent "${APP}" "${BUILD_DIR}/${ASSET}"

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

echo
echo "==> Done"
echo "    https://github.com/${GH_REPO}/releases/tag/${TAG}"

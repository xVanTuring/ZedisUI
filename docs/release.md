# Release process

This is the end-to-end "cut a new public build" workflow. The whole
thing is automated by [`release.sh`](../release.sh) once a few
one-time bits of machine state are in place.

## Contract (six rules)

Any change to `release.sh` must preserve these. They are the canonical
release-flow rules for this project; if you (human or agent) are about
to cut a release, this is the checklist.

1. **User-triggered only.** Releases start with a human running
   `./release.sh <version>`. Never auto-trigger from a script or agent.
2. **Bump → build-verify → commit.** After bumping `project.yml` and
   regenerating `Resources/Info.plist` via `xcodegen`, run a Debug
   `xcodebuild` to confirm the bumped sources compile. Only commit if
   the build succeeds. On failure, restore both files (`git checkout
   --`) + re-run `xcodegen` and exit — never leave a half-baked
   version-bump commit on the branch.
3. **Working tree clean before push.** Pre-flight requires `git status
   --porcelain` empty before bumping; after the bump commit there is a
   second `--porcelain` check. Push only when both pass.
4. **Tag every released version.** After archive + notarize + staple
   succeed, the script creates an annotated tag (`vX.Y.Z` or
   `vX.Y.Z-<pre>` for pre-releases) on the bump commit and pushes it.
5. **Release notes derived from commits.** Default uses `gh release
   create --generate-notes` so GitHub renders notes from commit
   messages since the previous tag. `--notes-file` exists as an
   override but is the exception — keep commit messages descriptive
   instead of relying on a custom file.
6. **Every release ships a signed appcast.** The asset is signed with
   the Sparkle EdDSA key, the new `<item>` is inserted at the top of
   `appcast.xml`, and that file is committed + pushed to `main`
   **after** the GitHub Release exists. Existing installs poll
   `raw.githubusercontent.com/.../main/appcast.xml`, so the feed must
   never reference a download URL that isn't yet live.

## What gets produced

For a given version `X.Y.Z` (optionally with a `--prerelease beta`
suffix):

- A `Bump version to X.Y.Z (build N)` commit on `main`
- An annotated tag `vX.Y.Z` (or `vX.Y.Z-beta`) pointing at it
- A universal-binary `ZedisUI.app`, **Developer ID signed**
  (team `T8F5T6HKG8`) and **notarized + stapled** by Apple
- A `ZedisUI-X.Y.Z[-beta].zip` asset attached to a GitHub Release on
  [`xVanTuring/ZedisUI`](https://github.com/xVanTuring/ZedisUI), marked
  as prerelease when applicable

End users download the zip, unzip, drag the app to `/Applications`,
and double-click. No Gatekeeper warning, no right-click → Open.

In-place updates happen via **Sparkle 2**: the app polls
`appcast.xml`, verifies the new zip's EdDSA signature against
`SUPublicEDKey`, and an XPC installer service swaps the bundle on
disk. We don't hand-roll any of that any more — see
[`Sources/Services/UpdaterService.swift`](../Sources/Services/UpdaterService.swift).

## One-time setup

These four pieces of machine state need to exist on whichever Mac runs
the release. They survive across rebuilds and reboots, so you set them
up once.

### 1. Tools on `PATH`

```sh
brew install xcodegen
brew install gh
```

Xcode itself must be installed (`xcodebuild`, `codesign`, `notarytool`,
`stapler`, `spctl` all come with it).

### 2. `gh` authenticated for the repo

```sh
gh auth login
```

Pick `github.com` → HTTPS or SSH → web flow. Must have push +
release-create permissions on `xVanTuring/ZedisUI`.

### 3. Developer ID Application certificate

The release build is re-signed with **Developer ID Application** at
export time (the build itself uses Apple Development; see the comments
in `project.yml`). The cert must exist in the login keychain under
team `T8F5T6HKG8`. Verify with:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If it's missing: Xcode → Settings → Accounts → select the team →
Manage Certificates… → `+` → **Developer ID Application**. Make sure
the **private key** for the cert is also in the keychain — the cert
without the key can't sign.

### 4. Sparkle EdDSA key

Sparkle signs every release asset with an EdDSA key. The public half
lives in `project.yml` (→ `Info.plist` as `SUPublicEDKey`); the
private half lives in your **login keychain** under
`https://sparkle-project.org` and is read by `sign_update` at release
time. Generate it once with:

```sh
./DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

(That path exists after any Debug build resolves the Sparkle SPM
package.) The tool prints the public key — match it against
`SUPublicEDKey` in `project.yml`; if they differ, the public key in
`project.yml` is authoritative for already-released installs. **Never
regenerate the key after the first release ships** — existing
installs will reject updates signed with a new private key. If the
key is genuinely lost, you have to ship a one-time "manual download"
build that has a fresh `SUPublicEDKey` and tell users to install it
by hand.

Back the private key up out-of-band:

```sh
./DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
    -x sparkle_ed_private_key.pem
```

(Then move that file to a password manager / hardware key. Delete the
on-disk copy.)

### 5. `notarytool` keychain profile

`release.sh` calls `notarytool` with `--keychain-profile zedis-notary`.
Set the profile up once:

```sh
xcrun notarytool store-credentials zedis-notary \
    --apple-id <your@apple.id> \
    --team-id T8F5T6HKG8 \
    --password <app-specific-password>
```

The `--password` is **not** your Apple ID's real password. Generate an
app-specific one at <https://appleid.apple.com/account/manage> →
Sign-In and Security → App-Specific Passwords. Anything goes for the
label (e.g. `notarytool-zedis`); you'll get a `xxxx-xxxx-xxxx-xxxx`
token.

`store-credentials` validates against Apple and stores the trio
(Apple ID + team + app-specific password) in the login keychain under
the profile name `zedis-notary`. The release script never sees the
password — it just references the profile.

> Alternative: App Store Connect API key
> (`--key <.p8> --key-id <id> --issuer <uuid>`). Both work; the
> app-specific password flow is slightly simpler if you don't already
> have an API key.

## Cutting a release

```sh
./release.sh 0.1.2                         # stable
./release.sh 0.1.2 --prerelease beta       # prerelease
./release.sh 0.1.2 --notes-file CHANGELOG.md   # custom release body
./release.sh 0.1.2 --dry-run               # bump + commit only, no push/build/release
```

The script enforces:

- Run from the repo root (`project.yml` present)
- Working tree clean
- Version matches `X.Y.Z`
- Tag doesn't already exist locally or on origin
- All four pieces of one-time setup are present (cert, notary profile,
  gh login, xcodegen)

If a check fails it exits before touching anything.

`CFBundleVersion` is auto-incremented based on the current value in
`project.yml`; you only pass the short version. The script regenerates
the xcodeproj after the bump.

If `--notes-file` is omitted, GitHub auto-generates the release body
from commit messages since the previous tag (`gh release create
--generate-notes`).

## What the script does, step by step

1. **Pre-flight checks** — fails fast if any prereq is missing,
   including `git status --porcelain` being empty.
2. **Bump version in `project.yml`** — sets `CFBundleShortVersionString`
   and bumps `CFBundleVersion`.
3. **Regenerate xcodeproj** via `xcodegen`.
4. **Verify Debug build** — `xcodebuild -configuration Debug build`.
   On failure: `git checkout -- project.yml Resources/Info.plist`,
   re-run `xcodegen`, exit non-zero. No commit is created.
5. **Commit** the version bump (`project.yml` +
   `Resources/Info.plist`).
6. **Post-commit clean check** — a second `git status --porcelain`
   guard. If anything else slipped in (hook, stray file), abort before
   pushing.
7. **Push `main`**.
8. **Archive** the Release configuration into
   `build/ZedisUI.xcarchive`.
9. **Write `build/ExportOptions.plist`** with
   `method=developer-id`, `teamID=T8F5T6HKG8`, automatic signing.
10. **Export** → `build/Export/ZedisUI.app` re-signed with Developer ID.
11. **Verify signature** with `codesign -d` and `codesign -v --strict`.
12. **`ditto -c -k`** the app into `build/ZedisUI-<version>.zip`.
13. **Submit to Apple notary**
    (`xcrun notarytool submit --keychain-profile zedis-notary --wait`)
    — blocks here until the result comes back, typically 1–5 minutes.
14. **Staple** the notary ticket onto the app (`xcrun stapler staple`)
    so Gatekeeper can verify offline.
15. **Verify Gatekeeper** with `spctl -a -t exec -vv` — expect
    `source=Notarized Developer ID`.
16. **Re-zip** the now-stapled app (the original zip didn't carry the
    ticket).
17. **Sparkle-sign** the final zip with `sign_update` and capture the
    EdDSA signature + length.
18. **Insert a new `<item>` at the top of `appcast.xml`** with the
    signature, length, predicted GitHub release download URL,
    `sparkle:version` (= build number), `sparkle:shortVersionString`,
    `sparkle:minimumSystemVersion=15.0`, and (for pre-releases)
    `sparkle:channel=<suffix>`.
19. **Tag** the bump commit `vX.Y.Z[-suffix]` and push.
20. **`gh release create`** with the zip as the asset and
    `--generate-notes` (or `--notes-file` if explicitly requested),
    marking prerelease when applicable.
21. **Commit + push `appcast.xml`** to `main` (`Update appcast for
    vX.Y.Z`). This must happen *after* `gh release create` so the feed
    never points at a 404.

## Troubleshooting

### Debug build verification failed

The script restored `project.yml` + `Resources/Info.plist` and exited
before committing. Fix the compile error on `main`, commit it, then
re-run `./release.sh <version>`. No clean-up is needed — the bump
was rolled back.

### "ARCHIVE FAILED" with a signing error

Open the project in Xcode once, let it pick a provisioning profile, and
re-run. If the cert is missing, see one-time setup §3.

### Notarization rejected

```sh
xcrun notarytool log <submission-id> --keychain-profile zedis-notary
```

Common causes:
- An embedded binary isn't hardened-runtime signed (Hardened Runtime is
  enabled in `project.yml`, so any new framework dep needs to inherit
  this — usually automatic).
- A symlink resolves outside the bundle.
- `--timestamp` was missing on a binary (we set
  `OTHER_CODE_SIGN_FLAGS: --timestamp` for Release).

### Tag already exists

```sh
git tag -d vX.Y.Z          # delete local
git push origin :vX.Y.Z    # delete on origin
gh release delete vX.Y.Z   # delete the release if it was made
```

Then re-run.

### "gh release create" 422 with "Validation Failed"

Usually means the tag already has a release. Same fix as above.

### `notarytool history` errors

The keychain profile name is wrong or got corrupted. Re-run
`store-credentials` to recreate it.

### `sign_update` fails or hangs on a Keychain prompt

The first call after a fresh keychain login asks for permission to
read the Sparkle EdDSA private key. Click "Always Allow" so future
release runs don't block.

If `sign_update` reports "No existing signing key found", regenerate
**only on machines that have never released before** — on a machine
that has, restore the key from your backup (`generate_keys -f
sparkle_ed_private_key.pem`) instead.

### Sparkle says "The update is improperly signed" after install

Means `SUPublicEDKey` in the running app doesn't match the private
key that signed the asset. Either the key in `project.yml` drifted,
or someone signed with the wrong machine's key. Re-sign the asset
with the correct key (see `sign_update`), edit `appcast.xml` to use
the new signature, push, and tell affected users to re-check.

## Manual mode

If something inside the script is failing and you want to run the
remaining steps by hand, the script's commands map 1:1 to the doc
above. Just run them in order from the failure point. The script never
takes a destructive action you can't undo locally — the only
irreversible step is `git push origin <tag>` plus
`gh release create`, both at the very end.

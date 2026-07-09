# Releasing Rocky (signed & notarized)

Homebrew users build Rocky from source, so they never hit Gatekeeper. This doc
is for producing a **signed, notarized `Rocky.app` zip** for people who download
the app directly (and for a future Homebrew cask).

## One-time setup

1. **Join the Apple Developer Program** ($99/yr): https://developer.apple.com/programs/
2. **Create a "Developer ID Application" certificate**
   (Xcode → Settings → Accounts → Manage Certificates → **+** → Developer ID
   Application). Confirm it's present:
   ```bash
   security find-identity -v -p codesigning   # look for "Developer ID Application: …"
   ```
3. **Create an app-specific password** for notarization at
   https://appleid.apple.com → Sign-In & Security → App-Specific Passwords.
   (Optional but tidier: store a notarytool profile once with
   `xcrun notarytool store-credentials rocky-notary --apple-id … --team-id … --password …`.)

## Cut a release locally

```bash
DEVELOPER_ID="Developer ID Application: Ketan Somvanshi (TEAMID)" \
APPLE_ID="you@example.com" APPLE_TEAM_ID="TEAMID" APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
scripts/release.sh 1.0.0

gh release create v1.0.0 build/Rocky-1.0.0.zip --generate-notes
```

`scripts/release.sh` compiles, signs with the hardened runtime, notarizes via
Apple, staples the ticket, and prints the artifact path + sha256.

## Cut a release in CI

`.github/workflows/release.yml` does all of the above automatically on any
`v*` tag push (or via **Actions → release → Run workflow**). Add these
repository secrets first (Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `CERT_P12_BASE64` | Your Developer ID cert exported as `.p12`, base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `DEVELOPER_ID` | e.g. `Developer ID Application: Ketan Somvanshi (TEAMID)` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your 10-char Team ID |
| `APPLE_APP_PASSWORD` | The app-specific password |

Until these secrets exist, the workflow's signing step fails by design — that's
the only part that needs your Apple account.

## Updating the Homebrew formula on a new version

The tap formula builds from source, so a new release just needs the tag's
tarball hash:

```bash
V=1.1.0
git tag -a v$V -m "Rocky v$V" && git push origin v$V
curl -sL "https://github.com/KetanSomvanshi/rocky/archive/refs/tags/v$V.tar.gz" | shasum -a 256
# update url + sha256 in KetanSomvanshi/homebrew-tap → Formula/rocky.rb
```

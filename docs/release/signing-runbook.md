# Signing runbook: rv's first signed, notarized release

This runbook is for the repository owner. It covers making the Apple and SSH
credentials, storing them as GitHub Actions secrets, cutting the release, and
checking the result on a Mac. Every command is one **you** run on your own
machine. Text in `<angle brackets>` is a placeholder for your own value. Never
paste a real value into this file, an issue, a pull request, or a chat.

Sources this runbook was written from (at commit `245aa9b`):
`.github/workflows/release.yml`, `Scripts/release.sh`, `Scripts/sign-macos.sh`,
`Scripts/release-assets.sh`, `Scripts/release-sign-sums.sh`,
`Scripts/install-smoke.sh`, `Scripts/build-microvm.sh`, `install.sh`,
`Scripts/custodian/RVApprovals.entitlements`, `Scripts/custodian/Info.plist`,
`Packages/rv-microvm/rv-microvm.entitlements`.

"Not verified here" means the step was written from the scripts and Apple's
documented behaviour, but it could not be run without a real Apple account or
a Mac.

---

## 0. What gets signed, and with what

| Credential | Signs or proves | Where it is used |
|---|---|---|
| Developer ID Application certificate (`.p12`) | Every macOS binary: `rv`, `rv-cli`, `rvd`, `rv-workspace-host`, `rv-pty-claim`, `rv-microvm`, `libswiftCompatibilitySpan.dylib`, `RVApprovals.app`, and `rv-macvm` + `rv-macvm-agent` when the build SDK is 27 or newer (`Scripts/build-microvm.sh:41-54` leaves them out otherwise) | `Scripts/sign-macos.sh:239-295` |
| Developer ID provisioning profile for `dev.rv.mcp-custodian` | Allows `RVApprovals.app` to hold the `keychain-access-groups` entitlement `<TEAMID>.dev.rv.mcp-custodian` | `Scripts/sign-macos.sh:264-295` |
| App Store Connect API key (`.p8`) | Notarization through `xcrun notarytool` | `Scripts/sign-macos.sh:297-333` |
| SSH ed25519 key | `SHA256SUMS.sig`, which `install.sh` checks on every OS once the key is pinned | `Scripts/release-sign-sums.sh`, `install.sh:339-376` |

Without the provisioning profile the workflow still signs the binaries but
leaves `RVApprovals.app` unsigned (`Scripts/sign-macos.sh:261-263`). Customers
then cannot use MCP approvals or `rv mcp trust`. **Treat all eight secrets as
required.**

---

## 1. Prerequisites in the Apple Developer account

You need an Apple Developer Program membership. Developer ID certificates can
only be created by the team's **Account Holder** (whether an Admin can do it on
your team depends on your team settings; not verified here). Do steps 1.1 to 1.4
on the Mac that will hold the certificate's private key.

Keep every file this section produces **outside the repository checkout**, for
example in `~/rv-release-secrets/` on an encrypted volume, and back each one up
to a password manager or an offline encrypted disk.

### 1.1 Find your Team ID

* Where: <https://developer.apple.com/account> → **Membership details** → **Team ID**.
* What comes out: a 10-character string such as `<TEAMID>`. You need it in
  sections 1.4, 4 and 5. It also appears in parentheses at the end of the
  certificate name, `Developer ID Application: <Your Name or Company> (<TEAMID>)`.

### 1.2 Developer ID Application certificate

1. On the Mac, open **Keychain Access** → menu **Keychain Access** →
   **Certificate Assistant** → **Request a Certificate From a Certificate
   Authority…**
   * User Email Address: your Apple ID email.
   * Common Name: anything, e.g. `rv Developer ID`.
   * CA Email Address: leave empty.
   * Choose **Saved to disk**. This produces `CertificateSigningRequest.certSigningRequest`
     and puts the private key in your login keychain.
2. Go to <https://developer.apple.com/account/resources/certificates/list> →
   **+**.
3. Under **Software**, pick **Developer ID Application**. Do not pick
   *Developer ID Installer*, *Apple Distribution* or *Apple Development*: the
   workflow checks for `Authority=Developer ID Application:` and refuses anything
   else (`Scripts/sign-macos.sh:255`).
4. Profile Type: **G2 Sub-CA (Xcode 11.4.1 or later)**.
5. Upload the `.certSigningRequest`, then **Download**. You get
   `developerID_application.cer`.
6. Double-click the `.cer`. It goes into the login keychain and pairs with the
   private key from step 1.
7. In Keychain Access → **login** → **My Certificates**, find
   `Developer ID Application: <Your Name or Company> (<TEAMID>)`. Expand it and
   check there is a private key under it. Right-click → **Export…** → format
   **Personal Information Exchange (.p12)** → save as `<path-to-your.p12>` and
   set a **non-empty** password. The workflow treats an empty password as a
   missing secret (`.github/workflows/release.yml:104`).

What comes out: `<path-to-your.p12>` (certificate + private key) and its password.

Prefer Keychain Access for the export. A `.p12` made by OpenSSL 3 with its
default (AES/PBKDF2) encryption may not import with `security import` on older
macOS. If you must use OpenSSL, add `-legacy` to `openssl pkcs12 -export`. Not
verified here on the `macos-26` runner.

Check that the `.p12` imports the way the workflow imports it, in a throwaway
keychain (you are asked for the `.p12` password and a password for the
throwaway keychain):

```bash
security create-keychain ~/rv-p12-check.keychain-db
```

```bash
security import <path-to-your.p12> -k ~/rv-p12-check.keychain-db -T /usr/bin/codesign
```

```bash
security find-identity -v -p codesigning ~/rv-p12-check.keychain-db
```

```bash
security delete-keychain ~/rv-p12-check.keychain-db
```

The `find-identity` line must show exactly one
`"Developer ID Application: <Your Name or Company> (<TEAMID>)"`. That quoted
string is the value of `DEVELOPER_ID_APP` (section 2.1).

### 1.3 App ID `dev.rv.mcp-custodian`

1. Go to <https://developer.apple.com/account/resources/identifiers/list> → **+**.
2. Pick **App IDs** → Continue → type **App** → Continue.
3. Description: `rv MCP approvals custodian`.
4. Bundle ID: **Explicit**, `dev.rv.mcp-custodian`. This must match
   `CFBundleIdentifier` in `Scripts/custodian/Info.plist:6` and the
   `--identifier` that `Scripts/sign-macos.sh:290-293` signs with.
5. If the form asks for a platform, pick **macOS**.
6. Capabilities: there is nothing to tick for the keychain. *Keychain Sharing*
   is an Xcode capability, not a portal checkbox. Every provisioning profile
   authorizes the keychain access groups that start with your Team ID
   (`<TEAMID>.*`), and that covers the group `<TEAMID>.dev.rv.mcp-custodian`
   that the custodian uses (`Scripts/custodian/RVApprovals.entitlements:7`,
   `Sources/RVMCP/CustodianWire.swift:87`). You check this in the downloaded
   profile in step 1.4. Not verified here.
7. Continue → **Register**.

What comes out: nothing to download. The App ID is used by the profile.

### 1.4 Developer ID provisioning profile

1. Go to <https://developer.apple.com/account/resources/profiles/list> → **+**.
2. Under **Distribution**, pick **Developer ID**. (Not *Mac App Store
   Connect*, and not a *Development* profile.)
3. App ID: **`dev.rv.mcp-custodian`** (from 1.3).
4. Certificate: **the Developer ID Application certificate from 1.2**. If there
   are several, pick the one whose expiry date matches the one you exported.
   The profile only works with code signed by a certificate it lists.
5. Provisioning Profile Name: `rv mcp-custodian Developer ID`.
6. **Generate** → **Download**.

What comes out: `<path-to-your.provisionprofile>`.

Check what it allows:

```bash
security cms -D -i <path-to-your.provisionprofile> | plutil -p -
```

Look for:

* `"Entitlements"` → `"com.apple.application-identifier" => "<TEAMID>.dev.rv.mcp-custodian"`
* `"Entitlements"` → `"keychain-access-groups"` containing `"<TEAMID>.*"`
* `"TeamIdentifier"` containing `"<TEAMID>"`
* `"ProvisionsAllDevices" => 1` (a Developer ID profile)
* `"ExpirationDate"`: write it down; see section 6.

Not verified here: the exact key list of a Developer ID profile. If
`keychain-access-groups` is missing from the profile, macOS will not let the
custodian use the keychain group, whatever the workflow does.

### 1.5 App Store Connect API key for notarization

1. Go to <https://appstoreconnect.apple.com/access/integrations/api>
   (**Users and Access** → **Integrations** → **App Store Connect API** →
   **Team Keys**). The first time, the Account Holder must click
   **Request Access** and accept the terms.
2. **+** (Generate API Key). Name: `rv notarization`. Access: **Developer**
   is enough for `notarytool` (not verified here for your team; use **Admin**
   if submissions return 401/403).
3. **Generate**. In the row for the new key, note the **Key ID** (10
   characters). Above the table, note the **Issuer ID** (a UUID).
4. **Download API Key**. You get `AuthKey_<KEYID>.p8`. Apple lets you
   download it **once only**.

What comes out: `<path-to-AuthKey_KEYID.p8>`, `<KEY_ID>`, `<ISSUER_ID>`.

### 1.6 SSH key that signs `SHA256SUMS`

`Scripts/release-sign-sums.sh` signs with `ssh-keygen -Y sign -n rv-release`.
It needs an **unencrypted** OpenSSH private key, because CI has no terminal to
type a passphrase into (`Scripts/release-sign-sums.sh:115-118`). Make a key
that is only for this:

```bash
ssh-keygen -t ed25519 -N '' -C rv-release -f <path-to>/rv-release-signing
```

What comes out: `<path-to>/rv-release-signing` (private key; becomes the
secret) and `<path-to>/rv-release-signing.pub` (public key; goes into
`install.sh` in section 5).

Because the key has no passphrase, its file is the whole secret. Keep it on an
encrypted volume and back it up. Do not reuse your login SSH key.

---

## 2. The eight secrets

The workflow reads repository secrets, not environment secrets: none of its
jobs declares `environment:`. Every `gh secret set` below reads the value from
stdin, so it never appears in your shell history or on the command line. Run
them from a Mac or Linux shell where `gh auth status` shows you logged in with
admin rights on `christopherkarani/rv`.

`base64 < file | tr -d '\n'` gives one unwrapped line on both macOS and Linux.
The workflow decodes with `base64 --decode`, which needs no particular line
length; one line is used only to keep the value tidy.

To check any base64 secret before storing it, round-trip it locally. Silence
means the round-trip matches:

```bash
base64 < <file> | tr -d '\n' | base64 --decode | cmp - <file>
```

| # | Secret | Contents | Encoding | Read at |
|---|---|---|---|---|
| 1 | `DEVELOPER_ID_APP` | identity name | plain text | `Scripts/sign-macos.sh:167,249,270-273` |
| 2 | `MACOS_CERT_P12` | the `.p12` | base64 | `Scripts/sign-macos.sh:216` |
| 3 | `MACOS_CERT_PASSWORD` | `.p12` password | plain text, non-empty | `Scripts/sign-macos.sh:174,228` |
| 4 | `NOTARY_KEY_ID` | API Key ID | plain text | `Scripts/sign-macos.sh:168,314` |
| 5 | `NOTARY_ISSUER_ID` | Issuer ID | plain text | `Scripts/sign-macos.sh:169,314` |
| 6 | `NOTARY_KEY_P8` | the `.p8` file | **base64** of the file, not the PEM text | `Scripts/sign-macos.sh:299` |
| 7 | `RV_CUSTODIAN_PROVISIONING_PROFILE_B64` | the `.provisionprofile` | base64 | `.github/workflows/release.yml:99-103` |
| 8 | `RV_RELEASE_SSH_SIGNING_KEY` | the private key file | **raw text**, not base64 | `Scripts/release-sign-sums.sh:182` |

Secrets 1 to 7 reach only the gate job's **Sign and notarize** step
(`.github/workflows/release.yml:82-115`). Secret 8 reaches only the publish
job's **Sign SHA256SUMS** step (`.github/workflows/release.yml:400-407`).

### 2.1 `DEVELOPER_ID_APP`

* Contains: the full identity name, exactly as `security find-identity`
  printed it in 1.2, without the quotes:
  `Developer ID Application: <Your Name or Company> (<TEAMID>)`.
* Encoding: plain text. Used as `codesign --sign "$DEVELOPER_ID_APP"`.
* Do **not** use the 40-character SHA-1 hash, although `codesign` accepts it.
  `sign-macos.sh` reads the Team ID from the text between the last `(` and `)`
  to fill in the custodian's keychain group, and fails with
  `cannot read the team id from DEVELOPER_ID_APP` without it
  (`Scripts/sign-macos.sh:270-273`).
* Store (type or paste the value at the hidden prompt):

```bash
gh secret set DEVELOPER_ID_APP --repo christopherkarani/rv
```

### 2.2 `MACOS_CERT_P12`

* Contains: the `.p12` from 1.2 (Developer ID Application certificate **and
  its private key**).
* Encoding: base64 of the file. The workflow runs
  `printf '%s' "$MACOS_CERT_P12" | base64 --decode > cert.p12` and imports it
  into a temporary keychain (`Scripts/sign-macos.sh:212-237`).
* Store:

```bash
base64 < <path-to-your.p12> | tr -d '\n' | gh secret set MACOS_CERT_P12 --repo christopherkarani/rv
```

### 2.3 `MACOS_CERT_PASSWORD`

* Contains: the password you set when exporting the `.p12`.
* Encoding: plain text. Passed as `security import -P` (`Scripts/sign-macos.sh:228`).
  Must not be empty.
* Store (type it at the hidden prompt):

```bash
gh secret set MACOS_CERT_PASSWORD --repo christopherkarani/rv
```

### 2.4 `NOTARY_KEY_ID`

* Contains: the 10-character Key ID from 1.5.
* Encoding: plain text. Passed as `notarytool --key-id`.
* Store:

```bash
gh secret set NOTARY_KEY_ID --repo christopherkarani/rv
```

### 2.5 `NOTARY_ISSUER_ID`

* Contains: the Issuer ID (UUID) from 1.5.
* Encoding: plain text. Passed as `notarytool --issuer`.
* Store:

```bash
gh secret set NOTARY_ISSUER_ID --repo christopherkarani/rv
```

### 2.6 `NOTARY_KEY_P8`

* Contains: the whole `AuthKey_<KEYID>.p8` file from 1.5.
* Encoding: **base64 of the file**. The script decodes it
  (`printf '%s' "$NOTARY_KEY_P8" | base64 --decode > AuthKey.p8`,
  `Scripts/sign-macos.sh:299`) and passes the file as `notarytool --key`.
  Pasting the `-----BEGIN PRIVATE KEY-----` text directly is the most likely
  mistake: it decodes to garbage, and notarytool fails to authenticate.
* Store:

```bash
base64 < <path-to-AuthKey_KEYID.p8> | tr -d '\n' | gh secret set NOTARY_KEY_P8 --repo christopherkarani/rv
```

### 2.7 `RV_CUSTODIAN_PROVISIONING_PROFILE_B64`

* Contains: the `.provisionprofile` from 1.4.
* Encoding: base64 of the file. The workflow decodes it into
  `rv-custodian.provisionprofile` and exports its path as
  `RV_CUSTODIAN_PROVISIONING_PROFILE` (`.github/workflows/release.yml:99-103`).
  `sign-macos.sh` copies it to `RVApprovals.app/Contents/embedded.provisionprofile`
  (`Scripts/sign-macos.sh:282`).
* Store:

```bash
base64 < <path-to-your.provisionprofile> | tr -d '\n' | gh secret set RV_CUSTODIAN_PROVISIONING_PROFILE_B64 --repo christopherkarani/rv
```

### 2.8 `RV_RELEASE_SSH_SIGNING_KEY`

* Contains: the private key file from 1.6, starting with
  `-----BEGIN OPENSSH PRIVATE KEY-----`.
* Encoding: **raw text, not base64**. The script writes the secret to a 0600
  file with `printf '%s\n'` and passes that file to `ssh-keygen -Y sign -f`
  (`Scripts/release-sign-sums.sh:181-184`).
* Store (stdin redirect keeps the newlines):

```bash
gh secret set RV_RELEASE_SSH_SIGNING_KEY --repo christopherkarani/rv < <path-to>/rv-release-signing
```

### 2.9 Repository variable `RV_REQUIRE_SIGNED_RELEASE` (recommended)

This is a variable, not a secret. Set to `1`, the gate fails when any of
secrets 1 to 6 is missing instead of shipping an unsigned macOS build
(`.github/workflows/release.yml:108-110`), and publish fails without secret 8
(`Scripts/release-sign-sums.sh:165-168`).

```bash
gh variable set RV_REQUIRE_SIGNED_RELEASE --body 1 --repo christopherkarani/rv
```

It does **not** check secret 7. A release with a missing or empty profile
secret still publishes, with an unsigned `RVApprovals.app`. Check
`gh secret list --repo christopherkarani/rv` (names only) before you tag.

---

## 3. Cutting the release

### 3.1 Bump the version (a normal pull request)

The workflow does not check that the tag matches the version compiled into the
binaries. Before tagging `v<X.Y.Z>`, merge a PR that sets the new version in:

* `Sources/RVDomain/ProductVersion.swift:2` (`semver`)
* `Scripts/custodian/Info.plist:14` (`CFBundleShortVersionString`) and
  increment `CFBundleVersion` on line 16
* the tests that pin it: `Tests/RVDomainTests/ProductVersionTests.swift:6`,
  `Tests/RVCLITests/RVVersionTests.swift:6`,
  `Tests/RVServiceTests/RVDLaunchVersionTests.swift:6`
* `CHANGELOG.md` (new section and compare links at the bottom)

### 3.2 Rehearse with a manual run (signs and notarizes, publishes nothing)

`workflow_dispatch` runs gate (including real signing and notarization),
macOS 15 smoke, Linux builds and install smoke, but **skips publish**
(`.github/workflows/release.yml:372`, `if: github.event_name == 'push'`), and so
also skips the SSH signature step.

```bash
gh workflow run release.yml --repo christopherkarani/rv --ref main
```

```bash
gh run list --repo christopherkarani/rv --workflow release.yml --limit 1
```

```bash
gh run watch <run-id> --repo christopherkarani/rv
```

When it is green, download the signed macOS assets and run the checks in
section 4 (all except 4.4, the SSH signature, which only publish makes):

```bash
gh run download <run-id> --repo christopherkarani/rv --name release-assets-darwin-arm64 --dir <empty-dir>
```

**Do this rehearsal before the first tag.** It is the only way to see whether
`RVApprovals.app` really works (section 4.5) before customers download it. See
problem A in the pull request that added this runbook.

### 3.3 Push the tag

Any tag starting with `v` triggers the workflow (`.github/workflows/release.yml:3-7`).
The workflow file used is the one at the tagged commit.

```bash
git switch main && git pull --ff-only
```

```bash
git tag -a v<X.Y.Z> -m "rv <X.Y.Z>"
```

```bash
git push origin v<X.Y.Z>
```

### 3.4 What each job does and how long it takes

The times are from the last successful release run (v0.2.1, run
[40351079923](https://github.com/christopherkarani/rv/actions/runs/40351079923)),
which was **unsigned**. Signing adds notarization time to the gate job: usually
a few minutes, at most the 30-minute `notarytool --wait` timeout
(`Scripts/sign-macos.sh:311`), plus up to 60 seconds per binary while
Gatekeeper's ticket lookup catches up (`Scripts/sign-macos.sh:348-356`). Not
verified here for a signed run.

| Job | Runner | Does | v0.2.1 time |
|---|---|---|---|
| `gate` | macos-26 | Installs Swift 6.4; preflight and module tests (≈10 min); isolation tests in three shards (≈14 min); `Scripts/release.sh` builds and stages everything, including `RVApprovals.app` (≈6 min); **Sign and notarize** (`Scripts/sign-macos.sh --keychain-from-env`); C hook and host-attach proofs against the signed stage; uploads `rv-<tag>` (the stage) and `release-assets-darwin-arm64` (renamed by `Scripts/release-assets.sh`, with `RVApprovals.app` zipped as `rv-approvals-darwin-arm64.zip`). Timeout 120 min. | 33 min (+ notarization) |
| `linux` ×2 | ubuntu-22.04 / -arm | Builds and stages the Linux binaries, smoke-runs them, checks the glibc floor against `install.sh`, uploads `release-assets-linux-*`. Runs in parallel with gate. | 8–11 min |
| `sequoia-smoke` | macos-15 | Checks `minos 15.0`; when gate reports `signed=1`, verifies the hardened Developer ID signature and Gatekeeper `source=Notarized Developer ID` for `rv`, `rv-cli`, `rvd`, `rv-workspace-host`, `rv-pty-claim`; runs the binaries. | < 1 min |
| `install-smoke` ×4 | macos-15, ubuntu-24.04, ubuntu-24.04-arm, ubuntu-22.04 | Runs the repo's `install.sh` against the renamed assets over loopback (`Scripts/install-smoke.sh --local`). | ≈1 min each |
| `publish` | ubuntu-24.04 | Only on a tag push. Adds `install.sh` and `SHA256SUMS`, signs `SHA256SUMS` into `SHA256SUMS.sig` with secret 8, then creates the GitHub release (or uploads with `--clobber` if it exists). The release is **not** a draft: it becomes "latest" at once, and `curl … | sh` installs pick it up. | < 1 min |
| `curl-e2e` ×3 | macos-15, ubuntu-24.04, ubuntu-24.04-arm | Installs from the live URL `https://rykanv.com/install`. | < 1 min |

Expect about 40–60 minutes from tag push to the end of `curl-e2e`.

The log of **Sign SHA256SUMS** prints the line to pin in `install.sh`
(`Scripts/release-sign-sums.sh:209`). Copy it for section 5.

---

## 4. Verifying the release on a Mac

Use an Apple Silicon Mac on macOS 15 or newer, online (Gatekeeper looks up
notarization tickets for bare binaries online). Download everything into an
empty folder:

```bash
mkdir <empty-dir> && cd <empty-dir>
```

```bash
gh release download v<X.Y.Z> --repo christopherkarani/rv
```

### 4.1 Code signature: `codesign -dv --verbose=4`

```bash
codesign -dv --verbose=4 rv-darwin-arm64
```

Expect:

* `Identifier=dev.rv.rv` (each binary is `dev.rv.<name>`; the dylib is
  `dev.rv.libswiftCompatibilitySpan`)
* `CodeDirectory … flags=0x10000(runtime)` (hardened runtime)
* `Authority=Developer ID Application: <Your Name or Company> (<TEAMID>)`,
  then `Authority=Developer ID Certification Authority`, then
  `Authority=Apple Root CA`
* `Timestamp=<date>` (a secure timestamp, not `Signed Time=`)
* `TeamIdentifier=<TEAMID>`

Repeat for every macOS binary, and verify each strictly (the loop skips `rv-macvm` and `rv-macvm-agent` when the release does not include them):

```bash
for f in rv rv-cli rvd rv-workspace-host rv-pty-claim rv-microvm rv-macvm rv-macvm-agent; do [ -f "$f-darwin-arm64" ] || continue; codesign --verify --strict --verbose=2 "$f-darwin-arm64"; done
```

```bash
codesign -dv --verbose=4 libswiftCompatibilitySpan.dylib
```

`rv-microvm` and `rv-macvm` must also carry the virtualization entitlement:

```bash
codesign -d --entitlements - --xml rv-microvm-darwin-arm64 | plutil -p -
```

Expect `"com.apple.security.virtualization" => true`.

### 4.2 Gatekeeper: `spctl -a -vv`

For the bare command-line binaries, plain `spctl -a -vv` assesses them as apps
and rejects them ("does not seem to be an app"). Use the same form the
workflow and `install.sh` use:

```bash
for f in rv rv-cli rvd rv-workspace-host rv-pty-claim rv-microvm rv-macvm rv-macvm-agent; do [ -f "$f-darwin-arm64" ] || continue; spctl -a -t open --context context:primary-signature -vv "$f-darwin-arm64"; done
```

Each must print `<file>: accepted` and `source=Notarized Developer ID`.

For the app bundle (after unzipping it in 4.5), plain `spctl -a -vv` is right:

```bash
spctl -a -vv RVApprovals.app
```

Expect `RVApprovals.app: accepted` and `source=Notarized Developer ID`.

### 4.3 Stapled ticket: `stapler validate`

Only the app bundle carries a stapled ticket. Bare Mach-O files cannot be
stapled; Gatekeeper fetches their ticket online (`Scripts/sign-macos.sh:329-333`).

```bash
xcrun stapler validate RVApprovals.app
```

Expect `The validate action worked!`.

### 4.4 The SSH signature on `SHA256SUMS` (what `install.sh` does)

`install.sh` writes its pinned allowed-signers line to a file and runs
`ssh-keygen -Y verify` with principal and namespace `rv-release`
(`install.sh:369-375`). Do the same with your public key:

```bash
printf 'rv-release %s\n' "$(awk '{print $1, $2}' <path-to>/rv-release-signing.pub)" > allowed_signers
```

```bash
/usr/bin/ssh-keygen -Y verify -f allowed_signers -I rv-release -n rv-release -s SHA256SUMS.sig < SHA256SUMS
```

Expect `Good "rv-release" signature for rv-release with ED25519 key SHA256:<fingerprint>`.
Then check every asset against the signed list:

```bash
shasum -a 256 -c SHA256SUMS
```

Every line must say `OK`.

### 4.5 `RVApprovals.app`: profile and keychain access group

```bash
ditto -x -k rv-approvals-darwin-arm64.zip .
```

```bash
codesign --verify --deep --strict --verbose=2 RVApprovals.app
```

```bash
codesign -dv --verbose=4 RVApprovals.app
```

Expect `Identifier=dev.rv.mcp-custodian`, the hardened runtime flag, your
Developer ID authority and `TeamIdentifier=<TEAMID>`.

The entitlements it was signed with:

```bash
codesign -d --entitlements - --xml RVApprovals.app | plutil -p -
```

Expect `"keychain-access-groups" => [ "<TEAMID>.dev.rv.mcp-custodian" ]`.
`<TEAMID>` must be your real Team ID, not the literal `$(TeamIdentifierPrefix)`
(`Scripts/sign-macos.sh:266-276` fills it in).

The embedded profile:

```bash
security cms -D -i RVApprovals.app/Contents/embedded.provisionprofile | plutil -p -
```

Expect the same values as in 1.4, and that the profile's `keychain-access-groups`
(`<TEAMID>.*`) covers the group in the signature.

Whether macOS accepts the pair can only be seen by running it. Run the
custodian once by hand and watch for the system killing it:

```bash
./RVApprovals.app/Contents/MacOS/rv-mcp-custodian; echo "exit $?"
```

A `Killed: 9` (exit 137) right away means macOS refused the signature or the
profile. The reason is in the log:

```bash
log show --last 2m --style compact --predicate 'process == "amfid" OR process == "taskgated" OR eventMessage CONTAINS "mcp-custodian"'
```

Any other result (an error about the Mach service, or the process waiting for
connections) means it was allowed to start. Not verified here: the exact output
of a correctly signed custodian launched outside launchd.

### 4.6 First install from the release

Use a Mac user account you can throw away, or a fresh macOS VM, because
`install.sh` runs `rv setup`, which writes launch agents and agent hooks. Pin
the tag you just released:

```bash
curl -fsSL https://github.com/christopherkarani/rv/releases/download/v<X.Y.Z>/install.sh | RV_INSTALL_VERSION=v<X.Y.Z> sh
```

Then check:

* The installer **still prints** `rv: warning: release files are not code-signed: …`.
  This is expected for the first signed release: its `install.sh` does not pin
  a Team ID yet, so it treats Developer ID files as unsigned
  (`install.sh:873-880`). Section 5 removes the warning. It must **not** print
  `refusing to install`.
* `~/Applications/RVApprovals.app` exists (`install.sh:1386-1394`).
* The custodian's launch agent is loaded:

```bash
launchctl print gui/$(id -u)/dev.rv.mcp-custodian
```

* MCP approvals work end to end: run `rv mcp trust` in a project with an
  `mcp.json` and approve it. Not verified here: the exact prompts, since they
  need a signed custodian on a real Mac.
* Optionally check the live one-line URL too:

```bash
curl -fsSL https://rykanv.com/install | sh
```

Not verified here: where `https://rykanv.com/install` redirects. Check with
`curl -sSIL https://rykanv.com/install | grep -i '^location'`. If it serves
`install.sh` from `main` rather than from the latest release, the pins in
section 5 go live when they merge, not when the next release ships.

---

## 5. Follow-up: pin the release in `install.sh`

Do this **only after** section 4 passed, and in particular after 4.5 showed a
signed, working `RVApprovals.app`. Once a Team ID is pinned, a release in which
some macOS files are signed and others are not is refused outright
(`install.sh:920-923`), so an unsigned `RVApprovals.app` would break every
macOS install.

### 5.1 The lines

In `install.sh`, change lines 101, 102 and 111 from:

```sh
signed_releases=0
release_team_id=""
...
release_ssh_allowed_signers=""
```

to:

```sh
signed_releases=1
release_team_id="<TEAMID>"
...
release_ssh_allowed_signers="rv-release ssh-ed25519 <base64-public-key>"
```

* `<TEAMID>`: from 1.1, or from
  `codesign -dv rv-darwin-arm64 2>&1 | grep '^TeamIdentifier='`, or the text in
  parentheses at the end of `DEVELOPER_ID_APP`.
* The allowed-signers line: copy it from the **Sign SHA256SUMS** step log of
  the publish job (`release-sign-sums: to enforce it, set in install.sh:
  release_ssh_allowed_signers="…"`), or make it from your public key:

```bash
printf 'rv-release %s\n' "$(awk '{print $1, $2}' <path-to>/rv-release-signing.pub)"
```

  The format is `rv-release <key-type> <base64-key>`, with no comment field and
  no quotes inside. To trust two keys during a rotation, put one line per key
  inside the same double quotes.

### 5.2 Tests that must change with it

`Tests/RVCLITests/InstallScriptTests.swift` patches the unpinned literals and
will fail once they change. Update it in the same PR:

* line 1558 replaces `release_team_id=""`
* lines 2094-2095 and 2120-2121 replace `\nsigned_releases=0\n`
* lines 2559-2561 replace `\nrelease_ssh_allowed_signers=""\n`

### 5.3 What changes once it is pinned

* macOS installs refuse unsigned, ad-hoc, non-notarized or other-team files
  unless the user sets `RV_INSTALL_ALLOW_UNSIGNED=1` (`install.sh:914-929`).
* Every install, Linux included, needs a `SHA256SUMS.sig` that verifies
  against the pinned key, and needs `/usr/bin/ssh-keygen` or `/bin/ssh-keygen`
  (`install.sh:339-376`).
* The publish job fails if secret 8 is missing or does not match the pin
  (`Scripts/release-sign-sums.sh:160-164,194-203`), so no release can ship
  that every installer would refuse.
* `install-smoke` keeps the team pin and so runs the full notarization check
  on macos-15; it removes only the SSH pin, because it serves its own
  `SHA256SUMS` (`Scripts/install-smoke.sh:94-107`).
* Older unsigned releases (v0.2.1 and earlier) can only be installed with
  `RV_INSTALL_ALLOW_UNSIGNED=1`.

The `install.sh` that customers run is the one attached to a release. After
the pin merges, cut the next release (section 3) so its attached `install.sh`
carries the pin.

---

## 6. Rotation and failure

### 6.1 Expiry and leaks

| Credential | Lifetime | When it expires | If it leaks |
|---|---|---|---|
| Developer ID Application certificate | 5 years (check *Expiration* in the portal) | Releases already signed keep working: they carry a secure timestamp. Make a new certificate (1.2), then a **new profile** naming it (1.4), and update secrets 1 (only if the name changed), 2, 3 and 7. The Team ID is unchanged, so the `install.sh` pin stays. | Revoke the certificate. Apple Developer Support can set the revocation date so releases signed before the leak stay valid; whether the portal lets you revoke a Developer ID certificate yourself is not verified here. Then do the expiry steps. Anything signed after the revocation date stops launching. |
| Developer ID provisioning profile | Check `ExpirationDate` (1.4) | Regenerate it in the portal (Profiles → the profile → **Edit** → **Generate**) and update secret 7, then release. Not verified here: whether an already-installed `RVApprovals.app` keeps working after its embedded profile expires. Assume it does not, and release a new profile well before the date. | A profile is not secret by itself (it holds only public certificate data). Delete and regenerate it if the certificate is rotated. |
| App Store Connect API key | No expiry | — | Revoke it in App Store Connect → Integrations → the key → **Revoke**. Make a new key (1.5) and update secrets 4, 5 (if the issuer changed) and 6. A leaked key lets someone submit to notarization under your team; it cannot sign code by itself. |
| SSH release key | No expiry | — | Make a new key (1.6), update secret 8, change `release_ssh_allowed_signers` in `install.sh` to the **new key only**, and release. Copies of `install.sh` already downloaded still trust the old key; that cannot be revoked. |
| `.p12` password only | — | — | Re-export the `.p12` with a new password (1.2) and update secrets 2 and 3. |

**Planned rotation of the SSH key** without breaking installs: put both the
old and the new line in `release_ssh_allowed_signers`, switch secret 8 to the
new key, release, then remove the old line in a later release.

After a leak of any of these, also review who can edit the repository's
secrets and Actions settings, since anyone who can push a `v*` tag or change
`release.yml` can make the workflow sign with them.

### 6.2 Most likely failure of each job

| Job / step | Symptom | Likely cause and fix |
|---|---|---|
| gate: tests | A test or shard fails or times out | Not related to signing. Re-run with `gh run rerun <run-id> --failed --repo christopherkarani/rv`; if it repeats, fix on `main` and re-tag a new patch version. |
| gate: Sign and notarize | `::warning::signing secrets are not configured` or, with the variable set, `RV_REQUIRE_SIGNED_RELEASE=1 but signing secrets are missing` | A secret name is misspelled or a value is empty. Compare `gh secret list` with section 2. |
| gate: Sign and notarize | `security import` fails (`MAC verification failed`, `Unknown format`) | Wrong password in secret 3, secret 2 is not base64 of the `.p12`, or an OpenSSL 3 `.p12`. Redo the throwaway-keychain check in 1.2 and re-export from Keychain Access. |
| gate: Sign and notarize | `codesign: … no identity found` or `ambiguous` | Secret 1 does not match the certificate name in the `.p12`, or the `.p12` holds two certificates with the same name. Export only the one identity. |
| gate: Sign and notarize | `cannot read the team id from DEVELOPER_ID_APP` | Secret 1 is a SHA-1 hash or lacks the `(<TEAMID>)` suffix. Use the full name. |
| gate: Sign and notarize | `is not signed by a Developer ID Application certificate` | The `.p12` holds an *Apple Development* or *Apple Distribution* certificate. Make a Developer ID Application certificate (1.2). |
| gate: Sign and notarize | `notarization returned … (exit …)` with an HTTP 401/403 | Secret 6 is the PEM text instead of base64, the key was revoked, the Key ID and Issuer ID belong to different keys, or the key's role is too low. |
| gate: Sign and notarize | `notarization returned Invalid` | The script prints `notarytool log`. Fix what it names; the usual causes are a missing secure timestamp or hardened runtime, which the script already checks for. |
| gate: Sign and notarize | `Gatekeeper does not accept <name> as notarized` | Ticket propagation took longer than 60 s. Re-run the failed job. |
| gate: Sign and notarize | `RVApprovals.app left unsigned` warning | Secret 7 is missing or empty. The run still passes. Set it and re-run; do not publish such a release once section 5 is done. |
| gate: proofs | C hook or host-attach proof fails only on a signed stage | Not verified here: these proofs have never run against a signed stage. Read the proof log; this is a pipeline bug, not a credential problem. |
| sequoia-smoke | `is not hardened Developer ID code` or Gatekeeper rejects | Should not happen if gate passed. Re-run once for ticket propagation; otherwise compare with 4.1–4.2 on the downloaded `rv-<tag>` artifact. |
| linux | glibc floor or stage smoke fails | Not related to signing; see the step's message. |
| install-smoke (darwin) | `refusing to install: some release files are signed and some are not` | Only once a team is pinned: a file, usually `RVApprovals.app`, was not signed. Fix secret 7. |
| publish: Sign SHA256SUMS | `the signing key does not match install.sh's release_ssh_allowed_signers pin` | Secret 8 is not the key the pin names. Store the right key (2.8). |
| publish: Sign SHA256SUMS | `ssh-keygen` asks for or rejects a passphrase, or `invalid format` | The key is encrypted, or secret 8 was stored as base64. Make an unencrypted key (1.6) and store the raw file. |
| publish: create release | `gh release` error | Re-run the failed job: upload uses `--clobber`, so a second run replaces assets. |
| curl-e2e | Live install fails right after publish | CDN or redirect lag at `rykanv.com`. Re-run after a few minutes. If it fails on signature checks, the published assets differ from what install-smoke tested; run section 4 on the release. |

If a broken release is already published and is "latest", stop new installs
by marking it a pre-release (the "latest" link then falls back to the
previous release), then fix and ship the next patch version. Do not move a
tag that has been published.

```bash
gh release edit v<X.Y.Z> --prerelease --repo christopherkarani/rv
```

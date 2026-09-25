# macOS 15 Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Darwin binaries so they launch and evaluate on macOS 15.0 (Sequoia) Apple Silicon, and keep working on macOS 26 and 27.

**Architecture:** Keep the Swift 6.4 compiler and the macOS 26/27 SDK. Lower the deployment target to macOS 15.0. The C hook, `rv-cli`, `rvd`, and `rv-workspace-host` all get `minos 15.0`. Foundation Models stays a macOS 26 runtime feature and keeps failing closed on 15. Linux is unchanged. The compiler stays on a macOS 26 host; Sequoia only executes the binaries.

**Tech Stack:** Swift 6.4 (`swift-tools-version: 6.4`, language mode `.v6`), clang C11, SwiftPM `platforms`, `vtool` load commands, GitHub Actions `macos-26` (build) and `macos-15` (smoke).

## Global Constraints

- Base branch is `compat/macos-15`, cut from `origin/main` at `d77a8da560a86e7672ff90242d6b0e848100cb50`. Do not merge other open PR branches into it.
- Darwin floor is macOS 15.0, `arm64` only. Intel stays refused.
- macOS 26 and 27 stay supported. Install accepts a Darwin major version greater than or equal to 15.
- Linux floor stays aarch64 and x86_64. No Linux behavior change.
- Swift pin stays `.swift-version` `6.4`. Do not drop the tools version to run the compiler on Sequoia.
- Swift 6.4 / Xcode 27 compiles on macOS 26.6 or newer. Do not install that toolchain on the `macos-15` runner.
- Foundation Models stays `#available(macOS 26, *)` / `@available(macOS 26, *)`. On macOS 15, `FoundationModelsEnglishCompiler.compile` throws `EnglishCompilerError.unavailable` and `FoundationModelsActionReviewer.review` throws `ActionReviewerError.unsupported`. Do not stub an allow.
- Hook evaluation, Seatbelt launch, XPC, and `install.sh` must work on macOS 15. The on-device model is the only Darwin feature that stays 26-only.
- Advertised refuse string, everywhere it is user-facing or asserted, is exactly: `macOS 15 Apple Silicon, or Linux aarch64/x86_64`.
- Clang deployment flag, everywhere a Darwin C binary is built, is exactly: `-mmacosx-version-min=15.0`.
- Do not vendor `libswiftCore.dylib` into `~/.local/bin`.

---

### Task 1: Lower the SwiftPM deployment target

**Files:**
- Create: `Tests/RVCLITests/DarwinFloorTests.swift`
- Modify: `Package.swift:200-204`

**Interfaces:**
- Consumes: nothing
- Produces: package platform `.macOS(.v15)`, which makes SwiftPM pass `-target arm64-apple-macosx15.0` for every Darwin product

- [ ] **Step 1: Write the failing floor test**

```swift
import Foundation
import Testing

@Test func packageDeclaresMacOS15() throws {
    let package = try String(contentsOf: repoRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(package.contains(".macOS(.v15)"))
    #expect(package.contains(".macOS(.v26)") == false)
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `Scripts/swift-6.4 test --filter DarwinFloorTests.packageDeclaresMacOS15`

Expected: FAIL because `Package.swift` contains `.macOS(.v26)`.

- [ ] **Step 3: Set the platform**

In `Package.swift`, replace the platforms block with:

```swift
    platforms: [
        .macOS(.v15),
    ],
```

- [ ] **Step 4: Re-run the floor test**

Run: `Scripts/swift-6.4 test --filter DarwinFloorTests.packageDeclaresMacOS15`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/RVCLITests/DarwinFloorTests.swift
git commit -m "$(cat <<'EOF'
build: set the Darwin deployment target to macOS 15

EOF
)"
```

---

### Task 2: Make the Swift 6.4 Darwin build typecheck at macOS 15

**Files:**
- Modify: `Package.swift` (RVPolicy linker settings only if Step 2 emits the FoundationModels module error)
- Modify: whichever Swift files the compiler names. Known call sites that must stay gated, not deleted:
  - `Sources/RVPolicy/FoundationModelsEnglishCompiler.swift`
  - `Sources/RVPolicy/FoundationModelsActionReviewer.swift`

**Interfaces:**
- Consumes: `.macOS(.v15)` from Task 1
- Produces: `Scripts/swift-6.4 build -c release --product rv` exits 0 on a macOS 26 host

`Synchronization.Mutex` shipped in macOS 15, so those imports stay as they are. `posix_spawn_file_actions_addinherit_np` and `posix_spawn_file_actions_addchdir` are older than macOS 15. `hdiutil` / `diskutil` ram-disk mounts in `WorkspaceInodeBoundary.swift` need no source change for this floor.

- [ ] **Step 1: Build the operator binary**

Run: `Scripts/swift-6.4 build -c release --product rv`

Expected on the first run: either success, or availability diagnostics. A success with no source edits is the preferred outcome. The live Foundation Models calls are already inside `#available(macOS 26, *)`.

- [ ] **Step 2: If the compiler rejects the FoundationModels module, weak-link it**

Apply this only when the diagnostic is `compiling for macOS 15.0, but module 'FoundationModels' has a minimum deployment target of macOS 26.0` (or the import line is reported unavailable).

In the Darwin `#else` branch of `Package.swift` (the branch that already sets `policyTargetDependencies` to `["RVDomain"]`), add:

```swift
let policyLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"],
        .when(platforms: [.macOS])
    ),
]
```

In the Linux `#if os(Linux)` branch, add the empty counterpart so both branches define the name:

```swift
let policyLinkerSettings: [LinkerSetting] = []
```

Pass it on the RVPolicy target:

```swift
    .target(
        name: "RVPolicy",
        dependencies: policyTargetDependencies,
        linkerSettings: policyLinkerSettings
    ),
```

Leave every `#available(macOS 26, *)` and `@available(macOS 26, *)` in the two Foundation Models files. Do not `dlopen` the framework.

- [ ] **Step 3: Fix any other availability diagnostic by guarding the use**

For each remaining diagnostic, wrap that call in the availability the compiler prints. Example shape, using the OS version from the diagnostic (`N` is that version, not a guess):

```swift
if #available(macOS N, *) {
    // the call the compiler rejected
} else {
    // the existing typed failure for that feature
}
```

Use `EnglishCompilerError.unavailable` or `ActionReviewerError.unsupported` for the model path. For any other API, use the failure that feature already returns when it cannot run. Do not raise `.macOS(.v15)`.

- [ ] **Step 4: Rebuild release products**

Run:

```bash
Scripts/swift-6.4 build -c release --product rv
Scripts/swift-6.4 build -c release --product rvd
Scripts/swift-6.4 build -c release --product rv-workspace-host
```

Expected: all three exit 0.

- [ ] **Step 5: Confirm the load command**

Run: `vtool -show-build "$(Scripts/swift-6.4 build -c release --show-bin-path)/rv"`

Expected: a `LC_BUILD_VERSION` block containing `platform MACOS` and `minos 15.0`. The `sdk` line may be 26 or 27. `minos` must be `15.0`.

Repeat for `rvd` and `rv-workspace-host` in that same bin directory.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/RVPolicy
git commit -m "$(cat <<'EOF'
build: typecheck Darwin products against the macOS 15 deployment target

EOF
)"
```

If Step 2 and Step 3 changed no files, skip this commit.

---

### Task 3: Accept macOS 15 in the installer

**Files:**
- Modify: `install.sh:1-27`
- Modify: `Tests/RVCLITests/InstallScriptTests.swift:235-283`
- Modify: `Tests/RVCLITests/DarwinFloorTests.swift`

**Interfaces:**
- Consumes: the refuse string from Global Constraints
- Produces: `install.sh` exits 0 for Darwin product versions `15.0`, `15.6`, `26.0`, `26.1`, `27.0` on arm64, and exits 1 for `14.6`, `14.0`, and an empty version

- [ ] **Step 1: Update the installer tests first**

In `Tests/RVCLITests/InstallScriptTests.swift`:

Replace the Windows assertion string `macOS 26 Apple Silicon, or Linux aarch64/x86_64` with `macOS 15 Apple Silicon, or Linux aarch64/x86_64`.

Replace the accept test with:

```swift
@Test(arguments: ["15.0", "15.6", "26.0", "26.1", "27.0"])
func installSh_acceptsDarwinMacOS15OrNewer(_ productVersion: String) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-darwin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim, productVersion: productVersion)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 0)
    #expect(
        FileManager.default.isExecutableFile(
            atPath: home.appendingPathComponent(".local/bin/rv").path
        )
    )
}
```

Replace the refuse test with:

```swift
@Test(arguments: ["14.6", "14.0", ""])
func installSh_refusesOlderMacOS(_ productVersion: String) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-install-oldmac-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try writeDummyTrio(in: src)

    let shim = root.appendingPathComponent("shim", isDirectory: true)
    try writeDarwinShims(in: shim, productVersion: productVersion)

    let result = try runInstallScript(home: home, src: src, pathPrefix: shim.path)
    #expect(result.status == 1)
    #expect(result.stderr.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/rv") == false)
}
```

Add this test to `Tests/RVCLITests/DarwinFloorTests.swift`:

```swift
@Test func installScriptRequiresMacOS15() throws {
    let install = try String(contentsOf: repoRoot().appendingPathComponent("install.sh"), encoding: .utf8)
    #expect(install.contains("[ \"$major\" -ge 15 ]"))
    #expect(install.contains("[ \"$major\" -ge 26 ]") == false)
    #expect(install.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    #expect(install.contains("macOS 26 Apple Silicon") == false)
}
```

- [ ] **Step 2: Run the installer tests and confirm they fail**

Run: `Scripts/swift-6.4 test --filter installSh_ --filter DarwinFloorTests.installScriptRequiresMacOS15`

Expected: FAIL. The script still refuses major versions below 26 and still prints the macOS 26 string. `15.0` and `15.6` are the new failures that matter.

- [ ] **Step 3: Lower the installer gate**

Replace the header comment and `refuse` body in `install.sh`:

```sh
# Darwin: macOS 15 or newer + arm64. Linux: aarch64 or x86_64. No Windows.
```

```sh
refuse() {
  echo "rv: macOS 15 Apple Silicon, or Linux aarch64/x86_64" >&2
  exit 1
}
```

Replace the Darwin major check:

```sh
    [ "$major" -ge 15 ] || refuse
```

Major `15`, `26`, and `27` all pass that integer compare. macOS never shipped 16 through 25, so no extra range is required.

- [ ] **Step 4: Re-run the installer tests**

Run: `Scripts/swift-6.4 test --filter installSh_ --filter DarwinFloorTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add install.sh Tests/RVCLITests/InstallScriptTests.swift Tests/RVCLITests/DarwinFloorTests.swift
git commit -m "$(cat <<'EOF'
install: accept macOS 15 Apple Silicon

EOF
)"
```

---

### Task 4: Compile every C hook at macOS 15

**Files:**
- Modify: `Scripts/release.sh:53` and `Scripts/release.sh:65`
- Modify: `Scripts/c-hook-proof.sh:36`, `Scripts/c-hook-proof.sh:45`, `Scripts/c-hook-proof.sh:740`, `Scripts/c-hook-proof.sh:851`
- Modify: `Scripts/host-attach-proof.sh:177`
- Modify: `Sources/rv-c/tests/run.sh:18` and `Sources/rv-c/tests/run.sh:30`
- Modify: `Tests/RVCLITests/DarwinFloorTests.swift`

**Interfaces:**
- Consumes: the clang flag from Global Constraints
- Produces: Darwin C binaries whose `vtool` output contains `minos 15.0`

- [ ] **Step 1: Extend the floor test**

Add to `Tests/RVCLITests/DarwinFloorTests.swift`:

```swift
@Test func clangDeploymentTargetIsMacOS15() throws {
    let root = repoRoot()
    let paths = [
        "Scripts/release.sh",
        "Scripts/c-hook-proof.sh",
        "Scripts/host-attach-proof.sh",
        "Sources/rv-c/tests/run.sh",
    ]
    for path in paths {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        #expect(text.contains("-mmacosx-version-min=15.0"), "\(path) must target macOS 15")
        #expect(text.contains("-mmacosx-version-min=26.0") == false, "\(path) still targets macOS 26")
    }
    let release = try String(contentsOf: root.appendingPathComponent("Scripts/release.sh"), encoding: .utf8)
    #expect(release.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    let units = try String(contentsOf: root.appendingPathComponent("Sources/rv-c/tests/run.sh"), encoding: .utf8)
    #expect(units.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
    let proof = try String(contentsOf: root.appendingPathComponent("Scripts/c-hook-proof.sh"), encoding: .utf8)
    #expect(proof.contains("macOS 15 Apple Silicon, or Linux aarch64/x86_64"))
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `Scripts/swift-6.4 test --filter DarwinFloorTests.clangDeploymentTargetIsMacOS15`

Expected: FAIL on `-mmacosx-version-min=26.0`.

- [ ] **Step 3: Replace the four Darwin clang sites**

In each file, replace every `-mmacosx-version-min=26.0` with `-mmacosx-version-min=15.0`.

Replace every `macOS 26 Apple Silicon, or Linux aarch64/x86_64` in those three scripts (`Scripts/release.sh`, `Scripts/c-hook-proof.sh`, `Sources/rv-c/tests/run.sh`) with `macOS 15 Apple Silicon, or Linux aarch64/x86_64`.

`Scripts/host-attach-proof.sh` has the clang flag only. Leave its proof IDs (`AC-ATTACH-GROK-DENY` and the rest) untouched.

- [ ] **Step 4: Re-run the floor test and the C units**

Run:

```bash
Scripts/swift-6.4 test --filter DarwinFloorTests
Sources/rv-c/tests/run.sh
vtool -show-build .build/rv-c-tests/json_escape_test
```

Expected: the Swift test passes, the C unit script exits 0, and `vtool` shows `minos 15.0`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/release.sh Scripts/c-hook-proof.sh Scripts/host-attach-proof.sh Sources/rv-c/tests/run.sh Tests/RVCLITests/DarwinFloorTests.swift
git commit -m "$(cat <<'EOF'
build: compile the C hook for macOS 15

EOF
)"
```

---

### Task 5: Refuse a Darwin release whose minos is not 15.0

**Files:**
- Modify: `Scripts/release.sh` (after the Swift products are copied into the stage)

**Interfaces:**
- Consumes: staged paths `$STAGE/rv`, `$STAGE/rv-cli`, `$STAGE/rvd`, `$STAGE/rv-workspace-host`
- Produces: `Scripts/release.sh` exits non-zero on Darwin unless each of those four binaries has `minos 15.0`

- [ ] **Step 1: Add the check before the final `Staged` printf**

Insert this immediately above `printf "Staged %s\n" "$STAGE"` in `Scripts/release.sh`:

```bash
if [[ "$OS" == "Darwin" ]]; then
  for staged in "$STAGE/rv" "$STAGE/rv-cli" "$STAGE/rvd" "$STAGE/rv-workspace-host"; do
    show="$(vtool -show-build "$staged")"
    printf '%s\n' "$show" | grep -q 'minos 15.0' || {
      printf 'release: %s minos is not 15.0\n%s\n' "$staged" "$show" >&2
      exit 1
    }
  done
  if otool -L "$STAGE/rv-cli" | grep -E 'libswiftCore|FoundationModels' | grep -q '@rpath'; then
    printf 'release: rv-cli must link the OS Swift runtime, not an @rpath toolchain\n' >&2
    otool -L "$STAGE/rv-cli" >&2
    exit 1
  fi
fi
```

`rv-cli` linking `@rpath/libswiftCore.dylib` would launch only on a machine that has the Swift 6.4 toolchain. The OS copy is `/usr/lib/swift/libswiftCore.dylib`. FoundationModels may appear as a weak system framework; it must not appear as an `@rpath` copy.

- [ ] **Step 2: Run the release stage**

Run: `Scripts/release.sh`

Expected: exit 0, and the four staged binaries each show `minos 15.0`:

```bash
vtool -show-build .build/release-stage/rv
vtool -show-build .build/release-stage/rv-cli
vtool -show-build .build/release-stage/rvd
vtool -show-build .build/release-stage/rv-workspace-host
```

- [ ] **Step 3: Commit**

```bash
git add Scripts/release.sh
git commit -m "$(cat <<'EOF'
build: fail the Darwin release unless minos is 15.0

EOF
)"
```

---

### Task 6: Execute the staged binaries on macOS 15

**Files:**
- Modify: `.github/workflows/pr.yml` (comment above `hook-grade`, upload step, new job)
- Modify: `.github/workflows/release.yml` (new job)
- Modify: `README.md:13` and `README.md:54`

**Interfaces:**
- Consumes: `.build/release-stage` produced by `Scripts/release.sh` on `macos-26`
- Produces: a `macos-15` job that loads `rv-cli`, `rvd`, and `rv-workspace-host` and runs the C unit script with the system clang

The existing `hook-grade` job stays on `runs-on: macos-26`. That is the compiler host. `HostAttachProofTests` requires the job name `macos hook grade` and at least two `Scripts/host-attach-proof.sh` steps in `pr.yml`. Do not rename that job. The new job does not run the host-attach proof.

- [ ] **Step 1: Upload the stage from hook-grade**

In `.github/workflows/pr.yml`, change the comment above `hook-grade` to:

```yaml
  # Compiler host is macos-26. Advertised Darwin floor is macOS 15.
  # sequoia-smoke executes the staged binaries; it does not compile Swift.
```

At the end of the `hook-grade` steps, after `Isolated-HOME host attach`, add:

```yaml
      - uses: actions/upload-artifact@v4
        with:
          name: rv-macos-stage
          path: |
            .build/release-stage/rv
            .build/release-stage/rv-cli
            .build/release-stage/rvd
            .build/release-stage/rv-workspace-host
            .build/release-stage/*_RVPacks.bundle
          if-no-files-found: error
```

- [ ] **Step 2: Add the Sequoia smoke job to PR CI**

Append this job to `.github/workflows/pr.yml`:

```yaml
  sequoia-smoke:
    name: macos 15 smoke
    runs-on: macos-15
    needs: hook-grade
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: rv-macos-stage
          path: stage

      - name: Load commands are macOS 15
        run: |
          set -euo pipefail
          for bin in stage/rv stage/rv-cli stage/rvd stage/rv-workspace-host; do
            chmod 755 "$bin"
            show="$(vtool -show-build "$bin")"
            printf '%s\n' "$show" | grep -q 'minos 15.0' || {
              printf 'sequoia: %s minos is not 15.0\n%s\n' "$bin" "$show" >&2
              exit 1
            }
          done

      - name: Swift binaries load on Sequoia
        run: |
          set -euo pipefail
          stage/rv-cli --help > /tmp/rv-cli-help.txt
          grep -q 'setup' /tmp/rv-cli-help.txt
          stage/rvd --version > /tmp/rvd-version.txt
          grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' /tmp/rvd-version.txt
          set +e
          stage/rv-workspace-host > /tmp/rv-host-usage.txt 2>&1
          host_status=$?
          set -e
          test "$host_status" -eq 2
          grep -q 'usage: rv-workspace-host --workspace' /tmp/rv-host-usage.txt
          # `rv test` exits 1 on a deny. Robot JSON is rv.test.v1 and does not echo the command.
          set +e
          stage/rv-cli test --robot 'git reset --hard' > /tmp/rv-test.json 2> /tmp/rv-test.err
          test_status=$?
          set -e
          test "$test_status" -eq 0 -o "$test_status" -eq 1
          grep -q 'rv.test.v1' /tmp/rv-test.json
          if grep -E 'Symbol not found|Library not loaded' /tmp/rv-test.err; then
            exit 1
          fi

      - name: C units on the Sequoia clang
        run: Sources/rv-c/tests/run.sh
```

`rv-cli test` evaluates in process and does not start `rvd`. `rvd --version` returns before `RVDProcess.run`. `rv-workspace-host` with no arguments exits `WorkspaceHostExit.unsupported` (`2`) before `setsid`.

- [ ] **Step 3: Run the same smoke on release tags**

Append to `.github/workflows/release.yml`, and add `contents: read` is already set. The `gate` job already uploads `rv-${{ github.ref_name }}`. Add:

```yaml
  sequoia-smoke:
    name: macos 15 smoke
    runs-on: macos-15
    needs: gate
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: rv-${{ github.ref_name }}
          path: stage

      - name: Load commands are macOS 15
        run: |
          set -euo pipefail
          for bin in stage/rv stage/rv-cli stage/rvd stage/rv-workspace-host; do
            chmod 755 "$bin"
            show="$(vtool -show-build "$bin")"
            printf '%s\n' "$show" | grep -q 'minos 15.0' || {
              printf 'sequoia: %s minos is not 15.0\n%s\n' "$bin" "$show" >&2
              exit 1
            }
          done

      - name: Swift binaries load on Sequoia
        run: |
          set -euo pipefail
          stage/rv-cli --help > /tmp/rv-cli-help.txt
          grep -q 'setup' /tmp/rv-cli-help.txt
          stage/rvd --version > /tmp/rvd-version.txt
          grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' /tmp/rvd-version.txt
          set +e
          stage/rv-workspace-host > /tmp/rv-host-usage.txt 2>&1
          host_status=$?
          set -e
          test "$host_status" -eq 2
          grep -q 'usage: rv-workspace-host --workspace' /tmp/rv-host-usage.txt
          # `rv test` exits 1 on a deny. Robot JSON is rv.test.v1 and does not echo the command.
          set +e
          stage/rv-cli test --robot 'git reset --hard' > /tmp/rv-test.json 2> /tmp/rv-test.err
          test_status=$?
          set -e
          test "$test_status" -eq 0 -o "$test_status" -eq 1
          grep -q 'rv.test.v1' /tmp/rv-test.json
          if grep -E 'Symbol not found|Library not loaded' /tmp/rv-test.err; then
            exit 1
          fi
```

- [ ] **Step 4: Update the README platform line**

Replace the badge image tag with:

```html
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20arm64%20%7C%20Linux-111827" alt="macOS 15 or newer, Apple Silicon, and Linux">
```

Replace the platform table cell with:

```markdown
| Platform | macOS 15 or newer, Apple Silicon. Linux aarch64/x86_64. Foundation Models on macOS 26 or newer. PR CI builds Swift on macos-26 and smokes the binaries on macos-15. Linux PR CI is ubuntu-24.04 x86_64; aarch64 is a supported install, not a PR job. |
```

- [ ] **Step 5: Run the local locks**

Run:

```bash
Scripts/swift-6.4 test --filter DarwinFloorTests
Scripts/swift-6.4 test --filter HostAttachProofTests
Scripts/swift-6.4 test --filter installSh_
```

Expected: PASS. `HostAttachProofTests` still sees `name: macos hook grade` and at least two `Scripts/host-attach-proof.sh` steps.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/pr.yml .github/workflows/release.yml README.md
git commit -m "$(cat <<'EOF'
ci: smoke Darwin release binaries on macOS 15

EOF
)"
```

---

### Task 7: Record what Sequoia does not prove

**Files:**
- Modify: `README.md` only if Task 6 left the platform cell short of the model caveat. No new doc file.

**Interfaces:**
- Consumes: the Sequoia job from Task 6
- Produces: a written residual, in the PR body when this branch opens, not a second markdown plan

- [ ] **Step 1: Confirm the model path still fails closed without the framework**

Run: `Scripts/swift-6.4 test --filter FoundationModels`

Expected: existing policy tests pass. They inject `usesSystemModel = false` or a fake compiler. They do not require a live on-device model, so they pass on a macOS 26 host and do not claim Sequoia ran the model.

- [ ] **Step 2: Write the PR residual**

When the PR opens, the body states these limits in this order:

1. macOS 15 runs hook evaluation, install, the C hook, `rvd --version`, and `rv-cli test`.
2. Foundation Models throws `unavailable` / `unsupported` on macOS 15. The model framework is not on that OS.
3. The full Seatbelt, ram-disk, and host-attach proofs still run on the `macos-26` compiler host. The Sequoia job proves those binaries load and that `minos` is 15.0. It does not re-run `Scripts/host-attach-proof.sh`.
4. If Sequoia aborts with `Symbol not found` in `libswiftCore.dylib`, stop. Do not copy the toolchain's Swift libraries into the stage. Fix the emitting API or the link line, then re-run Task 5 and Task 6.

- [ ] **Step 3: No commit unless a README sentence was still wrong**

If Step 1 only re-ran tests, do not create an empty commit.

---

## Self-review

- Spec coverage: deployment target (Task 1), Swift availability including Foundation Models (Task 2), installer (Task 3), C hook (Task 4), release `minos` gate (Task 5), Sequoia execution plus README (Task 6), residual limits (Task 7).
- Linux, Intel, and the Swift 6.4 pin are constrained above and have no tasks that change them.
- `@available(macOS 26, *)` on the model types stays. The banned string is `macOS 26 Apple Silicon` and `-mmacosx-version-min=26.0`, which the floor tests lock.
- Placeholder scan: no TBD steps. The weak-link edit is conditional on a named diagnostic. Other availability fixes use the version the compiler prints.

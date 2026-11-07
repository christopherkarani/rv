# Fuzzing

rv fuzzes the three parsers that see attacker-shaped bytes first:

| Harness | Parser | In-suite twin |
| --- | --- | --- |
| `rv-fuzz-gateway-request` (`Fuzz/GatewayRequest`) | Secret gateway request head, route, body framing, socket head/chunk reader | `RVIsolationTests` `GatewayRequestFuzzTests` |
| `rv-fuzz-tls-client-hello` (`Fuzz/TLSClientHello`) | Egress proxy ClientHello record reader, SNI `tlsServerName`, `checkSNI`, CONNECT / absolute-URI request lines | `RVIsolationTests` `ClientHelloFuzzTests` |
| `rv-fuzz-normalize` (`Fuzz/Normalize`) | `Normalize`, pin `evaluate`, and the door `evaluateWithSemantics` over day-one packs | `RVCorpusTests` `NormalizeFuzzTests` |

Each harness traps on a crash and on a broken invariant: a parsed gateway
head must reparse to itself and its route must stay on the binding's host;
a server name must not change when bytes follow the record; a command past
the byte cap is indeterminate; and a denied command on line one stays
non-allow whatever later lines hold (bash runs line one before it parses
line two).

## In the test suite

The twins are seeded, fixed-iteration mutation runs over the corpora in
`Tests/RVEngineTests/Fixtures/corpus` and generated ClientHellos. They run
with `swift test` on every platform and finish in seconds. For a longer
or different run:

```sh
RV_FUZZ_SEED=42 RV_FUZZ_ITERATIONS=200000 swift test --filter 'Fuzz'
```

A failure message names the seed and the input as `base64:…`.

## libFuzzer

The harnesses are only in the package graph when `RV_FUZZ=1`. They need a
toolchain that ships the libFuzzer runtime:

- Linux: the swift.org Swift 6.4 tarball does.
- macOS: the swift.org 6.4 `.xctoolchain` does (`libclang_rt.fuzzer_osx.a`);
  Xcode's toolchain does not. Use `Scripts/swift-6.4`, and set `SDKROOT`
  so the swift.org driver finds the macOS SDK (`ld: library 'c++' not
  found` otherwise).

They use `@testable import`, so build them in debug. Build one product at
a time; `-sanitize=fuzzer` supplies `main`.

```sh
RV_FUZZ=1 SDKROOT="$(xcrun --show-sdk-path)" Scripts/swift-6.4 build \
  --product rv-fuzz-normalize -Xswiftc -sanitize=fuzzer,address --scratch-path .build/fuzz
mkdir -p .build/fuzz-corpus/normalize
.build/fuzz/debug/rv-fuzz-normalize .build/fuzz-corpus/normalize -max_total_time=60
```

On Linux drop `SDKROOT`. The two `RVIsolation` harnesses run several
hundred thousand inputs a minute; `rv-fuzz-normalize` evaluates every
input twice through both doors and runs a few thousand. Seed its corpus
directory with the `command` strings from
`Tests/RVEngineTests/Fixtures/corpus/*.json` for a faster start (the
workflow's "Seed corpus" step does this); the other two start from
`Fuzz/<Harness>/seeds`. Pass `-dict=Fuzz/Normalize/shell.dict` or
`-dict=Fuzz/GatewayRequest/http.dict`, and a `-max_len` past the parser's
cap (CI uses 70000 for normalize, so commands over the 65,536-byte
`commandByteCap` are generated).

Leak detection is Linux-only: LeakSanitizer is not supported with
AddressSanitizer on macOS. On Linux, pass
`LSAN_OPTIONS=suppressions=$PWD/Fuzz/lsan.supp`. It suppresses only
`_CFRegularExpressionCreate`: LeakSanitizer reports corelibs Foundation's
ICU regex allocation as leaked even while its `NSRegularExpression` is
alive (the normalize harness's compiled packs, Foundation's pattern cache).
Any other leak fails the run.

Replace `normalize` with `gateway-request` or `tls-client-hello`. Pass a
crash file instead of a directory to replay it:
`.build/fuzz/debug/rv-fuzz-normalize crash-<sha>`.

A crash in gate verdict logic gets a failing regression test first (the
corpus under `Tests/RVEngineTests/Fixtures/corpus` or a case in the twin
suite), then a fix in its own PR.

Open finding: heredoc masking blanks the first occurrence of the body text
anywhere in the command, so `git reset --hard` followed by a heredoc whose
body is `git` is allowed. `NormalizeFuzzTests.heredocBodyRepeatingAnEarlierWordDoesNotHideIt`
holds it as a known issue. Until it is fixed the twin reports allows of
that exact shape (a line after a `<<` opener whose text already occurs
earlier in the command) as a known issue, and `rv-fuzz-normalize` skips
only those inputs in the fail-closed check; every other heredoc and
here-string input is still checked.

CI runs each harness for 60 seconds on Linux in the `fuzz` workflow. It is
not a required check.

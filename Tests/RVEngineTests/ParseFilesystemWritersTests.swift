import Testing
import RVDomain
@testable import RVEngine

@Suite("Parse filesystem writers (Step 8B P10c)")
struct ParseFilesystemWritersTests {
    @Test func cp_lastOperandIsDestination() {
        expectWriterParsed(parseCp(["a", "/tmp/x"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(parseCp(["-r", "src", "dst"]), "overwrite", paths: ["dst"])
        expectWriterParsed(
            parseCp(["--reflink=always", "a", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["cp", "a", "b"]),
            "overwrite",
            paths: ["b"]
        )
        #expect(parseCp(["only"]) == nil)
        #expect(parseCp([]) == nil)
        #expect(parseCp(["--help"]) == nil)
        #expect(parseCp(["-z", "a", "b"]) == nil)
    }

    @Test func cp_targetDirectoryOverride() {
        expectWriterParsed(parseCp(["-t", "/tmp/x", "a", "b"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(
            parseCp(["--target-directory=/tmp/x", "a", "b"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseCp(["--target-directory", "/tmp/x", "a", "b"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(parseCp(["-vt/tmp/x", "a"]), "overwrite", paths: ["/tmp/x"])
        // After `--`, `-t` is an operand, not a flag.
        expectWriterParsed(parseCp(["--", "-t", "dst"]), "overwrite", paths: ["dst"])
    }

    @Test func mv_targetDirectoryOverride() {
        expectWriterParsed(parseMv(["-t", "/tmp/x", "a", "b"]), "move", paths: ["a", "b", "/tmp/x"])
        expectWriterParsed(
            parseMv(["--target-directory=/tmp/x", "a"]),
            "move",
            paths: ["a", "/tmp/x"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["mv", "-t", "/tmp/x", "a", "b"]),
            "move",
            paths: ["a", "b", "/tmp/x"]
        )
    }

    @Test func tee_everyOperandIsDestination() {
        expectWriterParsed(parseTee(["/tmp/x"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(
            parseTee(["-a", "/tmp/a", "/tmp/b"]),
            "overwrite",
            paths: ["/tmp/a", "/tmp/b"]
        )
        #expect(parseTee([]) == nil)
        #expect(parseTee(["--help", "/tmp/x"]) == nil)
        #expect(parseTee(["-z", "/tmp/x"]) == nil)
    }

    @Test func install_fileAndDirectoryModes() {
        expectWriterParsed(parseInstall(["a", "/tmp/x"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(
            parseInstall(["-m", "755", "a", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseInstall(["-t", "/tmp/x", "a", "b"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(parseInstall(["-d", "sub", "/tmp/x"]), "create", paths: ["sub", "/tmp/x"])
        expectWriterParsed(
            parseInstall(["-d", "-t", "/tmp/x", "a"]),
            "create",
            paths: ["/tmp/x"]
        )
        #expect(parseInstall(["only"]) == nil)
        #expect(parseInstall(["--help"]) == nil)
    }

    @Test func ln_destinationAndSingleOperandCwd() {
        expectWriterParsed(parseLn(["-s", "a", "/tmp/x"]), "create", paths: ["/tmp/x"])
        expectWriterParsed(parseLn(["-s", "a"]), "create", paths: ["."])
        expectWriterParsed(parseLn(["-t", "/tmp/x", "a"]), "create", paths: ["/tmp/x"])
        #expect(parseLn([]) == nil)
        #expect(parseLn(["--help"]) == nil)
        #expect(parseLn(["-z", "a", "b"]) == nil)
    }

    @Test func rsync_lastOperandAuxAndRemote() {
        expectWriterParsed(parseRsync(["a", "/tmp/x"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(parseRsync(["-avz", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(
            parseRsync(["--log-file=/tmp/x.log", "a", "b"]),
            "overwrite",
            paths: ["/tmp/x.log", "b"]
        )
        expectWriterParsed(
            parseRsync(["-T", "/tmp/t", "a", "b"]),
            "overwrite",
            paths: ["/tmp/t", "b"]
        )
        expectWriterParsed(parseRsync(["a", "host:/x"]), "overwrite", paths: ["/"])
        expectWriterParsed(
            parseRsync(["a", "rsync://h/mod"]),
            "overwrite",
            paths: ["/"]
        )
        // Slash before colon is a local path, matching rsync's own rule.
        expectWriterParsed(parseRsync(["a", "./b:c"]), "overwrite", paths: ["./b:c"])
        #expect(parseRsync(["-n", "a", "/tmp/x"]) == nil)
        #expect(parseRsync(["--dry-run", "a", "/tmp/x"]) == nil)
        #expect(parseRsync(["--list-only", "a"]) == nil)
        #expect(parseRsync([]) == nil)
    }

    @Test func rsync_dryRunStillWritesLogAndBatch() {
        // `--log-file` and `--write-batch` write even under a dry run.
        expectWriterParsed(
            parseRsync(["-n", "--log-file=/tmp/evil", "a", "b"]),
            "overwrite",
            paths: ["/tmp/evil"]
        )
        expectWriterParsed(
            parseRsync(["--dry-run", "--log-file", "/tmp/evil", "a", "b"]),
            "overwrite",
            paths: ["/tmp/evil"]
        )
        expectWriterParsed(
            parseRsync(["-n", "--write-batch=/tmp/b", "a", "b"]),
            "overwrite",
            paths: ["/tmp/b"]
        )
        expectWriterParsed(
            parseRsync(["--list-only", "--write-batch", "/tmp/b", "a"]),
            "overwrite",
            paths: ["/tmp/b"]
        )
        // Non-dry-run batch also collects.
        expectWriterParsed(
            parseRsync(["--write-batch=/tmp/b", "a", "b"]),
            "overwrite",
            paths: ["/tmp/b", "b"]
        )
    }

    @Test func tar_createExtractList() {
        expectWriterParsed(
            parseTar(["-cf", "/tmp/x.tar", "a"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["-czf/tmp/x.tar", "a"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["xvf", "local.tar"]),
            "overwrite",
            paths: ["."]
        )
        expectWriterParsed(
            parseTar(["-x", "-f", "a.tar", "-C", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseTar(["--extract", "--file=a.tar", "--one-top-level=/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        #expect(parseTar(["-tzf", "a.tar"]) == nil)
        #expect(parseTar(["--list", "-f", "a.tar"]) == nil)
        #expect(parseTar(["--help"]) == nil)
    }

    @Test func tar_unboundedShapesFailClosed() {
        expectWriterParsed(parseTar(["-xPf", "a.tar"]), "overwrite", paths: ["/"])
        expectWriterParsed(
            parseTar(["-c", "-I", "gzip", "-f", "/tmp/x.tar", "a"]),
            "overwrite",
            paths: ["/"]
        )
        expectWriterParsed(
            parseTar(["-x", "-f", "a.tar", "--to-command=tee /tmp/x"]),
            "overwrite",
            paths: ["/"]
        )
        expectWriterParsed(
            parseTar(["-x", "-f", "a.tar", "--recursive-unlink"]),
            "delete",
            paths: ["."],
            recursive: true,
            force: true
        )
    }

    @Test func curl_outputDestsOnly() {
        expectWriterParsed(
            parseCurl(["-o", "/tmp/x", "http://localhost"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseCurl(["-vo/tmp/x", "http://localhost"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseCurl(["--output=/tmp/x", "http://localhost"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(parseCurl(["-O", "http://h/f"]), "overwrite", paths: ["."])
        expectWriterParsed(
            parseCurl(["-O", "--output-dir", "/tmp/x", "http://h/f"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseCurl(["--trace", "/tmp/x", "http://h"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseCurl(["--stderr", "/tmp/x", "http://h"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseCurl(["--stderr=/tmp/x", "http://h"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        #expect(parseCurl(["http://localhost"]) == nil)
        #expect(parseCurl(["-o", "-", "http://localhost"]) == nil)
        #expect(parseCurl(["--help"]) == nil)
    }

    @Test func curlOutputDirPrependsToRelativeDashO() {
        // curl man: --output-dir prepends to relative -o names too.
        // Claiming the raw relative path would resolve inside while curl
        // writes outside (fail-open); claim both (superset, fail-closed).
        expectWriterParsed(
            parseCurl(["-o", "rel", "--output-dir", "/outside", "http://h"]),
            "overwrite",
            paths: ["rel", "/outside/rel"]
        )
        // Order-insensitive superset: a dir seen anywhere applies to
        // every relative dest (curl evaluates at transfer time).
        expectWriterParsed(
            parseCurl(["--output-dir", "/outside", "-o", "rel", "http://h"]),
            "overwrite",
            paths: ["rel", "/outside/rel"]
        )
        // Absolute -o wins over --output-dir (man).
        expectWriterParsed(
            parseCurl(["-o", "/abs", "--output-dir", "/outside", "http://h"]),
            "overwrite",
            paths: ["/abs"]
        )
        // The unbounded sentinel never joins (it is absolute by shape).
        expectWriterParsed(
            parseCurl(["-K", "evil.conf", "--output-dir", "/outside", "http://h"]),
            "overwrite",
            paths: ["/"]
        )
    }

    @Test func escapedVerbStillDispatches() throws {
        // Backslash-escaped spellings execute the tool (`c\url` runs
        // curl); the tokenizer preserves backslashes, so dispatch must
        // unescape pairs before matching or the destinations are missed
        // (fail-open). A quoted literal (`'c\url'`, runtime: not-found)
        // mapping onto the tool over-claims (fail-closed).
        let curl = parseFilesystemCommand(["c\\url", "-o", "/outside/x", "http://h"])
        let curlClaim = try #require(curl)
        #expect(curlClaim.operation == .overwrite)
        #expect(curlClaim.paths == ["/outside/x"])
        let rm = parseFilesystemCommand(["\\rm", "f"])
        let rmClaim = try #require(rm)
        #expect(rmClaim.operation == .delete)
        #expect(rmClaim.paths == ["f"])
    }

    @Test func curlOutputDirStickyAcrossNext() {
        // --next transfer boundaries do not shrink the claim: every dir
        // seen joins every relative dest, so a multi-transfer command
        // can never under-claim an earlier dir.
        expectWriterParsed(
            parseCurl([
                "--output-dir", "/a", "-O", "--next",
                "--output-dir", "/b", "-o", "rel", "http://h",
            ]),
            "overwrite",
            paths: ["rel", "/a/rel", "/b/rel", "/a", "/b"]
        )
    }

    @Test func dd_ofOperandIsDestination() {
        expectWriterParsed(parseDd(["if=a", "of=/tmp/x"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(parseDd(["if=a", "of=b"]), "overwrite", paths: ["b"])
        #expect(parseDd(["if=a"]) == nil)
        #expect(parseDd(["--help"]) == nil)
    }

    @Test func redirectTargetsUnionWithWriterDests() {
        expectWriterParsed(
            parseFilesystemCommand(["cp", "a", "b", ">", "/tmp/log"]),
            "overwrite",
            paths: ["b", "/tmp/log"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["tee", "/tmp/a", ">", "/tmp/b"]),
            "overwrite",
            paths: ["/tmp/a", "/tmp/b"]
        )
        // Shell-side redirects survive verb-parse failure: the shell
        // truncated the target even though the tool errored or helped.
        expectWriterParsed(
            parseFilesystemCommand(["cp", "-z", "a", "b", ">", "/tmp/log"]),
            "overwrite",
            paths: ["/tmp/log"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["tar", "--help", ">", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["curl", "--help", ">", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["tar", "-tzf", "a.tar", ">", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["rm", "-z", "x", ">", "/tmp/log"]),
            "overwrite",
            paths: ["/tmp/log"]
        )
        // Input redirects never become destinations, but their target stays
        // visible (fail-closed over-approximation, never eaten evidence).
        expectWriterParsed(
            parseFilesystemCommand(["cp", "a", "b", "<", "/tmp/in"]),
            "overwrite",
            paths: ["/tmp/in"]
        )
    }

    @Test func redirectOperatorCoverage() {
        for op in [">", ">|", ">>", "&>", "&>>", ">&", "1>", "2>", "<>"] {
            expectWriterParsed(
                parseFilesystemCommand(["cp", "a", "b", op, "/tmp/log"]),
                "overwrite",
                paths: ["b", "/tmp/log"]
            )
        }
        for word in [">/tmp/x", "2>/tmp/x", "&>>/tmp/x", ">&/tmp/x", "<>/tmp/x"] {
            expectWriterParsed(
                parseFilesystemCommand(["cp", "a", "b", word]),
                "overwrite",
                paths: ["b", "/tmp/x"]
            )
        }
        // Dup/close words are not files and never pollute the operands.
        expectWriterParsed(
            parseFilesystemCommand(["cp", "a", "b", "2>&1"]),
            "overwrite",
            paths: ["b"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["cp", "a", "b", ">&-"]),
            "overwrite",
            paths: ["b"]
        )
    }

    @Test func cp_conflictedSuffixShort() {
        // `-S` is GNU-value / BSD-bare: attached rest reads as the suffix,
        // a separate `-S` stays bare, and the destination survives both.
        expectWriterParsed(parseCp(["-S", "suf", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseCp(["-Ssuf", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseCp(["-S=suf", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseCp(["-N", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseCp(["-Z", "a", "b"]), "overwrite", paths: ["b"])
    }

    @Test func cp_abbreviatedTargetDirectory() {
        expectWriterParsed(
            parseCp(["--targ", "/tmp/t", "a", "b"]),
            "overwrite",
            paths: ["/tmp/t"]
        )
        expectWriterParsed(
            parseCp(["--targ=/tmp/t", "a", "b"]),
            "overwrite",
            paths: ["/tmp/t"]
        )
        // Every `-t` value evaluates: last-wins needs no tracking.
        expectWriterParsed(
            parseCp(["-t", "/tmp/a", "--targ", "/tmp/b", "x", "y"]),
            "overwrite",
            paths: ["/tmp/a", "/tmp/b"]
        )
        // `-StDIR`: `-S` is bare-for-`-t` but conflicted, so the last
        // operand evaluates too (GNU reads suffix `tDIR`, dest `b`).
        expectWriterParsed(
            parseCp(["-StDIR", "a", "b"]),
            "overwrite",
            paths: ["DIR", "b"]
        )
        expectWriterParsed(
            parseCp(["-t=/tmp/t", "a", "b"]),
            "overwrite",
            paths: ["=/tmp/t"]
        )
        #expect(parseCp(["--targ"]) == nil)
    }

    @Test func ln_targetShortAndNewFlags() {
        expectWriterParsed(parseLn(["-T", "a", "b"]), "create", paths: ["b"])
        expectWriterParsed(
            parseLn(["--strip-trailing-slashes", "a", "b"]),
            "create",
            paths: ["b"]
        )
        expectWriterParsed(
            parseLn(["--targ", "/tmp/t", "a", "b"]),
            "create",
            paths: ["/tmp/t"]
        )
        // `ln -S` is purely GNU-value: `-StDIR` reads suffix `tDIR`.
        expectWriterParsed(parseLn(["-StDIR", "a", "b"]), "create", paths: ["b"])
        expectWriterParsed(parseLn(["-S", "suf", "a", "b"]), "create", paths: ["b"])
    }

    @Test func install_bsdValuesAndDPreScan() {
        // `-D destdir` (BSD) and `-M metalog` always evaluate.
        expectWriterParsed(
            parseInstall(["-D", "/tmp/d", "a", "b"]),
            "overwrite",
            paths: ["b", "/tmp/d"]
        )
        expectWriterParsed(
            parseInstall(["-D/tmp/d", "a", "b"]),
            "overwrite",
            paths: ["/tmp/d"]
        )
        expectWriterParsed(
            parseInstall(["-M", "/tmp/m", "a", "b"]),
            "overwrite",
            paths: ["/tmp/m", "b"]
        )
        expectWriterParsed(parseInstall(["-B", "suf", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-f", "uchg", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-h", "sha256", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-l", "flags", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-T", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-S", "suf", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-Ssuf", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-U", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseInstall(["-Z", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(
            parseInstall(["--targ", "/tmp/t", "a", "b"]),
            "overwrite",
            paths: ["/tmp/t"]
        )
        #expect(parseInstall(["--help", "-D", "/tmp/d"]) == nil)
    }

    @Test func rsync_shortAndLongAudit() {
        // Value shorts consume; bare shorts parse; the destination survives.
        expectWriterParsed(
            parseRsync(["-f", "+ */", "-M", "opt", "-B", "512", "a", "b"]),
            "overwrite",
            paths: ["b"]
        )
        expectWriterParsed(parseRsync(["-k", "-N", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseRsync(["-g", "-C", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseRsync(["-8", "-I", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(parseRsync(["-0", "-d", "-F", "a", "b"]), "overwrite", paths: ["b"])
        expectWriterParsed(
            parseRsync(["--remote-option=x", "--suffix", "suf", "a", "b"]),
            "overwrite",
            paths: ["b"]
        )
        // `--cvs-exclude` is bare: it consumes nothing.
        expectWriterParsed(
            parseRsync(["--cvs-exclude", "a", "b"]),
            "overwrite",
            paths: ["b"]
        )
        expectWriterParsed(
            parseRsync(["--copy-a", "u", "--skip-compress", "gz", "a", "b"]),
            "overwrite",
            paths: ["b"]
        )
    }

    @Test func tar_deleteModeAndValueShorts() {
        // `-D` is delete mode (the archive rewrites).
        expectWriterParsed(
            parseTar(["-D", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        // Attached letters after a value taker cannot re-read as modes.
        expectWriterParsed(
            parseTar(["-cHustar", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["-c", "-T", "list", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["-cVlabel", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["-c", "-G", "/tmp/snap", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/snap", "/tmp/x.tar"]
        )
        // `=`-clusters and `=`-bundles read like the tool (`-f` keeps
        // everything after it, `=` included).
        expectWriterParsed(parseTar(["-cf=/tmp/x.tar", "m"]), "overwrite", paths: ["=/tmp/x.tar"])
        expectWriterParsed(parseTar(["cf=/tmp/x.tar", "m"]), "overwrite", paths: ["=/tmp/x.tar"])
    }

    @Test func tar_abbreviatedLongsAndSidecars() {
        expectWriterParsed(parseTar(["--extr", "-f", "a.tar"]), "overwrite", paths: ["."])
        expectWriterParsed(parseTar(["--cre", "-f", "/tmp/x.tar", "m"]), "overwrite", paths: ["/tmp/x.tar"])
        expectWriterParsed(parseTar(["--to-com", "tee", "-f", "a.tar"]), "overwrite", paths: ["/"])
        expectWriterParsed(
            parseTar(["-c", "--volno-file=/tmp/v", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/v", "/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["-c", "--index-file", "/tmp/i", "-f", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/i", "/tmp/x.tar"]
        )
        expectWriterParsed(
            parseTar(["--checkpoint", "500", "-cf", "/tmp/x.tar", "m"]),
            "overwrite",
            paths: ["/tmp/x.tar"]
        )
        // Ambiguous abbreviations keep the legacy skip (the tool errors).
        #expect(parseTar(["--c", "-f", "a.tar"]) == nil)
    }

    @Test func curl_writeFlagAudit() {
        expectWriterParsed(
            parseCurl(["--etag-save", "/tmp/e", "http://h"]),
            "overwrite",
            paths: ["/tmp/e"]
        )
        expectWriterParsed(
            parseCurl(["--alt-svc", "/tmp/a", "http://h"]),
            "overwrite",
            paths: ["/tmp/a"]
        )
        expectWriterParsed(
            parseCurl(["--libcurl", "/tmp/x.c", "http://h"]),
            "overwrite",
            paths: ["/tmp/x.c"]
        )
        expectWriterParsed(
            parseCurl(["--ssl-keylogfile", "/tmp/k", "http://h"]),
            "overwrite",
            paths: ["/tmp/k"]
        )
        expectWriterParsed(
            parseCurl(["--remote-name-all", "http://h/f"]),
            "overwrite",
            paths: ["."]
        )
        // Config content is unbounded; `--manual` prints like `--help`.
        expectWriterParsed(parseCurl(["-K", "evil.conf", "http://h"]), "overwrite", paths: ["/"])
        expectWriterParsed(parseCurl(["--config=x", "http://h"]), "overwrite", paths: ["/"])
        #expect(parseCurl(["--manual"]) == nil)
        // `=`-words and abbreviations read like the tool.
        expectWriterParsed(parseCurl(["-o=/tmp/x", "http://h"]), "overwrite", paths: ["=/tmp/x"])
        expectWriterParsed(
            parseCurl(["--output-d", "/tmp/x", "http://h", "-O"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        // `--outp` is ambiguous (`output`/`output-dir`): the tool errors.
        #expect(parseCurl(["--outp", "/tmp/x", "http://h"]) == nil)
        #expect(parseCurl(["--trac", "/tmp/x", "http://h"]) == nil)
    }

    @Test func dd_stdioTargetsSkipped() {
        #expect(parseDd(["if=a", "of=-"]) == nil)
        #expect(parseDd(["if=a", "of=/dev/stdout"]) == nil)
        #expect(parseDd(["if=a", "of=/dev/stderr"]) == nil)
        expectWriterParsed(parseDd(["if=a", "of=/tmp/x"]), "overwrite", paths: ["/tmp/x"])
        expectWriterParsed(
            parseFilesystemCommand(["dd", "if=a", "of=/dev/stdout", ">", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
    }

    @Test func extractTargetDirectory_valueShortsBlockT() {
        // `mv -StDIR` reads suffix `tDIR`: no `-t`, word left whole.
        let blocked = extractTargetDirectory(["-StDIR", "a", "b"], valueShorts: ["S"])
        #expect(blocked.overrides.isEmpty)
        #expect(blocked.reduced == ["-StDIR", "a", "b"])
        // Without a blocking value short, `-t` reads through the cluster.
        let through = extractTargetDirectory(["-StDIR", "a", "b"])
        #expect(through.overrides == ["DIR"])
        #expect(through.reduced == ["-S", "a", "b"])
        #expect(through.overrideAmbiguous == false)
        // A conflicted short before `t` flags the override ambiguous.
        let conflicted = extractTargetDirectory(["-StDIR", "a", "b"], conflictedShorts: ["S"])
        #expect(conflicted.overrides == ["DIR"])
        #expect(conflicted.overrideAmbiguous)
        let plain = extractTargetDirectory(["-vtDIR", "a", "b"], conflictedShorts: ["S"])
        #expect(plain.overrides == ["DIR"])
        #expect(plain.overrideAmbiguous == false)
        // `=`-clusters, separate form, and repeats all collect.
        let equals = extractTargetDirectory(["-t=/tmp/t", "a"])
        #expect(equals.overrides == ["=/tmp/t"])
        #expect(equals.overrideAmbiguous == false)
        let multi = extractTargetDirectory(["-t", "/tmp/a", "--targ", "x", "-t", "/tmp/b"])
        #expect(multi.overrides == ["/tmp/a", "/tmp/b"])
        #expect(multi.reduced == ["--targ", "x"])
        // Dangling `-t` stays for the main scan to fail.
        let dangling = extractTargetDirectory(["a", "-t"])
        #expect(dangling.overrides.isEmpty)
        #expect(dangling.reduced == ["a", "-t"])
    }

    @Test func extractInstallDValues_bsdReading() {
        #expect(extractInstallDValues(["-D", "/tmp/d", "a"], valueShorts: []) == ["/tmp/d"])
        #expect(extractInstallDValues(["-D/tmp/d", "a"], valueShorts: []) == ["/tmp/d"])
        // A value short before `D` consumes it (`-mDfoo` reads mode `Dfoo`).
        #expect(extractInstallDValues(["-mDfoo", "a"], valueShorts: ["m"]).isEmpty)
        #expect(extractInstallDValues(["-vDfoo", "a"], valueShorts: ["m"]) == ["foo"])
        // Pending values win over the terminator, exactly like getopt.
        #expect(extractInstallDValues(["-D", "--", "a"], valueShorts: []) == ["--"])
    }
}

private func expectWriterParsed(
    _ parsed: ParsedFilesystemCommand?,
    _ operation: String,
    paths: [String],
    recursive: Bool = false,
    force: Bool = false
) {
    guard let parsed else {
        Issue.record("expected \(operation) parse")
        return
    }
    #expect(writerOperationName(parsed.operation) == operation)
    #expect(parsed.paths == paths)
    #expect(parsed.recursive == recursive)
    #expect(parsed.force == force)
}

private func writerOperationName(_ operation: FilesystemOperation) -> String {
    switch operation {
    case .delete: return "delete"
    case .move: return "move"
    case .overwrite: return "overwrite"
    case .chmod: return "chmod"
    case .create: return "create"
    case .read: return "read"
    }
}

// MARK: - P10e9: wget / iconv / unzip / split / sed / sqlite3 / ditto / gzip / zip

@Suite("New writer verbs (Step 8B P10e9)")
struct ParseNewWriterVerbsTests {
    @Test func wget_outputFlags() {
        expectWriterParsed(
            parseWget(["-O", "/tmp/x", "http://h/y"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseWget(["-P", "/tmp/d", "http://h/y"]),
            "overwrite",
            paths: ["/tmp/d"]
        )
        expectWriterParsed(
            parseWget(["-o", "/tmp/w.log", "http://h/y"]),
            "overwrite",
            paths: ["/tmp/w.log"]
        )
        expectWriterParsed(
            parseWget(["--output-document=/tmp/x", "http://h/y"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseWget(["-O/tmp/x", "http://h/y"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseWget(["-qO", "/tmp/x", "http://h/y"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        #expect(parseWget(["http://h/y"]) == nil)
        #expect(parseWget(["-O", "-", "http://h/y"]) == nil)
        #expect(parseWget(["-e", "-O", "http://h/y"]) == nil)
    }

    @Test func iconv_outputOnly() {
        expectWriterParsed(
            parseIconv(["-f", "UTF-8", "-t", "UTF-8", "a", "-o", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseIconv(["--output=/tmp/x", "a"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        #expect(parseIconv(["-f", "UTF-8", "a"]) == nil)
        #expect(parseIconv(["-o", "-"]) == nil)
    }

    @Test func unzip_dashD() {
        expectWriterParsed(
            parseUnzip(["-o", "a.zip", "-d", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseUnzip(["-d/tmp/x", "a.zip"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        // `-d` consumes its attached value: query letters in the directory
        // (`/tmp`, `/var`, `/home`) must not misread as list-mode flags.
        expectWriterParsed(
            parseUnzip(["-od/var/x", "a.zip"]),
            "overwrite",
            paths: ["/var/x"]
        )
        #expect(parseUnzip(["-l", "a.zip"]) == nil)
        // M-05: default extraction claims the cwd root (like `tar -x`), so
        // `cd`-tracked outside cwds fail closed.
        expectWriterParsed(parseUnzip(["a.zip"]), "overwrite", paths: ["."])
    }

    @Test func unzip_queryModesAndBareClaimNothing() {
        // List/test/pipe modes never touch the disk; bare `unzip` prints
        // usage. None of these may claim the cwd root.
        for flag in ["-l", "-Z", "-t", "-p", "-c", "-v", "-h", "-Zl"] {
            #expect(parseUnzip([flag, "a.zip"]) == nil, "flag \(flag)")
        }
        #expect(parseUnzip([]) == nil)
        #expect(parseUnzip(["-o"]) == nil)
        #expect(parseUnzip(["-l", "-d", "/tmp/x", "a.zip"]) == nil)
    }

    @Test func split_prefixOperand() {
        expectWriterParsed(
            parseSplit(["-d", "a", "/tmp/p"]),
            "overwrite",
            paths: ["/tmp/p"]
        )
        expectWriterParsed(
            parseSplit(["-a", "3", "-b", "1m", "a", "/tmp/p"]),
            "overwrite",
            paths: ["/tmp/p"]
        )
        // M-05: default `x*` output claims the cwd root (like `tar -x`).
        expectWriterParsed(parseSplit(["a"]), "overwrite", paths: ["."])
        expectWriterParsed(parseSplit([]), "overwrite", paths: ["."])
        #expect(parseSplit(["--help"]) == nil)
    }

    @Test func sed_inPlaceEditsFiles() {
        expectWriterParsed(
            parseSed(["-i", "s/a/b/", "/tmp/x"]),
            "overwrite",
            paths: ["s/a/b/", "/tmp/x"].dropFirst().map { $0 }
        )
        expectWriterParsed(
            parseSed(["-i", "", "s/a/b/", "/tmp/x"]),
            "overwrite",
            paths: ["s/a/b/", "/tmp/x"]
        )
        expectWriterParsed(
            parseSed(["-i.bak", "s/a/b/", "/tmp/x"]),
            "overwrite",
            paths: ["s/a/b/", "/tmp/x"].dropFirst().map { $0 }
        )
        expectWriterParsed(
            parseSed(["-i", "-e", "s/a/b/", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseSed(["--in-place=.bak", "s/a/b/", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        #expect(parseSed(["s/a/b/", "f"]) == nil)
        #expect(parseSed(["-i", "s/a/b/"]) == nil)
    }

    @Test func sqlite_firstOperandIsDb() {
        expectWriterParsed(
            parseSqlite3(["/tmp/e.db", "CREATE TABLE t(x)"]),
            "overwrite",
            paths: ["/tmp/e.db"]
        )
        expectWriterParsed(
            parseSqlite3(["-cmd", ".mode csv", "/tmp/e.db"]),
            "overwrite",
            paths: ["/tmp/e.db"]
        )
        #expect(parseSqlite3([":memory:", "select 1"]) == nil)
        #expect(parseSqlite3(["-readonly", "/tmp/e.db"]) == nil)
        #expect(parseSqlite3(["file:/tmp/e.db?mode=ro"]) == nil)
        #expect(parseSqlite3(["--help"]) == nil)
    }

    @Test func ditto_lastOperandIsDest() {
        expectWriterParsed(
            parseDitto(["a", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseDitto(["-c", "-z", "a", "b", "/tmp/x.cpio"]),
            "overwrite",
            paths: ["/tmp/x.cpio"]
        )
        expectWriterParsed(
            parseDitto(["--outBom", "/tmp/x.bom", "a", "b"]),
            "overwrite",
            paths: ["b", "/tmp/x.bom"]
        )
        #expect(parseDitto(["only"]) == nil)
    }

    @Test func inplaceCompress_claimsOperands() {
        expectWriterParsed(
            parseInplaceCompress(["-9", "/tmp/x"]),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectWriterParsed(
            parseInplaceCompress(["-d", "/tmp/x.gz"]),
            "overwrite",
            paths: ["/tmp/x.gz"]
        )
        expectWriterParsed(
            parseFilesystemCommand(["xz", "-d", "/tmp/x.xz"]),
            "overwrite",
            paths: ["/tmp/x.xz"]
        )
        #expect(parseInplaceCompress(["-c", "a"]) == nil)
        #expect(parseInplaceCompress(["-t", "a.gz"]) == nil)
        #expect(parseInplaceCompress(["-l", "a.gz"]) == nil)
    }

    @Test func zip_firstOperandIsArchive() {
        expectWriterParsed(
            parseZip(["-r", "/tmp/z.zip", "a", "b"]),
            "overwrite",
            paths: ["/tmp/z.zip"]
        )
        expectWriterParsed(
            parseZip(["-m", "in.zip", "/tmp/a"]),
            "overwrite",
            paths: ["in.zip", "/tmp/a"]
        )
        expectWriterParsed(
            parseZip(["-O", "/tmp/new.zip", "old.zip", "a"]),
            "overwrite",
            paths: ["old.zip", "/tmp/new.zip"]
        )
        #expect(parseZip(["-", "a"]) == nil)
    }

    @Test func zip_testOnlySkipsArchiveClaim() {
        // Pure `-T`/`--test` reads the archive; with no file operands
        // there is nothing to update. Update+test still claims, and -m
        // stays conservative (destructive flavor, bizarre combo).
        #expect(parseZip(["-T", "/outside/x.zip"]) == nil)
        #expect(parseZip(["--test", "/outside/x.zip"]) == nil)
        expectWriterParsed(
            parseZip(["-T", "a.zip", "f"]),
            "overwrite",
            paths: ["a.zip"]
        )
        expectWriterParsed(
            parseZip(["-T", "-m", "a.zip"]),
            "overwrite",
            paths: ["a.zip"]
        )
    }
}

import Testing
import RVDomain
@testable import RVEngine

/// rv admin commands the launcher parser cannot follow: run by an
/// interpreter or runner as opaque script text, by `find -exec`, or by a
/// shell or interpreter that reads its program from stdin.
@Suite("rv self-protection guard: scripts, find -exec, stdin programs")
struct SelfProtectionScriptTests {
    static let weakening: [String] = [
        // Interpreter one-liners: the script text is opaque.
        #"perl -e 'system("rv uninstall")'"#,
        #"perl -E 'say qx(rv uninstall)'"#,
        #"perl -le 'system("rv\x20uninstall")'"#,
        #"python3 -c 'import os; os.system("rv uninstall")'"#,
        #"python3 -c "import subprocess; subprocess.run(['rv','packs','disable','core.git'])""#,
        #"python3 -c 'import os; os.system("/usr/local/bin/rv uninstall")'"#,
        #"python3 -c 'import os; os.system("r""v uninstall")'"#,
        #"python3.12 -c 'import os; os.system("RV UNINSTALL")'"#,
        #"node -e 'require("child_process").execSync("rv uninstall")'"#,
        #"node -p 'require("child_process").execSync("rv-cli host mode claude off")'"#,
        #"ruby -e 'system "rv", "safety", "normal"'"#,
        #"php -r 'shell_exec("rv uninstall");'"#,
        #"osascript -e 'do shell script "rv uninstall"'"#,
        #"awk 'BEGIN { system("rv uninstall") }'"#,
        #"gawk 'BEGIN { system("rv policy ceiling set c.toml") }'"#,
        #"expect -c 'spawn rv uninstall; interact'"#,
        #"sed 's/.*/rv uninstall/e' file.txt"#,
        // Runners that hand their operands to a shell.
        "su root -c 'rv uninstall'",
        "su -c 'rv packs disable core.git' root",
        "ssh localhost rv uninstall",
        "ssh -p 22 localhost 'rv host mode claude off'",
        "watch -n 1 rv uninstall",
        "tmux new -d 'rv uninstall'",
        "tmux new-session -d -s x 'rv setup --observe'",
        "screen -dm rv uninstall",
        // A dynamic head may be an interpreter.
        #"$PY -c 'import os; os.system("rv uninstall")'"#,
        // find runs its -exec/-execdir/-ok/-okdir command.
        #"find . -exec rv uninstall \;"#,
        "find . -exec rv uninstall ';'",
        #"find . -exec sh -c 'rv uninstall' \;"#,
        "find . -execdir rv packs disable core.git {} +",
        #"find . -ok rv uninstall \;"#,
        #"find . -okdir sudo rv uninstall \;"#,
        #"find . -name x -exec true \; -exec rv uninstall \;"#,
        #"find . -name rv -exec {} uninstall \;"#,
        #"find . -exec perl -e 'system("rv uninstall")' \;"#,
        #"find . -exec find . -exec rv uninstall \; \;"#,
        // A shell or interpreter reading its program from stdin.
        "echo 'rv policy ceiling set c.toml' | sh",
        "echo 'rv uninstall' | bash -s",
        "printf 'rv uninstall\\n' | bash -s -- x",
        "echo 'rv uninstall' | zsh",
        "echo 'rv uninstall' | sh -",
        "echo 'rv uninstall' | bash /dev/stdin",
        "echo 'rv uninstall' | bash -o pipefail",
        "echo 'rv uninstall' | $SHELL",
        "echo 'rv-cli uninstall' | sh",
        "echo $'rv\\x20uninstall' | sh",
        "echo 'r''v uninstall' | sh",
        "sh <<< 'rv uninstall'",
        "bash <<< \"rv packs disable core.git\"",
        "bash <<EOF\nrv uninstall\nEOF",
        "cat <<EOF | sh\nrv uninstall\nEOF",
        "sh -c \"echo 'rv uninstall' | sh\"",
        "echo 'rv uninstall' | ssh localhost",
        "echo 'rv uninstall' | su root",
        #"echo 'import os; os.system("rv uninstall")' | python3"#,
        #"python3 - <<< 'import os; os.system("rv uninstall")'"#,
        #"echo 'system("rv uninstall")' | perl"#,
    ]

    static let harmless: [String] = [
        #"perl -e 'print "hello\n"'"#,
        #"python3 -c 'import os; print(os.getcwd())'"#,
        #"python3 -c 'rv = 1; print(rv)'"#,
        #"python3 -c 'import shutil; print(shutil.which("rv"))'"#,
        #"python3 -c 'print("rv set up")'"#,
        #"python3 -c 'print(1)' ~/CodingProjects/rv/policy"#,
        #"python3 -c 'import json,sys; print(set(json.load(sys.stdin)))' < rv/data.json"#,
        #"node -e 'console.log(process.version)'"#,
        "awk '{print $1}' file.txt",
        "sed -i 's/rv policy apply/rv policy show/' README.md",
        "ssh host 'git pull'",
        "watch -n 2 git status",
        "tmux new -s dev",
        "find . -name '*.swift' -exec grep -l rv {} \\;",
        "find . -exec rv policy show \\;",
        "find . -type f -delete",
        "echo 'ls -la' | sh",
        "bash Scripts/preflight.sh && rv policy show",
        "rv policy show --json | python3 -c 'import json,sys; print(json.load(sys.stdin))'",
        "rv packs list | python3 -m json.tool",
        "rv packs list --json | python3 tool.py",
        "rv packs list | awk '{print $1}'",
        "rv policy show | jq .",
        "rv packs list --json | node -e 'process.stdin.pipe(process.stdout)'",
        "echo rv uninstall",
        "git commit -m 'rv uninstall docs'",
        "grep -rn 'rv uninstall' docs",
    ]

    @Test("rv admin commands run through a script, find, or stdin are flagged", arguments: weakening)
    func weakeningFlagged(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("everyday scripts, finds and stdin programs are not", arguments: harmless)
    func harmlessPass(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) == false, "\(command)")
    }
}

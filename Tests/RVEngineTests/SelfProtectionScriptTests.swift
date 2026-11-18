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
        #"python3.12 -c 'import os; os.system("RV uninstall")'"#,
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
        // Review round: more ways to read a program from stdin.
        "echo 'rv uninstall' | sudo -s",
        "echo 'rv uninstall' | sudo -i",
        "echo 'rv uninstall' | doas -s",
        #"echo 'rv uninstall' | find . -maxdepth 0 -exec sh \;"#,
        "echo 'rv uninstall' | python3 /dev//stdin",
        "echo 'rv uninstall' | bash /dev/./stdin",
        "echo 'rv uninstall' | bash /proc/$$/fd/0",
        #"echo 'import os; os.system("rv uninstall")' | python3 -m code"#,
        "source /dev/stdin <<< 'rv uninstall'",
        ". /dev/stdin <<< 'rv uninstall'",
        // An inline program that runs its input.
        "echo 'rv uninstall' | perl -ne 'system $_'",
        "echo 'rv uninstall' | php -R 'system($argn);'",
        "echo 'rv uninstall' | awk '{system($0)}'",
        "echo 'rv uninstall' | sed e",
        "echo 'rv uninstall' | python3 -c 'import sys;exec(sys.stdin.read())'",
        // rv in the script, the verb from stdin or the environment.
        "echo uninstall | sed 's/^/rv /e'",
        #"echo uninstall | awk '{system("rv " $0)}'"#,
        #"V=uninstall python3 -c 'import os;os.system("rv $V")'"#,
        // Spellings: `$'…'` joins, continuations, letter escapes.
        "echo 'r'$'v'' uninstall' | sh",
        #"printf 'r\\\nv uninstall' | sh"#,
        #"echo $'rv\cIuninstall' | sh"#,
        #"ruby -e 'system "rv\suninstall"'"#,
        // More runners and interpreters.
        "fd -x rv uninstall",
        #"python3.13t -c 'import os; os.system("rv uninstall")'"#,
        #"pypy3 -c 'import os; os.system("rv uninstall")'"#,
        #"tsx -e 'require("child_process").execSync("rv uninstall")'"#,
        "gdb -batch -ex 'shell rv uninstall'",
        "vim -c '!rv uninstall' -c q",
        "echo '* * * * * rv uninstall' | crontab -",
        "echo 'rv uninstall' | at now",
        "printf 'rv uninstall' | xargs -0 sh -c",
        #"echo . | xargs -I{} find {} -exec rv uninstall \;"#,
        // Second review round: other descriptors, globbed paths, loaders,
        // the environment, braced and undecodable escapes.
        "bash /dev/fd/3 3<<< 'rv uninstall'",
        "echo 'rv uninstall' | bash /dev/stdi?",
        #"awk -f /dev/fd/3 3<<<'BEGIN{system("rv uninstall")}'"#,
        #"python3 /dev/fd/3 3<<< 'import os; os.system("rv uninstall")'"#,
        #"echo 'system "rv uninstall"' | perl -e 'do "/dev/stdin"'"#,
        #"echo 'import os; os.system("rv uninstall")' | python3 -c 'import runpy;runpy.run_path("/dev/stdin")'"#,
        #"echo 'system "rv uninstall"' | ruby -e 'load "/dev/stdin"'"#,
        #"echo '<?php system("rv uninstall");' | php -r 'include "php://stdin";'"#,
        #"V='rv uninstall' perl -e 'open(F,"|$ENV{V}")'"#,
        #"perl -e 'system "rv \x{75}ninstall"'"#,
        #"node -e 'require("child_process").execSync("rv \u{75}ninstall")'"#,
        #"python3 -c 'import os;os.system("rv \N{LATIN SMALL LETTER U}ninstall")'"#,
        #"perl -e 'system "rv \LUNINSTALL"'"#,
        // Third review round: sudo values that split, finds run by xargs,
        // shell option values.
        "echo 'rv uninstall' | sudo -p 'Enter pw' -s",
        #"echo 'rv uninstall' | sudo -u "$(whoami)" -s"#,
        "echo 'rv uninstall' | sudo -u $(id -un; true) -s",
        "echo 'rv uninstall' | sudo -R /tmp -s",
        "echo 'rv uninstall' | doas -a bsdauth -s",
        "xargs find . -exec rv < f",
        #"echo . | xargs find . -exec /usr/local/bin/r? uninstall \;"#,
        #"xargs -I% sh -c 'find . -exec r[v] uninstall \;'"#,
        #"echo . | xargs find . -exec rv $(printf un)install \;"#,
        "echo 'rv uninstall' | bash -oe pipefail",
        "echo 'rv uninstall' | zsh --emulate sh",
        // Fourth review round: command boundaries that are not, fd's exec
        // flag through a variable, stdin run without a loader name.
        "echo 'rv uninstall' | sudo 2>&1 -s",
        #"echo 'rv uninstall' | sudo -p "$(echo ";")" -s"#,
        #"echo 'rv uninstall' | sudo -p $'\';' -s"#,
        "X=-x; fd . $X rv uninstall",
        "fd . $(printf %s -x) rv uninstall",
        #"echo 'os.execute("rv uninstall")' | lua -e '_G.dofile()'"#,
        #"echo 'system "rv uninstall"' | ruby -e 'Kernel.instance_eval($stdin.read)'"#,
        #"echo 'import os;os.system("rv uninstall")' | python3 -c 'import code,sys;code.InteractiveInterpreter().runsource(sys.stdin.read())'"#,
        #"echo 'require("child_process").execSync("rv uninstall")' | node -e 'process.stdin.on("data",d=>globalThis["ev"+"al"](""+d))'"#,
        #"echo 'import os;os.system("rv uninstall")' | python3 -c 'breakpoint()'"#,
        #"echo 'import os;os.system("rv uninstall")' | python3 -c 'import code;code.interact()'"#,
        #"echo 'system "rv uninstall"' | perl -e 'open F,"<&=0"; s//join"",<F>/ee'"#,
        #"echo 'x; rv uninstall' | xargs -I% find . -exec sh -c 'echo %' \;"#,
        // Fifth review round: escaped fd flags, bash single-dash long
        // options, a dynamic head that may be xargs under find under xargs.
        #"fd \-x rv uninstall"#,
        #"fd --\exec rv uninstall"#,
        "echo 'rv uninstall' | bash -init-file x",
        #"xargs -I@ find @ -exec "$X" -I% sh -c % ';'"#,
    ]

    static let harmless: [String] = [
        #"perl -e 'print "hello\n"'"#,
        #"python3 -c 'import os; print(os.getcwd())'"#,
        #"python3 -c 'rv = 1; print(rv)'"#,
        #"python3 -c 'import shutil; print(shutil.which("rv"))'"#,
        #"python3 -c 'print("rv set up")'"#,
        #"python3 -c 'import os; print(os.path.exists("/usr/local/bin/rv"))'"#,
        "tmux new -c ~/CodingProjects/rv 'swift test --filter Policy'",
        "rv policy show --json > p.json; python3 analyze.py < p.json",
        "echo 'print(1)' | python3 -m code",
        "sudo -u root ls -la",

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
        "rv packs list | python3 -m json.tool",
        "rv packs list --json | python3 tool.py",
        "rv packs list | awk '{print $1}'",
        "rv policy show | jq .",
        "echo rv uninstall",
        "git commit -m 'rv uninstall docs'",
        "grep -rn 'rv uninstall' docs",
    ]

    /// Floored though harmless, by design: an inline program that reads
    /// stdin may run it, an option before a script name may take it as a
    /// value, a runner's operands are a shell command, sudo's options are
    /// not modelled, and script text is opaque; each line holds an rv binary
    /// and verb. `jq`, `python3 -m json.tool` and a script file stay allowed.
    static let acceptedFloors: [String] = [
        "rv policy show --json | python3 -c 'import json,sys; print(json.load(sys.stdin))'",
        "rv packs list --json | node -e 'process.stdin.pipe(process.stdout)'",
        #"sudo ls; git commit -s -m "rv policy fix""#,
        "bash -x Scripts/preflight.sh && rv policy show",
        "fd secrets ~/CodingProjects/rv",
        "node --inspect app.js; rv packs list",
        "watch rv packs list",
        #"node -e 'console.log("rv policy show")'"#,
    ]

    @Test("accepted floors stay floored", arguments: acceptedFloors)
    func acceptedFloorsFlagged(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)), "\(command)")
    }

    /// Dynamic heads between `-exec`s branch at every word; the followed
    /// set is deduplicated and capped, so this ends quickly (and flags).
    @Test("find -exec with dynamic heads is bounded", .timeLimit(.minutes(1)))
    func findExecDynamicHeadsBounded() {
        let command = "find . " + String(repeating: "-exec $F ", count: 40) + "\\;"
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)))
    }

    @Test("rv admin commands run through a script, find, or stdin are flagged", arguments: weakening)
    func weakeningFlagged(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("everyday scripts, finds and stdin programs are not", arguments: harmless)
    func harmlessPass(command: String) {
        #expect(SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) == false, "\(command)")
    }
}

import Testing
import RVDomain
@testable import RVEngine

@Suite("Inline program guard")
struct InlineProgramGuardTests {
    static let risky: [String] = [
        #"perl -e 'system("rm -rf ~")'"#,
        #"perl -e 'qx{rm -rf ~}'"#,
        #"perl -le 'print `id`'"#,
        #"awk 'BEGIN{system("rm -rf ~")}'"#,
        #"gawk 'BEGIN { print "x" | "sh" }'"#,
        #"awk 'BEGIN { "id" | getline x }'"#,
        #"php -r 'system("rm -rf ~");'"#,
        #"php -r 'shell_exec("id");'"#,
        "sed -n '1e rm -rf ~' f",
        "sed 's/x/rm -rf ~/e' f",
        "sed -e 's/a/b/ge' f",
        #"node -e 'require("fs").rmSync(process.env.HOME,{recursive:true})'"#,
        #"node -e 'require("child_process").execSync("id")'"#,
        #"node --eval 'eval(process.argv[1])' x"#,
        #"python3 -c "from os import system; system('rm -rf ~')""#,
        #"python3 -c "import os as o; o.system('rm -rf ~')""#,
        #"python3 -c "import os; getattr(os, 'sys'+'tem')('id')""#,
        #"python3 -c "exec('aW1wb3J0IG9z')""#,
        #"python3 -c "import pty; pty.spawn('/bin/sh')""#,
        #"python3 -c "import shutil; shutil.rmtree('/home/u')""#,
        #"python -c "import os; os.remove('/etc/hosts')""#,
        #"python3 -c "print(open('/Users/x/.ssh/id_rsa').read())""#,
        #"ruby -e 'File.delete("/etc/hosts")'"#,
        #"ruby -e '%x(id)'"#,
        #"lua -e 'os.execute("rm -rf ~")'"#,
        #"sudo -u root perl -e 'system("id")'"#,
        #"FOO=1 env BAR=2 python3 -c 'import subprocess; subprocess.run(["id"])'"#,
        #"ls && /usr/bin/perl -e 'unlink "/etc/hosts"'"#,
        #"bash -c "perl -e 'system(\"id\")'""#,
        #"cat f | awk '{ system($0) }'"#,
    ]

    static let benign: [String] = [
        "awk '{print $1}' f",
        "awk '/rm -rf/'",
        "perl -ne 'print if /x/' f",
        #"perl -e "print 'git reset --hard'""#,
        #"php -r "echo 'git reset --hard';""#,
        #"lua -e "print('git reset --hard')""#,
        "python3 -c 'print(1)'",
        #"python3 -c 'import json,sys; print(json.load(sys.stdin)["x"])'"#,
        "node -e 'console.log(1)'",
        "sed -n '/rm -rf/p' f",
        "sed 's/foo/bar/g' f",
        "sed -n '/git reset --hard/p'",
        "python3 script.py --exec",
        "perl script.pl system",
        "echo 'system(\"rm -rf ~\")'",
        "git commit -m 'use exec in perl -e'",
    ]

    @Test("spawn, eval, delete and secret-read payloads need the judge", arguments: risky)
    func riskyPayloadsNeedJudge(command: String) {
        #expect(InlineProgramGuard.requiresJudge(ShellCommand(rawValue: command)), "\(command)")
    }

    @Test("benign payloads and non-inline invocations do not", arguments: benign)
    func benignPayloadsPass(command: String) {
        #expect(InlineProgramGuard.requiresJudge(ShellCommand(rawValue: command)) == false, "\(command)")
    }
}

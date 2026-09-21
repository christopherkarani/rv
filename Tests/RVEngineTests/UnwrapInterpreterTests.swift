import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap interpreters")
struct UnwrapInterpreterTests {
    @Test func pythonShellExtracts() {
        expectComplete(
            #"python -u -W ignore -c "os.system('git status')""#,
            inner: "git status",
            layers: [.python]
        )
        expectComplete(
            #"python -c "os.system ('git status')""#,
            inner: "git status",
            layers: [.python]
        )
        expectComplete(
            #"python -c "os.system( 'git status')""#,
            inner: "git status",
            layers: [.python]
        )
        expectComplete(
            #"python -c "os.system('a\\b')""#,
            inner: "a\\b",
            layers: [.python]
        )
        expectComplete(
            #"python -c "subprocess.call ( [ 'git' , 'status' ] )""#,
            inner: "git status",
            layers: [.python]
        )
        expectComplete(
            #"python -c "os.popen('git status')""#,
            inner: "git status",
            layers: [.python]
        )
        expectComplete(
            #"python3 -c "__import__('os').system('git reset --hard')""#,
            inner: "git reset --hard",
            layers: [.python]
        )
        expectComplete(
            #"python3.12 -c '__import__("os").system("rm -rf tree")'"#,
            inner: "rm -rf tree",
            layers: [.python]
        )
        expectComplete(
            #"python -c "subprocess.run('git status')""#,
            inner: "git status",
            layers: [.python]
        )
        expectComplete(
            #"python -c "subprocess.call(['git', 'reset', '--hard'])""#,
            inner: "git reset --hard",
            layers: [.python]
        )
        expectComplete(
            #"python -c "subprocess.Popen('echo ok')""#,
            inner: "echo ok",
            layers: [.python]
        )
        expectComplete(
            #"python -c "subprocess.check_call('true')""#,
            inner: "true",
            layers: [.python]
        )
        expectComplete(
            #"python -c "subprocess.check_output('true')""#,
            inner: "true",
            layers: [.python]
        )
        expectComplete(
            #"python -c "os.remove('file')""#,
            inner: "rm file",
            layers: [.python]
        )
        expectComplete(
            #"python -c "os.unlink('my file')""#,
            inner: "rm 'my file'",
            layers: [.python]
        )
        expectComplete(
            "python -c \"os.remove('o clock')\"",
            inner: "rm 'o clock'",
            layers: [.python]
        )
        expectComplete(
            #"/usr/bin/python3 -c "shutil.rmtree('tree')""#,
            inner: "rm -rf tree",
            layers: [.python]
        )
    }

    @Test func pythonDataOnlyAndLimited() {
        expectNotWrapper(#"python -c "import os""#)
        expectNotWrapper(#"python -c "from os import path""#)
        expectNotWrapper(#"python -c "print (1)""#)
        expectNotWrapper(#"python -c "pprint(1)""#)
        expectNotWrapper(#"python -c "; print('ok')""#)
        expectNotWrapper(#"python -c "print('rm -rf /')""#)
        expectNotWrapper(#"python -c "x = 1""#)
        expectNotWrapper(#"python3 -c "from pathlib import Path; p=Path('f'); print(p.read_text())""#)
        expectNotWrapper(#"python -c "mystery(payload)""#)
        expectLimited(#"python -c "os.system('')""#, .python)
        expectLimited(#"python3 -c $CMD"#, .python)
        expectLimited(#"python3 -c "$CMD""#, .python)
        expectLimited("python3 -c git status", .python)
        expectLimited(#"python -c "subprocess.run([])""#, .python)
        expectLimited(#"python -c "subprocess.run([git])""#, .python)
        expectNotWrapper(#"python -c "print('a\\;b'); print(1)""#)
        expectLimited(#"python -c "os.system('cmd""#, .python)
        expectLimited(#"python -c "os.system('a\\""#, .python)
        expectLimited(#"python -c "os.system(""#, .python)
        expectLimited("python -c", .python)
        expectLimited("python -W", .python)
        expectLimited("python -X", .python)
        expectNotWrapper("python script.py")
        expectNotWrapper("python")
    }

    @Test func nodeShellExtracts() {
        expectComplete(
            "node --eval \"require('child_process').exec('git status')\"",
            inner: "git status",
            layers: [.node]
        )
        expectComplete(
            #"node --print "require('node:child_process').execSync('true')""#,
            inner: "true",
            layers: [.node]
        )
        expectComplete(
            #"nodejs -p "require('node:child_process').exec('echo ok')""#,
            inner: "echo ok",
            layers: [.node]
        )
        expectComplete(
            "node -e \"require('node:child_process').execSync('git status')\"",
            inner: "git status",
            layers: [.node]
        )
        expectComplete(
            #"node -e "child_process.execSync('true')""#,
            inner: "true",
            layers: [.node]
        )
        expectComplete(
            #"node --title t -e "child_process.exec('true')""#,
            inner: "true",
            layers: [.node]
        )
        expectComplete(
            #"node -e "child_process.exec('true')""#,
            inner: "true",
            layers: [.node]
        )
        expectComplete(
            #"node -e "fs.unlinkSync('file')""#,
            inner: "rm file",
            layers: [.node]
        )
        expectComplete(
            #"node -e "fs.rmdirSync('dir')""#,
            inner: "rm dir",
            layers: [.node]
        )
        expectComplete(
            #"node -e "fs.rmSync('tree', {recursive: true})""#,
            inner: "rm -rf tree",
            layers: [.node]
        )
        expectComplete(
            #"node -e "fs.rm('file')""#,
            inner: "rm file",
            layers: [.node]
        )
    }

    @Test func nodeDataOnlyAndLimited() {
        expectNotWrapper(#"node -e "console.log(1)""#)
        expectNotWrapper(#"node -e "console.info(1)""#)
        expectNotWrapper(#"node -e "console.debug(1)""#)
        expectNotWrapper(#"node -e "console.warn(1)""#)
        expectNotWrapper(#"node -e "console.error(1)""#)
        expectNotWrapper(#"node -e "const x = 1""#)
        expectNotWrapper(#"node -e "mystery()""#)
        expectLimited(#"node -e $CMD"#, .node)
        expectLimited("node -e", .node)
        expectLimited("node --title", .node)
        expectNotWrapper("node app.js")
        expectNotWrapper("node")
    }

    @Test func rubyShellExtracts() {
        expectComplete(
            #"ruby -e "exec('git status')""#,
            inner: "git status",
            layers: [.ruby]
        )
        expectComplete(
            #"ruby -e "File.delete('file')""#,
            inner: "rm file",
            layers: [.ruby]
        )
        expectComplete(
            #"ruby -e "File.unlink('file')""#,
            inner: "rm file",
            layers: [.ruby]
        )
        expectComplete(
            #"ruby -e "FileUtils.rm_rf('tree')""#,
            inner: "rm -rf tree",
            layers: [.ruby]
        )
        expectComplete(
            #"ruby -e "FileUtils.remove_entry_secure('tree')""#,
            inner: "rm -rf tree",
            layers: [.ruby]
        )
        expectComplete(
            "ruby -e '`git reset --hard`'",
            inner: "git reset --hard",
            layers: [.ruby]
        )
        expectComplete(
            #"ruby -r json -e "system('true')""#,
            inner: "true",
            layers: [.ruby]
        )
        expectComplete(
            #"ruby3.2 -e "system('true')""#,
            inner: "true",
            layers: [.ruby]
        )
        expectComplete(
            "ruby -e'system(\"true\")'",
            inner: "true",
            layers: [.ruby]
        )
    }

    @Test func rubyDataOnlyAndLimited() {
        expectNotWrapper(#"ruby -e "puts 1""#)
        expectNotWrapper(#"ruby -e "puts(1)""#)
        expectNotWrapper(#"ruby -e "print 1""#)
        expectNotWrapper(#"ruby -e "print(1)""#)
        expectNotWrapper(#"ruby -e "p 1""#)
        expectNotWrapper(#"ruby -e "p(1)""#)
        expectNotWrapper(#"ruby -e "pp 1""#)
        expectNotWrapper(#"ruby -e "pp(1)""#)
        expectLimited("ruby -e '``'", .ruby)
        expectLimited(#"ruby -e "%x(git status)""#, .ruby)
        expectNotWrapper(#"ruby -e "x = 1""#)
        expectNotWrapper(#"ruby -e "mystery()""#)
        expectLimited("ruby -e", .ruby)
        expectLimited("ruby -W", .ruby)
        expectLimited("ruby -r", .ruby)
        expectNotWrapper("ruby script.rb")
        expectNotWrapper("ruby")
    }
}

private func expectComplete(_ raw: String, inner: String, layers: [WrapperKind]) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .complete(let unwrapped) = outcome else {
        Issue.record("expected complete unwrap of \(raw), got \(outcome)")
        return
    }
    #expect(unwrapped.command.rawValue == inner)
    #expect(unwrapped.layers == layers)
}

private func expectLimited(_ raw: String, _ kind: WrapperKind) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .limited(let layers) = outcome else {
        Issue.record("expected limited unwrap of \(raw), got \(outcome)")
        return
    }
    #expect(layers.contains(kind))
}

private func expectNotWrapper(_ raw: String) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .complete(let unwrapped) = outcome else {
        Issue.record("expected complete surface for \(raw), got \(outcome)")
        return
    }
    #expect(unwrapped.layers.isEmpty)
    #expect(unwrapped.command.rawValue == raw)
}

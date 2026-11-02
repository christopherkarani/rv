import Darwin
import Foundation
import RVMacVMAgent
import RVMicroVMCore
import Synchronization

// rv-macvm-agent: runs as a LaunchDaemon (root) inside rv's macOS guest
// images. It serves exec sessions from rv-macvm on vsock port 1024.
// `exec-as` is the internal spawn trampoline.

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == ExecAs.verb {
    ExecAs.run(Array(arguments.dropFirst(2)))
}
if arguments.count == 2, arguments[1] == MacVMSession.verb {
    SessionVerb.run()
}

signal(SIGPIPE, SIG_IGN)
let trampoline = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().path
let configuration = AgentConfiguration(
    trampoline: trampoline,
    user: MacVMAgent.user,
    mountWorkspace: { GuestMount.workspace($0, owner: MacVMAgent.user) },
    connectRelay: { port in Vsock.connectHost(port: UInt32(port)) }
)

let listener: Int32
switch Vsock.listen(port: MacVMAgent.controlPort) {
case .failure(let message):
    FileHandle.standardError.write(Data("rv-macvm-agent: \(message)\n".utf8))
    exit(1)
case .success(let fd):
    listener = fd
}

// One session at a time: the end-of-run sweep kills every process of the
// guest user, so a second session's command would die with the first.
let busy = Mutex(false)
while true {
    guard let client = Vsock.acceptHost(listener) else {
        FileHandle.standardError.write(Data("rv-macvm-agent: accept: \(String(cString: strerror(errno)))\n".utf8))
        exit(1)
    }
    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
    let accepted = busy.withLock { running in
        defer { running = true }
        return !running
    }
    guard accepted else {
        MacVMChannel(descriptor: client).send(.failure("another session is running in this guest"))
        close(client)
        continue
    }
    Thread.detachNewThread {
        AgentSession.serve(MacVMChannel(descriptor: client), configuration: configuration)
        close(client)
        busy.withLock { $0 = false }
    }
}

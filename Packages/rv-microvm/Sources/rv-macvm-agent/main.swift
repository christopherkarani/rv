import Darwin
import Foundation
import RVMacVMAgent
import RVMicroVMCore

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

// Every command starts over the guest's sshd, which launchd loads in
// parallel with this daemon. Listen only once it answers: the host retries
// until the agent does, so the first session never meets a closed port 22.
let sshdDeadline = Date().addingTimeInterval(TimeInterval(MacVMAgent.sshdReadySeconds))
while true {
    if let probe = connectLoopback(port: 22) {
        close(probe)
        break
    }
    guard Date() < sshdDeadline else {
        FileHandle.standardError.write(Data("rv-macvm-agent: sshd is not listening on 127.0.0.1:22; sessions will fail\n".utf8))
        break
    }
    usleep(200_000)
}

let listener: Int32
switch Vsock.listen(port: MacVMAgent.controlPort) {
case .failure(let message):
    FileHandle.standardError.write(Data("rv-macvm-agent: \(message)\n".utf8))
    exit(1)
case .success(let fd):
    listener = fd
}

// One session per boot, ever: the run boots a fresh clone for one command,
// so a second session could only be a leftover from that command (the
// end-of-run sweep would also kill it with the first), and in the same
// boot it would start a login shell in a home the command could write to.
var served = false
while true {
    guard let client = Vsock.acceptHost(listener) else {
        FileHandle.standardError.write(Data("rv-macvm-agent: accept: \(String(cString: strerror(errno)))\n".utf8))
        exit(1)
    }
    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
    guard !served else {
        MacVMChannel(descriptor: client).send(.failure("this guest already ran its one session"))
        close(client)
        continue
    }
    served = true
    Thread.detachNewThread {
        AgentSession.serve(MacVMChannel(descriptor: client), configuration: configuration)
        close(client)
    }
}

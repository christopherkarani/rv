#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// When `rv run` hands the terminal to the command and takes it back. Pure:
/// it decides, `SecretRunProcess` acts.
///
/// rv gives the terminal away only while it holds the foreground and no
/// other job shares its process group (a pipeline: `rv run -- x | less`
/// would leave `less` in the background). It takes the terminal back only
/// if it gave it away and nobody else has it now: while rv was stopped the
/// shell may have given it to another job, which keeps it.
struct SecretRunJobControl: Equatable {
    /// The group rv gave the terminal to, until rv takes it back.
    private(set) var handedTo: pid_t?

    /// Before the command resumes: at launch, and each time rv itself is
    /// continued (`fg` gives rv the foreground first; `bg` does not).
    mutating func handsTerminal(rvInForeground: Bool, sharesGroup: Bool, to group: pid_t) -> Bool {
        let hands = rvInForeground && sharesGroup == false
        handedTo = hands ? group : nil
        return hands
    }

    /// When the command stops or exits. `foreground` is the terminal's
    /// foreground group now (nil if it cannot be read: leave the terminal
    /// alone), `foregroundAlive` whether any process is in that group.
    mutating func reclaimsTerminal(foreground: pid_t?, foregroundAlive: Bool) -> Bool {
        defer { handedTo = nil }
        guard let handedTo, let foreground else { return false }
        return foreground == handedTo || foregroundAlive == false
    }

    /// Whether rv's process group holds a process other than rv and its
    /// ancestors (a non-job-control shell running rv is an ancestor; a
    /// pipeline's other commands are not). An empty list means the group
    /// could not be read, and counts as shared: the terminal stays put.
    static func sharesGroup(members: [pid_t], rv: pid_t, ancestors: Set<pid_t>) -> Bool {
        guard members.isEmpty == false else { return true }
        return members.contains { $0 != rv && ancestors.contains($0) == false }
    }
}

/// rv's side of the terminal while it supervises. `SecretRunTerminal` is
/// the real one; tests record what `supervise` asks of it.
protocol SecretRunTerminalControl: AnyObject {
    var rvInForeground: Bool { get }
    /// `tcgetpgrp`, or nil when it fails.
    var foregroundGroup: pid_t? { get }
    /// Per `SecretRunJobControl.sharesGroup`.
    var sharesGroup: Bool { get }
    func hand(to group: pid_t) -> Bool
    /// Only after `hand`, per `SecretRunJobControl`.
    func reclaim()
    /// Stops rv itself, so the shell sees its job stop and takes the terminal.
    func stopSelf()
}

/// Whether any process is in group `group` (one rv may not signal counts).
func secretRunGroupExists(_ group: pid_t) -> Bool {
    guard group > 1 else { return false }
    return kill(-group, 0) == 0 || errno == EPERM
}

/// Where `rv run` forwards the signals it receives: nowhere until the
/// command's group is known (the first one is kept), then to that group,
/// and nowhere again once `release` is called. `release` comes before the
/// leader is reaped: after that its group id may belong to someone else.
/// Each forwarded signal is followed by `SIGCONT`, so a stopped group
/// still receives it (as `timeout(1)` does).
final class SecretRunSignalTarget: @unchecked Sendable {
    private let lock = NSLock()
    private let send: @Sendable (pid_t, Int32) -> Void
    private var group: pid_t?
    private var pending: Int32?
    private var released = false

    init(send: @escaping @Sendable (pid_t, Int32) -> Void = { group, number in _ = kill(-group, number) }) {
        self.send = send
    }

    /// From here on, signals go to `group`. Returns one that arrived before.
    func target(_ group: pid_t) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if released == false { self.group = group }
        return pending
    }

    /// The first signal that arrived while no group was targeted.
    var interrupted: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func deliver(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if let group {
            send(group, number)
            send(group, SIGCONT)
        } else if pending == nil, released == false {
            pending = number
        }
    }

    /// No signal is sent after this returns.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        released = true
        group = nil
    }
}

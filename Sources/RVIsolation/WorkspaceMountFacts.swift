#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

enum ObservedDevice {
    case device(UInt64)
    case missing
    case stopped
}

func observedDevice(_ path: String, afterDetach: Bool = false) -> ObservedDevice {
    let observation = afterDetach
        ? diskImageObservePathWithinCancelClock(path)
        : diskImageObservePath(path)
    switch observation {
    case .value(let snapshot):
        return .device(snapshot.device)
    case .missing:
        return .missing
    case .stopped:
        return .stopped
    }
}

struct WorkspacePathIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
    var isDirectory: Bool
}

func workspacePathIdentity(_ path: String) -> WorkspacePathIdentity? {
    guard case let .value(snapshot) = diskImageObservePath(path) else { return nil }
    return WorkspacePathIdentity(
        device: snapshot.device,
        inode: snapshot.inode,
        isDirectory: (snapshot.mode & S_IFMT) == S_IFDIR
    )
}

private final class MountStatBox: @unchecked Sendable {
    var info = statfs()
}

struct WorkspaceMountFacts: Equatable {
    var source: String
    var point: String
}

func workspaceMountFacts(_ path: String) -> WorkspaceMountFacts? {
    let allowance = diskImageMountStatAllowance(
        sharedDeadline: CooperativeLaunchStop.cancelClock?.deadline,
        now: Date()
    )
    let limit: TimeInterval?
    switch allowance {
    case .skip:
        return nil
    case .uncancelled:
        limit = nil
    case .limited(let left):
        limit = left
    }
    let box = MountStatBox()
    let ok = diskImageWaitForStat(allowance: limit) {
        path.withCString { statfs($0, &box.info) == 0 }
    }
    guard ok == true else { return nil }
    let info = box.info
    let source = withUnsafePointer(to: info.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.f_mntfromname)) {
            String(cString: $0)
        }
    }
    let point = withUnsafePointer(to: info.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.f_mntonname)) {
            String(cString: $0)
        }
    }
    return WorkspaceMountFacts(source: source, point: point)
}

func workspaceMountSource(_ path: String) -> String? {
    workspaceMountFacts(path)?.source
}

func pathDepth(_ path: String) -> Int {
    path.split(separator: "/").count
}

func renamePath(_ source: String, _ destination: String) -> Bool {
    source.withCString { from in
        destination.withCString { to in
            rename(from, to) == 0
        }
    }
}

/// Delete a leftover mountpoint directory only when every inode is a
/// single-link object. A planted hard link is left in place.
func inodeCheckedDelete(_ root: String) -> Bool {
    switch diskImageLstatNode(root) {
    case .stopped:
        return false
    case .missing:
        return true
    case .value(let node):
        guard kind(of: node.mode) == .directory else {
            if node.nlink > 1 { return false }
            return diskImageUnlinkWithinCopyClock(root) == true
        }
        guard let names = readDirectoryNamesStoppingForDetachReserve(root, mayContinue: {
            cancelClockAllowsTreeCopy()
        }) else {
            return false
        }
        for name in names {
            let child = (root as NSString).appendingPathComponent(name)
            if inodeCheckedDelete(child) == false { return false }
        }
        return diskImageRmdirWithinCopyClock(root) == true
    }
}
#endif

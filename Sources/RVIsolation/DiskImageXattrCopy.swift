#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Records how large a single xattr get or set was. A user attribute is
/// transferred in `chunkBytes` windows. One `fgetxattr` or `fsetxattr` of
/// the whole value is not a chunked copy.
final class XattrCopyTrace: @unchecked Sendable {
    var largestRead = 0
    var largestWrite = 0
    var forkBytesWritten = 0
    var fcopyfileInvoked = false

    func noteRead(_ count: Int) {
        if count > largestRead { largestRead = count }
    }

    func noteWrite(_ count: Int) {
        if count > largestWrite { largestWrite = count }
    }

    func noteFork(_ count: Int) {
        if count > forkBytesWritten { forkBytesWritten = count }
    }

    func noteFcopyfile() {
        fcopyfileInvoked = true
    }
}

/// A failed path lookup must not skip the named fork. That skip is what
/// lets one unbounded copy of `..namedfork/rsrc` run with no further clock
/// check. No resolved path means the copy stops.
func namedForkCopyStarts(pathResolved: Bool) -> Bool {
    pathResolved
}

/// Copy extended attributes in slices that keep checking the clock.
/// A false return stops before the detach reserve is spent. A name other
/// than `com.apple.ResourceFork` is read and written in `chunkBytes`
/// windows, not one get and one set of the whole value. A Darwin resource
/// fork is read in 64KB slices.
func copyXattrsObservingClock(
    from source: Int32,
    to destination: Int32,
    chunkBytes: Int = 64 * 1024,
    trace: XattrCopyTrace = XattrCopyTrace(),
    mayContinue: () -> Bool
) -> Bool {
    if mayContinue() == false { return false }
    #if canImport(Darwin)
    if copyResourceForkObservingClock(from: source, to: destination, mayContinue: mayContinue) == false {
        return false
    }
    #endif
    guard let names = listXattrNames(source) else { return false }
    for name in names where name != "com.apple.ResourceFork" {
        if copyOneXattrObservingClock(
            from: source,
            to: destination,
            name: name,
            chunkBytes: chunkBytes,
            trace: trace,
            mayContinue: mayContinue
        ) == false {
            return false
        }
    }
    // The destination is an existing saved inode on the publish path.
    // An attribute the source no longer has must not survive there.
    guard let destinationNames = listXattrNames(destination) else { return false }
    let sourceNames = Set(names)
    for name in destinationNames
    where name != "com.apple.ResourceFork" && sourceNames.contains(name) == false {
        if mayContinue() == false { return false }
        if removeXattr(destination, name) == false { return false }
    }
    return true
}

func removeXattr(_ fd: Int32, _ name: String) -> Bool {
    let label = name
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let removed = label.withCString { xattrRemove(copy, $0) == 0 }
        close(copy)
        return removed
    }
    return ok == true
}

/// One user attribute. A value that fits the window is got and set in
/// that window. A larger value is got and set whole: Darwin's position
/// argument serves only the resource fork, so a windowed get of a plain
/// attribute cannot advance. The whole-value get and set still run on
/// clocked workers and the detach reserve is rechecked between them.
func copyOneXattrObservingClock(
    from source: Int32,
    to destination: Int32,
    name: String,
    chunkBytes: Int,
    trace: XattrCopyTrace,
    mayContinue: () -> Bool
) -> Bool {
    let needed: Int
    switch xattrByteCountWithinCopyClock(source, name) {
    case .stopped:
        return false
    case .bytes(let count):
        needed = count
    }
    guard needed >= 0 else { return false }
    if needed == 0 { return mayContinue() }
    let step = max(1, chunkBytes)
    var gathered = [UInt8]()
    if needed > step {
        if mayContinue() == false { return false }
        guard let whole = readXattr(source, name), whole.count == needed else { return false }
        trace.noteRead(whole.count)
        gathered = whole
    } else {
        gathered.reserveCapacity(needed)
        if mayContinue() == false { return false }
        guard let window = readXattrWindow(source, name, offset: 0, length: needed) else {
            return false
        }
        if window.count != needed { return false }
        trace.noteRead(window.count)
        gathered.append(contentsOf: window)
    }
    if mayContinue() == false { return false }
    // The get can finish inside the budget. That is not the set.
    if mayContinue() == false { return false }
    // Immediately before `fsetxattr`. The detach reserve can be gone
    // even though the get finished inside the budget.
    if xattrSetKeepsDetachReserve(mayContinue: mayContinue) == false { return false }
    trace.noteWrite(gathered.count)
    return writeXattr(destination, name, gathered)
}

/// The clock read that sits on the set itself. A true result from the
/// post-get check does not skip this one.
func xattrSetKeepsDetachReserve(mayContinue: () -> Bool) -> Bool {
    mayContinue()
}

/// Gets at most `length` bytes and only from `offset` zero. A larger value
/// returns nil instead of one `fgetxattr` of the whole attribute. Darwin's
/// position argument is not used for names other than the resource fork.
func readXattrWindow(_ fd: Int32, _ name: String, offset: Int, length: Int) -> [UInt8]? {
    if offset != 0 || length <= 0 { return nil }
    final class Box: @unchecked Sendable { var bytes: [UInt8]? }
    let box = Box()
    let label = name
    let limit = length
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let needed = label.withCString { xattrValueSize(copy, $0) }
        if needed < 0 || needed > limit {
            close(copy)
            return false
        }
        if needed == 0 {
            close(copy)
            box.bytes = []
            return true
        }
        var buffer = [UInt8](repeating: 0, count: limit)
        let got = buffer.withUnsafeMutableBytes { raw in
            label.withCString { item in
                xattrValue(copy, item, raw.baseAddress, limit)
            }
        }
        close(copy)
        guard got == needed, got >= 0 else { return false }
        box.bytes = Array(buffer.prefix(got))
        return true
    }
    guard ok == true else { return nil }
    return box.bytes
}

/// Walk `byteCount` in chunks. Each chunk checks the clock before it counts.
/// A large resource fork that starts with budget left stops while detach
/// time remains.
func copyXattrBytesObservingClock(
    byteCount: Int,
    chunkBytes: Int = 64 * 1024,
    mayContinue: () -> Bool
) -> Bool {
    if byteCount == 0 { return mayContinue() }
    let step = max(1, chunkBytes)
    var offset = 0
    while offset < byteCount {
        if mayContinue() == false { return false }
        offset += min(step, byteCount - offset)
    }
    return mayContinue()
}

func listXattrNames(_ fd: Int32) -> [String]? {
    final class SizeBox: @unchecked Sendable { var count = 0 }
    let sizeBox = SizeBox()
    let sized = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        sizeBox.count = xattrListSize(copy)
        close(copy)
        return true
    }
    guard sized == true else { return nil }
    let needed = sizeBox.count
    guard needed > 0 else { return [] }
    final class NameBox: @unchecked Sendable { var names: [String] = [] }
    let nameBox = NameBox()
    let listed = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        var buffer = [CChar](repeating: 0, count: needed)
        let count = buffer.withUnsafeMutableBufferPointer { raw in
            xattrList(copy, raw.baseAddress, needed)
        }
        close(copy)
        guard count > 0 else { return count == 0 }
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        let limit = min(count, bytes.count)
        var names: [String] = []
        var start = 0
        var index = 0
        while index < limit {
            if bytes[index] == 0 {
                if index > start {
                    names.append(String(decoding: bytes[start..<index], as: UTF8.self))
                }
                start = index + 1
            }
            index += 1
        }
        nameBox.names = names
        return true
    }
    guard listed == true else { return nil }
    return nameBox.names
}

func readXattr(_ fd: Int32, _ name: String) -> [UInt8]? {
    final class Box: @unchecked Sendable { var bytes: [UInt8]? }
    let box = Box()
    let label = name
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let needed = label.withCString { xattrValueSize(copy, $0) }
        if needed < 0 {
            close(copy)
            return false
        }
        if needed == 0 {
            close(copy)
            box.bytes = []
            return true
        }
        var buffer = [UInt8](repeating: 0, count: needed)
        let read = buffer.withUnsafeMutableBytes { raw in
            label.withCString { item in
                xattrValue(copy, item, raw.baseAddress, needed)
            }
        }
        close(copy)
        guard read == needed else { return false }
        box.bytes = buffer
        return true
    }
    guard ok == true else { return nil }
    return box.bytes
}

func writeXattr(_ fd: Int32, _ name: String, _ value: [UInt8]) -> Bool {
    let label = name
    let payload = value
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let wrote = payload.withUnsafeBytes { raw in
            label.withCString { item in
                xattrWrite(copy, item, raw.baseAddress, payload.count) == 0
            }
        }
        close(copy)
        return wrote
    }
    return ok == true
}

/// Size of one attribute. The name bytes live in the worker. `.stopped` is
/// not "no such attribute": a finished `fgetxattr` of `-1` is `.bytes(-1)`.
private enum ClockedXattrSize {
    case bytes(Int)
    case stopped
}

private func xattrByteCountWithinCopyClock(_ fd: Int32, _ name: String) -> ClockedXattrSize {
    final class Box: @unchecked Sendable { var count = -1 }
    let box = Box()
    let label = name
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        box.count = label.withCString { xattrValueSize(copy, $0) }
        close(copy)
        return true
    }
    if ok == nil { return .stopped }
    guard ok == true else { return .bytes(-1) }
    return .bytes(box.count)
}

#if canImport(Darwin)
func copyResourceForkObservingClock(
    from source: Int32,
    to destination: Int32,
    trace: XattrCopyTrace = XattrCopyTrace(),
    mayContinue: () -> Bool
) -> Bool {
    guard let sourcePath = pathForFileDescriptor(source),
        let destinationPath = pathForFileDescriptor(destination)
    else { return namedForkCopyStarts(pathResolved: false) }
    let sourceFork = sourcePath + "/..namedfork/rsrc"
    let destinationFork = destinationPath + "/..namedfork/rsrc"
    guard let src = diskImageOpenPathWithinCopyClock(sourceFork, O_RDONLY | O_CLOEXEC) else {
        return false
    }
    if src < 0 {
        // No source fork. The destination is an existing saved inode on
        // the publish path: clear its fork instead of resurrecting it.
        guard let stale = diskImageOpenPathWithinCopyClock(
            destinationFork,
            O_RDWR | O_CLOEXEC
        ) else { return false }
        if stale < 0 { return true }
        defer { close(stale) }
        guard let staleSize = descriptorSize(stale) else { return false }
        if staleSize == 0 { return true }
        return diskImageFtruncateWithinCopyClock(stale, 0) == true
    }
    defer { close(src) }
    guard let dst = diskImageOpenPathWithinCopyClock(
        destinationFork,
        O_RDWR | O_CREAT | O_CLOEXEC,
        mode_t(0o600)
    ) else { return false }
    guard dst >= 0 else { return false }
    defer { close(dst) }
    // A shrunk fork must not keep its stale tail bytes.
    guard diskImageFtruncateWithinCopyClock(dst, 0) == true else { return false }
    let copied = copyFileLeavingDetachReserve(
        from: src,
        to: dst,
        mayContinue: { _ in mayContinue() },
        copyXattr: { _, _ in true }
    )
    if let size = descriptorSize(dst) {
        trace.noteFork(Int(size))
    }
    return copied
}

func pathForFileDescriptor(_ fd: Int32) -> String? {
    final class Box: @unchecked Sendable { var path: String? }
    let box = Box()
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        // Darwin's pointer overlay. The variadic C `fcntl` is unavailable in Swift.
        let got = fcntl(copy, F_GETPATH, &buffer) == 0
        close(copy)
        guard got else { return false }
        let count = buffer.firstIndex(of: 0) ?? buffer.count
        box.path = String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return true
    }
    guard ok == true else { return nil }
    return box.path
}

func copyXattrsWithFcopyfile(
    from source: Int32,
    to destination: Int32,
    trace: XattrCopyTrace = XattrCopyTrace(),
    mayContinue: @escaping () -> Bool
) -> Bool {
    if mayContinue() == false { return false }
    // `fcopyfile` copies the other attributes. The named fork is skipped
    // there and copied in 64KB slices so a short clock stops during it.
    // A status callback that quits does not skip that slice copy.
    let attributesCopied = copyXattrsByFcopyfile(
        from: source,
        to: destination,
        trace: trace,
        mayContinue: mayContinue
    )
    let forkCopied = copyResourceForkObservingClock(
        from: source,
        to: destination,
        trace: trace,
        mayContinue: mayContinue
    )
    return attributesCopied && forkCopied
}

private final class FcopyfileClockBox {
    let mayContinue: () -> Bool
    var statusQuit = false
    var skippedNames: [String] = []
    init(_ mayContinue: @escaping () -> Bool) {
        self.mayContinue = mayContinue
    }
}

private func xattrFcopyfileStatus(
    _ what: Int32,
    _ stage: Int32,
    _ state: copyfile_state_t?,
    _ src: UnsafePointer<CChar>?,
    _ dst: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32 {
    _ = what
    _ = stage
    _ = src
    _ = dst
    guard let ctx else { return COPYFILE_QUIT }
    let box = Unmanaged<FcopyfileClockBox>.fromOpaque(ctx).takeUnretainedValue()
    var attributeName: String?
    if let state {
        var name: UnsafePointer<CChar>?
        let read = withUnsafeMutablePointer(to: &name) { pointer in
            copyfile_state_get(
                state,
                UInt32(COPYFILE_STATE_XATTRNAME),
                UnsafeMutableRawPointer(pointer)
            )
        }
        if read == 0, let name {
            if strcmp(name, "com.apple.ResourceFork") == 0 { return COPYFILE_SKIP }
            attributeName = String(cString: name)
        }
    }
    if box.mayContinue() == false {
        box.statusQuit = true
        return COPYFILE_QUIT
    }
    // A true clock at `COPYFILE_START` is not permission to `fsetxattr`
    // the whole value. Skip it here and copy it with a check on the set.
    if let attributeName {
        box.skippedNames.append(attributeName)
    }
    return COPYFILE_SKIP
}

private func copyXattrsByFcopyfile(
    from source: Int32,
    to destination: Int32,
    trace: XattrCopyTrace,
    mayContinue: @escaping () -> Bool
) -> Bool {
    guard let state = copyfile_state_alloc() else { return false }
    defer { copyfile_state_free(state) }
    let box = FcopyfileClockBox(mayContinue)
    let context = Unmanaged.passUnretained(box).toOpaque()
    // `copyfile_state_set` stores the pointer bits as the callback and the
    // context. The address of a local that holds those pointers is not
    // `xattrFcopyfileStatus`, so the status function would never run.
    let callback = xattrFcopyfileStatus as copyfile_callback_t
    let callbackBits = unsafeBitCast(callback, to: UInt.self)
    guard let callbackPointer = UnsafeRawPointer(bitPattern: callbackBits) else { return false }
    let contextSet = copyfile_state_set(
        state,
        UInt32(COPYFILE_STATE_STATUS_CTX),
        UnsafeRawPointer(context)
    )
    let callbackSet = copyfile_state_set(
        state,
        UInt32(COPYFILE_STATE_STATUS_CB),
        callbackPointer
    )
    guard contextSet == 0, callbackSet == 0 else { return false }
    trace.noteFcopyfile()
    let status = fcopyfile(source, destination, state, copyfile_flags_t(COPYFILE_XATTR))
    // `COPYFILE_QUIT` sets `ECANCELED` and still returns 0. That is not success.
    guard fcopyfileAttributeCopySucceeded(toolStatus: status, statusQuit: box.statusQuit) else {
        return false
    }
    for name in box.skippedNames where name != "com.apple.ResourceFork" {
        if copyOneXattrObservingClock(
            from: source,
            to: destination,
            name: name,
            chunkBytes: 64 * 1024,
            trace: trace,
            mayContinue: mayContinue
        ) == false {
            return false
        }
    }
    return true
}

private func xattrListSize(_ fd: Int32) -> Int {
    flistxattr(fd, nil, 0, 0)
}

private func xattrList(_ fd: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
    flistxattr(fd, buffer, size, 0)
}

private func xattrValueSize(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int {
    fgetxattr(fd, name, nil, 0, 0, 0)
}

private func xattrValue(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int {
    fgetxattr(fd, name, buffer, size, 0, 0)
}

private func xattrWrite(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeRawPointer?,
    _ size: Int
) -> Int32 {
    fsetxattr(fd, name, buffer, size, 0, 0)
}

private func xattrRemove(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
    fremovexattr(fd, name, 0)
}
#else
@_silgen_name("flistxattr")
private func rv_flistxattr(_ fd: Int32, _ list: UnsafeMutableRawPointer?, _ size: Int) -> Int

@_silgen_name("fgetxattr")
private func rv_fgetxattr(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int

@_silgen_name("fsetxattr")
private func rv_fsetxattr(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeRawPointer?,
    _ size: Int,
    _ flags: Int32
) -> Int32

private func xattrListSize(_ fd: Int32) -> Int {
    rv_flistxattr(fd, nil, 0)
}

private func xattrList(_ fd: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
    guard let buffer else { return rv_flistxattr(fd, nil, size) }
    return buffer.withMemoryRebound(to: UInt8.self, capacity: size) { raw in
        rv_flistxattr(fd, raw, size)
    }
}

private func xattrValueSize(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int {
    rv_fgetxattr(fd, name, nil, 0)
}

private func xattrValue(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int {
    rv_fgetxattr(fd, name, buffer, size)
}

private func xattrWrite(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeRawPointer?,
    _ size: Int
) -> Int32 {
    rv_fsetxattr(fd, name, buffer, size, 0)
}

@_silgen_name("fremovexattr")
private func rv_fremovexattr(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int32

private func xattrRemove(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
    rv_fremovexattr(fd, name)
}
#endif

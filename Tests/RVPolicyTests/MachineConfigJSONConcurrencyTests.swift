import Foundation
import RVDomain
import RVFileStore
import Testing
@testable import RVPolicy

/// AC-003: concurrent `config.json` updates of different keys must not lose any key.
struct MachineConfigJSONConcurrencyTests {
    @Test func concurrentUpdatesOfDifferentKeys_allKeysSurvive() throws {
        let root = try makeConcurrencyDirectory("race")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        let writers = 48
        let failures = FailureCounter()

        DispatchQueue.concurrentPerform(iterations: writers) { index in
            do {
                try MachineConfigJSON.update(file: file) { object in
                    object["key\(index)"] = .number(Double(index))
                }
            } catch {
                failures.increment()
            }
        }

        #expect(failures.value == 0)
        let loaded = MachineConfigJSON.load(from: file)
        let missing = (0..<writers).filter { loaded["key\($0)"] == nil }
        #expect(missing.isEmpty, "lost updates for keys: \(missing)")
    }

    @Test func updateWaitsForHolderOfSharedConfigLock() throws {
        let root = try makeConcurrencyDirectory("held")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        let lockURL = MachineConfigJSON.lockURL(for: file)
        #expect(lockURL == root.appendingPathComponent("config.json.lock"))

        let finished = DispatchSemaphore(value: 0)
        try ExclusiveFileLock.withLock(at: lockURL) {
            DispatchQueue.global().async {
                try? MachineConfigJSON.update(file: file) { object in
                    object["late"] = .bool(true)
                }
                finished.signal()
            }
            // While another holder owns the shared lock, the update must block.
            #expect(finished.wait(timeout: .now() + 0.3) == .timedOut)
            #expect(FileManager.default.fileExists(atPath: file.path) == false)
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(MachineConfigJSON.load(from: file)["late"]?.bool == true)
        let attrs = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func uninstallArtifactsIncludeConfigLock() {
        let root = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        let lockURL = MachineConfigJSON.lockURL(for: root.appendingPathComponent("config.json"))
        #expect(RVPolicyPaths.uninstallArtifacts(inConfigDir: root).contains(lockURL))
    }
}

private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}

private func makeConcurrencyDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-mcjson-conc-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

struct WorkspaceLeftoversTests {
    private func record(
        _ kind: WorkspaceLifecycleRecord.Kind,
        _ workspace: UUID,
        _ path: String,
        at seconds: TimeInterval
    ) -> WorkspaceLifecycleRecord {
        WorkspaceLifecycleRecord(
            kind: kind,
            workspace: workspace,
            originalPath: path,
            protectedPath: path,
            volumeDevice: 1,
            disk: "/dev/disk99s1",
            runtime: nil,
            recordedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func log(_ records: [WorkspaceLifecycleRecord]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-leftovers-\(UUID().uuidString).jsonl")
        for record in records {
            guard case .success = WorkspaceLifecycleLog.append(record, to: url) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return url
    }

    @Test func reportsOnlyUnclosedExistingProjectsWithoutALiveHost() throws {
        let closed = UUID(), orphan = UUID(), vanished = UUID(), live = UUID()
        let url = try log([
            record(.created, closed, "/p/closed", at: 1),
            record(.closed, closed, "/p/closed", at: 2),
            record(.created, orphan, "/p/orphan", at: 3),
            record(.runtimeStarted, orphan, "/p/orphan", at: 4),
            record(.created, vanished, "/p/vanished", at: 5),
            record(.created, live, "/p/live", at: 6),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        var inspected: [String] = []
        let found = WorkspaceHosts.leftovers(
            lifecycleLog: url,
            projectExists: { $0 != "/p/vanished" },
            inspect: { project in
                inspected.append(project)
                return project == "/p/live" ? .starting(live) : .orphaned(orphan)
            }
        )
        #expect(inspected.sorted() == ["/p/live", "/p/orphan"])
        #expect(found == [
            WorkspaceLeftover(
                project: "/p/orphan",
                workspace: orphan,
                lastEvent: "runtimeStarted",
                recordedAt: Date(timeIntervalSince1970: 4),
                attachment: .orphaned(orphan)
            ),
        ])
    }

    @Test func newestUnclosedWorkspacePerProjectWinsAndBlockedIsReported() throws {
        let older = UUID(), newer = UUID()
        let block = WorkspaceRecoveryBlock(workspace: newer, reason: .corrupt)
        let url = try log([
            record(.created, older, "/p/a", at: 1),
            record(.created, newer, "/p/a", at: 9),
            record(.recoveryBlocked, newer, "/p/a", at: 10),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let found = WorkspaceHosts.leftovers(
            lifecycleLog: url,
            projectExists: { _ in true },
            inspect: { _ in .blocked(block) }
        )
        #expect(found.count == 1)
        #expect(found.first?.workspace == newer)
        #expect(found.first?.lastEvent == "recoveryBlocked")
        #expect(found.first?.attachment == .blocked(block))
    }

    private static let hdiutilInfo = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>images</key><array>
          <dict><key>image-path</key><string>/System/Library/Assets/sim.dmg</string>
            <key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk7s1</string>
            <key>mount-point</key><string>/Library/Sim</string></dict></array></dict>
          <dict><key>image-path</key><string>/var/T/rv-inode-AAAA.sparseimage</string>
            <key>system-entities</key><array>
              <dict><key>dev-entry</key><string>/dev/disk61</string></dict>
              <dict><key>dev-entry</key><string>/dev/disk61s1</string></dict></array></dict>
          <dict><key>image-path</key><string>/var/T/rv-inode-BBBB.sparseimage</string>
            <key>system-entities</key><array>
              <dict><key>dev-entry</key><string>/dev/disk62</string></dict>
              <dict><key>dev-entry</key><string>/dev/disk62s1</string></dict></array></dict>
          <dict><key>image-path</key><string>/var/T/rv-inode-CCCC.sparseimage</string>
            <key>system-entities</key><array>
              <dict><key>dev-entry</key><string>/dev/disk63</string></dict></array></dict>
        </array></dict></plist>
        """.utf8)

    @Test func parsesOnlyRVImagesAndFillsMountPointsFromTheKernelTable() throws {
        let images = try #require(AttachedWorkspaceImage.parse(
            hdiutilInfo: Self.hdiutilInfo,
            mounts: ["/dev/disk61s1": "/p/live", "/dev/disk62s1": "/tmp/dead"]
        ))
        #expect(images == [
            AttachedWorkspaceImage(imagePath: "/var/T/rv-inode-AAAA.sparseimage", device: "/dev/disk61s1", mountPoint: "/p/live"),
            AttachedWorkspaceImage(imagePath: "/var/T/rv-inode-BBBB.sparseimage", device: "/dev/disk62s1", mountPoint: "/tmp/dead"),
            AttachedWorkspaceImage(imagePath: "/var/T/rv-inode-CCCC.sparseimage", device: "/dev/disk63", mountPoint: nil),
        ])
        #expect(AttachedWorkspaceImage.parse(hdiutilInfo: Data("nope".utf8)) == nil)
    }

    @Test func diskLeftoversSkipLiveHostsAndFindUnattachedFiles() throws {
        let images = try #require(AttachedWorkspaceImage.parse(
            hdiutilInfo: Self.hdiutilInfo,
            mounts: ["/dev/disk61s1": "/p/live", "/dev/disk62s1": "/tmp/dead"]
        ))
        let report = WorkspaceHosts.diskLeftovers(
            images: images,
            temporaryDirectory: "/var/T",
            temporaryFiles: [
                "rv-inode-AAAA.sparseimage", "rv-inode-DDDD.sparseimage", "other.sparseimage", "rv-inode-x.dmg",
            ],
            inspect: { $0 == "/p/live" ? .starting(UUID()) : .absent }
        )
        #expect(report.attachedCount == 3)
        #expect(report.stranded.map(\.imagePath) == [
            "/var/T/rv-inode-BBBB.sparseimage", "/var/T/rv-inode-CCCC.sparseimage",
        ])
        #expect(report.detachedImageFiles == ["/var/T/rv-inode-DDDD.sparseimage"])
    }

    @Test func liveMountTableResolvesTheRootVolume() {
        #expect(WorkspaceHosts.mountTable().values.contains("/"))
    }

    @Test func missingLogHasNoLeftovers() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-leftovers-missing-\(UUID().uuidString).jsonl")
        let found = WorkspaceHosts.leftovers(
            lifecycleLog: url,
            projectExists: { _ in true },
            inspect: { _ in .orphaned(UUID()) }
        )
        #expect(found.isEmpty)
    }
}
#endif

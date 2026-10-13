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
        #expect(report.attachedKnown)
        #expect(report.stranded.map(\.imagePath) == [
            "/var/T/rv-inode-BBBB.sparseimage", "/var/T/rv-inode-CCCC.sparseimage",
        ])
        #expect(report.retained.isEmpty)
        #expect(report.detachedImageFiles == ["/var/T/rv-inode-DDDD.sparseimage"])
    }

    @Test func recoveringAndStaleMountsAreOwned() throws {
        let images = try #require(AttachedWorkspaceImage.parse(
            hdiutilInfo: Self.hdiutilInfo,
            mounts: ["/dev/disk61s1": "/p/recovering", "/dev/disk62s1": "/p/stale"]
        ))
        let report = WorkspaceHosts.diskLeftovers(
            images: images,
            temporaryDirectory: "/var/T",
            temporaryFiles: [],
            inspect: { mount in
                if mount == "/p/recovering" { return .recovering(UUID()) }
                if mount == "/p/stale" { return .staleEndpoint }
                return .absent
            }
        )
        #expect(report.stranded.map(\.imagePath) == ["/var/T/rv-inode-CCCC.sparseimage"])
    }

    @Test func startingIdentityOwnsAnImageBeforeItIsMounted() throws {
        let images = try #require(AttachedWorkspaceImage.parse(
            hdiutilInfo: Self.hdiutilInfo,
            mounts: ["/dev/disk61s1": "/p/live", "/dev/disk62s1": "/tmp/dead"]
        ))
        let report = WorkspaceHosts.diskLeftovers(
            images: images,
            temporaryDirectory: "/var/T",
            temporaryFiles: [],
            inspect: { $0 == "/p/live" ? .starting(UUID()) : .absent },
            openImages: [
                OpenWorkspaceImage(
                    imagePath: "/var/T/rv-inode-CCCC.sparseimage",
                    attachment: .starting(UUID())
                ),
            ]
        )
        #expect(report.stranded.map(\.imagePath) == ["/var/T/rv-inode-BBBB.sparseimage"])
        #expect(report.retained.isEmpty)
    }

    @Test func orphanedAndBlockedMountsStayStrandedButAreNotDetached() throws {
        let images = try #require(AttachedWorkspaceImage.parse(
            hdiutilInfo: Self.hdiutilInfo,
            mounts: ["/dev/disk61s1": "/p/orphan", "/dev/disk62s1": "/p/blocked"]
        ))
        let orphan = UUID()
        let block = WorkspaceRecoveryBlock(workspace: UUID(), reason: .corrupt)
        let report = WorkspaceHosts.diskLeftovers(
            images: images,
            temporaryDirectory: "/var/T",
            temporaryFiles: ["rv-inode-DDDD.sparseimage"],
            inspect: { mount in
                if mount == "/p/orphan" { return .orphaned(orphan) }
                if mount == "/p/blocked" { return .blocked(block) }
                return .unsupported
            },
            openImages: [
                OpenWorkspaceImage(
                    imagePath: "/var/T/rv-inode-CCCC.sparseimage",
                    attachment: .orphaned(orphan)
                ),
            ]
        )
        #expect(report.stranded.map(\.imagePath) == [
            "/var/T/rv-inode-BBBB.sparseimage",
            "/var/T/rv-inode-AAAA.sparseimage",
            "/var/T/rv-inode-CCCC.sparseimage",
        ])
        #expect(report.retained.map(\.imagePath) == report.stranded.map(\.imagePath))
        #expect(report.detachedImageFiles == ["/var/T/rv-inode-DDDD.sparseimage"])
    }

    @Test func unsupportedMountsStayDetachable() {
        let image = AttachedWorkspaceImage(
            imagePath: "/var/T/rv-inode-UUUU.sparseimage",
            device: "/dev/disk9",
            mountPoint: "/tmp/nope"
        )
        let report = WorkspaceHosts.diskLeftovers(
            images: [image],
            temporaryDirectory: "/var/T",
            temporaryFiles: [],
            inspect: { _ in .unsupported }
        )
        #expect(report.stranded == [image])
        #expect(report.retained.isEmpty)
    }

    @Test func unknownAttachmentListStillListsImageFiles() {
        let report = WorkspaceHosts.diskLeftovers(
            images: [],
            temporaryDirectory: "/var/T",
            temporaryFiles: ["rv-inode-DDDD.sparseimage", "other.sparseimage"],
            inspect: { _ in .absent },
            attachedKnown: false
        )
        #expect(report.attachedKnown == false)
        #expect(report.attachedCount == 0)
        #expect(report.stranded.isEmpty)
        #expect(report.detachedImageFiles == ["/var/T/rv-inode-DDDD.sparseimage"])
    }

    @Test func openWorkspaceImagesSkipClosedWorkspaces() throws {
        let open = UUID()
        let closed = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-leftovers-identity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        for record in [
            identityRecord(open, "/p/open", "/var/T/rv-inode-OPEN.sparseimage", at: 1),
            identityRecord(closed, "/p/closed", "/var/T/rv-inode-CLOSED.sparseimage", at: 2),
            record(.closed, closed, "/p/closed", at: 3),
        ] {
            guard case .success = WorkspaceLifecycleLog.append(record, to: url) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let named = WorkspaceHosts.openWorkspaceImages(lifecycleLog: url) { project in
            project == "/p/open" ? .starting(open) : .absent
        }
        #expect(named.map(\.imagePath) == ["/var/T/rv-inode-OPEN.sparseimage"])
        #expect(named.map(\.attachment) == [.starting(open)])
    }

    private func identityRecord(
        _ workspace: UUID,
        _ path: String,
        _ imagePath: String,
        at seconds: TimeInterval
    ) -> WorkspaceLifecycleRecord {
        WorkspaceLifecycleRecord(
            kind: .created,
            workspace: workspace,
            originalPath: path,
            protectedPath: path,
            volumeDevice: 1,
            disk: "/dev/disk99s1",
            runtime: nil,
            recordedAt: Date(timeIntervalSince1970: seconds),
            identity: WorkspaceDurableIdentity(
                savedPath: path,
                savedDevice: 1,
                savedInode: 2,
                quarantinePath: path + ".saved",
                volumeDevice: 3,
                disk: "/dev/disk99s1",
                mountSource: "/dev/disk99s1",
                imagePath: imagePath,
                imageDevice: 4,
                imageInode: 5,
                lockPath: path + ".lock",
                lockDevice: 6,
                lockInode: 7,
                ownerToken: UUID(),
                snapshotPath: path + ".snap",
                snapshotDevice: 8,
                snapshotInode: 9
            )
        )
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

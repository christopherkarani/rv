#if os(macOS)
import Foundation
import Testing
@testable import RVCLI
import RVIsolation

struct WorkspaceLeftoversCommandTests {
    @Test func reportDoesNotDetachMountsRecoveryStillNeeds() {
        let id = UUID()
        let orphan = AttachedWorkspaceImage(
            imagePath: "/var/T/rv-inode-BBBB.sparseimage",
            device: "/dev/disk62s1",
            mountPoint: "/p/orphan"
        )
        let sessions = [
            WorkspaceLeftover(
                project: "/p/orphan",
                workspace: id,
                lastEvent: "runtimeStarted",
                recordedAt: Date(timeIntervalSince1970: 4),
                attachment: .orphaned(id)
            ),
        ]
        let text = WorkspaceCommandRun.leftoverReport(
            sessions: sessions,
            disk: WorkspaceDiskLeftovers(
                attachedCount: 1,
                stranded: [orphan],
                retained: [orphan],
                detachedImageFiles: [],
                attachedKnown: true
            )
        )
        #expect(text.contains("hdiutil detach") == false)
        #expect(text.contains("start the project to recover it"))
        #expect(text.contains("/p/orphan"))
    }

    @Test func reportDetachesAbsentMountsAndUnclaimedImages() {
        let absent = AttachedWorkspaceImage(
            imagePath: "/var/T/rv-inode-BBBB.sparseimage",
            device: "/dev/disk62s1",
            mountPoint: "/tmp/dead"
        )
        let text = WorkspaceCommandRun.leftoverReport(
            sessions: [],
            disk: WorkspaceDiskLeftovers(
                attachedCount: 1,
                stranded: [absent],
                retained: [],
                detachedImageFiles: [],
                attachedKnown: true
            )
        )
        #expect(text.contains("`hdiutil detach <device>` for each"))
    }

    @Test func reportNamesOnlyDetachableDevicesWhenRecoveryMountsAreListed() {
        let orphan = AttachedWorkspaceImage(
            imagePath: "/var/T/rv-inode-BBBB.sparseimage",
            device: "/dev/disk62s1",
            mountPoint: "/p/orphan"
        )
        let absent = AttachedWorkspaceImage(
            imagePath: "/var/T/rv-inode-CCCC.sparseimage",
            device: "/dev/disk63",
            mountPoint: "/tmp/dead"
        )
        let text = WorkspaceCommandRun.leftoverReport(
            sessions: [],
            disk: WorkspaceDiskLeftovers(
                attachedCount: 2,
                stranded: [orphan, absent],
                retained: [orphan],
                detachedImageFiles: [],
                attachedKnown: true
            )
        )
        #expect(text.contains("hdiutil detach /dev/disk63"))
        #expect(text.contains("hdiutil detach /dev/disk62") == false)
        #expect(text.contains("/p/orphan"))
    }

    @Test func unknownAttachmentListStillPrintsImageFiles() {
        let text = WorkspaceCommandRun.leftoverReport(
            sessions: [],
            disk: WorkspaceDiskLeftovers(
                attachedCount: 0,
                stranded: [],
                retained: [],
                detachedImageFiles: ["/var/T/rv-inode-DDDD.sparseimage"],
                attachedKnown: false
            )
        )
        let unknown = text.range(of: "attached workspace images: unknown (hdiutil info failed)")
        let files = text.range(of: "unattached workspace image files: 1")
        #expect(unknown != nil)
        #expect(files != nil)
        #expect(text.contains("/var/T/rv-inode-DDDD.sparseimage"))
        if let unknown, let files {
            #expect(unknown.lowerBound < files.lowerBound)
        }
    }
}
#endif

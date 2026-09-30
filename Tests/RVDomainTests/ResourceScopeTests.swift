import Foundation
import Testing
import RVDomain

@Suite("ResourceScope")
struct ResourceScopeTests {
    // MARK: AC-003 — a push refspec is never observable as BranchName

    @Test func pushRefspec_isNeverBranchName() {
        let push = GitAction.push(remote: "origin", refspec: "HEAD:main", force: .none)
        #expect(
            push.resources == .git(remote: RemoteName("origin"), ref: .refspec("HEAD:main"))
        )
    }

    @Test(arguments: ["main", "feature", "HEAD:main", "refs/heads/main", "+main"])
    func pushPayload_alwaysRefspecEvenForPlainNames(_ refspec: String) {
        let push = GitAction.push(remote: "origin", refspec: refspec, force: .force)
        #expect(push.resources.gitRef == .refspec(refspec))
        guard case .git(_, .some(.refspec(let spec))) = push.resources else {
            Issue.record("expected .refspec, got \(push.resources)")
            return
        }
        #expect(spec == refspec)
    }

    @Test func deleteRemoteRef_isRefspec() {
        let deleted = GitAction.deleteRemoteRef(remote: "origin", refspec: "topic")
        #expect(
            deleted.resources == .git(remote: RemoteName("origin"), ref: .refspec("topic"))
        )
    }

    @Test func branchActions_carryBranchNames() {
        #expect(
            GitAction.createBranch(name: "feature", startPoint: nil, force: false).resources
                == .git(remote: nil, ref: .branch(BranchName("feature")))
        )
        #expect(
            GitAction.switchBranch(name: "main", force: false).resources
                == .git(remote: nil, ref: .branch(BranchName("main")))
        )
        #expect(
            GitAction.deleteBranch(name: "stale", force: true).resources
                == .git(remote: nil, ref: .branch(BranchName("stale")))
        )
    }

    @Test func deleteTag_carriesTagNotBranch() {
        let tag = GitAction.deleteTag(name: "v1", remote: "origin")
        #expect(tag.resources == .git(remote: RemoteName("origin"), ref: .tag(TagName("v1"))))
    }

    @Test func localOnlyActions_haveNoScope() {
        #expect(GitAction.stash(verb: .push).resources == .none)
        #expect(GitAction.reset(mode: .hard, target: nil).resources == .none)
        #expect(GitAction.clean(force: true, dryRun: false, directories: true).resources == .none)
        #expect(
            GitAction.discardWorktree(pathspecs: ["a"], source: nil).resources == .none
        )
        #expect(
            GitAction.push(remote: nil, refspec: nil, force: .force).resources == .none
        )
    }

    @Test func filesystemProjection_carriesPrimaryTarget() {
        let target = FilesystemTarget(
            apparent: "a.swift",
            canonical: "/repo/a.swift",
            scope: .insideRepository,
            kind: .sourceCode
        )
        let action = FilesystemAction.delete(targets: [target], recursive: false, force: false)
        #expect(
            action.resources
                == .filesystem(
                    path: "/repo/a.swift",
                    scope: .insideRepository,
                    kind: .sourceCode
                )
        )
        #expect(
            FilesystemAction.delete(targets: [], recursive: false, force: false).resources
                == .none
        )
    }

    // MARK: Wire compatibility — old keys retained, refspec re-encodes distinctly

    @Test func oldGitWire_roundTripsSameKeys() throws {
        let data = Data(
            """
            {"remoteName": "origin", "branchName": "main"}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(ResourceScope.self, from: data)
        #expect(
            decoded == .git(remote: RemoteName("origin"), ref: .branch(BranchName("main")))
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(object["remoteName"] as? String == "origin")
        #expect(object["branchName"] as? String == "main")
        #expect(object["refspec"] == nil)
        #expect(object["tagName"] == nil)
    }

    @Test func oldRefspecInBranchName_decodesTolerantlyAndReencodesDistinctly() throws {
        let data = Data(
            """
            {"remoteName": "origin", "branchName": "HEAD:main"}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(ResourceScope.self, from: data)
        #expect(
            decoded == .git(remote: RemoteName("origin"), ref: .refspec("HEAD:main"))
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(object["remoteName"] as? String == "origin")
        #expect(object["refspec"] as? String == "HEAD:main")
        #expect(object["branchName"] == nil)
    }

    @Test(arguments: ["+main", "refs/heads/main", "main:feature"])
    func oldRefspecSpellings_classifyAsRefspec(_ branchName: String) throws {
        let data = Data(
            """
            {"branchName": "\(branchName)"}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(ResourceScope.self, from: data)
        #expect(decoded.gitRef == .refspec(branchName))
    }

    @Test func tagRoundTripsUnderTagName() throws {
        let scope = ResourceScope.git(remote: RemoteName("origin"), ref: .tag(TagName("v1")))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any]
        )
        #expect(object["tagName"] as? String == "v1")
        #expect(object["branchName"] == nil)
        let decoded = try JSONDecoder().decode(
            ResourceScope.self,
            from: JSONEncoder().encode(scope)
        )
        #expect(decoded == scope)
    }

    @Test func oldFilesystemWire_roundTripsSameKeys() throws {
        // Same key set the old bag emitted for a filesystem subject: no git
        // keys, and no new keys. The scope value spelling is FilesystemScope's
        // own (unchanged) Codable, so the vector is built from a real encode.
        let scope = ResourceScope.filesystem(
            path: "/repo/a.swift",
            scope: .insideRepository,
            kind: .sourceCode
        )
        let encoded = try JSONEncoder().encode(scope)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == ["path", "filesystemScope", "resourceKind"])
        #expect(object["path"] as? String == "/repo/a.swift")
        #expect(object["resourceKind"] as? String == "sourceCode")
        let decoded = try JSONDecoder().decode(ResourceScope.self, from: encoded)
        #expect(decoded == scope)
    }

    @Test func emptyWire_decodesToNoneAndReencodesEmpty() throws {
        let decoded = try JSONDecoder().decode(
            ResourceScope.self,
            from: Data("{}".utf8)
        )
        #expect(decoded == .none)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(object.isEmpty)
    }

    @Test func remoteOnlyWire_decodesToGitWithoutRef() throws {
        let decoded = try JSONDecoder().decode(
            ResourceScope.self,
            from: Data(#"{"remoteName": "origin"}"#.utf8)
        )
        #expect(decoded == .git(remote: RemoteName("origin"), ref: nil))
    }

    // MARK: Legacy 5-optional shape — pins behavior outside consumers rely on

    @Test func legacyInit_branchNameYieldsGitBranch() {
        #expect(
            ResourceScope(remoteName: "origin", branchName: "main")
                == .git(remote: RemoteName("origin"), ref: .branch(BranchName("main")))
        )
        #expect(
            ResourceScope(branchName: "HEAD:main")
                == .git(remote: nil, ref: .refspec("HEAD:main"))
        )
        #expect(ResourceScope() == .none)
        #expect(ResourceScope(remoteName: "origin") == .git(remote: RemoteName("origin"), ref: nil))
    }

    @Test func legacyInit_filesystemKeysYieldFilesystem() {
        #expect(
            ResourceScope(path: "/tmp/a.md")
                == .filesystem(path: "/tmp/a.md", scope: .unknown, kind: .unknown)
        )
        #expect(
            ResourceScope(path: "/t", filesystemScope: .insideRepository, resourceKind: .sourceCode)
                == .filesystem(
                    path: "/t",
                    scope: .insideRepository,
                    kind: .sourceCode
                )
        )
    }

    @Test func legacyReads_exposeRefStringRegardlessOfKind() {
        let refspec = ResourceScope.git(remote: RemoteName("origin"), ref: .refspec("HEAD:main"))
        #expect(refspec.remoteName == "origin")
        #expect(refspec.branchName == "HEAD:main")
        #expect(refspec.path == nil)
        let tag = ResourceScope.git(remote: nil, ref: .tag(TagName("v1")))
        #expect(tag.branchName == "v1")
        let fs = ResourceScope.filesystem(
            path: "/t",
            scope: .insideRepository,
            kind: .sourceCode
        )
        #expect(fs.path == "/t")
        #expect(fs.filesystemScope == .insideRepository)
        #expect(fs.resourceKind == .sourceCode)
        #expect(fs.remoteName == nil)
        #expect(fs.branchName == nil)
        #expect(ResourceScope.none.branchName == nil)
    }

    // MARK: Behavior preservation — shared-branch verdicts unchanged

    @Test func analyzedForcePushMain_stillDeniesAsSharedTarget() {
        let push = GitAction.push(remote: "origin", refspec: "main", force: .force)
        let action = ProposedAction.shell(
            ShellAction.analyzed(
                AnalyzedShell(
                    fingerprint: ActionFingerprint(rawValue: "fp-push-main"),
                    analysis: .git(push)
                )
            )
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "feature")
            ),
            gitWorld: .unprobed
        )
        #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
    }

    @Test func analyzedForcePushRefspec_stillAsksLikeLegacyExactMatch() {
        let push = GitAction.push(remote: "origin", refspec: "HEAD:main", force: .force)
        let action = ProposedAction.shell(
            ShellAction.analyzed(
                AnalyzedShell(
                    fingerprint: ActionFingerprint(rawValue: "fp-push-refspec"),
                    analysis: .git(push)
                )
            )
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "feature")
            ),
            gitWorld: .unprobed
        )
        #expect(
            verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
        )
    }
}

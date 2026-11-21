#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVJudgePool

@Suite("Worker arguments")
struct WorkerOptionsTests {
    @Test("the worker arguments name compute, engine and bundle, and nothing else")
    func workerArguments() {
        let key = ModelKey(engine: "ft", bundle: "/models/laya-ft-v2-coreml")
        let arguments = PosixWorkerSpawner.judgeWorkerArguments(slot: .primary, compute: .cpu, key: key)
        #expect(arguments == [
            "--worker", "--compute", "cpu", "--engine", "ft", "--bundle", "/models/laya-ft-v2-coreml",
        ])
    }

    @Test("parse inverts the supervisor's worker arguments")
    func roundTrip() throws {
        let key = ModelKey(engine: "laya", bundle: "/models/laya-multilingual-coreml")
        let arguments = PosixWorkerSpawner.judgeWorkerArguments(slot: .hedge, compute: .accelerated, key: key)
        #expect(arguments.first == "--worker")
        let options = try #require(WorkerOptions.parse(Array(arguments.dropFirst())))
        #expect(options == WorkerOptions(
            compute: .accelerated, engine: "laya", bundle: "/models/laya-multilingual-coreml"))
    }

    @Test("a worker with a missing, relative, unknown or extra option does not start", arguments: [
        ["--compute", "cpu", "--engine", "ft"],
        ["--compute", "cpu", "--engine", "ft", "--bundle", "b"],
        ["--compute", "cpu", "--engine", "ft", "--bundle"],
        ["--compute", "gpu", "--engine", "ft", "--bundle", "/b"],
        ["--compute", "cpu", "--engine", "x", "--bundle", "/b"],
        ["--compute", "cpu", "--engine", "ft", "--bundle", "/b", "--cache", "/c"],
        ["--compute", "cpu", "--engine", "ft", "--bundle", "/b", "--extra", "1"],
    ])
    func rejectsIncomplete(arguments: [String]) {
        #expect(WorkerOptions.parse(arguments) == nil)
    }

    @Test("the home comes from the password database")
    func passwdHome() throws {
        let home = try #require(JudgePoolServe.passwdHome())
        let entry = try #require(getpwuid(geteuid()))
        #expect(home == String(cString: try #require(entry.pointee.pw_dir)))
    }
}

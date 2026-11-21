#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore
import RVIsolation

/// Where the socket custodian keeps each account's key and ledger: a
/// directory only the custodian's own account can enter, one
/// subdirectory per uid. Every read refuses a file that is not the
/// custodian's own, regular and private.
public struct MCPCustodianStore: Sendable {
    public static let ledgerFileName = "ledger.json"
    static let maximumLedgerBytes = 256 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func account(_ uid: UInt32) -> URL {
        directory.appendingPathComponent("u\(uid)", isDirectory: true)
    }

    func keyURL(_ uid: UInt32) -> URL {
        account(uid).appendingPathComponent(MCPApprovalKeyIdentity.fileName, isDirectory: false)
    }

    func ledgerURL(_ uid: UInt32) -> URL {
        account(uid).appendingPathComponent(Self.ledgerFileName, isDirectory: false)
    }

    public var storage: MCPCustodianSocketService.Storage {
        .init(
            loadKey: { uid in
                let url = keyURL(uid)
                var info = stat()
                if lstat(url.path, &info) != 0 {
                    return errno == ENOENT ? .success(nil) : .failure(.init())
                }
                // There, and not a key this account may use: not "no key".
                guard let signer = MCPApprovalSigning.readKeyFile(url) else { return .failure(.init()) }
                return .success(signer)
            },
            createKey: { uid in
                // The ledger is made with the key, and before it: from
                // then on a key without one is a lost ledger, not a fresh
                // account, and a full disk between the two leaves a ledger
                // without a key, which is still a fresh account.
                var info = stat()
                let isNew = lstat(keyURL(uid).path, &info) != 0 && errno == ENOENT
                if isNew, lstat(ledgerURL(uid).path, &info) != 0 {
                    guard errno == ENOENT, let empty = try? JSONEncoder().encode(MCPCustodianLedger()),
                        OwnerOnlyFile.write(empty, to: ledgerURL(uid))
                    else { return .failure(.init()) }
                }
                guard let signer = MCPApprovalSigning.createKeyFile(keyURL(uid), directory: account(uid)) else {
                    return .failure(.init())
                }
                return .success(signer)
            },
            loadLedger: { uid in
                switch OwnerOnlyFile.read(ledgerURL(uid), maximumBytes: Self.maximumLedgerBytes, confidential: true) {
                case .failure: return .failure(.init())
                case .success(nil):
                    // No ledger and no key: a new account. No ledger beside
                    // a key: the counter and what it protects are lost, and
                    // starting again from zero would let an old grant's
                    // counter come round again.
                    var info = stat()
                    guard lstat(keyURL(uid).path, &info) != 0, errno == ENOENT else { return .failure(.init()) }
                    return .success(MCPCustodianLedger())
                case .success(let data?):
                    guard let ledger = try? JSONDecoder().decode(MCPCustodianLedger.self, from: data) else {
                        return .failure(.init())
                    }
                    return .success(ledger)
                }
            },
            saveLedger: { uid, ledger in
                guard let data = try? JSONEncoder().encode(ledger) else { return false }
                return OwnerOnlyFile.write(data, to: ledgerURL(uid))
            })
    }
}

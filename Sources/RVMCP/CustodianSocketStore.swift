#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
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
                MCPApprovalSigning.createKeyFile(keyURL(uid), directory: account(uid)).map { .success($0) }
                    ?? .failure(.init())
            },
            loadLedger: { uid in
                switch OwnerOnlyFile.read(ledgerURL(uid), maximumBytes: Self.maximumLedgerBytes, confidential: true) {
                case .failure: return .failure(.init())
                case .success(nil): return .success(MCPCustodianLedger())
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

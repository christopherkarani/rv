import Foundation
import RVDomain

extension ScanHome {
    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

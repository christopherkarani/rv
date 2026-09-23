#if os(macOS)
import Darwin
import RVIsolation

guard LocalTerminalRestorer.engage(STDIN_FILENO) != nil else {
    fputs("probe: stdin is not a terminal\n", stderr)
    exit(2)
}
raise(SIGINT)
exit(3)
#else
import Foundation
exit(0)
#endif

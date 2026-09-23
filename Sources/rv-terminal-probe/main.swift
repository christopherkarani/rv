#if os(macOS)
import Darwin
import RVIsolation

guard let restorer = LocalTerminalRestorer.engage(STDIN_FILENO) else {
    fputs("probe: stdin is not a terminal\n", stderr)
    exit(2)
}
// engage() arms SIGINT. Dropping the restorer here disarms that handler,
// and raise then dies as an uncaught SIGINT instead of exiting 1.
withExtendedLifetime(restorer) {
    raise(SIGINT)
}
exit(3)
#else
import Foundation
exit(0)
#endif

import RVDomain

/// One surface-extracted shell candidate from a SQLite adapter's embedded-JSON
/// step: the command text plus its store-recorded cwd. Shared by the OpenClaw
/// and Hermes adapters, which privately duplicated this shape before T3.
/// `command` is always non-empty; a row that yields no shell contributes zero
/// events instead of an event.
struct ScanExtractedShell: Sendable {
    var command: String
    var workingDirectory: WorkingDirectory?
}

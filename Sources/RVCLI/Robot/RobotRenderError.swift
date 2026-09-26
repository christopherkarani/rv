/// Failure rendering CLI robot JSON. Robot output is machine-read; an
/// encoding failure is a thrown error (nonzero exit), never a trap and never
/// silent placeholder bytes on a zero exit.
enum RobotRenderError: Error, Sendable, Equatable {
    case encodingFailed(String)
}

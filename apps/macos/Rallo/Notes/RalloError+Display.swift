extension RalloError {
    var displayMessage: String {
        switch self {
        case let .InvalidInput(_, message), let .NotFound(_, message), let .Conflict(_, message),
             let .Storage(_, message), let .IncompatibleSchema(_, _, message):
            return message
        }
    }
}

extension RalloError {
    /// The core's error code (`REVISION_CONFLICT`, `FOLDER_EXISTS`, …).
    var code: String {
        switch self {
        case let .InvalidInput(code, _), let .NotFound(code, _), let .Conflict(code, _), let .Storage(code, _): code
        case .IncompatibleSchema: "INCOMPATIBLE_SCHEMA"
        }
    }
}

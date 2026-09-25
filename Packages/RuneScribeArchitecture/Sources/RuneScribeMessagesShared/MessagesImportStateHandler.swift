import Foundation

/// Containing-app callback for terminal App Group envelope state. The Messages
/// extension never receives this handler and remains transport-only.
public typealias MessagesImportStateHandler = @Sendable (
    _ handoffID: String,
    _ state: MessagesImportAppState
) async -> Void

public enum MessagesImportStateHandlers {
    public static let unavailable: MessagesImportStateHandler = { _, _ in }
}

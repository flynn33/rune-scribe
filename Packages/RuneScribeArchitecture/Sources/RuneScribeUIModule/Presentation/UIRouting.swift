import Foundation

enum RuneScribeUIRoute: Equatable, Sendable {
    case openCipherLibrary
    case openSettings
    case replyToMessage(cipherID: UUID)
}

struct RuneScribeUIRouteRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let route: RuneScribeUIRoute

    init(id: UUID = UUID(), route: RuneScribeUIRoute) {
        self.id = id
        self.route = route
    }
}

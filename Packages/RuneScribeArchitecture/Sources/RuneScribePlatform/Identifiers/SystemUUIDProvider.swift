import Foundation
import RuneScribeContracts

public struct SystemUUIDProvider: UUIDProviding {
    public init() {}

    public func nextUUID() -> UUID {
        UUID()
    }
}

import Foundation

public protocol EntitlementProviding: Sendable {
    func satisfies(_ requirement: EntitlementRequirement) async -> Bool
}

public struct AllowAllEntitlements: EntitlementProviding {
    public init() {}

    public func satisfies(_ requirement: EntitlementRequirement) async -> Bool {
        true
    }
}

public struct ManifestEligibilityProvider: ModuleEligibilityProviding {
    private let entitlements: any EntitlementProviding

    public init(entitlements: any EntitlementProviding) {
        self.entitlements = entitlements
    }

    public func isEligible(_ manifest: ModuleManifest) async -> Bool {
        guard let requirement = manifest.entitlementRequirement else {
            return true
        }
        return await entitlements.satisfies(requirement)
    }
}

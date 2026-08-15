import Foundation

public enum ShareCompletionContractError: Error, Equatable, Sendable {
    case invalidRouteResult
    case invalidAttachmentEvidence
    case nonterminalEvidence
}

public enum ShareRouteClassDTO: String, Codable, CaseIterable, Sendable {
    case messages
    case shareSheet = "share-sheet"
    case airDrop = "air-drop"
    case fileExport = "file-export"
    case clipboard
    case qrDisplay = "qr-display"
}

public enum ShareRouteResultDTO: String, Codable, CaseIterable, Sendable {
    case presented
    case cancelled
    case completedBySystem = "completed-by-system"
    case sentConfirmed = "sent-confirmed"
    case failed
    case completionUnavailable = "completion-unavailable"

    public var isTerminal: Bool { self != .presented }
}

public struct SharePresentationReportDTO: Codable, Equatable, Hashable, Sendable {
    public let routeClass: ShareRouteClassDTO
    public let result: ShareRouteResultDTO
    public let requiredAttachmentAccepted: Bool?

    public init(
        routeClass: ShareRouteClassDTO,
        result: ShareRouteResultDTO,
        requiredAttachmentAccepted: Bool? = nil
    ) throws {
        switch result {
        case .sentConfirmed:
            guard routeClass == .messages else {
                throw ShareCompletionContractError.invalidRouteResult
            }
        case .completedBySystem:
            guard routeClass == .shareSheet || routeClass == .airDrop else {
                throw ShareCompletionContractError.invalidRouteResult
            }
            guard requiredAttachmentAccepted == nil else {
                throw ShareCompletionContractError.invalidAttachmentEvidence
            }
        case .completionUnavailable:
            guard routeClass == .fileExport
                    || routeClass == .clipboard
                    || routeClass == .qrDisplay
            else {
                throw ShareCompletionContractError.invalidRouteResult
            }
            guard requiredAttachmentAccepted == nil else {
                throw ShareCompletionContractError.invalidAttachmentEvidence
            }
        case .presented, .cancelled, .failed:
            guard requiredAttachmentAccepted == nil else {
                throw ShareCompletionContractError.invalidAttachmentEvidence
            }
        }
        self.routeClass = routeClass
        self.result = result
        self.requiredAttachmentAccepted = requiredAttachmentAccepted
    }

    public var isTerminal: Bool { result.isTerminal }

    public func isEligibleTerminal(requiresKeyDelivery: Bool) -> Bool {
        switch (routeClass, result) {
        case (.messages, .sentConfirmed):
            return !requiresKeyDelivery || requiredAttachmentAccepted == true
        case (.shareSheet, .completedBySystem), (.airDrop, .completedBySystem):
            return true
        default:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            routeClass: container.decode(ShareRouteClassDTO.self, forKey: .routeClass),
            result: container.decode(ShareRouteResultDTO.self, forKey: .result),
            requiredAttachmentAccepted: container.decodeIfPresent(
                Bool.self,
                forKey: .requiredAttachmentAccepted
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case routeClass
        case result
        case requiredAttachmentAccepted
    }
}

public struct ShareArtifactCompletionEvidenceDTO: Codable, Equatable, Hashable, Sendable {
    public let artifactID: ShareArtifactID
    public let report: SharePresentationReportDTO
    public let operationContext: RuntimePersistableOperationContext

    @_spi(RuntimeOperationAuthority)
    public init(
        artifactID: ShareArtifactID,
        report: SharePresentationReportDTO,
        operationContext: RuntimePersistableOperationContext
    ) throws {
        guard report.isTerminal else {
            throw ShareCompletionContractError.nonterminalEvidence
        }
        self.artifactID = artifactID
        self.report = report
        self.operationContext = operationContext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            artifactID: container.decode(ShareArtifactID.self, forKey: .artifactID),
            report: container.decode(SharePresentationReportDTO.self, forKey: .report),
            operationContext: container.decode(
                RuntimePersistableOperationContext.self,
                forKey: .operationContext
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID
        case report
        case operationContext
    }
}

import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

private let usage = "Usage: swift-compliance-scanner.swift --scan-root PATH [--fixture-root PATH]"

private struct Finding: Codable, Hashable {
    let ruleID: String
    let category: String
    let path: String
    let line: Int
    let detail: String
}

private struct Metadata: Codable {
    let engine: String
    let analysisScope: String
    let scannedSourceCount: Int
    let overlaySourceCount: Int
    let parseFailureCount: Int
}

private struct ScannerOutput: Codable {
    let schemaVersion: String
    let findings: [Finding]
    let errors: [String]
    let metadata: Metadata
}

private struct Options {
    let scanRoot: URL
    let fixtureRoot: URL?
}

private enum InvocationError: Error, CustomStringConvertible {
    case help
    case message(String)

    var description: String {
        switch self {
        case .help:
            return usage
        case let .message(message):
            return message
        }
    }
}

private func parseOptions() throws -> Options {
    var scanRoot: String?
    var fixtureRoot: String?
    var arguments = Array(CommandLine.arguments.dropFirst())

    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        switch option {
        case "--help", "-h":
            throw InvocationError.help
        case "--scan-root":
            guard !arguments.isEmpty else {
                throw InvocationError.message("--scan-root requires a path")
            }
            scanRoot = arguments.removeFirst()
        case "--fixture-root":
            guard !arguments.isEmpty else {
                throw InvocationError.message("--fixture-root requires a path")
            }
            fixtureRoot = arguments.removeFirst()
        default:
            throw InvocationError.message("unknown option \(option)")
        }
    }

    guard let scanRoot else {
        throw InvocationError.message("--scan-root is required")
    }
    return Options(
        scanRoot: URL(fileURLWithPath: scanRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath(),
        fixtureRoot: fixtureRoot.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
    )
}

private func writeStandardError(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
}

private func emit(_ output: ScannerOutput) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(output)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private let excludedDirectoryNames: Set<String> = [
    ".git", ".build", "DerivedData", ".remediation-execution",
]

private let shippingRoots = [
    "Packages/RuneScribeArchitecture/Sources",
    "RuneScrib",
]

private struct SourcePath {
    let relativePath: String
    let fileURL: URL
    let fromOverlay: Bool
}

private func sourceFiles(beneath base: URL, fromOverlay: Bool) throws -> [String: SourcePath] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw InvocationError.message("scan root is not a directory: \(base.path)")
    }

    var result: [String: SourcePath] = [:]
    for shippingRoot in shippingRoots {
        let directory = base.appendingPathComponent(shippingRoot, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            continue
        }

        for case let fileURL as URL in enumerator {
            let components = fileURL.pathComponents
            if components.contains(where: excludedDirectoryNames.contains) {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension == "swift" else { continue }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let marker = "/\(shippingRoot)/"
            guard let markerRange = fileURL.path.range(of: marker, options: .backwards) else {
                continue
            }
            let relativePath = shippingRoot + "/" + fileURL.path[markerRange.upperBound...]
            result[relativePath] = SourcePath(
                relativePath: relativePath,
                fileURL: fileURL,
                fromOverlay: fromOverlay
            )
        }
    }
    return result
}

private final class ParsedSource {
    let relativePath: String
    let fromOverlay: Bool
    let source: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter
    let nodes: [Syntax]

    init(path: SourcePath, source: String) {
        relativePath = path.relativePath
        fromOverlay = path.fromOverlay
        self.source = source
        tree = Parser.parse(source: source)
        converter = SourceLocationConverter(fileName: path.relativePath, tree: tree)

        var collected: [Syntax] = []
        var stack = [Syntax(tree)]
        while let current = stack.popLast() {
            collected.append(current)
            stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
        }
        nodes = collected
    }

    func line<T: SyntaxProtocol>(of node: T) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}

private func modifierNames(_ modifiers: DeclModifierListSyntax) -> Set<String> {
    Set(modifiers.map { $0.name.text })
}

private func isExternallyVisible(_ modifiers: DeclModifierListSyntax) -> Bool {
    !modifierNames(modifiers).isDisjoint(with: ["open", "public", "package"])
}

private func extensionDecl(containing syntax: Syntax) -> ExtensionDeclSyntax? {
    var current = syntax.parent
    while let node = current {
        if let declaration = node.as(ExtensionDeclSyntax.self) { return declaration }
        if node.is(SourceFileSyntax.self) { return nil }
        current = node.parent
    }
    return nil
}

private func memberIsExternallyVisible(
    _ modifiers: DeclModifierListSyntax,
    syntax: Syntax
) -> Bool {
    if isExternallyVisible(modifiers) { return true }
    var current = syntax.parent
    while let node = current {
        if let declaration = node.as(ProtocolDeclSyntax.self) {
            return isExternallyVisible(declaration.modifiers)
        }
        if nominalContext(for: node) != nil || node.is(SourceFileSyntax.self) { break }
        current = node.parent
    }
    guard let extensionDeclaration = extensionDecl(containing: syntax) else { return false }
    return isExternallyVisible(extensionDeclaration.modifiers)
}

private func isTopLevelOwnerDeclaration(_ syntax: Syntax) -> Bool {
    var current = syntax.parent
    while let node = current {
        if node.is(SourceFileSyntax.self) { return true }
        if nominalContext(for: node) != nil || node.is(ExtensionDeclSyntax.self) ||
            node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) ||
            node.is(ClosureExprSyntax.self)
        {
            return false
        }
        current = node.parent
    }
    return false
}

private func isCanonicalOwnerMember(
    _ syntax: Syntax,
    owner expectedOwner: String,
    source: ParsedSource,
    path expectedPath: String
) -> Bool {
    var current = syntax.parent
    while let node = current {
        if let nominal = nominalContext(for: node) {
            return source.relativePath == expectedPath && nominal.name == expectedOwner &&
                isTopLevelOwnerDeclaration(node)
        }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            let owner = declaration.extendedType.trimmedDescription
                .split(separator: ".").last.map(String.init)
            return source.relativePath.contains(
                "/Sources/RuneScribeRuntimeCore/"
            ) && owner == expectedOwner && isTopLevelOwnerDeclaration(node)
        }
        if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) ||
            node.is(ClosureExprSyntax.self)
        {
            return false
        }
        current = node.parent
    }
    return false
}

private func canonicalStoredFields(
    owner: String,
    path: String,
    in sources: [ParsedSource]
) -> [String: Set<String>] {
    var fields: [String: Set<String>] = [:]
    for source in sources where source.relativePath == path {
        for node in source.nodes {
            guard let variable = node.as(VariableDeclSyntax.self),
                  isCanonicalOwnerMember(node, owner: owner, source: source, path: path),
                  isRetainedOrGlobalVariable(variable)
            else {
                continue
            }
            for binding in variable.bindings {
                guard let annotation = binding.typeAnnotation else { continue }
                for name in patternNames(binding.pattern) {
                    fields[name, default: []].formUnion(typeNames(in: annotation.type))
                }
            }
        }
    }
    return fields
}

private struct NominalContext {
    let name: String
    let inheritance: Set<String>
    let genericParameters: Set<String>
    let modifiers: DeclModifierListSyntax
    let syntax: Syntax
}

private func typeNames<T: SyntaxProtocol>(in syntax: T) -> Set<String> {
    var names: Set<String> = []
    var stack = [Syntax(syntax)]
    while let current = stack.popLast() {
        if let identifier = current.as(IdentifierTypeSyntax.self) {
            names.insert(identifier.name.text)
        } else if let member = current.as(MemberTypeSyntax.self) {
            names.insert(member.name.text)
        } else if current.is(ArrayTypeSyntax.self) {
            names.insert("Array")
        } else if current.is(DictionaryTypeSyntax.self) {
            names.insert("Dictionary")
        } else if current.is(OptionalTypeSyntax.self) ||
                    current.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
        {
            names.insert("Optional")
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return names
}

private func outerTypeNames(in type: TypeSyntax) -> Set<String> {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return [identifier.name.text]
    }
    if let member = type.as(MemberTypeSyntax.self) {
        return [member.name.text]
    }
    if type.is(ArrayTypeSyntax.self) {
        return ["Array"]
    }
    if type.is(DictionaryTypeSyntax.self) {
        return ["Dictionary"]
    }
    if let optional = type.as(OptionalTypeSyntax.self) {
        return Set(["Optional"]).union(outerTypeNames(in: optional.wrappedType))
    }
    if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return Set(["Optional"]).union(outerTypeNames(in: optional.wrappedType))
    }
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return outerTypeNames(in: attributed.baseType)
    }
    return []
}

private func inheritanceNames(_ clause: InheritanceClauseSyntax?) -> Set<String> {
    guard let clause else { return [] }
    return clause.inheritedTypes.reduce(into: Set<String>()) { names, inherited in
        names.formUnion(typeNames(in: inherited.type))
    }
}

private func genericParameterNames(_ clause: GenericParameterClauseSyntax?) -> Set<String> {
    guard let clause else { return [] }
    return Set(clause.parameters.map { $0.name.text })
}

private func genericConstraintSubjectNames<T: SyntaxProtocol>(_ type: T) -> Set<String> {
    guard let identifier = Syntax(type).as(IdentifierTypeSyntax.self) else { return [] }
    return [identifier.name.text]
}

private func constrainedGenericNames(
    parameters: GenericParameterClauseSyntax?,
    whereClause: GenericWhereClauseSyntax?,
    constrainedTo targetTypes: Set<String>
) -> Set<String> {
    var result: Set<String> = []
    var relationships: [(left: Set<String>, right: Set<String>)] = []
    if let parameters {
        for parameter in parameters.parameters {
            guard let inheritedType = parameter.inheritedType else { continue }
            relationships.append(([parameter.name.text], typeNames(in: inheritedType)))
        }
    }
    if let whereClause {
        for requirement in whereClause.requirements {
            switch requirement.requirement {
            case let .conformanceRequirement(conformance):
                relationships.append((
                    genericConstraintSubjectNames(conformance.leftType),
                    typeNames(in: conformance.rightType)
                ))
            case let .sameTypeRequirement(sameType):
                relationships.append((
                    genericConstraintSubjectNames(sameType.leftType),
                    typeNames(in: sameType.rightType)
                ))
                relationships.append((
                    genericConstraintSubjectNames(sameType.rightType),
                    typeNames(in: sameType.leftType)
                ))
            case .layoutRequirement:
                break
            @unknown default:
                break
            }
        }
    }

    var known = targetTypes
    var changed = true
    while changed {
        changed = false
        for relationship in relationships where !relationship.right.isDisjoint(with: known) {
            let additions = relationship.left.subtracting(known)
            if !additions.isEmpty {
                known.formUnion(additions)
                result.formUnion(additions)
                changed = true
            }
        }
    }
    return result
}

private func serviceConstrainedGenericNames(
    containing syntax: Syntax,
    serviceTypes: Set<String>
) -> Set<String> {
    var result: Set<String> = []
    var current: Syntax? = syntax
    while let node = current {
        if let declaration = node.as(FunctionDeclSyntax.self) {
            result.formUnion(constrainedGenericNames(
                parameters: declaration.genericParameterClause,
                whereClause: declaration.genericWhereClause,
                constrainedTo: serviceTypes
            ))
        } else if let declaration = node.as(ActorDeclSyntax.self) {
            result.formUnion(constrainedGenericNames(
                parameters: declaration.genericParameterClause,
                whereClause: declaration.genericWhereClause,
                constrainedTo: serviceTypes
            ))
        } else if let declaration = node.as(ClassDeclSyntax.self) {
            result.formUnion(constrainedGenericNames(
                parameters: declaration.genericParameterClause,
                whereClause: declaration.genericWhereClause,
                constrainedTo: serviceTypes
            ))
        } else if let declaration = node.as(StructDeclSyntax.self) {
            result.formUnion(constrainedGenericNames(
                parameters: declaration.genericParameterClause,
                whereClause: declaration.genericWhereClause,
                constrainedTo: serviceTypes
            ))
        } else if let declaration = node.as(EnumDeclSyntax.self) {
            result.formUnion(constrainedGenericNames(
                parameters: declaration.genericParameterClause,
                whereClause: declaration.genericWhereClause,
                constrainedTo: serviceTypes
            ))
        } else if let declaration = node.as(ExtensionDeclSyntax.self) {
            result.formUnion(constrainedGenericNames(
                parameters: nil,
                whereClause: declaration.genericWhereClause,
                constrainedTo: serviceTypes
            ))
        }
        current = node.parent
    }
    return result
}

private func scopedGenericParameterNames(containing syntax: Syntax) -> Set<String> {
    var result: Set<String> = []
    var current: Syntax? = syntax
    while let node = current {
        if let declaration = node.as(FunctionDeclSyntax.self) {
            result.formUnion(genericParameterNames(declaration.genericParameterClause))
        } else if let declaration = node.as(ActorDeclSyntax.self) {
            result.formUnion(genericParameterNames(declaration.genericParameterClause))
        } else if let declaration = node.as(ClassDeclSyntax.self) {
            result.formUnion(genericParameterNames(declaration.genericParameterClause))
        } else if let declaration = node.as(StructDeclSyntax.self) {
            result.formUnion(genericParameterNames(declaration.genericParameterClause))
        } else if let declaration = node.as(EnumDeclSyntax.self) {
            result.formUnion(genericParameterNames(declaration.genericParameterClause))
        }
        current = node.parent
    }
    return result
}

private func qualifiedTypeNames(in type: TypeSyntax) -> Set<String> {
    var result: Set<String> = []
    var stack = [Syntax(type)]
    while let current = stack.popLast() {
        if let member = current.as(MemberTypeSyntax.self) {
            result.insert(member.name.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return result
}

private func resolvedServiceTypeNames<T: SyntaxProtocol>(
    _ type: TypeSyntax,
    at syntax: T,
    serviceTypes: Set<String>,
    localNominalShadows: Set<String> = []
) -> Set<String> {
    var names = typeNames(in: type)
    let qualifiedNames = qualifiedTypeNames(in: type)
    names.subtract(localNominalShadows.subtracting(qualifiedNames))
    let constrained = serviceConstrainedGenericNames(
        containing: Syntax(syntax),
        serviceTypes: serviceTypes
    )
    let unconstrained = scopedGenericParameterNames(containing: Syntax(syntax))
        .subtracting(constrained)
    names.subtract(unconstrained)
    return names.isDisjoint(with: constrained) ? names : names.union(serviceTypes)
}

private func nominalContext(for syntax: Syntax) -> NominalContext? {
    if let declaration = syntax.as(ActorDeclSyntax.self) {
        return NominalContext(
            name: declaration.name.text,
            inheritance: inheritanceNames(declaration.inheritanceClause),
            genericParameters: genericParameterNames(declaration.genericParameterClause),
            modifiers: declaration.modifiers,
            syntax: syntax
        )
    }
    if let declaration = syntax.as(ClassDeclSyntax.self) {
        return NominalContext(
            name: declaration.name.text,
            inheritance: inheritanceNames(declaration.inheritanceClause),
            genericParameters: genericParameterNames(declaration.genericParameterClause),
            modifiers: declaration.modifiers,
            syntax: syntax
        )
    }
    if let declaration = syntax.as(StructDeclSyntax.self) {
        return NominalContext(
            name: declaration.name.text,
            inheritance: inheritanceNames(declaration.inheritanceClause),
            genericParameters: genericParameterNames(declaration.genericParameterClause),
            modifiers: declaration.modifiers,
            syntax: syntax
        )
    }
    if let declaration = syntax.as(EnumDeclSyntax.self) {
        return NominalContext(
            name: declaration.name.text,
            inheritance: inheritanceNames(declaration.inheritanceClause),
            genericParameters: genericParameterNames(declaration.genericParameterClause),
            modifiers: declaration.modifiers,
            syntax: syntax
        )
    }
    return nil
}

private func enclosingNominalName(_ syntax: Syntax) -> String? {
    var current = syntax.parent
    while let node = current {
        if let nominal = nominalContext(for: node) { return nominal.name }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            return declaration.extendedType.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        current = node.parent
    }
    return nil
}

private func enclosingOperationOwnerName(_ syntax: Syntax) -> String? {
    var current = syntax.parent
    while let node = current {
        if let nominal = nominalContext(for: node) { return nominal.name }
        if let declaration = node.as(ProtocolDeclSyntax.self) {
            return declaration.name.text
        }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            return declaration.extendedType.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        current = node.parent
    }
    return nil
}

private func enclosingNominalGenericParameters(_ syntax: Syntax) -> Set<String> {
    var current = syntax.parent
    while let node = current {
        if let nominal = nominalContext(for: node) { return nominal.genericParameters }
        current = node.parent
    }
    return []
}

private func isInsideExternallyVisibleEnum(_ syntax: Syntax) -> Bool {
    var current = syntax.parent
    while let node = current {
        if let declaration = node.as(EnumDeclSyntax.self) {
            return isExternallyVisible(declaration.modifiers)
        }
        if nominalContext(for: node) != nil { return false }
        current = node.parent
    }
    return false
}

private func enclosingFunction(_ syntax: Syntax) -> FunctionDeclSyntax? {
    var current = syntax.parent
    while let node = current {
        if let declaration = node.as(FunctionDeclSyntax.self) { return declaration }
        current = node.parent
    }
    return nil
}

private func isQualifiedFunctionParameter(
    _ name: String,
    typeName: String,
    containing syntax: Syntax
) -> Bool {
    guard let function = enclosingFunction(syntax) else { return false }
    return functionParameters(function).contains { parameter in
        parameter.name == name && parameter.type.trimmedDescription == typeName
    }
}

private func isRetainedOrGlobalVariable(_ declaration: VariableDeclSyntax) -> Bool {
    var current = Syntax(declaration).parent
    while let node = current {
        if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) ||
            node.is(ClosureExprSyntax.self) || node.is(AccessorDeclSyntax.self)
        {
            return false
        }
        if nominalContext(for: node) != nil || node.is(ExtensionDeclSyntax.self) {
            return true
        }
        current = node.parent
    }
    return true
}

private struct NominalShadow {
    let name: String
    let lexicalScope: Syntax
}

private func isLexicalScope(_ syntax: Syntax) -> Bool {
    nominalContext(for: syntax) != nil ||
        syntax.is(ExtensionDeclSyntax.self) ||
        syntax.is(FunctionDeclSyntax.self) ||
        syntax.is(InitializerDeclSyntax.self) ||
        syntax.is(ClosureExprSyntax.self) ||
        syntax.is(SourceFileSyntax.self)
}

private func nearestLexicalScope(containing declaration: Syntax) -> Syntax? {
    var current = declaration.parent
    while let node = current {
        if isLexicalScope(node) { return node }
        current = node.parent
    }
    return nil
}

private func visibleNominalShadowNames<T: SyntaxProtocol>(
    at syntax: T,
    shadows: [NominalShadow]
) -> Set<String> {
    var visibleScopes: [Syntax] = []
    var current: Syntax? = Syntax(syntax)
    while let node = current {
        if isLexicalScope(node) { visibleScopes.append(node) }
        current = node.parent
    }
    return Set(shadows.compactMap { shadow in
        visibleScopes.contains { $0.id == shadow.lexicalScope.id } ? shadow.name : nil
    })
}

private func patternNames(_ pattern: PatternSyntax) -> [String] {
    var result: [String] = []
    var stack = [Syntax(pattern)]
    while let current = stack.popLast() {
        if let identifier = current.as(IdentifierPatternSyntax.self) {
            result.append(identifier.identifier.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return result
}

private func expressionIdentifierNames(_ expression: ExprSyntax) -> Set<String> {
    var result: Set<String> = []
    var stack = [Syntax(expression)]
    while let current = stack.popLast() {
        if let reference = current.as(DeclReferenceExprSyntax.self) {
            result.insert(reference.baseName.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return result
}

private func resolvedExpressionServiceNames(
    _ expression: ExprSyntax,
    at syntax: Syntax,
    serviceTypes: Set<String>,
    localNominalShadows: Set<String>
) -> Set<String> {
    var names = expressionIdentifierNames(expression)
    var qualified: Set<String> = []
    var stack = [Syntax(expression)]
    while let current = stack.popLast() {
        if let member = current.as(MemberAccessExprSyntax.self),
           directExpressionName(member.base) == "RuneScribeContracts"
        {
            qualified.insert(member.declName.baseName.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    names.formUnion(qualified)
    names.subtract(localNominalShadows.subtracting(qualified))
    let constrained = serviceConstrainedGenericNames(
        containing: syntax,
        serviceTypes: serviceTypes
    )
    names.subtract(scopedGenericParameterNames(containing: syntax).subtracting(constrained))
    return names.isDisjoint(with: constrained) ? names : names.union(serviceTypes)
}

private func exactSelfExpression(_ expression: ExprSyntax) -> Bool {
    expression.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
}

private struct CallTarget {
    let base: ExprSyntax?
    let member: String
}

private func callTarget(_ call: FunctionCallExprSyntax) -> CallTarget? {
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
        return CallTarget(base: member.base, member: member.declName.baseName.text)
    }
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
        return CallTarget(base: nil, member: reference.baseName.text)
    }
    if let specialization = call.calledExpression.as(GenericSpecializationExprSyntax.self) {
        if let member = specialization.expression.as(MemberAccessExprSyntax.self) {
            return CallTarget(base: member.base, member: member.declName.baseName.text)
        }
        if let reference = specialization.expression.as(DeclReferenceExprSyntax.self) {
            return CallTarget(base: nil, member: reference.baseName.text)
        }
    }
    return nil
}

private func directExpressionName(_ expression: ExprSyntax?) -> String? {
    guard let expression else { return nil }
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text
    }
    if let member = expression.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text
    }
    if let call = expression.as(FunctionCallExprSyntax.self) {
        return callTarget(call)?.member
    }
    if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
        return directExpressionName(subscriptCall.calledExpression)
    }
    if let optional = expression.as(OptionalChainingExprSyntax.self) {
        return directExpressionName(optional.expression)
    }
    if let forced = expression.as(ForceUnwrapExprSyntax.self) {
        return directExpressionName(forced.expression)
    }
    return nil
}

private func contextualTypeNames(containing syntax: Syntax) -> Set<String> {
    var current = syntax.parent
    while let node = current {
        if let binding = node.as(PatternBindingSyntax.self),
           let annotation = binding.typeAnnotation
        {
            return typeNames(in: annotation.type)
        }
        if let function = node.as(FunctionDeclSyntax.self),
           let returnType = function.signature.returnClause?.type
        {
            return typeNames(in: returnType)
        }
        if node.is(CodeBlockItemSyntax.self) || node.is(ReturnStmtSyntax.self) ||
            node.is(IfExprSyntax.self) || node.is(SwitchExprSyntax.self)
        {
            current = node.parent
            continue
        }
        current = node.parent
    }
    return []
}

private func directReferencedIdentifier(_ expression: ExprSyntax) -> String? {
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text
    }
    if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
       let element = tuple.elements.first
    {
        return directReferencedIdentifier(element.expression)
    }
    if let optional = expression.as(OptionalChainingExprSyntax.self) {
        return directReferencedIdentifier(optional.expression)
    }
    if let forced = expression.as(ForceUnwrapExprSyntax.self) {
        return directReferencedIdentifier(forced.expression)
    }
    return nil
}

private func labeledArgument(
    _ label: String,
    in call: FunctionCallExprSyntax
) -> ExprSyntax? {
    call.arguments.first { $0.label?.text == label }?.expression
}

private func isExactIdentifierArgument(
    _ label: String,
    named expectedName: String,
    in call: FunctionCallExprSyntax
) -> Bool {
    guard let expression = labeledArgument(label, in: call) else { return false }
    return directReferencedIdentifier(expression) == expectedName
}

private func isExactUnqualifiedMemberArgument(
    _ label: String,
    named expectedName: String,
    in call: FunctionCallExprSyntax
) -> Bool {
    guard let expression = labeledArgument(label, in: call),
          let member = expression.as(MemberAccessExprSyntax.self)
    else {
        return false
    }
    return member.base == nil && member.declName.baseName.text == expectedName
}

private func isExactCatalogMemberArgument(
    _ label: String?,
    catalogName: String,
    memberName: String,
    in call: FunctionCallExprSyntax
) -> Bool {
    guard let argument = call.arguments.first(where: { $0.label?.text == label }),
          let member = argument.expression.as(MemberAccessExprSyntax.self),
          member.declName.baseName.text == memberName,
          member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == catalogName
    else {
        return false
    }
    return true
}

private func inferredExpressionTypes(
    _ expression: ExprSyntax?,
    variables: [String: Set<String>],
    functionReturns: [String: Set<String>] = [:]
) -> Set<String> {
    guard let expression else { return [] }
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return variables[reference.baseName.text, default: []]
    }
    if expression.is(StringLiteralExprSyntax.self) { return ["String"] }
    if expression.is(IntegerLiteralExprSyntax.self) { return ["Int"] }
    if expression.is(FloatLiteralExprSyntax.self) { return ["Double"] }
    if expression.is(BooleanLiteralExprSyntax.self) { return ["Bool"] }
    if expression.is(ArrayExprSyntax.self) { return ["Array"] }
    if expression.is(DictionaryExprSyntax.self) { return ["Dictionary"] }
    if let call = expression.as(FunctionCallExprSyntax.self), let name = callTarget(call)?.member {
        return functionReturns[name, default: []].union([name])
    }
    if let typeExpression = expression.as(TypeExprSyntax.self) {
        return typeNames(in: typeExpression.type)
    }
    if let cast = expression.as(AsExprSyntax.self) {
        return typeNames(in: cast.type)
    }
    if let optional = expression.as(OptionalChainingExprSyntax.self) {
        return inferredExpressionTypes(
            optional.expression,
            variables: variables,
            functionReturns: functionReturns
        )
    }
    if let forced = expression.as(ForceUnwrapExprSyntax.self) {
        return inferredExpressionTypes(
            forced.expression,
            variables: variables,
            functionReturns: functionReturns
        )
    }
    if let attempted = expression.as(TryExprSyntax.self) {
        return inferredExpressionTypes(
            attempted.expression,
            variables: variables,
            functionReturns: functionReturns
        )
    }
    if let awaited = expression.as(AwaitExprSyntax.self) {
        return inferredExpressionTypes(
            awaited.expression,
            variables: variables,
            functionReturns: functionReturns
        )
    }
    return []
}

private func descendantCalls<T: SyntaxProtocol>(of syntax: T) -> [FunctionCallExprSyntax] {
    var result: [FunctionCallExprSyntax] = []
    var stack = [Syntax(syntax)]
    while let current = stack.popLast() {
        if let call = current.as(FunctionCallExprSyntax.self) { result.append(call) }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return result
}

private func directCalls(in function: FunctionDeclSyntax) -> [FunctionCallExprSyntax] {
    descendantCalls(of: function).filter { call in
        var current = Syntax(call).parent
        while let ancestor = current {
            if let enclosing = ancestor.as(FunctionDeclSyntax.self) {
                return enclosing.id == function.id
            }
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(InitializerDeclSyntax.self) {
                return false
            }
            current = ancestor.parent
        }
        return false
    }
}

private func terminalOutermostCalls(in function: FunctionDeclSyntax) -> [FunctionCallExprSyntax] {
    guard let terminal = function.body?.statements.last else { return [] }
    return descendantCalls(of: terminal).filter { call in
        var current = Syntax(call).parent
        while let ancestor = current, ancestor.id != terminal.id {
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(FunctionDeclSyntax.self) ||
                ancestor.is(InitializerDeclSyntax.self) || ancestor.is(FunctionCallExprSyntax.self)
            {
                return false
            }
            current = ancestor.parent
        }
        return current?.id == terminal.id
    }
}

private func terminalResultExpression(in function: FunctionDeclSyntax) -> ExprSyntax? {
    guard let item = function.body?.statements.last?.item else { return nil }
    if let statement = item.as(ReturnStmtSyntax.self) {
        return statement.expression
    }
    return item.as(ExprSyntax.self)
}

private struct TransparentRuntimeCall {
    let call: FunctionCallExprSyntax
    let sawTry: Bool
    let sawAwait: Bool
}

private func transparentRuntimeCall(
    in expression: ExprSyntax,
    sawTry: Bool = false,
    sawAwait: Bool = false
) -> TransparentRuntimeCall? {
    if let call = expression.as(FunctionCallExprSyntax.self) {
        return TransparentRuntimeCall(call: call, sawTry: sawTry, sawAwait: sawAwait)
    }
    if let attempted = expression.as(TryExprSyntax.self),
       attempted.questionOrExclamationMark == nil
    {
        return transparentRuntimeCall(
            in: attempted.expression,
            sawTry: true,
            sawAwait: sawAwait
        )
    }
    if let awaited = expression.as(AwaitExprSyntax.self) {
        return transparentRuntimeCall(
            in: awaited.expression,
            sawTry: sawTry,
            sawAwait: true
        )
    }
    if let tuple = expression.as(TupleExprSyntax.self),
       tuple.elements.count == 1,
       let element = tuple.elements.first,
       element.label == nil,
       element.trailingComma == nil
    {
        return transparentRuntimeCall(
            in: element.expression,
            sawTry: sawTry,
            sawAwait: sawAwait
        )
    }
    return nil
}

private func canonicalDirectCall(
    in expression: ExprSyntax,
    allowingDiscardAssignment: Bool = false
) -> FunctionCallExprSyntax? {
    if let transparent = transparentRuntimeCall(in: expression) {
        return transparent.call
    }
    if allowingDiscardAssignment,
       let sequence = expression.as(SequenceExprSyntax.self)
    {
        let elements = Array(sequence.elements)
        guard elements.count == 3,
              elements[0].is(DiscardAssignmentExprSyntax.self),
              elements[1].is(AssignmentExprSyntax.self)
        else {
            return nil
        }
        return transparentRuntimeCall(in: elements[2])?.call
    }
    return nil
}

private enum RuntimeResultUse: Equatable {
    case value
    case discarded
}

private struct CanonicalRuntimeCall {
    let call: FunctionCallExprSyntax
    let resultUse: RuntimeResultUse
    let sawTry: Bool
    let sawAwait: Bool
}

private func canonicalRuntimeTerminalCall(
    in function: FunctionDeclSyntax
) -> CanonicalRuntimeCall? {
    guard function.body?.statements.count == 1,
          let item = function.body?.statements.first?.item
    else {
        return nil
    }
    if let statement = item.as(ReturnStmtSyntax.self),
       let expression = statement.expression,
       let transparent = transparentRuntimeCall(in: expression)
    {
        return CanonicalRuntimeCall(
            call: transparent.call,
            resultUse: .value,
            sawTry: transparent.sawTry,
            sawAwait: transparent.sawAwait
        )
    }
    guard let expression = item.as(ExprSyntax.self) else { return nil }
    if let transparent = transparentRuntimeCall(in: expression) {
        return CanonicalRuntimeCall(
            call: transparent.call,
            resultUse: .value,
            sawTry: transparent.sawTry,
            sawAwait: transparent.sawAwait
        )
    }
    if let sequence = expression.as(SequenceExprSyntax.self) {
        let elements = Array(sequence.elements)
        guard elements.count == 3,
              elements[0].is(DiscardAssignmentExprSyntax.self),
              elements[1].is(AssignmentExprSyntax.self),
              let transparent = transparentRuntimeCall(in: elements[2])
        else {
            return nil
        }
        return CanonicalRuntimeCall(
            call: transparent.call,
            resultUse: .discarded,
            sawTry: transparent.sawTry,
            sawAwait: transparent.sawAwait
        )
    }
    return nil
}

private func canonicalTerminalCall(
    in function: FunctionDeclSyntax,
    allowingDiscardAssignment: Bool = false
) -> FunctionCallExprSyntax? {
    guard function.body?.statements.count == 1,
          let item = function.body?.statements.first?.item
    else {
        return nil
    }
    if let statement = item.as(ReturnStmtSyntax.self),
       let expression = statement.expression
    {
        return canonicalDirectCall(
            in: expression,
            allowingDiscardAssignment: allowingDiscardAssignment
        )
    }
    guard let expression = item.as(ExprSyntax.self) else { return nil }
    return canonicalDirectCall(
        in: expression,
        allowingDiscardAssignment: allowingDiscardAssignment
    )
}

private func compactSyntaxText<T: SyntaxProtocol>(_ syntax: T) -> String {
    syntax.trimmedDescription.filter { !$0.isWhitespace }
}

private func callArgumentLabels(_ call: FunctionCallExprSyntax) -> [String] {
    call.arguments.map { $0.label?.text ?? "_" }
}

private func functionParameterIdentities(
    _ function: FunctionDeclSyntax
) -> [String] {
    function.signature.parameterClause.parameters.map { parameter in
        "\(parameter.firstName.text):\(parameter.secondName?.text ?? parameter.firstName.text)"
    }
}

private func functionParameterTypeTexts(_ function: FunctionDeclSyntax) -> [String] {
    function.signature.parameterClause.parameters.map { compactSyntaxText($0.type) }
}

private func hasNoTrailingClosures(_ call: FunctionCallExprSyntax) -> Bool {
    call.trailingClosure == nil && call.additionalTrailingClosures.isEmpty
}

private func exactIdentifier(_ expression: ExprSyntax, named name: String) -> Bool {
    expression.as(DeclReferenceExprSyntax.self)?.baseName.text == name
}

private func exactMemberChain(_ expression: ExprSyntax, names: [String]) -> Bool {
    guard let last = names.last else { return false }
    if names.count == 1 { return exactIdentifier(expression, named: last) }
    guard let member = expression.as(MemberAccessExprSyntax.self),
          member.declName.baseName.text == last,
          let base = member.base
    else {
        return false
    }
    return exactMemberChain(base, names: Array(names.dropLast()))
}

private func exactUnqualifiedMember(_ expression: ExprSyntax, named name: String) -> Bool {
    guard let member = expression.as(MemberAccessExprSyntax.self) else { return false }
    return member.base == nil && member.declName.baseName.text == name
}

private func exactUnqualifiedZeroArgumentCall(
    _ expression: ExprSyntax,
    named name: String
) -> Bool {
    guard let call = expression.as(FunctionCallExprSyntax.self),
          call.arguments.isEmpty, hasNoTrailingClosures(call)
    else {
        return false
    }
    return call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == name
}

private func exactCatalogMemberExpression(
    _ expression: ExprSyntax,
    catalogName: String,
    memberName: String
) -> Bool {
    guard let member = expression.as(MemberAccessExprSyntax.self),
          member.declName.baseName.text == memberName,
          let base = member.base?.as(DeclReferenceExprSyntax.self)
    else {
        return false
    }
    return base.baseName.text == catalogName
}

private func exactNilCoalescing(
    _ expression: ExprSyntax,
    left: String,
    right: [String]
) -> Bool {
    guard let sequence = expression.as(SequenceExprSyntax.self) else { return false }
    let elements = Array(sequence.elements)
    guard elements.count == 3,
          exactIdentifier(elements[0], named: left),
          elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text == "??"
    else {
        return false
    }
    return exactMemberChain(elements[2], names: right)
}

private func exactCallArguments(
    _ call: FunctionCallExprSyntax,
    labels: [String],
    predicates: [(ExprSyntax) -> Bool]
) -> Bool {
    guard hasNoTrailingClosures(call), call.arguments.count == labels.count,
          labels.count == predicates.count
    else {
        return false
    }
    for ((argument, label), predicate) in zip(zip(call.arguments, labels), predicates) {
        guard (argument.label?.text ?? "_") == label,
              predicate(argument.expression)
        else {
            return false
        }
    }
    return true
}

private func terminalOutermostCalls(in closure: ClosureExprSyntax) -> [FunctionCallExprSyntax] {
    guard let terminal = closure.statements.last else { return [] }
    return descendantCalls(of: terminal).filter { call in
        var current = Syntax(call).parent
        while let ancestor = current, ancestor.id != terminal.id {
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(FunctionDeclSyntax.self) ||
                ancestor.is(InitializerDeclSyntax.self) || ancestor.is(FunctionCallExprSyntax.self)
            {
                return false
            }
            current = ancestor.parent
        }
        return current?.id == terminal.id
    }
}

private func localBindingNames(in function: FunctionDeclSyntax) -> Set<String> {
    var names = Set(functionParameters(function).map(\.name))
    guard let body = function.body else { return names }
    var stack = [Syntax(body)]
    while let current = stack.popLast() {
        if let nested = current.as(FunctionDeclSyntax.self), nested.id != function.id {
            names.insert(nested.name.text)
            continue
        }
        if let variable = current.as(VariableDeclSyntax.self),
           enclosingFunction(current)?.id == function.id
        {
            for binding in variable.bindings {
                names.formUnion(patternNames(binding.pattern))
            }
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return names
}

private func declaredFieldName(
    referencedBy expression: ExprSyntax?,
    fieldTypes: [String: Set<String>],
    acceptedTypes: Set<String>,
    localBindings: Set<String>
) -> String? {
    guard let expression else { return nil }
    let name: String
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
        name = reference.baseName.text
        guard !localBindings.contains(name) else { return nil }
    } else if let member = expression.as(MemberAccessExprSyntax.self),
              member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
    {
        name = member.declName.baseName.text
    } else {
        return nil
    }
    guard !fieldTypes[name, default: []].isDisjoint(with: acceptedTypes) else { return nil }
    return name
}

private func catalogMemberReferences(
    in syntax: some SyntaxProtocol,
    catalogName: String
) -> Set<String> {
    var names: Set<String> = []
    var stack = [Syntax(syntax)]
    while let current = stack.popLast() {
        if let member = current.as(MemberAccessExprSyntax.self),
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == catalogName
        {
            names.insert(member.declName.baseName.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return names
}

private func unqualifiedMemberReferences<T: SyntaxProtocol>(in syntax: T) -> Set<String> {
    var names: Set<String> = []
    var stack = [Syntax(syntax)]
    while let current = stack.popLast() {
        if let member = current.as(MemberAccessExprSyntax.self), member.base == nil {
            names.insert(member.declName.baseName.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return names
}

private func isShortCircuitOperator(_ syntax: Syntax) -> Bool {
    guard let operation = syntax.as(BinaryOperatorExprSyntax.self) else { return false }
    return ["&&", "||"].contains(operation.operator.text)
}

private func containsEarlyExitOrConditionalFlow(
    in function: FunctionDeclSyntax,
    allowingTerminalReturn: Bool = false
) -> Bool {
    var stack = function.body.map { [Syntax($0)] } ?? []
    while let current = stack.popLast() {
        if let returnStatement = current.as(ReturnStmtSyntax.self) {
            let isAllowedTerminal = allowingTerminalReturn &&
                function.body?.statements.last?.item.as(ReturnStmtSyntax.self)?.id == returnStatement.id
            if !isAllowedTerminal { return true }
        }
        if current.is(ThrowStmtSyntax.self) || current.is(BreakStmtSyntax.self) ||
            current.is(ContinueStmtSyntax.self) || current.is(LabeledStmtSyntax.self) ||
            current.is(DoStmtSyntax.self) || current.is(CatchClauseSyntax.self) ||
            current.is(DeferStmtSyntax.self)
        {
            return true
        }
        if current.is(IfExprSyntax.self) || current.is(SwitchExprSyntax.self) ||
            current.is(GuardStmtSyntax.self) || current.is(ForStmtSyntax.self) ||
            current.is(WhileStmtSyntax.self) || current.is(RepeatStmtSyntax.self) ||
            current.is(TernaryExprSyntax.self) || isShortCircuitOperator(current)
        {
            return true
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private func hasConditionalAncestor(
    _ syntax: Syntax,
    before ancestor: Syntax
) -> Bool {
    var current = syntax.parent
    while let node = current, node.id != ancestor.id {
        if node.is(IfExprSyntax.self) || node.is(SwitchExprSyntax.self) ||
            node.is(GuardStmtSyntax.self) || node.is(ForStmtSyntax.self) ||
            node.is(WhileStmtSyntax.self) || node.is(RepeatStmtSyntax.self) ||
            node.is(TernaryExprSyntax.self) || isShortCircuitOperator(node)
        {
            return true
        }
        current = node.parent
    }
    return false
}

private func assignments<T: SyntaxProtocol>(in scope: T) -> [(lhs: ExprSyntax, rhs: ExprSyntax, syntax: Syntax)] {
    var result: [(ExprSyntax, ExprSyntax, Syntax)] = []
    var stack = [Syntax(scope)]
    while let current = stack.popLast() {
        if let sequence = current.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            for index in elements.indices where elements[index].is(AssignmentExprSyntax.self) {
                guard index > elements.startIndex, index + 1 < elements.endIndex else { continue }
                result.append((elements[index - 1], elements[index + 1], Syntax(elements[index])))
            }
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return result
}

private func assignmentTargetName(_ expression: ExprSyntax) -> String? {
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text
    }
    if let member = expression.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text
    }
    if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
        return directExpressionName(subscriptCall.calledExpression)
    }
    if let optional = expression.as(OptionalChainingExprSyntax.self) {
        return assignmentTargetName(optional.expression)
    }
    return nil
}

private func isNonlocalMemberOrSubscriptTarget(_ expression: ExprSyntax) -> Bool {
    if let member = expression.as(MemberAccessExprSyntax.self) {
        return member.base != nil
    }
    if expression.is(SubscriptCallExprSyntax.self) { return true }
    if let optional = expression.as(OptionalChainingExprSyntax.self) {
        return isNonlocalMemberOrSubscriptTarget(optional.expression)
    }
    if let forced = expression.as(ForceUnwrapExprSyntax.self) {
        return isNonlocalMemberOrSubscriptTarget(forced.expression)
    }
    return false
}

private func expressionContainsSelf(_ expression: ExprSyntax) -> Bool {
    var stack = [Syntax(expression)]
    while let current = stack.popLast() {
        if let reference = current.as(DeclReferenceExprSyntax.self),
           reference.baseName.text == "self"
        {
            return true
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private func enclosingCallableScope(_ syntax: Syntax) -> Syntax? {
    var current: Syntax? = syntax
    while let node = current {
        if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) ||
            node.is(AccessorDeclSyntax.self) || node.is(ClosureExprSyntax.self)
        {
            return node
        }
        current = node.parent
    }
    return nil
}

private func selfAliasNames(containing syntax: Syntax) -> Set<String> {
    guard let scope = enclosingCallableScope(syntax) else { return [] }
    var aliases: Set<String> = []
    var changed = true
    while changed {
        changed = false
        var stack = [scope]
        while let current = stack.popLast() {
            if let variable = current.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let initializer = binding.initializer else { continue }
                    let carriesSelf = expressionContainsSelf(initializer.value) ||
                        !expressionIdentifierNames(initializer.value).isDisjoint(with: aliases)
                    guard carriesSelf else { continue }
                    let additions = Set(patternNames(binding.pattern)).subtracting(aliases)
                    if !additions.isEmpty {
                        aliases.formUnion(additions)
                        changed = true
                    }
                }
            }
            stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
        }
        for assignment in assignments(in: scope) {
            guard let destination = assignmentTargetName(assignment.lhs) else { continue }
            let carriesSelf = expressionContainsSelf(assignment.rhs) ||
                !expressionIdentifierNames(assignment.rhs).isDisjoint(with: aliases)
            if carriesSelf && aliases.insert(destination).inserted { changed = true }
        }
    }
    return aliases
}

private func expressionCarriesSelf(_ expression: ExprSyntax, aliases: Set<String>) -> Bool {
    expressionContainsSelf(expression) ||
        !expressionIdentifierNames(expression).isDisjoint(with: aliases)
}

private func propagatedIdentifierNames(
    from seedNames: Set<String>,
    in scope: Syntax
) -> Set<String> {
    var names = seedNames
    var changed = true
    while changed {
        changed = false
        var stack = [scope]
        while let current = stack.popLast() {
            if let variable = current.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let initializer = binding.initializer,
                          !expressionIdentifierNames(initializer.value).isDisjoint(with: names)
                    else {
                        continue
                    }
                    let additions = Set(patternNames(binding.pattern)).subtracting(names)
                    if !additions.isEmpty {
                        names.formUnion(additions)
                        changed = true
                    }
                }
            }
            stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
        }
        for assignment in assignments(in: scope) {
            guard let destination = assignmentTargetName(assignment.lhs),
                  !expressionIdentifierNames(assignment.rhs).isDisjoint(with: names)
            else {
                continue
            }
            if names.insert(destination).inserted { changed = true }
        }
    }
    return names
}

private struct AliasDeclaration {
    let name: String
    let referencedNames: Set<String>
    let isDirectRawErasure: Bool
    let path: String
    let line: Int
}

private struct ProtocolDeclaration {
    let name: String
    let inheritedNames: Set<String>
    let path: String
    let line: Int
}

private func protocolSelfConstraintNames(_ clause: GenericWhereClauseSyntax?) -> Set<String> {
    guard let clause else { return [] }
    var names: Set<String> = []
    for requirement in clause.requirements {
        switch requirement.requirement {
        case let .conformanceRequirement(conformance):
            if typeNames(in: conformance.leftType).contains("Self") {
                names.formUnion(typeNames(in: conformance.rightType))
            }
        case let .sameTypeRequirement(sameType):
            if typeNames(in: sameType.leftType).contains("Self") {
                names.formUnion(typeNames(in: sameType.rightType))
            }
            if typeNames(in: sameType.rightType).contains("Self") {
                names.formUnion(typeNames(in: sameType.leftType))
            }
        case .layoutRequirement:
            break
        @unknown default:
            break
        }
    }
    names.remove("Self")
    return names
}

private func transitiveNames(
    roots: Set<String>,
    aliases: [AliasDeclaration],
    protocols: [ProtocolDeclaration]
) -> Set<String> {
    var result = roots
    var changed = true
    while changed {
        changed = false
        for alias in aliases where !result.contains(alias.name) {
            if !alias.referencedNames.isDisjoint(with: result) {
                result.insert(alias.name)
                changed = true
            }
        }
        for declaration in protocols where !result.contains(declaration.name) {
            if !declaration.inheritedNames.isDisjoint(with: result) {
                result.insert(declaration.name)
                changed = true
            }
        }
    }
    return result
}

private func expandedAliasTargets(
    _ names: Set<String>,
    aliases: [AliasDeclaration]
) -> Set<String> {
    var result = names
    var changed = true
    while changed {
        changed = false
        for alias in aliases where result.contains(alias.name) {
            let additions = alias.referencedNames.subtracting(result)
            if !additions.isEmpty {
                result.formUnion(additions)
                changed = true
            }
        }
    }
    return result
}

private func functionParameters(_ declaration: FunctionDeclSyntax) -> [(name: String, type: TypeSyntax)] {
    declaration.signature.parameterClause.parameters.compactMap { parameter in
        let name = parameter.secondName?.text ?? parameter.firstName.text
        guard name != "_" else { return nil }
        return (name, parameter.type)
    }
}

private func initializerParameters(_ declaration: InitializerDeclSyntax) -> [(name: String, type: TypeSyntax)] {
    declaration.signature.parameterClause.parameters.compactMap { parameter in
        let name = parameter.secondName?.text ?? parameter.firstName.text
        guard name != "_" else { return nil }
        return (name, parameter.type)
    }
}

private func lexicalVariableTypes(
    at syntax: Syntax,
    in source: ParsedSource,
    functionReturns: [String: Set<String>]
) -> [String: Set<String>] {
    let functionID = enclosingFunction(syntax)?.id
    var result: [String: Set<String>] = [:]
    for node in source.nodes {
        if let function = node.as(FunctionDeclSyntax.self), function.id == functionID {
            for parameter in functionParameters(function) {
                result[parameter.name] = outerTypeNames(in: parameter.type)
            }
        }
        guard let variable = node.as(VariableDeclSyntax.self) else { continue }
        let candidateFunctionID = enclosingFunction(node)?.id
        guard isRetainedOrGlobalVariable(variable) || candidateFunctionID == functionID else {
            continue
        }
        for binding in variable.bindings {
            let names = patternNames(binding.pattern)
            let annotated = binding.typeAnnotation.map { outerTypeNames(in: $0.type) } ?? []
            let inferred = inferredExpressionTypes(
                binding.initializer?.value,
                variables: result,
                functionReturns: functionReturns
            )
            for name in names {
                if !annotated.isEmpty {
                    result[name] = annotated
                } else {
                    result[name, default: []].formUnion(inferred)
                }
            }
        }
    }
    return result
}

private func isRawErasedValueType(
    _ type: TypeSyntax,
    genericNames: Set<String>,
    rawErasureTypes: Set<String>
) -> Bool {
    let compact = type.trimmedDescription.filter { !$0.isWhitespace }
    if compact == "Any" || compact == "AnyObject" ||
        compact == "anySendable" || compact == "anyActor"
    {
        return true
    }
    return !typeNames(in: type).isDisjoint(with: genericNames.union(rawErasureTypes))
}

private func isRawStorageType(
    _ type: TypeSyntax,
    genericNames: Set<String>,
    rawErasureTypes: Set<String>
) -> Bool {
    let compact = type.trimmedDescription.filter { !$0.isWhitespace }
    if compact.range(
        of: #"(^|[^A-Za-z0-9_])(Any|AnyObject)([^A-Za-z0-9_]|$)"#,
        options: .regularExpression
    ) != nil ||
        compact.contains("anySendable") || compact.contains("anyActor")
    {
        return true
    }
    return !typeNames(in: type).isDisjoint(with: genericNames.union(rawErasureTypes))
}

private func isProviderErasureSurfaceType(
    _ type: TypeSyntax,
    rawErasureTypes: Set<String>
) -> Bool {
    let compact = type.trimmedDescription.filter { !$0.isWhitespace }
    if compact.range(
        of: #"(^|[^A-Za-z0-9_])(Any|AnyObject)([^A-Za-z0-9_]|$)"#,
        options: .regularExpression
    ) != nil || compact.contains("anySendable") || compact.contains("anyActor") {
        return true
    }
    return !typeNames(in: type).isDisjoint(with: rawErasureTypes)
}

private func syntaxCarriesProviderValue<T: SyntaxProtocol>(
    _ syntax: T,
    providerNames: Set<String>,
    includeSelf: Bool
) -> Bool {
    var stack = [Syntax(syntax)]
    while let current = stack.popLast() {
        if let reference = current.as(DeclReferenceExprSyntax.self) {
            if providerNames.contains(reference.baseName.text) ||
                (includeSelf && reference.baseName.text == "self")
            {
                return true
            }
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private let providerContainerWrapperTargets: Set<String> = [
    "Array", "ContiguousArray", "Dictionary", "Optional", "Result", "Set",
    "failure", "some", "success",
]

private struct ServiceReturningOperation: Hashable {
    let owner: String?
    let name: String
}

private struct ProviderResultContext {
    let source: ParsedSource
    let providerTypes: Set<String>
    let wrapperTypes: Set<String>
    let providerReturningOperations: Set<ServiceReturningOperation>
    let includeSelf: Bool
}

private func syntaxIsDescendant(_ syntax: Syntax, of ancestor: Syntax) -> Bool {
    var current: Syntax? = syntax
    while let node = current {
        if node.id == ancestor.id { return true }
        current = node.parent
    }
    return false
}

private func nearestCodeBlock(containing syntax: Syntax) -> CodeBlockSyntax? {
    var current = syntax.parent
    while let node = current {
        if let block = node.as(CodeBlockSyntax.self) { return block }
        current = node.parent
    }
    return nil
}

private func syntaxDepth(_ syntax: Syntax) -> Int {
    var depth = 0
    var current = syntax.parent
    while let node = current {
        depth += 1
        current = node.parent
    }
    return depth
}

private func enclosingSubscript(_ syntax: Syntax) -> SubscriptDeclSyntax? {
    var current = syntax.parent
    while let node = current {
        if let declaration = node.as(SubscriptDeclSyntax.self) { return declaration }
        current = node.parent
    }
    return nil
}

private func resultRootExpressions(
    in statements: CodeBlockItemListSyntax,
    includeYields: Bool = true
) -> [ExprSyntax] {
    var result: [ExprSyntax] = []
    if let terminal = statements.last?.item.as(ExprSyntax.self) {
        result.append(terminal)
    }
    var stack = statements.map(Syntax.init)
    while let current = stack.popLast() {
        if current.is(ClosureExprSyntax.self) || current.is(FunctionDeclSyntax.self) ||
            current.is(InitializerDeclSyntax.self) || current.is(AccessorDeclSyntax.self)
        {
            continue
        }
        if let statement = current.as(ReturnStmtSyntax.self) {
            if let expression = statement.expression { result.append(expression) }
            continue
        }
        if includeYields, let statement = current.as(YieldStmtSyntax.self) {
            switch statement.yieldedExpressions {
            case let .single(expression):
                result.append(ExprSyntax(expression))
            case let .multiple(clause):
                result.append(contentsOf: clause.elements.map(\.expression))
            @unknown default:
                break
            }
            continue
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return result
}

private func accessorResultExpressions(_ accessorBlock: AccessorBlockSyntax) -> [ExprSyntax] {
    switch accessorBlock.accessors {
    case let .getter(statements):
        return resultRootExpressions(in: statements)
    case let .accessors(accessors):
        return accessors.flatMap { accessor -> [ExprSyntax] in
            guard ["get", "_read", "read"].contains(accessor.accessorSpecifier.text),
                  let body = accessor.body
            else {
                return []
            }
            return resultRootExpressions(in: body.statements)
        }
    @unknown default:
        return []
    }
}

private func nearestVisibleVariable(
    named name: String,
    at use: Syntax,
    in source: ParsedSource
) -> (declaration: VariableDeclSyntax, binding: PatternBindingSyntax)? {
    let useOffset = use.positionAfterSkippingLeadingTrivia.utf8Offset
    let useOwner = enclosingOperationOwnerName(use)
    var best: (
        declaration: VariableDeclSyntax,
        binding: PatternBindingSyntax,
        local: Bool,
        depth: Int,
        offset: Int
    )?
    for node in source.nodes {
        guard let declaration = node.as(VariableDeclSyntax.self) else { continue }
        for binding in declaration.bindings where patternNames(binding.pattern).contains(name) {
            let bindingSyntax = Syntax(binding)
            let offset = binding.positionAfterSkippingLeadingTrivia.utf8Offset
            let localScope = nearestCodeBlock(containing: bindingSyntax)
            if let localScope {
                guard offset < useOffset,
                      syntaxIsDescendant(use, of: Syntax(localScope))
                else {
                    continue
                }
            } else {
                let declarationOwner = enclosingOperationOwnerName(bindingSyntax)
                guard declarationOwner == nil || declarationOwner == useOwner else { continue }
            }
            let candidate = (
                declaration,
                binding,
                localScope != nil,
                localScope.map { syntaxDepth(Syntax($0)) } ?? 0,
                offset
            )
            if let best {
                let candidateRank = (candidate.2 ? 1 : 0, candidate.3, candidate.4)
                let bestRank = (best.local ? 1 : 0, best.depth, best.offset)
                if candidateRank <= bestRank { continue }
            }
            best = candidate
        }
    }
    return best.map { ($0.declaration, $0.binding) }
}

private func parameterProviderResolution(
    named name: String,
    at use: Syntax,
    providerTypes: Set<String>
) -> Bool? {
    if let function = enclosingFunction(use),
       let parameter = functionParameters(function).first(where: { $0.name == name })
    {
        return !typeNames(in: parameter.type).isDisjoint(with: providerTypes)
    }
    if let declaration = enclosingSubscript(use),
       let parameter = declaration.parameterClause.parameters.first(where: {
        ($0.secondName?.text ?? $0.firstName.text) == name
       })
    {
        return !typeNames(in: parameter.type).isDisjoint(with: providerTypes)
    }
    return nil
}

private func localFunctionShadows(
    _ name: String,
    at use: Syntax,
    in source: ParsedSource
) -> Bool {
    let useOffset = use.positionAfterSkippingLeadingTrivia.utf8Offset
    return source.nodes.contains { node in
        guard let function = node.as(FunctionDeclSyntax.self), function.name.text == name,
              let scope = nearestCodeBlock(containing: Syntax(function))
        else {
            return false
        }
        return function.positionAfterSkippingLeadingTrivia.utf8Offset < useOffset &&
            syntaxIsDescendant(use, of: Syntax(scope))
    }
}

private func providerReturningOperationMatches(
    name: String,
    base: ExprSyntax?,
    at use: Syntax,
    context: ProviderResultContext
) -> Bool {
    let candidates = context.providerReturningOperations.filter { $0.name == name }
    guard !candidates.isEmpty else { return false }
    if base == nil {
        let owner = enclosingOperationOwnerName(use)
        return candidates.contains { $0.owner == owner || $0.owner == nil }
    }
    if let reference = base?.as(DeclReferenceExprSyntax.self) {
        if reference.baseName.text == "self" {
            let owner = enclosingOperationOwnerName(use)
            return candidates.contains { $0.owner == owner }
        }
        if let resolved = nearestVisibleVariable(
            named: reference.baseName.text,
            at: use,
            in: context.source
        ) {
            let receiverTypes = resolved.binding.typeAnnotation.map {
                outerTypeNames(in: $0.type)
            } ?? []
            return candidates.contains { candidate in
                candidate.owner.map(receiverTypes.contains) == true
            }
        }
        return candidates.contains { $0.owner == reference.baseName.text }
    }
    if let call = base?.as(FunctionCallExprSyntax.self), let target = callTarget(call) {
        let constructedOwner = target.member == "init"
            ? directExpressionName(target.base)
            : (target.base == nil ? target.member : nil)
        if let constructedOwner {
            return candidates.contains { $0.owner == constructedOwner }
        }
    }
    return false
}

private func declarationIsLexicallyVisible(_ declaration: Syntax, at use: Syntax) -> Bool {
    if let scope = nearestCodeBlock(containing: declaration) {
        return syntaxIsDescendant(use, of: Syntax(scope))
    }
    let declarationOwner = enclosingOperationOwnerName(declaration)
    return declarationOwner == nil || declarationOwner == enclosingOperationOwnerName(use)
}

private func symbolIsShadowed(
    named symbolName: String,
    canonicalPath: String,
    at use: Syntax,
    in function: FunctionDeclSyntax?,
    source: ParsedSource
) -> Bool {
    if function.map({ functionParameters($0).contains(where: { $0.name == symbolName }) }) == true ||
        function.map({ genericParameterNames($0.genericParameterClause).contains(symbolName) }) == true ||
        enclosingNominalGenericParameters(use).contains(symbolName)
    {
        return true
    }
    if nearestVisibleVariable(named: symbolName, at: use, in: source) != nil {
        return true
    }
    for node in source.nodes {
        let declaredName: String?
        let isCanonicalDeclaration: Bool
        if let alias = node.as(TypeAliasDeclSyntax.self) {
            declaredName = alias.name.text
            isCanonicalDeclaration = false
        } else if let function = node.as(FunctionDeclSyntax.self) {
            declaredName = function.name.text
            isCanonicalDeclaration = false
        } else if let nominal = nominalContext(for: node) {
            declaredName = nominal.name
            isCanonicalDeclaration = source.relativePath == canonicalPath &&
                nearestCodeBlock(containing: node) == nil &&
                enclosingOperationOwnerName(node) == nil &&
                isExternallyVisible(nominal.modifiers)
        } else {
            continue
        }
        guard declaredName == symbolName, !isCanonicalDeclaration,
              declarationIsLexicallyVisible(node, at: use)
        else {
            continue
        }
        return true
    }
    return false
}

private func catalogSymbolIsShadowed(
    at use: Syntax,
    in function: FunctionDeclSyntax,
    source: ParsedSource
) -> Bool {
    symbolIsShadowed(
        named: "RuntimeApplicationEndpointCatalog",
        canonicalPath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift",
        at: use,
        in: Optional(function),
        source: source
    )
}

private func immediatelyInvokedClosure(
    in expression: ExprSyntax
) -> ClosureExprSyntax? {
    if let closure = expression.as(ClosureExprSyntax.self) {
        return closure
    }
    if let tuple = expression.as(TupleExprSyntax.self) {
        let elements = Array(tuple.elements)
        guard elements.count == 1,
              elements[0].label == nil,
              elements[0].trailingComma == nil
        else {
            return nil
        }
        return immediatelyInvokedClosure(in: elements[0].expression)
    }
    return nil
}

private func escapingClosureReferencesProvider(
    _ closure: ClosureExprSyntax,
    context: ProviderResultContext,
    visitedBindings: Set<Int>
) -> Bool {
    var stack = Array(Syntax(closure).children(viewMode: .sourceAccurate).reversed())
    while let current = stack.popLast() {
        if let capture = current.as(ClosureCaptureSyntax.self) {
            if let initializer = capture.initializer,
               expressionPublishesProvider(
                initializer.value,
                context: context,
                visitedBindings: visitedBindings
               )
            {
                return true
            }
            let name = capture.name.text
            if name == "self", context.includeSelf { return true }
            if let resolved = nearestVisibleVariable(
                named: name,
                at: Syntax(capture),
                in: context.source
            ) {
                let identity = resolved.binding.positionAfterSkippingLeadingTrivia.utf8Offset
                if visitedBindings.contains(identity) { return true }
                if let annotation = resolved.binding.typeAnnotation,
                   !typeNames(in: annotation.type).isDisjoint(with: context.providerTypes)
                {
                    return true
                }
                if let initializer = resolved.binding.initializer {
                    var nextVisited = visitedBindings
                    nextVisited.insert(identity)
                    if expressionPublishesProvider(
                        initializer.value,
                        context: context,
                        visitedBindings: nextVisited
                    ) {
                        return true
                    }
                }
            } else if parameterProviderResolution(
                named: name,
                at: Syntax(capture),
                providerTypes: context.providerTypes
            ) == true {
                return true
            }
        }
        if let expression = current.as(ExprSyntax.self),
           expressionPublishesProvider(
            expression,
            context: context,
            visitedBindings: visitedBindings
           )
        {
            return true
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private func referenceContributesToExternalResult(
    _ reference: DeclReferenceExprSyntax,
    context: ProviderResultContext
) -> Bool {
    var current = Syntax(reference)
    while let parent = current.parent {
        if parent.is(ReturnStmtSyntax.self) || parent.is(YieldStmtSyntax.self) ||
            parent.is(CodeBlockItemSyntax.self)
        {
            return true
        }
        if parent.is(LabeledExprSyntax.self) || parent.is(ArrayElementSyntax.self) ||
            parent.is(DictionaryElementSyntax.self) || parent.is(ArrayElementListSyntax.self) ||
            parent.is(DictionaryElementListSyntax.self)
        {
            current = parent
            continue
        }
        if parent.is(LabeledExprListSyntax.self) {
            guard let container = parent.parent else { return false }
            if container.is(TupleExprSyntax.self) {
                current = parent
                continue
            }
            if let call = container.as(FunctionCallExprSyntax.self),
               let target = callTarget(call)
            {
                let ownerName = target.member == "init"
                    ? directExpressionName(target.base)
                    : nil
                let calledName = ownerName ?? target.member
                guard context.wrapperTypes.contains(calledName) ||
                        providerContainerWrapperTargets.contains(calledName)
                else {
                    return false
                }
                current = parent
                continue
            }
            return false
        }
        if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) ||
            parent.is(AsExprSyntax.self) || parent.is(OptionalChainingExprSyntax.self) ||
            parent.is(ForceUnwrapExprSyntax.self) || parent.is(MemberAccessExprSyntax.self) ||
            parent.is(SubscriptCallExprSyntax.self) || parent.is(ArrayExprSyntax.self) ||
            parent.is(DictionaryExprSyntax.self) || parent.is(TernaryExprSyntax.self) ||
            parent.is(IfExprSyntax.self) || parent.is(SwitchExprSyntax.self)
        {
            current = parent
            continue
        }
        if parent.is(TupleExprSyntax.self) {
            current = parent
            continue
        }
        if let call = parent.as(FunctionCallExprSyntax.self),
           let target = callTarget(call)
        {
            let ownerName = target.member == "init" ? directExpressionName(target.base) : nil
            let calledName = ownerName ?? target.member
            guard context.wrapperTypes.contains(calledName) ||
                    providerContainerWrapperTargets.contains(calledName)
            else {
                return false
            }
            current = parent
            continue
        }
        return false
    }
    return false
}

private func invokedClosureResultPublishesProvider(
    _ call: FunctionCallExprSyntax,
    target: CallTarget,
    context: ProviderResultContext,
    visitedBindings: Set<Int>
) -> Bool? {
    let directSelfBase = target.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
    guard target.base == nil || directSelfBase,
          let resolved = nearestVisibleVariable(
            named: target.member,
            at: Syntax(call),
            in: context.source
          )
    else {
        return nil
    }
    var closures: [ClosureExprSyntax] = []
    if let initializer = resolved.binding.initializer,
       let closure = immediatelyInvokedClosure(in: initializer.value)
    {
        closures.append(closure)
    }
    if let accessors = resolved.binding.accessorBlock {
        closures.append(contentsOf: accessorResultExpressions(accessors).compactMap {
            immediatelyInvokedClosure(in: $0)
        })
    }
    guard !closures.isEmpty else { return nil }
    return closures.contains { closure in
        resultRootExpressions(in: closure.statements).contains {
            expressionPublishesProvider(
                $0,
                context: context,
                visitedBindings: visitedBindings
            )
        }
    }
}

private func assignmentIntroducesProvider(
    _ expression: ExprSyntax,
    ignoringBinding identity: Int,
    context: ProviderResultContext,
    visitedBindings: Set<Int>
) -> Bool {
    var stack = [Syntax(expression)]
    while let current = stack.popLast() {
        if let reference = current.as(DeclReferenceExprSyntax.self) {
            if let resolved = nearestVisibleVariable(
                named: reference.baseName.text,
                at: Syntax(reference),
                in: context.source
            ), resolved.binding.positionAfterSkippingLeadingTrivia.utf8Offset == identity {
                continue
            }
            if expressionPublishesProvider(
                ExprSyntax(reference),
                context: context,
                visitedBindings: visitedBindings
            ) {
                return true
            }
            continue
        }
        if let call = current.as(FunctionCallExprSyntax.self),
           let target = callTarget(call)
        {
            let ownerName = target.member == "init" ? directExpressionName(target.base) : nil
            let calledName = ownerName ?? target.member
            if context.providerTypes.contains(calledName) ||
                providerReturningOperationMatches(
                    name: target.member,
                    base: target.base,
                    at: Syntax(call),
                    context: context
                )
            {
                return true
            }
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private func expressionPublishesProvider(
    _ expression: ExprSyntax,
    context: ProviderResultContext,
    visitedBindings: Set<Int> = []
) -> Bool {
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
        let name = reference.baseName.text
        if name == "self" { return context.includeSelf }
        if let resolved = nearestVisibleVariable(
            named: name,
            at: Syntax(reference),
            in: context.source
        ) {
            let resolvedIsLocal = nearestCodeBlock(
                containing: Syntax(resolved.declaration)
            ) != nil
            if !resolvedIsLocal,
               let parameter = parameterProviderResolution(
                named: name,
                at: Syntax(reference),
                providerTypes: context.providerTypes
               )
            {
                return parameter
            }
            let identity = resolved.binding.positionAfterSkippingLeadingTrivia.utf8Offset
            if visitedBindings.contains(identity) { return true }
            if let annotation = resolved.binding.typeAnnotation,
               !typeNames(in: annotation.type).isDisjoint(with: context.providerTypes)
            {
                return true
            }
            var nextVisited = visitedBindings
            nextVisited.insert(identity)
            if let initializer = resolved.binding.initializer,
               expressionPublishesProvider(
                initializer.value,
                context: context,
                visitedBindings: nextVisited
               )
            {
                return true
            }
            if resolvedIsLocal &&
                referenceContributesToExternalResult(reference, context: context) &&
                resolved.declaration.bindingSpecifier.text == "var"
            {
                let useOffset = reference.positionAfterSkippingLeadingTrivia.utf8Offset
                for assignment in assignments(in: context.source.tree) {
                    guard assignmentTargetName(assignment.lhs) == name,
                          assignment.syntax.positionAfterSkippingLeadingTrivia.utf8Offset < useOffset,
                          let assignedBinding = nearestVisibleVariable(
                            named: name,
                            at: Syntax(assignment.lhs),
                            in: context.source
                          ),
                          assignedBinding.binding.positionAfterSkippingLeadingTrivia.utf8Offset == identity,
                          assignmentIntroducesProvider(
                            assignment.rhs,
                            ignoringBinding: identity,
                            context: context,
                            visitedBindings: visitedBindings
                          )
                    else {
                        continue
                    }
                    return true
                }
            }
            if let accessorBlock = resolved.binding.accessorBlock,
               accessorResultExpressions(accessorBlock).contains(where: {
                expressionPublishesProvider(
                    $0,
                    context: context,
                    visitedBindings: nextVisited
                )
               })
            {
                return true
            }
            return false
        }
        if let parameter = parameterProviderResolution(
            named: name,
            at: Syntax(reference),
            providerTypes: context.providerTypes
        ) {
            return parameter
        }
        return providerReturningOperationMatches(
            name: name,
            base: nil,
            at: Syntax(reference),
            context: context
        )
    }
    if expression.is(StringLiteralExprSyntax.self) ||
        expression.is(IntegerLiteralExprSyntax.self) ||
        expression.is(FloatLiteralExprSyntax.self) ||
        expression.is(BooleanLiteralExprSyntax.self) ||
        expression.is(NilLiteralExprSyntax.self)
    {
        return false
    }
    if let closure = expression.as(ClosureExprSyntax.self) {
        return escapingClosureReferencesProvider(
            closure,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let optional = expression.as(OptionalChainingExprSyntax.self) {
        return expressionPublishesProvider(
            optional.expression,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let forced = expression.as(ForceUnwrapExprSyntax.self) {
        return expressionPublishesProvider(
            forced.expression,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let attempted = expression.as(TryExprSyntax.self) {
        return expressionPublishesProvider(
            attempted.expression,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let awaited = expression.as(AwaitExprSyntax.self) {
        return expressionPublishesProvider(
            awaited.expression,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let cast = expression.as(AsExprSyntax.self) {
        return expressionPublishesProvider(
            cast.expression,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let tuple = expression.as(TupleExprSyntax.self) {
        return tuple.elements.contains {
            expressionPublishesProvider(
                $0.expression,
                context: context,
                visitedBindings: visitedBindings
            )
        }
    }
    if let array = expression.as(ArrayExprSyntax.self) {
        return array.elements.contains {
            expressionPublishesProvider(
                $0.expression,
                context: context,
                visitedBindings: visitedBindings
            )
        }
    }
    if let dictionary = expression.as(DictionaryExprSyntax.self) {
        switch dictionary.content {
        case .colon:
            return false
        case let .elements(elements):
            return elements.contains {
                expressionPublishesProvider(
                    $0.key,
                    context: context,
                    visitedBindings: visitedBindings
                ) || expressionPublishesProvider(
                    $0.value,
                    context: context,
                    visitedBindings: visitedBindings
                )
            }
        @unknown default:
            return true
        }
    }
    if let ternary = expression.as(TernaryExprSyntax.self) {
        return expressionPublishesProvider(
            ternary.thenExpression,
            context: context,
            visitedBindings: visitedBindings
        ) || expressionPublishesProvider(
            ternary.elseExpression,
            context: context,
            visitedBindings: visitedBindings
        )
    }
    if let conditional = expression.as(IfExprSyntax.self) {
        return Syntax(conditional).children(viewMode: .sourceAccurate).contains { child in
            if let block = child.as(CodeBlockSyntax.self) {
                return resultRootExpressions(in: block.statements).contains {
                    expressionPublishesProvider(
                        $0,
                        context: context,
                        visitedBindings: visitedBindings
                    )
                }
            }
            if let nested = child.as(IfExprSyntax.self) {
                return expressionPublishesProvider(
                    ExprSyntax(nested),
                    context: context,
                    visitedBindings: visitedBindings
                )
            }
            return false
        }
    }
    if let switchExpression = expression.as(SwitchExprSyntax.self) {
        var stack = Array(Syntax(switchExpression).children(viewMode: .sourceAccurate))
        while let current = stack.popLast() {
            if let switchCase = current.as(SwitchCaseSyntax.self) {
                if resultRootExpressions(in: switchCase.statements).contains(where: {
                    expressionPublishesProvider(
                        $0,
                        context: context,
                        visitedBindings: visitedBindings
                    )
                }) {
                    return true
                }
                continue
            }
            stack.append(contentsOf: current.children(viewMode: .sourceAccurate))
        }
        return false
    }
    if let sequence = expression.as(SequenceExprSyntax.self) {
        return sequence.elements.contains {
            expressionPublishesProvider(
                $0,
                context: context,
                visitedBindings: visitedBindings
            )
        }
    }
    if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
        return expressionPublishesProvider(
            subscriptCall.calledExpression,
            context: context,
            visitedBindings: visitedBindings
        ) || subscriptCall.arguments.contains {
            expressionPublishesProvider(
                $0.expression,
                context: context,
                visitedBindings: visitedBindings
            )
        }
    }
    if let call = expression.as(FunctionCallExprSyntax.self) {
        guard let target = callTarget(call) else {
            if let closure = immediatelyInvokedClosure(in: call.calledExpression) {
                return resultRootExpressions(in: closure.statements).contains {
                    expressionPublishesProvider(
                        $0,
                        context: context,
                        visitedBindings: visitedBindings
                    )
                } || call.arguments.contains {
                    expressionPublishesProvider(
                        $0.expression,
                        context: context,
                        visitedBindings: visitedBindings
                    )
                }
            }
            return expressionPublishesProvider(
                call.calledExpression,
                context: context,
                visitedBindings: visitedBindings
            ) || call.arguments.contains {
                expressionPublishesProvider(
                    $0.expression,
                    context: context,
                    visitedBindings: visitedBindings
                )
            }
        }
        if let publishes = invokedClosureResultPublishesProvider(
            call,
            target: target,
            context: context,
            visitedBindings: visitedBindings
        ) {
            return publishes || call.arguments.contains {
                expressionPublishesProvider(
                    $0.expression,
                    context: context,
                    visitedBindings: visitedBindings
                )
            }
        }
        let exactStringDescription = target.base == nil && target.member == "String" &&
            call.arguments.count == 1 &&
            call.arguments.first?.label?.text == "describing" &&
            !symbolIsShadowed(
                named: "String",
                canonicalPath: "",
                at: Syntax(call),
                in: enclosingFunction(Syntax(call)),
                source: context.source
            )
        if exactStringDescription { return false }

        let argumentPublishes = call.arguments.contains {
            expressionPublishesProvider(
                $0.expression,
                context: context,
                visitedBindings: visitedBindings
            )
        }
        let basePublishes = target.base.map {
            expressionPublishesProvider(
                $0,
                context: context,
                visitedBindings: visitedBindings
            )
        } ?? false
        let ownerName = target.member == "init" ? directExpressionName(target.base) : nil
        let calledName = ownerName ?? target.member
        let visibleValueShadow = nearestVisibleVariable(
            named: calledName,
            at: Syntax(call),
            in: context.source
        ) != nil
        if !visibleValueShadow &&
            (context.providerTypes.contains(calledName) ||
                (!localFunctionShadows(calledName, at: Syntax(call), in: context.source) &&
                    providerReturningOperationMatches(
                        name: target.member,
                        base: target.base,
                        at: Syntax(call),
                        context: context
                    )))
        {
            return true
        }
        if !visibleValueShadow &&
            (context.wrapperTypes.contains(calledName) ||
                providerContainerWrapperTargets.contains(calledName))
        {
            return argumentPublishes
        }
        return basePublishes || argumentPublishes
    }
    if let member = expression.as(MemberAccessExprSyntax.self) {
        if providerReturningOperationMatches(
            name: member.declName.baseName.text,
            base: member.base,
            at: Syntax(member),
            context: context
        ) {
            return true
        }
        return member.base.map {
            expressionPublishesProvider(
                $0,
                context: context,
                visitedBindings: visitedBindings
            )
        } ?? false
    }
    return false
}

private func resultRootsPublishProvider(
    _ roots: [ExprSyntax],
    context: ProviderResultContext
) -> Bool {
    roots.contains { expressionPublishesProvider($0, context: context) }
}

private func functionCanReturnValue(_ function: FunctionDeclSyntax) -> Bool {
    guard let returnType = function.signature.returnClause?.type else { return false }
    let rendered = compactSyntaxText(returnType)
    return rendered != "Void" && rendered != "()"
}

private func isMenuBufferType(_ type: TypeSyntax, aliasTypes: Set<String>) -> Bool {
    if !typeNames(in: type).isDisjoint(with: aliasTypes) { return true }
    guard typeNames(in: type).contains("ApplicationMenuCommandDTO") else { return false }
    if type.is(ArrayTypeSyntax.self) || type.is(DictionaryTypeSyntax.self) { return true }
    let wrappers: Set<String> = [
        "Array", "ContiguousArray", "Set", "Deque", "Dictionary", "AsyncStream",
        "AsyncThrowingStream", "Continuation", "Collection", "Buffer", "Queue",
    ]
    return !typeNames(in: type).isDisjoint(with: wrappers)
}

private func expressionInitializesRawStorage(
    _ expression: ExprSyntax,
    genericNames: Set<String>,
    rawErasureTypes: Set<String>
) -> Bool {
    var stack = [Syntax(expression)]
    while let current = stack.popLast() {
        if let typeExpression = current.as(TypeExprSyntax.self),
           isRawStorageType(
            typeExpression.type,
            genericNames: genericNames,
            rawErasureTypes: rawErasureTypes
           )
        {
            return true
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private func expressionInitializesMenuBuffer(
    _ expression: ExprSyntax,
    aliasTypes: Set<String>
) -> Bool {
    var stack = [Syntax(expression)]
    while let current = stack.popLast() {
        if let typeExpression = current.as(TypeExprSyntax.self),
           isMenuBufferType(typeExpression.type, aliasTypes: aliasTypes)
        {
            return true
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return false
}

private func isCorePath(_ path: String) -> Bool {
    path.hasPrefix("Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/")
}

private func isContractsPath(_ path: String) -> Bool {
    path.hasPrefix("Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/")
}

private func isRuntimeCorePath(_ path: String) -> Bool {
    path.hasPrefix("Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/")
}

private func isConsumerPath(_ path: String) -> Bool {
    !isCorePath(path) && !isContractsPath(path) && !isRuntimeCorePath(path)
}

private struct RawStorage {
    let name: String
    let path: String
    let line: Int
}

private struct PublicationSurface {
    let name: String
    let storedParameters: Set<String>
    let path: String
    let line: Int
}

private enum CoreOperationKind: String {
    case instance
    case `static`
    case topLevel
}

private struct CoreOperation {
    let name: String
    let owner: String?
    let kind: CoreOperationKind
    let path: String
    let line: Int
}

private struct CoreSubscript {
    let owner: String
    let allLabels: [String]
    let requiredLabels: [String]
    let variadicLabels: Set<String>
    let path: String
    let line: Int
}

private struct CoreInitializer {
    let owner: String
    let allLabels: [String]
    let requiredLabels: [String]
    let variadicLabels: Set<String>
    let path: String
    let line: Int
}

private struct MemberIdentity: Hashable {
    let owner: String
    let name: String
}

private func callableLabelsMatch(
    callLabels: [String],
    allLabels: [String],
    requiredLabels: [String],
    variadicLabels: Set<String>
) -> Bool {
    var normalizedCallLabels: [String] = []
    var activeVariadicLabel: String?
    for label in callLabels {
        if variadicLabels.contains(label) {
            if activeVariadicLabel != label { normalizedCallLabels.append(label) }
            activeVariadicLabel = label
        } else if label == "_", activeVariadicLabel != nil {
            continue
        } else {
            normalizedCallLabels.append(label)
            activeVariadicLabel = nil
        }
    }
    guard requiredLabels.allSatisfy(callLabels.contains),
          normalizedCallLabels.allSatisfy(allLabels.contains)
    else {
        return false
    }
    var remaining = allLabels[...]
    for label in normalizedCallLabels {
        guard let index = remaining.firstIndex(of: label) else { return false }
        remaining = remaining[remaining.index(after: index)...]
    }
    return true
}

private func initializerLabelsMatch(callLabels: [String], initializer: CoreInitializer) -> Bool {
    callableLabelsMatch(
        callLabels: callLabels,
        allLabels: initializer.allLabels,
        requiredLabels: initializer.requiredLabels,
        variadicLabels: initializer.variadicLabels
    )
}

private func sortedFindings(_ findings: Set<Finding>) -> [Finding] {
    findings.sorted {
        ($0.ruleID, $0.path, $0.line, $0.category, $0.detail) <
            ($1.ruleID, $1.path, $1.line, $1.category, $1.detail)
    }
}

private let p04UIModulePrefix =
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
private let p04UIRuntimePrefix =
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/"
private let p04PlatformPrefix =
    "Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/"
private let p04RuntimeIOGatewayPath =
    "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeIOGateway.swift"

private let p04ExplicitOperationalSymbols: Set<String> = [
    "AppStorage", "AudioServicesPlaySystemSound", "AVAudioPlayer", "AVAudioSession",
    "AVCaptureDevice", "AVCaptureDeviceInput",
    "AVCaptureMetadataOutput", "AVCaptureSession", "AVCaptureVideoPreviewLayer",
    "AVPlayer", "AVPlayerLayer", "CKContainer", "CNContact", "CNContactFormatter",
    "CNContactPickerDelegate", "CNContactPickerViewController", "CNContactStore",
    "FileDocument", "FileHandle", "FileManager", "GKLocalPlayer", "Link",
    "MFMessageComposeViewController",
    "MFMessageComposeViewControllerDelegate", "NSPasteboard", "NSSharingService",
    "NSSharingServiceDelegate", "NSSharingServicePicker",
    "NSOpenPanel", "NSSavePanel", "NSSharingServicePickerDelegate", "NSWorkspace",
    "NSViewController", "OpenURLAction", "PhotosPicker", "ReferenceFileDocument",
    "SecItemAdd", "SecItemCopyMatching", "SecItemDelete", "SecItemUpdate", "ShareLink",
    "UIActivityViewController", "UIApplication", "UIDocumentPickerViewController",
    "UIPasteboard", "UIViewController", "URLSession", "UserDefaults",
    "fileExporter", "fileImporter", "openURL", "startAccessingSecurityScopedResource",
]

private let p04QualifiedOperationalMembers: Set<String> = [
    "authorizationStatus", "requestAccess",
]

private func isP04OperationalPlatformSymbol(_ name: String) -> Bool {
    if p04ExplicitOperationalSymbols.contains(name) { return true }
    return ["AudioServices", "AV", "CK", "CL", "CN", "GK", "MFMessage", "MPMusic",
            "MTL", "NW", "PHPhoto", "SecItem", "SFSpeech"].contains {
        name.hasPrefix($0) && name.count > $0.count
    }
}

private let p04UIRuntimeOperationalAllowlist: [String: Set<String>] = [
    "RuntimeApplicationResourcePresentation.swift": [
        "AVAudioSession", "AVPlayer", "AVPlayerItemDidPlayToEndTime", "AVPlayerLayer",
        "MTLBuffer", "MTLClearColor", "MTLCommandQueue", "MTLCreateSystemDefaultDevice",
        "MTLDevice", "MTLLibrary", "MTLRenderPipelineDescriptor", "MTLRenderPipelineState",
    ],
    "RuntimeContactPicker.swift": [
        "CNContact", "CNContactFormatter", "CNContactPickerDelegate",
        "CNContactPickerViewController", "UIViewController",
    ],
    "RuntimeInboundFileImporter.swift": ["fileImporter"],
    "RuntimeMessageComposeView.swift": [
        "MFMessageComposeViewController", "MFMessageComposeViewControllerDelegate",
        "UIViewController",
    ],
    "RuntimeNativeShareView.swift": [
        "NSSharingService", "NSSharingServiceDelegate", "NSSharingServicePicker",
        "NSSharingServicePickerDelegate", "UIActivityViewController", "UIViewController",
    ],
    "RuntimeQRScanner.swift": [
        "AVAuthorizationStatus", "AVCaptureConnection", "AVCaptureDevice",
        "AVCaptureDeviceInput", "AVCaptureMetadataOutput",
        "AVCaptureMetadataOutputObjectsDelegate", "AVCaptureSession",
        "AVCaptureVideoPreviewLayer", "AVMetadataMachineReadableCodeObject",
        "AVMetadataObject", "UIApplication", "UIViewController", "authorizationStatus",
        "requestAccess",
    ],
    "RuntimeSharePresentation.swift": ["fileExporter"],
]

private let p04OperationalFrameworks: Set<String> = [
    "AudioToolbox", "AVFoundation", "CloudKit", "Contacts", "ContactsUI", "CoreAudio",
    "CoreLocation", "GameKit", "MediaPlayer", "MessageUI", "Metal", "MetalKit",
    "Network", "Photos", "PhotosUI", "Security", "Speech",
]

private let p04UIRuntimeFrameworkAllowlist: [String: Set<String>] = [
    "RuntimeApplicationResourcePresentation.swift": ["AVFoundation", "Metal", "MetalKit"],
    "RuntimeContactPicker.swift": ["Contacts", "ContactsUI"],
    "RuntimeMessageComposeView.swift": ["MessageUI"],
    "RuntimeQRScanner.swift": ["AVFoundation"],
]

private let p04HostOperationalAllowlist: [String: Set<String>] = [
    "RuneScrib/AppHost/AppDelegate.swift": ["UIApplication"],
]

private func p04SyntaxNames<T: SyntaxProtocol>(in syntax: T) -> Set<String> {
    var names: Set<String> = []
    var stack = [Syntax(syntax)]
    while let current = stack.popLast() {
        if let reference = current.as(DeclReferenceExprSyntax.self) {
            names.insert(reference.baseName.text)
        } else if let member = current.as(MemberAccessExprSyntax.self) {
            names.insert(member.declName.baseName.text)
        } else if let identifier = current.as(IdentifierTypeSyntax.self) {
            names.insert(identifier.name.text)
        } else if let member = current.as(MemberTypeSyntax.self) {
            names.insert(member.name.text)
        }
        stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return names
}

private func p04OperationalName(in node: Syntax) -> String? {
    if let reference = node.as(DeclReferenceExprSyntax.self),
       isP04OperationalPlatformSymbol(reference.baseName.text)
    {
        return reference.baseName.text
    }
    if let member = node.as(MemberAccessExprSyntax.self) {
        let memberName = member.declName.baseName.text
        if isP04OperationalPlatformSymbol(memberName) { return memberName }
        if p04QualifiedOperationalMembers.contains(memberName),
           member.base.map({ base in
            p04SyntaxNames(in: base).contains(where: isP04OperationalPlatformSymbol)
           }) == true
        {
            return memberName
        }
    }
    if let identifier = node.as(IdentifierTypeSyntax.self),
       isP04OperationalPlatformSymbol(identifier.name.text)
    {
        return identifier.name.text
    }
    if let member = node.as(MemberTypeSyntax.self),
       isP04OperationalPlatformSymbol(member.name.text)
    {
        return member.name.text
    }
    return nil
}

private func p04IsManifestResourceRead(_ node: Syntax, source: ParsedSource) -> Bool {
    guard [
        "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreModule.swift",
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift",
    ].contains(source.relativePath),
          (node.as(FunctionDeclSyntax.self)?.name.text ??
           enclosingFunction(node)?.name.text) == "manifestData"
    else {
        return false
    }
    return true
}

private func p04TargetName(for path: String) -> String? {
    let prefix = "Packages/RuneScribeArchitecture/Sources/"
    guard path.hasPrefix(prefix) else { return nil }
    return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
}

private func p04IsShippingModuleImplementation(_ path: String) -> Bool {
    p04TargetName(for: path)?.hasSuffix("Module") == true
}

private func p04FactoryCaptureIsOperational(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return [
        "adapter", "client", "dependencies", "facility", "locator", "provider",
        "runtimeio", "service", "store",
    ].contains { lowered.contains($0) }
}

private func p04ApplicationResourceName(
    from expression: ExprSyntax,
    at use: Syntax,
    in source: ParsedSource,
    visited: Set<String> = []
) -> String? {
    if let member = expression.as(MemberAccessExprSyntax.self),
       member.declName.baseName.text != "init"
    {
        return member.declName.baseName.text
    }
    guard let reference = expression.as(DeclReferenceExprSyntax.self) else { return nil }
    let name = reference.baseName.text
    guard !visited.contains(name),
          let binding = nearestVisibleVariable(named: name, at: use, in: source),
          let initializer = binding.binding.initializer
    else {
        return nil
    }
    return p04ApplicationResourceName(
        from: initializer.value,
        at: Syntax(binding.binding),
        in: source,
        visited: visited.union(Set([name]))
    )
}

private func p04AcceptedRuntimeAuthorityNames(in source: ParsedSource) -> Set<String> {
    var names: Set<String> = []
    for node in source.nodes {
        if let function = node.as(FunctionDeclSyntax.self) {
            for parameter in functionParameters(function) {
                names.formUnion(typeNames(in: parameter.type))
            }
        } else if let initializer = node.as(InitializerDeclSyntax.self) {
            for parameter in initializerParameters(initializer) {
                names.formUnion(typeNames(in: parameter.type))
            }
        }
    }
    return names
}

private func p04HasTypedAuthorityCall(
    _ memberName: String,
    authorityTypes: Set<String>,
    acquiredLeaseTypes: Set<String> = [],
    in source: ParsedSource
) -> Bool {
    for node in source.nodes {
        guard let call = node.as(FunctionCallExprSyntax.self),
              let target = callTarget(call), target.member == memberName,
              let baseName = directExpressionName(target.base)
        else {
            continue
        }
        let variables = lexicalVariableTypes(
            at: Syntax(call),
            in: source,
            functionReturns: acquiredLeaseTypes.isEmpty
                ? [:]
                : ["acquire": acquiredLeaseTypes]
        )
        if !variables[baseName, default: []].isDisjoint(with: authorityTypes) {
            return true
        }
    }
    return false
}

private func p04HandlesRuntimeRevocation(in source: ParsedSource) -> Bool {
    for node in source.nodes {
        guard let member = node.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "revoked"
        else {
            continue
        }
        var hasEventLoop = false
        var hasConditionalHandling = false
        var current = Syntax(member).parent
        while let ancestor = current {
            if ancestor.is(ForStmtSyntax.self) { hasEventLoop = true }
            if ancestor.is(GuardStmtSyntax.self) || ancestor.is(SwitchCaseSyntax.self) ||
                ancestor.is(IfExprSyntax.self)
            {
                hasConditionalHandling = true
            }
            current = ancestor.parent
        }
        if hasEventLoop && hasConditionalHandling { return true }
    }
    return false
}

private func p04UIRuntimeBridgeHasOpaqueAuthority(
    _ source: ParsedSource,
    runtimeAuthorityNames: Set<String>
) -> Bool {
    let fileName = URL(fileURLWithPath: source.relativePath).lastPathComponent
    let names = p04SyntaxNames(in: source.tree)
    let sourceText = compactSyntaxText(source.tree)
    let sessionTypes = Set(runtimeAuthorityNames.filter { $0.hasSuffix("Session") })
    let leaseTypes = Set(runtimeAuthorityNames.filter { $0.hasSuffix("Lease") })
    let acquiresRuntimeLease = p04HasTypedAuthorityCall(
        "acquire",
        authorityTypes: sessionTypes,
        in: source
    )
    let observesRuntimeEvents = p04HasTypedAuthorityCall(
        "events",
        authorityTypes: leaseTypes,
        acquiredLeaseTypes: leaseTypes,
        in: source
    )
    let closesRuntimeLease = p04HasTypedAuthorityCall(
        "close",
        authorityTypes: leaseTypes,
        acquiredLeaseTypes: leaseTypes,
        in: source
    )
    let handlesRuntimeRevocation = p04HandlesRuntimeRevocation(in: source)
    switch fileName {
    case "RuntimeApplicationResourcePresentation.swift":
        return runtimeAuthorityNames.contains("RuntimeApplicationResourceSession") &&
            runtimeAuthorityNames.contains("RuntimeApplicationResourceLease") &&
            names.contains("RuntimeApplicationResourceSession") &&
            names.contains("RuntimeApplicationResourceLease") &&
            source.source.contains("@_spi(RuntimeResourceHost) import RuneScribeRuntimeCore") &&
            acquiresRuntimeLease && observesRuntimeEvents && handlesRuntimeRevocation &&
            closesRuntimeLease
    case "RuntimeSharePresentation.swift":
        return runtimeAuthorityNames.contains("RuntimeSharePresentationSession") &&
            runtimeAuthorityNames.contains("RuntimeSharePresentationLease") &&
            names.contains("RuntimeSharePresentationSession") &&
            names.contains("RuntimeSharePresentationLease") &&
            source.source.contains("@_spi(RuntimeResourceHost) import RuneScribeRuntimeCore") &&
            acquiresRuntimeLease && observesRuntimeEvents && handlesRuntimeRevocation &&
            closesRuntimeLease
    case "RuntimeInboundFileImporter.swift":
        return runtimeAuthorityNames.contains("RuntimeInboundFileImportSession") &&
            names.contains("RuntimeInboundFileImportSession") &&
            source.source.contains("@_spi(RuntimeFileImportHost) import RuneScribeRuntimeCore") &&
            names.contains("importSelectedFile")
    case "RuntimeMessageComposeView.swift", "RuntimeNativeShareView.swift":
        return names.contains("OpaqueShareTransfer") &&
            names.contains("finish") && !sourceText.contains("publicvarpresentationURL")
    case "RuntimeQRScanner.swift", "RuntimeContactPicker.swift":
        let acceptedAuthorities = p04AcceptedRuntimeAuthorityNames(in: source)
            .intersection(runtimeAuthorityNames)
        let acceptedSession = acceptedAuthorities.contains { $0.hasSuffix("Session") }
        let referencedLease = names.intersection(runtimeAuthorityNames).contains {
            $0.hasSuffix("Lease")
        }
        return acceptedSession && referencedLease &&
            source.source.contains("@_spi(RuntimeResourceHost) import RuneScribeRuntimeCore") &&
            acquiresRuntimeLease && observesRuntimeEvents && handlesRuntimeRevocation &&
            closesRuntimeLease
    default:
        return false
    }
}

private func p04ReturnTypeIsRawResourceSurface(
    _ type: TypeSyntax,
    rawResourceAliases: Set<String> = []
) -> Bool {
    let names = typeNames(in: type)
    if !names.isDisjoint(with: Set(["Data", "URL"]).union(rawResourceAliases)) {
        return true
    }
    return names.contains { name in
        ["Adapter", "Locator", "Provider", "Service", "Store"].contains {
            name.hasSuffix($0)
        }
    }
}

private func p04Findings(in sources: [ParsedSource]) -> Set<Finding> {
    var findings: Set<Finding> = []

    func insert(
        _ ruleID: String,
        _ category: String,
        _ source: ParsedSource,
        _ node: some SyntaxProtocol,
        _ detail: String
    ) {
        findings.insert(Finding(
            ruleID: ruleID,
            category: category,
            path: source.relativePath,
            line: source.line(of: node),
            detail: detail
        ))
    }

    var declaredApplicationResources: Set<String> = []
    var requiredApplicationResourcesByTarget: [String: Set<String>] = [:]
    var runtimeAuthorityNames: Set<String> = []
    var resourceAliasTargets: [String: Set<String>] = [:]
    for source in sources {
        for node in source.nodes {
            if let alias = node.as(TypeAliasDeclSyntax.self) {
                resourceAliasTargets[alias.name.text] = typeNames(in: alias.initializer.value)
            }
            if isRuntimeCorePath(source.relativePath),
               let nominal = nominalContext(for: node),
               nominal.name.hasPrefix("Runtime"),
               nominal.name.hasSuffix("Session") || nominal.name.hasSuffix("Lease"),
               nominal.inheritance.contains("Sendable"),
               isExternallyVisible(nominal.modifiers)
            {
                runtimeAuthorityNames.insert(nominal.name)
            }
            if let variable = node.as(VariableDeclSyntax.self),
               enclosingOperationOwnerName(node) == "ApplicationResource"
            {
                for binding in variable.bindings {
                    guard binding.initializer.map({ initializer in
                        descendantCalls(of: initializer.value).contains {
                            callTarget($0)?.member == "ApplicationResource"
                        }
                    }) == true
                    else { continue }
                    declaredApplicationResources.formUnion(patternNames(binding.pattern))
                }
            }

            guard let call = node.as(FunctionCallExprSyntax.self),
                  callTarget(call)?.member == "ModuleDescriptor",
                  let target = p04TargetName(for: source.relativePath),
                  let resources = labeledArgument("requiredResources", in: call)
            else {
                continue
            }
            var names: Set<String> = []
            var stack = [Syntax(resources)]
            while let current = stack.popLast() {
                if let member = current.as(MemberAccessExprSyntax.self), member.base == nil {
                    names.insert(member.declName.baseName.text)
                }
                stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
            }
            requiredApplicationResourcesByTarget[target, default: []].formUnion(names)
        }
    }

    var rawResourceAliases: Set<String> = []
    var applicationResourceAliases: Set<String> = []
    var moduleFactoryAliases: Set<String> = []
    var aliasesChanged = true
    while aliasesChanged {
        aliasesChanged = false
        for (name, targets) in resourceAliasTargets where !rawResourceAliases.contains(name) {
            let isRaw = !targets.isDisjoint(with: Set(["Data", "URL"]).union(rawResourceAliases)) ||
                targets.contains { p04FactoryCaptureIsOperational($0) }
            if isRaw {
                rawResourceAliases.insert(name)
                aliasesChanged = true
            }
        }
        for (name, targets) in resourceAliasTargets where !applicationResourceAliases.contains(name) {
            if targets.contains("ApplicationResource") ||
                !targets.isDisjoint(with: applicationResourceAliases)
            {
                applicationResourceAliases.insert(name)
                aliasesChanged = true
            }
        }
        for (name, targets) in resourceAliasTargets where !moduleFactoryAliases.contains(name) {
            if targets.contains("AnyModuleFactory") ||
                !targets.isDisjoint(with: moduleFactoryAliases)
            {
                moduleFactoryAliases.insert(name)
                aliasesChanged = true
            }
        }
    }

    for source in sources {
        let isUIModule = source.relativePath.hasPrefix(p04UIModulePrefix)
        let isUIRuntime = source.relativePath.hasPrefix(p04UIRuntimePrefix)
        let isPlatformImplementation = source.relativePath.hasPrefix(p04PlatformPrefix)
        let isOperationalModule = p04IsShippingModuleImplementation(source.relativePath)
        let uiRuntimeFile = URL(fileURLWithPath: source.relativePath).lastPathComponent
        let applicationResourceTypes = applicationResourceAliases.union(
            Set(["ApplicationResource"])
        )
        let moduleFactoryTypes = moduleFactoryAliases.union(Set(["AnyModuleFactory"]))
        var uiRuntimeOperationalUse = false

        for node in source.nodes {
            if let member = node.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "module",
               directExpressionName(member.base) == "Bundle",
               !p04IsManifestResourceRead(node, source: source)
            {
                insert(
                    "FG-016",
                    "guessed-bundle-resource-location",
                    source,
                    member,
                    "module guesses a Bundle.module resource location outside its manifest loader"
                )
            }

            if let operationalName = p04OperationalName(in: node) {
                let hostAllowsSymbol = p04HostOperationalAllowlist[source.relativePath]?
                    .contains(operationalName) == true
                if !isPlatformImplementation, !isUIRuntime, !hostAllowsSymbol,
                   !p04IsManifestResourceRead(node, source: source)
                {
                    insert(
                        "FG-007",
                        "module-owned-operational-platform-api",
                        source,
                        node,
                        isOperationalModule
                            ? "shipping module implementation uses operational platform symbol \(operationalName)"
                            : "non-designated shipping source uses operational platform symbol \(operationalName)"
                    )
                }
                if isUIRuntime {
                    uiRuntimeOperationalUse = true
                    let allowed = p04UIRuntimeOperationalAllowlist[uiRuntimeFile]
                    if allowed?.contains(operationalName) != true {
                        insert(
                            "FG-007",
                            "unallowlisted-runtime-native-bridge-symbol",
                            source,
                            node,
                            "UIRuntime operational symbol \(operationalName) is not allowlisted for \(uiRuntimeFile)"
                        )
                    }
                }
            }

            if let call = node.as(FunctionCallExprSyntax.self), let target = callTarget(call) {
                let labels = callArgumentLabels(call)
                let isRawFileRead = target.member == "Data" && labels.contains("contentsOf")
                if !isPlatformImplementation, isRawFileRead,
                   !p04IsManifestResourceRead(node, source: source)
                {
                    insert(
                        "FG-007",
                        "module-owned-file-data-extraction",
                        source,
                        call,
                        "shipping module implementation reads file data directly"
                    )
                }

                let constructsApplicationResource = applicationResourceTypes.contains(target.member) ||
                    (target.member == "init" &&
                     (!p04SyntaxNames(in: call.calledExpression).isDisjoint(
                        with: applicationResourceTypes
                     ) ||
                      !contextualTypeNames(containing: Syntax(call)).isDisjoint(
                        with: applicationResourceTypes
                      )))
                if constructsApplicationResource, !isContractsPath(source.relativePath) {
                    insert(
                        "FG-016",
                        "guessed-application-resource",
                        source,
                        call,
                        "shipping code constructs an ApplicationResource outside its canonical catalog"
                    )
                }

                if ["applicationResourceSession", "registerBundledSystemFont"].contains(target.member),
                   let argument = call.arguments.first?.expression
                {
                    let requestedName = p04ApplicationResourceName(
                        from: argument,
                        at: Syntax(call),
                        in: source
                    )
                    if let requestedName {
                        let targetName = p04TargetName(for: source.relativePath)
                        let declaredForTarget = targetName.flatMap {
                            requiredApplicationResourcesByTarget[$0]
                        } ?? []
                        if !declaredApplicationResources.contains(requestedName) ||
                            !declaredForTarget.contains(requestedName)
                        {
                            insert(
                                "FG-016",
                                "undeclared-application-resource",
                                source,
                                call,
                                "module requests ApplicationResource.\(requestedName) without a catalog and descriptor declaration"
                            )
                        }
                    } else if p04IsShippingModuleImplementation(source.relativePath) {
                        insert(
                            "FG-016",
                            "unproven-application-resource-request",
                            source,
                            call,
                            "module requests an ApplicationResource that cannot be proven against its catalog and descriptor"
                        )
                    }
                }

                let constructsModuleFactory = moduleFactoryTypes.contains(target.member) ||
                    (target.member == "init" &&
                     (!p04SyntaxNames(in: call.calledExpression).isDisjoint(
                        with: moduleFactoryTypes
                     ) ||
                      !contextualTypeNames(containing: Syntax(call)).isDisjoint(
                        with: moduleFactoryTypes
                      )))
                if constructsModuleFactory {
                    if callArgumentLabels(call).contains("descriptor") {
                        insert(
                            "FG-009",
                            "shipping-runtime-testing-factory-initializer",
                            source,
                            call,
                            "shipping source uses the RuntimeTesting descriptor-and-closure AnyModuleFactory initializer"
                        )
                    }
                    let closure = call.trailingClosure ??
                        labeledArgument("make", in: call)?.as(ClosureExprSyntax.self)
                    if let closure {
                        let closureNames = p04SyntaxNames(in: closure)
                        let lexicalTypes = lexicalVariableTypes(
                            at: Syntax(closure),
                            in: source,
                            functionReturns: [:]
                        )
                        let capturesOperationalValue = closureNames.contains { name in
                            p04FactoryCaptureIsOperational(name) ||
                                lexicalTypes[name, default: []].contains(
                                    where: p04FactoryCaptureIsOperational
                                )
                        }
                        if capturesOperationalValue {
                            insert(
                                "FG-009",
                                "factory-closure-operational-capture",
                                source,
                                closure,
                                "AnyModuleFactory closure captures an operational dependency or facility"
                            )
                        }
                        let constructedWithArguments = descendantCalls(of: closure).contains {
                            nested in
                            nested.id != call.id && !nested.arguments.isEmpty
                        }
                        if constructedWithArguments {
                            insert(
                                "FG-009",
                                "factory-closure-parameterized-module",
                                source,
                                closure,
                                "AnyModuleFactory closure constructs a module with captured arguments"
                            )
                        }
                    } else if callArgumentLabels(call).contains("make") {
                        insert(
                            "FG-009",
                            "factory-closure-opaque-capture",
                            source,
                            call,
                            "shipping AnyModuleFactory uses an unanalyzable make closure or function reference"
                        )
                    }
                }

                if target.member == "factory", !call.arguments.isEmpty,
                   compactSyntaxText(call.calledExpression).contains("ModuleBootstrap")
                {
                    insert(
                        "FG-009",
                        "parameterized-module-bootstrap-call",
                        source,
                        call,
                        "host invokes a module bootstrap factory with captured dependencies"
                    )
                }

                if isUIModule, target.member == "InboundURLDTO" {
                    insert(
                        "FG-016",
                        "url-bearing-module-dto",
                        source,
                        call,
                        "RuneScribeUIModule constructs a URL-bearing DTO"
                    )
                }
            }

            if let function = node.as(FunctionDeclSyntax.self) {
                let isModuleFactory = function.name.text == "factory" &&
                    (p04IsShippingModuleImplementation(source.relativePath) ||
                     enclosingNominalName(node)?.hasSuffix("ModuleBootstrap") == true ||
                     function.signature.returnClause.map {
                        !typeNames(in: $0.type).isDisjoint(with: moduleFactoryTypes)
                     } == true)
                if isModuleFactory, !functionParameters(function).isEmpty
                {
                    insert(
                        "FG-009",
                        "parameterized-module-factory",
                        source,
                        function,
                        "shipping module factory accepts arbitrary dependencies"
                    )
                }

                if let owner = enclosingOperationOwnerName(node),
                   ["ModuleContext", "RuntimeIOClient"].contains(owner),
                   memberIsExternallyVisible(function.modifiers, syntax: node),
                   let returnType = function.signature.returnClause?.type,
                   p04ReturnTypeIsRawResourceSurface(
                    returnType,
                    rawResourceAliases: rawResourceAliases
                   ),
                   !(source.relativePath == p04RuntimeIOGatewayPath &&
                     owner == "RuntimeIOClient" &&
                     ["readInboundFile", "readProtectedFile", "secureValueData"]
                        .contains(function.name.text) &&
                     typeNames(in: returnType).contains("Data") &&
                     !typeNames(in: returnType).contains("URL") &&
                     !typeNames(in: returnType).contains(where: { name in
                        ["Adapter", "Locator", "Provider", "Service", "Store"]
                            .contains { name.hasSuffix($0) }
                     }))
                {
                    insert(
                        "FG-016",
                        "raw-runtime-resource-vending",
                        source,
                        function,
                        "\(owner) exposes a provider or raw URL/Data resource result instead of an opaque session"
                    )
                }

                if isUIModule, !p04IsManifestResourceRead(node, source: source) {
                    let parameters = functionParameters(function)
                    let parameterTypes = parameters.reduce(into: Set<String>()) {
                        $0.formUnion(typeNames(in: $1.type))
                    }
                    let resultTypes = function.signature.returnClause.map {
                        typeNames(in: $0.type)
                    } ?? []
                    let rawTypes = parameterTypes.union(resultTypes)
                    let boundaryName = function.name.text.lowercased()
                    let boundaryHints = [
                        "artifact", "file", "import", "ingest", "key", "resource", "share", "url",
                    ]
                    let hasBoundaryName = boundaryHints.contains(where: boundaryName.contains) ||
                        parameters.contains { parameter in
                            let name = parameter.name.lowercased()
                            return boundaryHints.contains(where: name.contains)
                        }
                    let containsRawAlias = !rawTypes.isDisjoint(with: rawResourceAliases)
                    if rawTypes.contains("URL") || containsRawAlias ||
                        (rawTypes.contains("Data") && hasBoundaryName)
                    {
                        insert(
                            "FG-016",
                            "raw-module-url-data-boundary",
                            source,
                            function,
                            "RuneScribeUIModule accepts or returns raw URL/Data at a resource boundary"
                        )
                    }
                }

                if isUIRuntime, memberIsExternallyVisible(function.modifiers, syntax: node) {
                    var exposedTypes = functionParameters(function).reduce(into: Set<String>()) {
                        $0.formUnion(typeNames(in: $1.type))
                    }
                    if let result = function.signature.returnClause?.type {
                        exposedTypes.formUnion(typeNames(in: result))
                    }
                    if exposedTypes.contains(where: isP04OperationalPlatformSymbol) {
                        insert(
                            "FG-007",
                            "public-native-presentation-type",
                            source,
                            function,
                            "UIRuntime bridge exposes a native operational presentation type publicly"
                        )
                    }
                }
            }

            if let variable = node.as(VariableDeclSyntax.self),
               isRetainedOrGlobalVariable(variable)
            {
                for binding in variable.bindings {
                    guard let initializer = binding.initializer,
                          let closure = initializer.value.as(ClosureExprSyntax.self)
                    else { continue }
                    let declaredTypes = binding.typeAnnotation.map {
                        typeNames(in: $0.type)
                    } ?? []
                    let closureNames = p04SyntaxNames(in: closure)
                    guard !declaredTypes.isDisjoint(with: moduleFactoryTypes) ||
                            !closureNames.isDisjoint(with: moduleFactoryTypes)
                    else {
                        continue
                    }
                    insert(
                        "FG-009",
                        "closure-valued-shipping-module-factory",
                        source,
                        binding,
                        "shipping source declares a closure-valued module factory instead of the uniform zero-argument factory"
                    )
                    if declaredTypes.union(closureNames).contains(
                        where: p04FactoryCaptureIsOperational
                    ) {
                        insert(
                            "FG-009",
                            "factory-closure-operational-capture",
                            source,
                            closure,
                            "module bootstrap closure captures an operational dependency or facility"
                        )
                    }
                }
            }

            if isUIRuntime, let initializer = node.as(InitializerDeclSyntax.self),
               memberIsExternallyVisible(initializer.modifiers, syntax: node)
            {
                let exposedTypes = initializerParameters(initializer).reduce(into: Set<String>()) {
                    $0.formUnion(typeNames(in: $1.type))
                }
                if exposedTypes.contains(where: isP04OperationalPlatformSymbol) {
                    insert(
                        "FG-007",
                        "public-native-presentation-type",
                        source,
                        initializer,
                        "UIRuntime bridge initializer exposes a native operational presentation type publicly"
                    )
                }
            }

            if isUIRuntime, let variable = node.as(VariableDeclSyntax.self),
               memberIsExternallyVisible(variable.modifiers, syntax: node)
            {
                for binding in variable.bindings {
                    let exposedTypes = binding.typeAnnotation.map {
                        typeNames(in: $0.type)
                    } ?? []
                    if exposedTypes.contains(where: isP04OperationalPlatformSymbol) {
                        insert(
                            "FG-007",
                            "public-native-presentation-type",
                            source,
                            binding,
                            "UIRuntime bridge property exposes a native operational presentation type publicly"
                        )
                    }
                }
            }

            if let variable = node.as(VariableDeclSyntax.self),
               let owner = enclosingOperationOwnerName(node),
               ["ModuleContext", "RuntimeIOClient"].contains(owner),
               memberIsExternallyVisible(variable.modifiers, syntax: node)
            {
                for binding in variable.bindings {
                    guard let type = binding.typeAnnotation?.type,
                          p04ReturnTypeIsRawResourceSurface(
                            type,
                            rawResourceAliases: rawResourceAliases
                          )
                    else { continue }
                    insert(
                        "FG-016",
                        "raw-runtime-resource-property",
                        source,
                        binding,
                        "\(owner) exposes a provider or raw URL/Data resource property instead of an opaque session"
                    )
                }
            }

            if let subscriptDeclaration = node.as(SubscriptDeclSyntax.self),
               let owner = enclosingOperationOwnerName(node),
               ["ModuleContext", "RuntimeIOClient"].contains(owner),
               memberIsExternallyVisible(subscriptDeclaration.modifiers, syntax: node),
               p04ReturnTypeIsRawResourceSurface(
                subscriptDeclaration.returnClause.type,
                rawResourceAliases: rawResourceAliases
               )
            {
                insert(
                    "FG-016",
                    "raw-runtime-resource-subscript",
                    source,
                    subscriptDeclaration,
                    "\(owner) exposes a provider or raw URL/Data resource subscript instead of an opaque session"
                )
            }

            if isUIModule, let variable = node.as(VariableDeclSyntax.self),
               isRetainedOrGlobalVariable(variable),
               !p04IsManifestResourceRead(node, source: source)
            {
                for binding in variable.bindings {
                    let declaredTypes = binding.typeAnnotation.map {
                        typeNames(in: $0.type)
                    } ?? []
                    let inferredTypes = binding.initializer.map {
                        p04SyntaxNames(in: $0.value)
                    } ?? []
                    let resourceTypes = declaredTypes.union(inferredTypes)
                    let isDTO = enclosingNominalName(node)?.hasSuffix("DTO") == true
                    let boundaryHints = [
                        "artifact", "file", "import", "ingest", "key", "resource", "share", "url",
                    ]
                    let bindingNames = patternNames(binding.pattern).map { $0.lowercased() }
                    let isResourceNamed = bindingNames.contains { name in
                        boundaryHints.contains(where: name.contains)
                    }
                    let storesURL = resourceTypes.contains("URL")
                    let storesDataOrRawAlias = resourceTypes.contains("Data") ||
                        !resourceTypes.isDisjoint(with: rawResourceAliases)
                    if storesURL || (storesDataOrRawAlias && (isDTO || isResourceNamed)) {
                        insert(
                            "FG-016",
                            isDTO ? "url-data-bearing-module-dto" : "stored-raw-module-resource",
                            source,
                            binding,
                            isDTO
                                ? "RuneScribeUIModule declares a URL/Data-bearing DTO instead of an opaque resource handle"
                                : "RuneScribeUIModule stores raw URL/Data instead of an opaque resource handle"
                        )
                    }
                }
            }

            if let declaration = node.as(ImportDeclSyntax.self) {
                let importText = compactSyntaxText(declaration)
                let importedModule = declaration.path.trimmedDescription
                if p04OperationalFrameworks.contains(importedModule) {
                    if !isPlatformImplementation, !isUIRuntime {
                        insert(
                            "FG-007",
                            "module-owned-operational-framework",
                            source,
                            declaration,
                            isOperationalModule
                                ? "shipping module implementation imports operational framework \(importedModule)"
                                : "non-designated shipping source imports operational framework \(importedModule)"
                        )
                    } else if isUIRuntime,
                              p04UIRuntimeFrameworkAllowlist[uiRuntimeFile]?
                                .contains(importedModule) != true
                    {
                        insert(
                            "FG-007",
                            "unallowlisted-runtime-native-bridge-framework",
                            source,
                            declaration,
                            "UIRuntime framework \(importedModule) is not allowlisted for \(uiRuntimeFile)"
                        )
                    }
                }
                let spiName: String?
                if importText.contains("@_spi(RuntimeResourceHost)") {
                    spiName = "RuntimeResourceHost"
                } else if importText.contains("@_spi(RuntimeFileImportHost)") {
                    spiName = "RuntimeFileImportHost"
                } else {
                    spiName = nil
                }
                if let spiName {
                    let allowedFiles: [String: Set<String>] = [
                        "RuntimeResourceHost": [
                            "RuntimeApplicationResourcePresentation.swift",
                            "RuntimeContactPicker.swift", "RuntimeQRScanner.swift",
                            "RuntimeSharePresentation.swift",
                        ],
                        "RuntimeFileImportHost": ["RuntimeInboundFileImporter.swift"],
                    ]
                    if !isUIRuntime || allowedFiles[spiName]?.contains(uiRuntimeFile) != true {
                        insert(
                            "FG-016",
                            "unauthorized-runtime-resource-spi-import",
                            source,
                            declaration,
                            "shipping source imports the \(spiName) SPI outside its exact UIRuntime bridge allowlist"
                        )
                    }
                }
                if importText.contains("@_spi(RuntimeTesting)"),
                   declaration.path.trimmedDescription == "RuneScribeRuntimeCore"
                {
                    insert(
                        "FG-009",
                        "shipping-runtime-testing-spi-import",
                        source,
                        declaration,
                        "shipping source imports the RuntimeTesting SPI"
                    )
                }
            }
        }

        if isUIRuntime, uiRuntimeOperationalUse,
           !p04UIRuntimeBridgeHasOpaqueAuthority(
            source,
            runtimeAuthorityNames: runtimeAuthorityNames
           )
        {
            findings.insert(Finding(
                ruleID: "FG-007",
                category: "runtime-native-bridge-without-opaque-authority",
                path: source.relativePath,
                line: 1,
                detail: "UIRuntime native bridge lacks opaque runtime authority acquisition, revocation handling, and deterministic close"
            ))
        }
    }

    if let gateway = sources.first(where: { $0.relativePath == p04RuntimeIOGatewayPath }) {
        var functions: [String: [FunctionDeclSyntax]] = [:]
        for node in gateway.nodes {
            guard let function = node.as(FunctionDeclSyntax.self),
                  isCanonicalOwnerMember(
                    node,
                    owner: "RuntimeIOGateway",
                    source: gateway,
                    path: p04RuntimeIOGatewayPath
                  )
            else { continue }
            functions[function.name.text, default: []].append(function)
        }
        func directlyOwnedGuardConditions(_ function: FunctionDeclSyntax) -> [String] {
            guard let body = function.body else { return [] }
            var conditions: [String] = []
            var stack = [Syntax(body)]
            while let current = stack.popLast() {
                if let nested = current.as(FunctionDeclSyntax.self), nested.id != function.id {
                    continue
                }
                if current.is(ClosureExprSyntax.self) || current.is(InitializerDeclSyntax.self) {
                    continue
                }
                if let statement = current.as(GuardStmtSyntax.self),
                   !hasConditionalAncestor(Syntax(statement), before: Syntax(function))
                {
                    conditions.append(compactSyntaxText(statement.conditions))
                }
                stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
            }
            return conditions
        }

        func insertLifecycleFinding(
            functionName: String,
            detail: String,
            validates: (FunctionDeclSyntax) -> Bool
        ) {
            guard let matches = functions[functionName], matches.count == 1,
                  let function = matches.first, validates(function)
            else {
                findings.insert(Finding(
                    ruleID: "FG-016",
                    category: "missing-runtime-resource-lifecycle-validation",
                    path: gateway.relativePath,
                    line: 1,
                    detail: detail
                ))
                return
            }
        }

        insertLifecycleFinding(
            functionName: "validateLifecycle",
            detail: "runtime I/O lifecycle validation no longer checks runtime and module generations"
        ) { function in
            let guards = directlyOwnedGuardConditions(function)
            return guards.contains("runtimeIsActive") &&
                guards.contains("runtimeGeneration==lease.runtimeGeneration") &&
                guards.contains {
                    $0.contains("letsource=sources[lease.sourceModuleID]") &&
                        $0.contains("source.generation==lease.sourceModuleGeneration")
                }
        }

        insertLifecycleFinding(
            functionName: "invalidateModule",
            detail: "module invalidation no longer revokes runtime resource bindings"
        ) { function in
            let calls = directCalls(in: function).filter {
                !hasConditionalAncestor(Syntax($0), before: Syntax(function))
            }.map { compactSyntaxText($0) }
            return calls.contains { $0.contains("sources.removeValue(forKey:moduleID)") } &&
                calls.contains {
                    $0.contains(
                        "revokeResourceBindings(moduleID:moduleID,generation:generation)"
                    )
                }
        }

        insertLifecycleFinding(
            functionName: "acquireApplicationResource",
            detail: "application resource acquisition no longer creates a validated opaque lease"
        ) { function in
            guard let body = function.body else { return false }
            let compact = compactSyntaxText(body)
            return [
                "authorizedResourceHandlers", "resourceBindings",
                "RuntimeApplicationResourceLease",
            ].allSatisfy(compact.contains)
        }

        insertLifecycleFinding(
            functionName: "revokeResourceBindings",
            detail: "resource revocation no longer validates generation and emits revocation"
        ) { function in
            guard let body = function.body else { return false }
            var guardChecksGeneration = false
            var terminatesRevokedLease = false
            var stack = [Syntax(body)]
            while let current = stack.popLast() {
                if let statement = current.as(GuardStmtSyntax.self) {
                    let condition = compactSyntaxText(statement.conditions)
                    if condition.contains("binding.lease.sourceModuleID==moduleID") &&
                        condition.contains(
                            "generation==nil||binding.lease.sourceModuleGeneration==generation"
                        )
                    {
                        guardChecksGeneration = true
                    }
                }
                if let call = current.as(FunctionCallExprSyntax.self),
                   callTarget(call)?.member == "terminate",
                   compactSyntaxText(call).contains("with:.revoked")
                {
                    var ancestor = Syntax(call).parent
                    while let node = ancestor, node.id != function.id {
                        if node.is(ForStmtSyntax.self) {
                            terminatesRevokedLease = true
                            break
                        }
                        ancestor = node.parent
                    }
                }
                stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
            }
            return guardChecksGeneration && terminatesRevokedLease
        }
    } else {
        findings.insert(Finding(
            ruleID: "FG-016",
            category: "missing-runtime-resource-lifecycle-validation",
            path: p04RuntimeIOGatewayPath,
            line: 1,
            detail: "canonical RuntimeIOGateway source is missing"
        ))
    }

    return findings
}

private func scan(_ sources: [ParsedSource]) -> Set<Finding> {
    var findings: Set<Finding> = []
    var aliases: [AliasDeclaration] = []
    var protocols: [ProtocolDeclaration] = []

    var declaredFieldsByOwner: [String: [String: Set<String>]] = [:]
    var applicationEndpointCatalogMembers: Set<String> = []
    for source in sources {
        for node in source.nodes {
            guard let variable = node.as(VariableDeclSyntax.self),
                  isRetainedOrGlobalVariable(variable),
                  let owner = enclosingNominalName(node)
            else {
                continue
            }
            for binding in variable.bindings {
                let names = patternNames(binding.pattern)
                let declaredTypes = binding.typeAnnotation.map {
                    typeNames(in: $0.type)
                } ?? []
                for name in names {
                    declaredFieldsByOwner[owner, default: [:]][name, default: []]
                        .formUnion(declaredTypes)
                    if owner == "RuntimeApplicationEndpointCatalog",
                       !declaredTypes.isDisjoint(with: [
                        "RuntimeEndpointKey", "RuntimeStateEndpointDescriptor",
                       ])
                    {
                        applicationEndpointCatalogMembers.insert(name)
                    }
                }
            }
        }
    }

    for source in sources {
        for node in source.nodes {
            if let declaration = node.as(TypeAliasDeclSyntax.self) {
                aliases.append(AliasDeclaration(
                    name: declaration.name.text,
                    referencedNames: typeNames(in: declaration.initializer.value),
                    isDirectRawErasure: isRawStorageType(
                        declaration.initializer.value,
                        genericNames: [],
                        rawErasureTypes: []
                    ),
                    path: source.relativePath,
                    line: source.line(of: declaration)
                ))
            } else if let declaration = node.as(ProtocolDeclSyntax.self) {
                protocols.append(ProtocolDeclaration(
                    name: declaration.name.text,
                    inheritedNames: inheritanceNames(declaration.inheritanceClause).union(
                        protocolSelfConstraintNames(declaration.genericWhereClause)
                    ),
                    path: source.relativePath,
                    line: source.line(of: declaration)
                ))
            }
        }
    }

    let serviceTypes = transitiveNames(
        roots: ["RuneScribeApplicationService", "RuneScribeInboundInputService"],
        aliases: aliases,
        protocols: protocols
    )
    let actorExistentialTypes = transitiveNames(
        roots: ["Actor"],
        aliases: aliases,
        protocols: protocols
    )
    var rawErasureTypes = Set(aliases.filter(\.isDirectRawErasure).map(\.name))
    var rawErasureAliasesChanged = true
    while rawErasureAliasesChanged {
        rawErasureAliasesChanged = false
        for alias in aliases where !alias.referencedNames.isDisjoint(with: rawErasureTypes) {
            if rawErasureTypes.insert(alias.name).inserted { rawErasureAliasesChanged = true }
        }
    }
    let menuBufferAliasTypes = transitiveNames(
        roots: ["ApplicationMenuCommandDTO"],
        aliases: aliases,
        protocols: []
    ).subtracting(["ApplicationMenuCommandDTO"])
    var localNominalShadowsByPath: [String: [NominalShadow]] = [:]
    for source in sources {
        for node in source.nodes {
            let shadowName: String?
            if let nominal = nominalContext(for: node),
               nominal.inheritance.isDisjoint(with: serviceTypes)
            {
                shadowName = nominal.name
            } else if let alias = node.as(TypeAliasDeclSyntax.self),
                      typeNames(in: alias.initializer.value).isDisjoint(with: serviceTypes)
            {
                shadowName = alias.name.text
            } else if let declaration = node.as(ProtocolDeclSyntax.self) {
                let relationships = inheritanceNames(declaration.inheritanceClause).union(
                    protocolSelfConstraintNames(declaration.genericWhereClause)
                )
                shadowName = relationships.isDisjoint(with: serviceTypes)
                    ? declaration.name.text
                    : nil
            } else {
                shadowName = nil
            }
            guard let shadowName,
                  let lexicalScope = nearestLexicalScope(containing: node)
            else { continue }
            localNominalShadowsByPath[source.relativePath, default: []].append(
                NominalShadow(name: shadowName, lexicalScope: lexicalScope)
            )
        }
    }
    func visibleShadows<T: SyntaxProtocol>(
        in source: ParsedSource,
        at syntax: T
    ) -> Set<String> {
        visibleNominalShadowNames(
            at: syntax,
            shadows: localNominalShadowsByPath[source.relativePath, default: []]
        )
    }

    var providerNominalTypes: Set<String> = []
    var publicCoreTypes: Set<String> = []
    var coreNominalRelationships: [String: Set<String>] = [:]
    for source in sources where isCorePath(source.relativePath) {
        for node in source.nodes {
            if let nominal = nominalContext(for: node) {
                coreNominalRelationships[nominal.name, default: []]
                    .formUnion(nominal.inheritance)
                if isExternallyVisible(nominal.modifiers) {
                    publicCoreTypes.insert(nominal.name)
                }
            } else if let declaration = node.as(ProtocolDeclSyntax.self) {
                coreNominalRelationships[declaration.name.text, default: []]
                    .formUnion(inheritanceNames(declaration.inheritanceClause))
                if isExternallyVisible(declaration.modifiers) {
                    publicCoreTypes.insert(declaration.name.text)
                }
            } else if let declaration = node.as(ExtensionDeclSyntax.self) {
                let name = declaration.extendedType.trimmedDescription
                    .split(separator: ".").last.map(String.init) ?? ""
                if !name.isEmpty {
                    coreNominalRelationships[name, default: []]
                        .formUnion(inheritanceNames(declaration.inheritanceClause))
                }
            }
        }
    }
    var knownProviderTypes = serviceTypes
    var providerRelationshipsChanged = true
    while providerRelationshipsChanged {
        providerRelationshipsChanged = false
        for (name, relationships) in coreNominalRelationships
            where !relationships.isDisjoint(with: knownProviderTypes) &&
                !knownProviderTypes.contains(name)
        {
            knownProviderTypes.insert(name)
            providerNominalTypes.insert(name)
            providerRelationshipsChanged = true
        }
    }
    providerNominalTypes.formUnion(["RuneScribeCoreApplicationService"])
    let providerExposureTypes = transitiveNames(
        roots: providerNominalTypes.union(serviceTypes),
        aliases: aliases,
        protocols: protocols
    )
    var providerWrapperTypes: Set<String> = []
    for source in sources where isCorePath(source.relativePath) {
        for node in source.nodes {
            guard let variable = node.as(VariableDeclSyntax.self),
                  isRetainedOrGlobalVariable(variable),
                  let owner = enclosingNominalName(node)
            else {
                continue
            }
            let canRetainProvider = variable.bindings.contains { binding in
                guard let annotation = binding.typeAnnotation else { return false }
                return isProviderErasureSurfaceType(
                    annotation.type,
                    rawErasureTypes: rawErasureTypes
                ) || !typeNames(in: annotation.type).isDisjoint(with: providerExposureTypes) ||
                    !typeNames(in: annotation.type).isDisjoint(
                        with: enclosingNominalGenericParameters(node)
                    )
            }
            if canRetainProvider { providerWrapperTypes.insert(owner) }
        }
    }
    var providerWrapperAliasesChanged = true
    while providerWrapperAliasesChanged {
        providerWrapperAliasesChanged = false
        for alias in aliases where !alias.referencedNames.isDisjoint(with: providerWrapperTypes) {
            if providerWrapperTypes.insert(alias.name).inserted {
                providerWrapperAliasesChanged = true
            }
        }
    }
    func visibleProviderShadows<T: SyntaxProtocol>(
        in source: ParsedSource,
        at syntax: T
    ) -> Set<String> {
        visibleShadows(in: source, at: syntax).subtracting(providerExposureTypes)
    }
    publicCoreTypes.remove("RuneScribeCoreModuleBootstrap")
    let bootstrapAliasTypes = transitiveNames(
        roots: ["RuneScribeCoreModuleBootstrap"],
        aliases: aliases,
        protocols: []
    ).subtracting(["RuneScribeCoreModuleBootstrap"])
    let prohibitedCoreTypes = transitiveNames(
        roots: publicCoreTypes,
        aliases: aliases,
        protocols: []
    ).union(bootstrapAliasTypes)

    var providerReturningCoreOperations: Set<ServiceReturningOperation> = []
    for source in sources where isCorePath(source.relativePath) {
        for node in source.nodes {
            if let function = node.as(FunctionDeclSyntax.self),
               let returnType = function.signature.returnClause?.type,
               !resolvedServiceTypeNames(
                returnType,
                at: function,
                serviceTypes: providerExposureTypes,
                localNominalShadows: visibleProviderShadows(in: source, at: function)
               ).isDisjoint(with: providerExposureTypes)
            {
                providerReturningCoreOperations.insert(ServiceReturningOperation(
                    owner: enclosingOperationOwnerName(node),
                    name: function.name.text
                ))
            }
            if let variable = node.as(VariableDeclSyntax.self),
               isRetainedOrGlobalVariable(variable)
            {
                for binding in variable.bindings {
                    guard binding.typeAnnotation.map({
                        !resolvedServiceTypeNames(
                            $0.type,
                            at: binding,
                            serviceTypes: providerExposureTypes,
                            localNominalShadows: visibleProviderShadows(in: source, at: binding)
                        ).isDisjoint(with: providerExposureTypes)
                    }) == true
                    else {
                        continue
                    }
                    for name in patternNames(binding.pattern) {
                        providerReturningCoreOperations.insert(ServiceReturningOperation(
                            owner: enclosingOperationOwnerName(node),
                            name: name
                        ))
                    }
                }
            }
        }
    }

    var providerSummariesChanged = true
    while providerSummariesChanged {
        providerSummariesChanged = false
        for source in sources where isCorePath(source.relativePath) {
            for node in source.nodes {
                let context = ProviderResultContext(
                    source: source,
                    providerTypes: providerExposureTypes,
                    wrapperTypes: providerWrapperTypes,
                    providerReturningOperations: providerReturningCoreOperations,
                    includeSelf: enclosingNominalName(node).map(providerNominalTypes.contains) == true
                )
                if let function = node.as(FunctionDeclSyntax.self),
                   functionCanReturnValue(function), let body = function.body,
                   resultRootsPublishProvider(
                    resultRootExpressions(in: body.statements),
                    context: context
                   ),
                   providerReturningCoreOperations.insert(ServiceReturningOperation(
                    owner: enclosingOperationOwnerName(node),
                    name: function.name.text
                   )).inserted
                {
                    providerSummariesChanged = true
                }
                if let variable = node.as(VariableDeclSyntax.self),
                   isRetainedOrGlobalVariable(variable)
                {
                    for binding in variable.bindings {
                        let publishes = binding.initializer.map {
                            expressionPublishesProvider($0.value, context: context)
                        } == true || binding.accessorBlock.map {
                            resultRootsPublishProvider(
                                accessorResultExpressions($0),
                                context: context
                            )
                        } == true
                        guard publishes else { continue }
                        let additions = Set(patternNames(binding.pattern)).map {
                            ServiceReturningOperation(
                                owner: enclosingOperationOwnerName(node),
                                name: $0
                            )
                        }.filter { !providerReturningCoreOperations.contains($0) }
                        if !additions.isEmpty {
                            providerReturningCoreOperations.formUnion(additions)
                            providerSummariesChanged = true
                        }
                    }
                }
            }
        }
    }
    for source in sources where isCorePath(source.relativePath) {
        for node in source.nodes {
            if let function = node.as(FunctionDeclSyntax.self),
               memberIsExternallyVisible(function.modifiers, syntax: node),
               let returnType = function.signature.returnClause?.type,
               !resolvedServiceTypeNames(
                returnType,
                at: function,
                serviceTypes: providerExposureTypes,
                localNominalShadows: visibleProviderShadows(in: source, at: function)
               ).isDisjoint(with: providerExposureTypes)
            {
                findings.insert(Finding(
                    ruleID: "FG-004",
                    category: "provider-result-publication-surface",
                    path: source.relativePath,
                    line: source.line(of: function),
                    detail: "public or package Core function exposes a provider-owned service result"
                ))
            }
            if let function = node.as(FunctionDeclSyntax.self),
               memberIsExternallyVisible(function.modifiers, syntax: node),
               functionCanReturnValue(function),
               let body = function.body,
               resultRootsPublishProvider(
                resultRootExpressions(in: body.statements),
                context: ProviderResultContext(
                    source: source,
                    providerTypes: providerExposureTypes,
                    wrapperTypes: providerWrapperTypes,
                    providerReturningOperations: providerReturningCoreOperations,
                    includeSelf: enclosingNominalName(node)
                        .map(providerNominalTypes.contains) == true
                )
               )
            {
                findings.insert(Finding(
                    ruleID: "FG-004",
                    category: "provider-wrapper-result-publication-surface",
                    path: source.relativePath,
                    line: source.line(of: function),
                    detail: "public or package Core function wraps a provider-owned value in its returned result"
                ))
            }
            if let variable = node.as(VariableDeclSyntax.self),
               memberIsExternallyVisible(variable.modifiers, syntax: node)
            {
                for binding in variable.bindings {
                    let context = ProviderResultContext(
                        source: source,
                        providerTypes: providerExposureTypes,
                        wrapperTypes: providerWrapperTypes,
                        providerReturningOperations: providerReturningCoreOperations,
                        includeSelf: enclosingNominalName(node)
                            .map(providerNominalTypes.contains) == true
                    )
                    let annotatedExposure = binding.typeAnnotation.map { annotation in
                        !resolvedServiceTypeNames(
                            annotation.type,
                            at: binding,
                            serviceTypes: providerExposureTypes,
                            localNominalShadows: visibleProviderShadows(in: source, at: binding)
                        ).isDisjoint(with: providerExposureTypes)
                    } ?? false
                    let rootedExposure = binding.initializer.map {
                        expressionPublishesProvider($0.value, context: context)
                    } == true || binding.accessorBlock.map {
                        resultRootsPublishProvider(
                            accessorResultExpressions($0),
                            context: context
                        )
                    } == true
                    guard annotatedExposure || rootedExposure else {
                        continue
                    }
                    findings.insert(Finding(
                        ruleID: "FG-004",
                        category: "provider-property-publication-surface",
                        path: source.relativePath,
                        line: source.line(of: binding),
                        detail: "public or package Core property exposes a provider-owned service value"
                    ))
                }
            }
            if let subscriptDeclaration = node.as(SubscriptDeclSyntax.self),
               memberIsExternallyVisible(subscriptDeclaration.modifiers, syntax: node),
               (!resolvedServiceTypeNames(
                    subscriptDeclaration.returnClause.type,
                    at: subscriptDeclaration,
                    serviceTypes: providerExposureTypes,
                    localNominalShadows: visibleProviderShadows(
                        in: source,
                        at: subscriptDeclaration
                    )
                ).isDisjoint(with: providerExposureTypes) ||
                subscriptDeclaration.accessorBlock.map {
                    resultRootsPublishProvider(
                        accessorResultExpressions($0),
                        context: ProviderResultContext(
                            source: source,
                            providerTypes: providerExposureTypes,
                            wrapperTypes: providerWrapperTypes,
                            providerReturningOperations: providerReturningCoreOperations,
                            includeSelf: enclosingNominalName(node)
                                .map(providerNominalTypes.contains) == true
                        )
                    )
                } == true)
            {
                findings.insert(Finding(
                    ruleID: "FG-004",
                    category: "provider-subscript-publication-surface",
                    path: source.relativePath,
                    line: source.line(of: subscriptDeclaration),
                    detail: "public or package Core subscript exposes a provider-owned service value"
                ))
            }
            if let caseDeclaration = node.as(EnumCaseDeclSyntax.self),
               isInsideExternallyVisibleEnum(node)
            {
                let exposesProvider = caseDeclaration.elements.contains { element in
                    guard let parameters = element.parameterClause?.parameters else { return false }
                    return parameters.contains { parameter in
                        !resolvedServiceTypeNames(
                            parameter.type,
                            at: parameter,
                            serviceTypes: providerExposureTypes,
                            localNominalShadows: visibleProviderShadows(in: source, at: parameter)
                        ).isDisjoint(with: providerExposureTypes)
                    }
                }
                if exposesProvider {
                    findings.insert(Finding(
                        ruleID: "FG-004",
                        category: "provider-enum-publication-surface",
                        path: source.relativePath,
                        line: source.line(of: caseDeclaration),
                        detail: "public or package Core enum case carries a provider-owned service value"
                    ))
                }
            }
        }
    }

    var rawStorageByPath: [String: Set<String>] = [:]
    var rawStorageByOwner: [String: Set<String>] = [:]
    var rawStorages: [RawStorage] = []
    var retainedStorageByPath: [String: Set<String>] = [:]
    var retainedStorageByOwner: [String: Set<String>] = [:]
    var variableTypesByPath: [String: [String: Set<String>]] = [:]
    var functionReturnTypes: [String: Set<String>] = [:]
    var receiverFunctionReturnTypes: [String: Set<String>] = [:]
    var memberValueTypes: [MemberIdentity: Set<String>] = [:]
    var rawStorageReturningFunctions: Set<String> = []

    for source in sources {
        for node in source.nodes {
            guard let function = node.as(FunctionDeclSyntax.self),
                  let returnType = function.signature.returnClause?.type
            else {
                continue
            }
            functionReturnTypes[function.name.text, default: []]
                .formUnion(resolvedServiceTypeNames(
                    returnType,
                    at: function,
                    serviceTypes: serviceTypes,
                    localNominalShadows: visibleShadows(in: source, at: function)
                ))
            receiverFunctionReturnTypes[function.name.text, default: []]
                .formUnion(outerTypeNames(in: returnType))
            let genericNames = genericParameterNames(function.genericParameterClause)
                .union(enclosingNominalGenericParameters(node))
            if isRawStorageType(
                returnType,
                genericNames: genericNames,
                rawErasureTypes: rawErasureTypes
            ) {
                rawStorageReturningFunctions.insert(function.name.text)
            }
        }
    }

    for source in sources {
        for node in source.nodes {
            guard let variable = node.as(VariableDeclSyntax.self),
                  let owner = enclosingNominalName(node)
            else {
                continue
            }
            for binding in variable.bindings {
                var resultTypes = binding.typeAnnotation.map {
                    outerTypeNames(in: $0.type)
                } ?? []
                if resultTypes.isEmpty, let initializer = binding.initializer {
                    resultTypes.formUnion(inferredExpressionTypes(
                        initializer.value,
                        variables: [:],
                        functionReturns: receiverFunctionReturnTypes
                    ))
                }
                for name in patternNames(binding.pattern) {
                    memberValueTypes[MemberIdentity(owner: owner, name: name), default: []]
                        .formUnion(resultTypes)
                }
            }
        }
    }

    for source in sources {
        for node in source.nodes {
            if let variable = node.as(VariableDeclSyntax.self) {
                let genericNames = enclosingNominalGenericParameters(node)
                for binding in variable.bindings {
                    let names = patternNames(binding.pattern)
                    if isRetainedOrGlobalVariable(variable) {
                        let retainedNames = Set(names).union(names.map { "_\($0)" })
                        retainedStorageByPath[source.relativePath, default: []]
                            .formUnion(retainedNames)
                        if let owner = enclosingNominalName(Syntax(binding)) {
                            retainedStorageByOwner[owner, default: []].formUnion(retainedNames)
                        }
                    }
                    if let annotation = binding.typeAnnotation {
                        let references = resolvedServiceTypeNames(
                            annotation.type,
                            at: binding,
                            serviceTypes: serviceTypes,
                            localNominalShadows: visibleShadows(in: source, at: binding)
                        )
                        for name in names {
                            variableTypesByPath[source.relativePath, default: [:]][name, default: []]
                                .formUnion(references)
                        }
                        if isRetainedOrGlobalVariable(variable),
                           isRawStorageType(
                            annotation.type,
                            genericNames: genericNames,
                            rawErasureTypes: rawErasureTypes
                           )
                        {
                            for name in names {
                                rawStorageByPath[source.relativePath, default: []].insert(name)
                                if let owner = enclosingNominalName(Syntax(binding)) {
                                    rawStorageByOwner[owner, default: []].insert(name)
                                }
                                rawStorages.append(RawStorage(
                                    name: name,
                                    path: source.relativePath,
                                    line: source.line(of: binding)
                                ))
                            }
                        }
                    }
                    if let initializer = binding.initializer {
                        let initializesRawStorage = expressionInitializesRawStorage(
                            initializer.value,
                            genericNames: genericNames,
                            rawErasureTypes: rawErasureTypes
                        ) || descendantCalls(of: initializer.value).contains { call in
                            callTarget(call).map {
                                rawStorageReturningFunctions.contains($0.member)
                            } ?? false
                        }
                        if isRetainedOrGlobalVariable(variable), initializesRawStorage
                        {
                            for name in names {
                                rawStorageByPath[source.relativePath, default: []].insert(name)
                                if let owner = enclosingNominalName(Syntax(binding)) {
                                    rawStorageByOwner[owner, default: []].insert(name)
                                }
                                rawStorages.append(RawStorage(
                                    name: name,
                                    path: source.relativePath,
                                    line: source.line(of: binding)
                                ))
                            }
                        }
                        let inferred = inferredExpressionTypes(
                            initializer.value,
                            variables: variableTypesByPath[source.relativePath, default: [:]],
                            functionReturns: functionReturnTypes
                        )
                        for name in names {
                            variableTypesByPath[source.relativePath, default: [:]][name, default: []]
                                .formUnion(inferred)
                        }
                    }
                }
            } else if let function = node.as(FunctionDeclSyntax.self) {
                for parameter in functionParameters(function) {
                    variableTypesByPath[source.relativePath, default: [:]][parameter.name, default: []]
                        .formUnion(resolvedServiceTypeNames(
                            parameter.type,
                            at: function,
                            serviceTypes: serviceTypes,
                            localNominalShadows: visibleShadows(in: source, at: function)
                        ))
                }
            } else if let initializer = node.as(InitializerDeclSyntax.self) {
                for parameter in initializerParameters(initializer) {
                    variableTypesByPath[source.relativePath, default: [:]][parameter.name, default: []]
                        .formUnion(resolvedServiceTypeNames(
                            parameter.type,
                            at: initializer,
                            serviceTypes: serviceTypes,
                            localNominalShadows: visibleShadows(in: source, at: initializer)
                        ))
                }
            }
        }
    }

    var menuBufferNamesByPath: [String: Set<String>] = [:]
    var menuValueNamesByPath: [String: Set<String>] = [:]
    var menuReturningFunctions: Set<String> = []
    for source in sources where isConsumerPath(source.relativePath) {
        for node in source.nodes {
            if let variable = node.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    let names = patternNames(binding.pattern)
                    if let annotation = binding.typeAnnotation {
                        if typeNames(in: annotation.type).contains("ApplicationMenuCommandDTO") {
                            menuValueNamesByPath[source.relativePath, default: []].formUnion(names)
                        }
                        if isRetainedOrGlobalVariable(variable),
                           isMenuBufferType(annotation.type, aliasTypes: menuBufferAliasTypes)
                        {
                            menuBufferNamesByPath[source.relativePath, default: []].formUnion(names)
                            findings.insert(Finding(
                                ruleID: "FG-006",
                                category: "second-consumer-menu-buffer",
                                path: source.relativePath,
                                line: source.line(of: binding),
                                detail: "shipping consumer retains a second menu command collection, stream, or continuation"
                            ))
                        }
                    }
                    if isRetainedOrGlobalVariable(variable),
                       let initializer = binding.initializer,
                       expressionInitializesMenuBuffer(
                        initializer.value,
                        aliasTypes: menuBufferAliasTypes
                       )
                    {
                        menuBufferNamesByPath[source.relativePath, default: []].formUnion(names)
                        findings.insert(Finding(
                            ruleID: "FG-006",
                            category: "second-consumer-menu-buffer",
                            path: source.relativePath,
                            line: source.line(of: binding),
                            detail: "shipping consumer retains a second menu command collection, stream, or continuation"
                        ))
                    }
                }
            } else if let function = node.as(FunctionDeclSyntax.self) {
                for parameter in functionParameters(function)
                    where typeNames(in: parameter.type).contains("ApplicationMenuCommandDTO")
                {
                    menuValueNamesByPath[source.relativePath, default: []].insert(parameter.name)
                }
                if let returnType = function.signature.returnClause?.type,
                   typeNames(in: returnType).contains("ApplicationMenuCommandDTO")
                {
                    menuReturningFunctions.insert(function.name.text)
                }
            } else if let initializer = node.as(InitializerDeclSyntax.self) {
                for parameter in initializerParameters(initializer)
                    where typeNames(in: parameter.type).contains("ApplicationMenuCommandDTO")
                {
                    menuValueNamesByPath[source.relativePath, default: []].insert(parameter.name)
                }
            }
        }
    }
    for source in sources where isConsumerPath(source.relativePath) {
        let bufferNames = menuBufferNamesByPath[source.relativePath, default: []]
        let valueNames = menuValueNamesByPath[source.relativePath, default: []]
        guard !bufferNames.isEmpty else { continue }
        for node in source.nodes {
            guard let call = node.as(FunctionCallExprSyntax.self),
                  let target = callTarget(call),
                  ["append", "insert", "updateValue", "replaceSubrange", "merge"].contains(target.member),
                  let base = directExpressionName(target.base),
                  bufferNames.contains(base)
            else {
                continue
            }
            let carriesMenuValue = call.arguments.contains { argument in
                if !expressionIdentifierNames(argument.expression).isDisjoint(with: valueNames) {
                    return true
                }
                return descendantCalls(of: argument.expression).contains { nested in
                    callTarget(nested).map { menuReturningFunctions.contains($0.member) } ?? false
                }
            }
            if carriesMenuValue {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "second-consumer-menu-buffer-flow",
                    path: source.relativePath,
                    line: source.line(of: call),
                    detail: "menu command value is appended or inserted into consumer-owned retained buffering"
                ))
            }
        }
    }

    var publicationSurfaces: [PublicationSurface] = []
    for source in sources {
        for node in source.nodes {
            guard let function = node.as(FunctionDeclSyntax.self) else { continue }
            let rawNames = rawStorageByPath[source.relativePath, default: []].union(
                enclosingNominalName(node).map {
                    rawStorageByOwner[$0, default: []]
                } ?? []
            )
            let genericNames = genericParameterNames(function.genericParameterClause)
                .union(enclosingNominalGenericParameters(node))
            let erasedParameters = Set(functionParameters(function).compactMap { parameter in
                let names = typeNames(in: parameter.type)
                return isRawErasedValueType(
                    parameter.type,
                    genericNames: [],
                    rawErasureTypes: rawErasureTypes
                ) ||
                    !names.isDisjoint(with: actorExistentialTypes) ||
                    !names.isDisjoint(with: serviceTypes)
                    ? parameter.name
                    : nil
            })
            let storableParameters = Set(functionParameters(function).compactMap { parameter in
                let names = typeNames(in: parameter.type)
                return isRawErasedValueType(
                    parameter.type,
                    genericNames: genericNames,
                    rawErasureTypes: rawErasureTypes
                ) ||
                    !names.isDisjoint(with: actorExistentialTypes) ||
                    !names.isDisjoint(with: serviceTypes)
                    ? parameter.name
                    : nil
            })
            if let returnType = function.signature.returnClause?.type,
               !typeNames(in: returnType).isDisjoint(with: genericNames)
            {
                let resolvedRawNames = propagatedIdentifierNames(
                    from: rawNames.union(erasedParameters),
                    in: Syntax(function)
                )
                let resolvesRawStorage = source.nodes.contains { candidate in
                    if let cast = candidate.as(AsExprSyntax.self),
                       enclosingFunction(Syntax(cast))?.id == function.id,
                       !typeNames(in: cast.type).isDisjoint(with: genericNames)
                    {
                        return !expressionIdentifierNames(cast.expression).isDisjoint(with: resolvedRawNames)
                    }
                    guard let sequence = candidate.as(SequenceExprSyntax.self),
                          enclosingFunction(Syntax(sequence))?.id == function.id
                    else {
                        return false
                    }
                    let elements = Array(sequence.elements)
                    for index in elements.indices where elements[index].is(UnresolvedAsExprSyntax.self) {
                        guard index > elements.startIndex,
                              index + 1 < elements.endIndex,
                              let typeExpression = elements[index + 1].as(TypeExprSyntax.self),
                              !typeNames(in: typeExpression.type).isDisjoint(with: genericNames),
                              !expressionIdentifierNames(elements[index - 1]).isDisjoint(with: resolvedRawNames)
                        else {
                            continue
                        }
                        return true
                    }
                    return false
                }
                if resolvesRawStorage {
                    findings.insert(Finding(
                        ruleID: "FG-004",
                        category: "raw-generic-resolution-surface",
                        path: source.relativePath,
                        line: source.line(of: function),
                        detail: "caller-selected generic result is cast from retained erased storage"
                    ))
                }
            }
            guard !storableParameters.isEmpty else { continue }
            let propagatedStorableParameters = propagatedIdentifierNames(
                from: storableParameters,
                in: Syntax(function)
            )

            var storedParameters: Set<String> = []
            for assignment in assignments(in: function) {
                guard let destination = assignmentTargetName(assignment.lhs), rawNames.contains(destination) else {
                    continue
                }
                storedParameters.formUnion(
                    expressionIdentifierNames(assignment.rhs).intersection(propagatedStorableParameters)
                )
            }
            for call in descendantCalls(of: function) {
                guard let target = callTarget(call),
                      ["updateValue", "append", "insert", "replaceSubrange", "merge"].contains(target.member),
                      let base = directExpressionName(target.base),
                      rawNames.contains(base)
                else {
                    continue
                }
                for argument in call.arguments {
                    storedParameters.formUnion(
                        expressionIdentifierNames(argument.expression).intersection(propagatedStorableParameters)
                    )
                }
            }
            guard !storedParameters.isEmpty,
                  isCorePath(source.relativePath) || isRuntimeCorePath(source.relativePath)
            else {
                continue
            }
            let surface = PublicationSurface(
                name: function.name.text,
                storedParameters: storedParameters,
                path: source.relativePath,
                line: source.line(of: function)
            )
            publicationSurfaces.append(surface)
            findings.insert(Finding(
                ruleID: "FG-004",
                category: "raw-value-publication-surface",
                path: source.relativePath,
                line: source.line(of: function),
                detail: "generic or erased parameter is retained in raw-value storage"
            ))
        }
    }

    var publicationSurfaceNames = Set(publicationSurfaces.map(\.name))
    var publicationSurfacesChanged = true
    while publicationSurfacesChanged {
        publicationSurfacesChanged = false
        for source in sources where isCorePath(source.relativePath) ||
            isRuntimeCorePath(source.relativePath)
        {
            for node in source.nodes {
                guard let function = node.as(FunctionDeclSyntax.self),
                      !publicationSurfaceNames.contains(function.name.text)
                else {
                    continue
                }
                let genericNames = genericParameterNames(function.genericParameterClause)
                    .union(enclosingNominalGenericParameters(node))
                let storableParameters = Set(functionParameters(function).compactMap { parameter in
                    let names = typeNames(in: parameter.type)
                    return isRawErasedValueType(
                        parameter.type,
                        genericNames: genericNames,
                        rawErasureTypes: rawErasureTypes
                    ) ||
                        !names.isDisjoint(with: actorExistentialTypes) ||
                        !names.isDisjoint(with: serviceTypes)
                        ? parameter.name
                        : nil
                })
                guard !storableParameters.isEmpty else { continue }
                let propagatedParameters = propagatedIdentifierNames(
                    from: storableParameters,
                    in: Syntax(function)
                )
                let forwardsToSurface = descendantCalls(of: function).contains { call in
                    guard let target = callTarget(call),
                          publicationSurfaceNames.contains(target.member)
                    else {
                        return false
                    }
                    return call.arguments.contains {
                        !expressionIdentifierNames($0.expression)
                            .isDisjoint(with: propagatedParameters)
                    }
                }
                guard forwardsToSurface else { continue }
                publicationSurfaceNames.insert(function.name.text)
                publicationSurfacesChanged = true
                findings.insert(Finding(
                    ruleID: "FG-004",
                    category: "raw-value-publication-surface",
                    path: source.relativePath,
                    line: source.line(of: function),
                    detail: "generic or erased parameter forwards into a raw-value publication surface"
                ))
            }
        }
    }
    var coreFunctionVisibility: [String: [Bool]] = [:]
    for source in sources where isCorePath(source.relativePath) {
        for node in source.nodes {
            guard let function = node.as(FunctionDeclSyntax.self) else { continue }
            coreFunctionVisibility[function.name.text, default: []].append(
                memberIsExternallyVisible(function.modifiers, syntax: node)
            )
        }
    }
    let allowedProviderHandlerCalls: Set<String> = [
        "registerApplicationEndpoints", "registerInboundInputEndpoint",
    ]
    for source in sources {
        let variableTypes = variableTypesByPath[source.relativePath, default: [:]]
        for node in source.nodes {
            guard let call = node.as(FunctionCallExprSyntax.self), let target = callTarget(call) else { continue }
            let argumentProviderNames = call.arguments.reduce(into: Set<String>()) { result, argument in
                result.formUnion(expressionIdentifierNames(argument.expression).filter {
                    name in !variableTypes[name, default: []].isDisjoint(with: providerNominalTypes.union(serviceTypes))
                })
            }
            let selfCanRepresentProvider = target.member == "publishService" ||
                enclosingNominalName(node).map(providerNominalTypes.contains) == true
            let aliasesOfSelf = isCorePath(source.relativePath) && selfCanRepresentProvider
                ? selfAliasNames(containing: node)
                : []
            let passesProviderSelf = selfCanRepresentProvider && call.arguments.contains {
                expressionCarriesSelf($0.expression, aliases: aliasesOfSelf)
            }
            let passesProvider = passesProviderSelf ||
                !argumentProviderNames.isEmpty || call.arguments.contains { argument in
                    guard let constructor = argument.expression.as(FunctionCallExprSyntax.self) else { return false }
                    return callTarget(constructor).map { providerNominalTypes.contains($0.member) } ?? false
                }
            let isCanonicalProviderHandlerRegistration =
                allowedProviderHandlerCalls.contains(target.member) &&
                directExpressionName(target.base).map { receiverName in
                    let hasCanonicalType = variableTypes[receiverName, default: []]
                        .contains("ModuleContext")
                    let moduleContextIsShadowed = visibleShadows(in: source, at: call)
                        .contains("ModuleContext")
                    let isExplicitlyQualified = isQualifiedFunctionParameter(
                        receiverName,
                        typeName: "RuneScribeRuntimeCore.ModuleContext",
                        containing: Syntax(call)
                    )
                    return hasCanonicalType && (!moduleContextIsShadowed || isExplicitlyQualified)
                } == true

            if isCorePath(source.relativePath),
               publicationSurfaceNames.contains(target.member), passesProvider
            {
                findings.insert(Finding(
                    ruleID: "FG-004",
                    category: "provider-object-publication",
                    path: source.relativePath,
                    line: source.line(of: call),
                    detail: "provider-owned object flows into a generic or erased storage surface"
                ))
            }

            if isCorePath(source.relativePath),
               passesProviderSelf,
               !isCanonicalProviderHandlerRegistration,
               !(coreFunctionVisibility[target.member]?.allSatisfy { !$0 } ?? false)
            {
                findings.insert(Finding(
                    ruleID: "FG-004",
                    category: "provider-object-publication",
                    path: source.relativePath,
                    line: source.line(of: call),
                    detail: "provider self escapes through a non-handler-registration call"
                ))
            }
        }
    }

    var serviceReturningOperations: Set<ServiceReturningOperation> = []
    for source in sources {
        for node in source.nodes {
            guard let function = node.as(FunctionDeclSyntax.self),
                  let returnType = function.signature.returnClause?.type,
                  !resolvedServiceTypeNames(
                    returnType,
                    at: function,
                    serviceTypes: serviceTypes,
                    localNominalShadows: visibleShadows(in: source, at: function)
                  ).isDisjoint(with: serviceTypes)
            else {
                continue
            }
            serviceReturningOperations.insert(ServiceReturningOperation(
                owner: enclosingOperationOwnerName(node),
                name: function.name.text
            ))
        }
    }

    func callReturnsService(
        _ call: FunctionCallExprSyntax,
        in source: ParsedSource
    ) -> Bool {
        guard let target = callTarget(call) else { return false }
        let candidates = serviceReturningOperations.filter { $0.name == target.member }
        guard !candidates.isEmpty else { return false }
        let variables = lexicalVariableTypes(
            at: Syntax(call),
            in: source,
            functionReturns: receiverFunctionReturnTypes
        )
        var receiverTypes = inferredExpressionTypes(
            target.base,
            variables: variables,
            functionReturns: receiverFunctionReturnTypes
        )
        if let directBase = directExpressionName(target.base) {
            receiverTypes.insert(directBase)
        }
        let expandedReceiverTypes = expandedAliasTargets(receiverTypes, aliases: aliases)
        return candidates.contains { operation in
            guard let owner = operation.owner else {
                return target.base == nil
            }
            let expandedOwners = expandedAliasTargets([owner], aliases: aliases)
            if target.base == nil {
                return enclosingOperationOwnerName(Syntax(call)).map {
                    !expandedAliasTargets([$0], aliases: aliases)
                        .isDisjoint(with: expandedOwners)
                } == true
            }
            return !expandedReceiverTypes.isDisjoint(with: expandedOwners)
        }
    }

    let retainedCollectionMutators: Set<String> = [
        "append", "insert", "updateValue", "replaceSubrange", "merge",
    ]
    var peerRetentionSurfaceNames: Set<String> = []
    var peerRetentionSurfacesChanged = true
    while peerRetentionSurfacesChanged {
        peerRetentionSurfacesChanged = false
        for source in sources where isConsumerPath(source.relativePath) {
            for node in source.nodes {
                guard let function = node.as(FunctionDeclSyntax.self) else { continue }
                let retainedNames = retainedStorageByPath[source.relativePath, default: []].union(
                    enclosingNominalName(node).map {
                        retainedStorageByOwner[$0, default: []]
                    } ?? []
                )
                let parameterNames = Set(functionParameters(function).map(\.name))
                guard !parameterNames.isEmpty else { continue }
                let propagatedParameterNames = propagatedIdentifierNames(
                    from: parameterNames,
                    in: Syntax(function)
                )
                let directlyStoresParameter = assignments(in: function).contains { assignment in
                    guard let destination = assignmentTargetName(assignment.lhs),
                          retainedNames.contains(destination) ||
                            isNonlocalMemberOrSubscriptTarget(assignment.lhs)
                    else {
                        return false
                    }
                    return !expressionIdentifierNames(assignment.rhs)
                        .isDisjoint(with: propagatedParameterNames)
                } || descendantCalls(of: function).contains { call in
                    guard let target = callTarget(call) else { return false }
                    let argumentsCarryParameter = call.arguments.contains {
                        !expressionIdentifierNames($0.expression)
                            .isDisjoint(with: propagatedParameterNames)
                    }
                    guard argumentsCarryParameter else { return false }
                    if peerRetentionSurfaceNames.contains(target.member) { return true }
                    return retainedCollectionMutators.contains(target.member) &&
                        directExpressionName(target.base).map(retainedNames.contains) == true
                }
                if directlyStoresParameter && peerRetentionSurfaceNames.insert(function.name.text).inserted {
                    peerRetentionSurfacesChanged = true
                }
            }
        }
    }

    for source in sources where isConsumerPath(source.relativePath) {
        let variableTypes = variableTypesByPath[source.relativePath, default: [:]]
        let baseServiceVariables = Set(variableTypes.compactMap { name, types in
            types.isDisjoint(with: serviceTypes) ? nil : name
        })
        for node in source.nodes {
            if let function = node.as(FunctionDeclSyntax.self) {
                let retainedNames = retainedStorageByPath[source.relativePath, default: []].union(
                    enclosingNominalName(node).map {
                        retainedStorageByOwner[$0, default: []]
                    } ?? []
                )
                let serviceVariables = propagatedIdentifierNames(
                    from: baseServiceVariables,
                    in: Syntax(function)
                )
                for assignment in assignments(in: function) {
                    let returnsService = descendantCalls(of: assignment.rhs).contains { call in
                        callReturnsService(call, in: source)
                    }
                    guard let destination = assignmentTargetName(assignment.lhs),
                          retainedNames.contains(destination) ||
                            isNonlocalMemberOrSubscriptTarget(assignment.lhs),
                          returnsService ||
                            !expressionIdentifierNames(assignment.rhs).isDisjoint(with: serviceVariables)
                    else {
                        continue
                    }
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-assignment",
                        path: source.relativePath,
                        line: source.line(of: assignment.syntax),
                        detail: "provider-owned service value flows into retained or erased storage"
                    ))
                }
            } else if let initializer = node.as(InitializerDeclSyntax.self) {
                let retainedNames = retainedStorageByPath[source.relativePath, default: []].union(
                    enclosingNominalName(node).map {
                        retainedStorageByOwner[$0, default: []]
                    } ?? []
                )
                let serviceVariables = propagatedIdentifierNames(
                    from: baseServiceVariables,
                    in: Syntax(initializer)
                )
                for assignment in assignments(in: initializer) {
                    let returnsService = descendantCalls(of: assignment.rhs).contains { call in
                        callReturnsService(call, in: source)
                    }
                    guard let destination = assignmentTargetName(assignment.lhs),
                          retainedNames.contains(destination) ||
                            isNonlocalMemberOrSubscriptTarget(assignment.lhs),
                          returnsService ||
                            !expressionIdentifierNames(assignment.rhs).isDisjoint(with: serviceVariables)
                    else {
                        continue
                    }
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-assignment",
                        path: source.relativePath,
                        line: source.line(of: assignment.syntax),
                        detail: "provider-owned service value flows into retained or erased storage"
                    ))
                }
            }

            if let variable = node.as(VariableDeclSyntax.self), isRetainedOrGlobalVariable(variable) {
                for binding in variable.bindings {
                    let names = patternNames(binding.pattern)
                    if let annotation = binding.typeAnnotation,
                       !resolvedServiceTypeNames(
                        annotation.type,
                        at: binding,
                        serviceTypes: serviceTypes,
                        localNominalShadows: visibleShadows(in: source, at: binding)
                       ).isDisjoint(with: serviceTypes)
                    {
                        findings.insert(Finding(
                            ruleID: "FG-005",
                            category: "retained-peer-service-type",
                            path: source.relativePath,
                            line: source.line(of: binding),
                            detail: "retained property or global uses a provider-owned service type"
                        ))
                    }
                    if let initializer = binding.initializer {
                        let calls = descendantCalls(of: initializer.value)
                        if calls.contains(where: { call in
                            callReturnsService(call, in: source) || call.arguments.contains { argument in
                                !resolvedExpressionServiceNames(
                                    argument.expression,
                                    at: Syntax(call),
                                    serviceTypes: serviceTypes,
                                    localNominalShadows: visibleShadows(in: source, at: call)
                                ).isDisjoint(with: serviceTypes)
                            }
                        }) {
                            findings.insert(Finding(
                                ruleID: "FG-005",
                                category: "retained-service-call-result",
                                path: source.relativePath,
                                line: source.line(of: binding),
                                detail: "retained property captures a service-producing call result"
                            ))
                        }
                    }
                    _ = names
                }
            } else if let initializer = node.as(InitializerDeclSyntax.self) {
                for parameter in initializerParameters(initializer)
                    where !resolvedServiceTypeNames(
                        parameter.type,
                        at: initializer,
                        serviceTypes: serviceTypes,
                        localNominalShadows: visibleShadows(in: source, at: initializer)
                    ).isDisjoint(with: serviceTypes)
                {
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-initializer-parameter",
                        path: source.relativePath,
                        line: source.line(of: parameter.type),
                        detail: "initializer accepts a provider-owned service type"
                    ))
                }
            } else if let function = node.as(FunctionDeclSyntax.self),
                      let returnType = function.signature.returnClause?.type,
                      !resolvedServiceTypeNames(
                        returnType,
                        at: function,
                        serviceTypes: serviceTypes,
                        localNominalShadows: visibleShadows(in: source, at: function)
                      ).isDisjoint(with: serviceTypes)
            {
                findings.insert(Finding(
                    ruleID: "FG-005",
                    category: "peer-service-result-type",
                    path: source.relativePath,
                    line: source.line(of: returnType),
                    detail: "function exposes a provider-owned service result type"
                ))
            } else if let call = node.as(FunctionCallExprSyntax.self), let target = callTarget(call) {
                let retainedNames = retainedStorageByPath[source.relativePath, default: []].union(
                    enclosingNominalName(node).map {
                        retainedStorageByOwner[$0, default: []]
                    } ?? []
                )
                let serviceVariables = enclosingFunction(node).map {
                    propagatedIdentifierNames(
                        from: baseServiceVariables,
                        in: Syntax($0)
                    )
                } ?? baseServiceVariables
                let argumentsCarryService = call.arguments.contains { argument in
                    !expressionIdentifierNames(argument.expression).isDisjoint(with: serviceVariables) ||
                        descendantCalls(of: argument.expression).contains { nested in
                            callReturnsService(nested, in: source)
                        }
                }
                let writesRetainedCollection = retainedCollectionMutators.contains(target.member) &&
                    directExpressionName(target.base).map(retainedNames.contains) == true
                if argumentsCarryService &&
                    (writesRetainedCollection || peerRetentionSurfaceNames.contains(target.member))
                {
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-collection-retention",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "provider-owned service value flows through a retained collection or helper sink"
                    ))
                }
                let hasServiceMetatype = call.arguments.contains { argument in
                    !resolvedExpressionServiceNames(
                        argument.expression,
                        at: node,
                        serviceTypes: serviceTypes,
                        localNominalShadows: visibleShadows(in: source, at: node)
                    ).isDisjoint(with: serviceTypes)
                } || !resolvedExpressionServiceNames(
                    call.calledExpression,
                    at: node,
                    serviceTypes: serviceTypes,
                    localNominalShadows: visibleShadows(in: source, at: node)
                ).isDisjoint(with: serviceTypes)
                if hasServiceMetatype {
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-resolve-flow",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "call requests or forwards a provider-owned service type"
                    ))
                }
                if callReturnsService(call, in: source) {
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-call-result",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "consumer invokes a function whose declared result is a provider-owned service type"
                    ))
                }
                if let baseName = directExpressionName(target.base), serviceVariables.contains(baseName) {
                    findings.insert(Finding(
                        ruleID: "FG-005",
                        category: "peer-service-direct-call",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "consumer invokes an operation through a retained provider-owned service value"
                    ))
                }
            }
        }
    }

    var coreOperations: [CoreOperation] = []
    var coreSubscripts: [CoreSubscript] = []
    var coreInitializers: [CoreInitializer] = []
    for source in sources where isCorePath(source.relativePath) {
        for node in source.nodes {
            if let function = node.as(FunctionDeclSyntax.self),
               memberIsExternallyVisible(function.modifiers, syntax: node)
            {
                let owner = enclosingOperationOwnerName(node)
                let modifierSet = modifierNames(function.modifiers)
                let kind: CoreOperationKind
                if owner == nil {
                    kind = .topLevel
                } else if !modifierSet.isDisjoint(with: ["static", "class"]) {
                    kind = .static
                } else {
                    kind = .instance
                }
                coreOperations.append(CoreOperation(
                    name: function.name.text,
                    owner: owner,
                    kind: kind,
                    path: source.relativePath,
                    line: source.line(of: function)
                ))
            } else if let subscriptDeclaration = node.as(SubscriptDeclSyntax.self),
                      memberIsExternallyVisible(subscriptDeclaration.modifiers, syntax: node),
                      let owner = enclosingOperationOwnerName(node)
            {
                coreSubscripts.append(CoreSubscript(
                    owner: owner,
                    allLabels: subscriptDeclaration.parameterClause.parameters.map {
                        $0.firstName.text
                    },
                    requiredLabels: subscriptDeclaration.parameterClause.parameters.compactMap {
                        $0.defaultValue == nil && $0.ellipsis == nil ? $0.firstName.text : nil
                    },
                    variadicLabels: Set(subscriptDeclaration.parameterClause.parameters.compactMap {
                        $0.ellipsis != nil ? $0.firstName.text : nil
                    }),
                    path: source.relativePath,
                    line: source.line(of: subscriptDeclaration)
                ))
            } else if let initializer = node.as(InitializerDeclSyntax.self),
                      memberIsExternallyVisible(initializer.modifiers, syntax: node),
                      let owner = enclosingOperationOwnerName(node)
            {
                coreInitializers.append(CoreInitializer(
                    owner: owner,
                    allLabels: initializer.signature.parameterClause.parameters.map {
                        $0.firstName.text
                    },
                    requiredLabels: initializer.signature.parameterClause.parameters.compactMap {
                        $0.defaultValue == nil && $0.ellipsis == nil ? $0.firstName.text : nil
                    },
                    variadicLabels: Set(initializer.signature.parameterClause.parameters.compactMap {
                        $0.ellipsis != nil ? $0.firstName.text : nil
                    }),
                    path: source.relativePath,
                    line: source.line(of: initializer)
                ))
            } else if let variable = node.as(VariableDeclSyntax.self),
                      memberIsExternallyVisible(variable.modifiers, syntax: node)
            {
                let owner = enclosingOperationOwnerName(node)
                let modifierSet = modifierNames(variable.modifiers)
                let kind: CoreOperationKind = owner == nil
                    ? .topLevel
                    : (!modifierSet.isDisjoint(with: ["static", "class"]) ? .static : .instance)
                for binding in variable.bindings {
                    for name in patternNames(binding.pattern) {
                        coreOperations.append(CoreOperation(
                            name: name,
                            owner: owner,
                            kind: kind,
                            path: source.relativePath,
                            line: source.line(of: binding)
                        ))
                    }
                }
            }
        }
    }

    let bootstrapPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
    let bootstrapMembers: Set<String> = ["factory", "manifest", "manifestData"]
    for source in sources where isConsumerPath(source.relativePath) {
        for node in source.nodes {
            let variableTypes = lexicalVariableTypes(
                at: node,
                in: source,
                functionReturns: receiverFunctionReturnTypes
            )
            if let declaration = node.as(ImportDeclSyntax.self),
               declaration.path.trimmedDescription == "RuneScribeCoreModule",
               source.relativePath != bootstrapPath
            {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "direct-core-import",
                    path: source.relativePath,
                    line: source.line(of: declaration),
                    detail: "consumer imports the Core implementation module directly"
                ))
            }

            if let type = node.as(IdentifierTypeSyntax.self), prohibitedCoreTypes.contains(type.name.text) {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "direct-core-type",
                    path: source.relativePath,
                    line: source.line(of: type),
                    detail: "consumer refers to a Core implementation type or alias"
                ))
            }
            if let type = node.as(MemberTypeSyntax.self), prohibitedCoreTypes.contains(type.name.text) {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "direct-core-type",
                    path: source.relativePath,
                    line: source.line(of: type),
                    detail: "consumer refers to a module-qualified Core implementation type or alias"
                ))
            }
            if let reference = node.as(DeclReferenceExprSyntax.self),
               prohibitedCoreTypes.contains(reference.baseName.text)
            {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "direct-core-type-reference",
                    path: source.relativePath,
                    line: source.line(of: reference),
                    detail: "consumer references a Core implementation type or alias as an expression"
                ))
            }

            if let call = node.as(FunctionCallExprSyntax.self), let target = callTarget(call) {
                if prohibitedCoreTypes.contains(target.member) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-construction",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "consumer constructs a Core implementation type or alias"
                    ))
                }
                let labels = call.arguments.map { $0.label?.text ?? "_" }
                var constructorOwnerNames: Set<String> = [target.member]
                if target.member == "init", target.base == nil {
                    constructorOwnerNames.formUnion(contextualTypeNames(containing: Syntax(call)))
                }
                let constructorOwners = expandedAliasTargets(
                    constructorOwnerNames,
                    aliases: aliases
                )
                if coreInitializers.contains(where: {
                    !constructorOwners.isDisjoint(with: expandedAliasTargets([$0.owner], aliases: aliases)) &&
                        initializerLabelsMatch(callLabels: labels, initializer: $0)
                }) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-initializer",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "consumer invokes a public Core initializer operation on \(target.member)"
                    ))
                }
            }

            if let call = node.as(FunctionCallExprSyntax.self) {
                var callableTypes = expandedAliasTargets(
                    inferredExpressionTypes(
                        call.calledExpression,
                        variables: variableTypes,
                        functionReturns: receiverFunctionReturnTypes
                    ),
                    aliases: aliases
                )
                if callableTypes.isEmpty,
                   let member = call.calledExpression.as(MemberAccessExprSyntax.self)
                {
                    let receiverOwners = expandedAliasTargets(
                        inferredExpressionTypes(
                            member.base,
                            variables: variableTypes,
                            functionReturns: receiverFunctionReturnTypes
                        ),
                        aliases: aliases
                    )
                    for owner in receiverOwners {
                        callableTypes.formUnion(expandedAliasTargets(
                            memberValueTypes[MemberIdentity(
                                owner: owner,
                                name: member.declName.baseName.text
                            ), default: []],
                            aliases: aliases
                        ))
                    }
                }
                if coreOperations.contains(where: { operation in
                    guard operation.name == "callAsFunction",
                          operation.kind == .instance,
                          let owner = operation.owner
                    else {
                        return false
                    }
                    let owners = expandedAliasTargets(
                        [owner],
                        aliases: aliases
                    )
                    return !callableTypes.isDisjoint(with: owners)
                }) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-call-as-function",
                        path: source.relativePath,
                        line: source.line(of: call),
                        detail: "consumer invokes a public Core callAsFunction extension operation"
                    ))
                }
            }

            if let subscriptCall = node.as(SubscriptCallExprSyntax.self) {
                let callLabels = subscriptCall.arguments.map { $0.label?.text ?? "_" }
                let receiverTypes = inferredExpressionTypes(
                    subscriptCall.calledExpression,
                    variables: variableTypes,
                    functionReturns: receiverFunctionReturnTypes
                )
                let expandedReceiverTypes = expandedAliasTargets(receiverTypes, aliases: aliases)
                for operation in coreSubscripts where callableLabelsMatch(
                    callLabels: callLabels,
                    allLabels: operation.allLabels,
                    requiredLabels: operation.requiredLabels,
                    variadicLabels: operation.variadicLabels
                ) {
                    let operationOwners = expandedAliasTargets([operation.owner], aliases: aliases)
                    let isExtensionOwner = operationOwners.isDisjoint(with: publicCoreTypes)
                    if !expandedReceiverTypes.isDisjoint(with: operationOwners) ||
                        (receiverTypes.isEmpty && isExtensionOwner)
                    {
                        findings.insert(Finding(
                            ruleID: "FG-006",
                            category: "direct-core-subscript",
                            path: source.relativePath,
                            line: source.line(of: subscriptCall),
                            detail: "consumer uses a public Core subscript on \(operation.owner)"
                        ))
                    }
                }
            }

            if let keyPath = node.as(KeyPathExprSyntax.self) {
                let rootTypes = keyPath.root.map {
                    expandedAliasTargets(typeNames(in: $0), aliases: aliases)
                } ?? []
                let propertyNames = Set(keyPath.components.compactMap { component in
                    component.component.as(KeyPathPropertyComponentSyntax.self)?
                        .declName.baseName.text
                })
                if coreOperations.contains(where: { operation in
                    guard operation.kind == .instance,
                          propertyNames.contains(operation.name),
                          let owner = operation.owner
                    else {
                        return false
                    }
                    let expandedOwners = expandedAliasTargets(
                        [owner],
                        aliases: aliases
                    )
                    let isExtensionOwner = expandedOwners.isDisjoint(with: publicCoreTypes)
                    return !rootTypes.isDisjoint(with: expandedOwners) ||
                        (rootTypes.isEmpty && isExtensionOwner)
                }) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-key-path",
                        path: source.relativePath,
                        line: source.line(of: keyPath),
                        detail: "consumer retains a key path to a public Core extension property"
                    ))
                }
                let subscriptLabels = keyPath.components.compactMap { component -> [String]? in
                    component.component.as(KeyPathSubscriptComponentSyntax.self)?.arguments.map {
                        $0.label?.text ?? "_"
                    }
                }
                if subscriptLabels.contains(where: { labels in
                    coreSubscripts.contains { operation in
                        callableLabelsMatch(
                            callLabels: labels,
                            allLabels: operation.allLabels,
                            requiredLabels: operation.requiredLabels,
                            variadicLabels: operation.variadicLabels
                        ) && (rootTypes.isEmpty || !rootTypes.isDisjoint(with: expandedAliasTargets(
                            [operation.owner],
                            aliases: aliases
                        )))
                    }
                }) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-key-path-subscript",
                        path: source.relativePath,
                        line: source.line(of: keyPath),
                        detail: "consumer retains a key path to a public Core extension subscript"
                    ))
                }
            }

            guard let member = node.as(MemberAccessExprSyntax.self) else { continue }
            let memberName = member.declName.baseName.text
            let baseName = directExpressionName(member.base)
            let receiverTypes = inferredExpressionTypes(
                member.base,
                variables: variableTypes,
                functionReturns: receiverFunctionReturnTypes
            )
            let expandedReceiverTypes = expandedAliasTargets(receiverTypes, aliases: aliases)
            let contextualBaseNames = member.base == nil
                ? contextualTypeNames(containing: Syntax(member))
                : []
            let expandedBaseNames = baseName.map {
                expandedAliasTargets([$0], aliases: aliases)
            } ?? expandedAliasTargets(contextualBaseNames, aliases: aliases)
            if memberName == "init", let baseName {
                let owners = expandedAliasTargets([baseName], aliases: aliases)
                let labels = member.declName.argumentNames?.arguments.map {
                    $0.name.text
                } ?? []
                if coreInitializers.contains(where: {
                    !owners.isDisjoint(with: expandedAliasTargets([$0.owner], aliases: aliases)) &&
                        initializerLabelsMatch(callLabels: labels, initializer: $0)
                }) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-initializer-reference",
                        path: source.relativePath,
                        line: source.line(of: member),
                        detail: "consumer retains a reference to a public Core initializer operation"
                    ))
                }
            }
            if baseName == "RuneScribeCoreModuleBootstrap" {
                if source.relativePath != bootstrapPath || !bootstrapMembers.contains(memberName) {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-bootstrap-operation",
                        path: source.relativePath,
                        line: source.line(of: member),
                        detail: "Core bootstrap operation is outside the exact composition allowlist"
                    ))
                }
                continue
            }

            for operation in coreOperations where operation.name == memberName {
                let matches: Bool
                switch operation.kind {
                case .topLevel:
                    matches = true
                case .static:
                    matches = operation.owner.map(expandedBaseNames.contains) == true
                case .instance:
                    guard let operationOwner = operation.owner else {
                        matches = false
                        break
                    }
                    let operationOwners = expandedAliasTargets([operationOwner], aliases: aliases)
                    let isExtensionOwner = operationOwners.isDisjoint(with: publicCoreTypes)
                    matches = !expandedReceiverTypes.isDisjoint(with: operationOwners) ||
                        (member.base == nil && enclosingNominalName(node).map {
                            operationOwners.contains($0)
                        } == true) ||
                        (receiverTypes.isEmpty && isExtensionOwner)
                }
                if matches {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "direct-core-operation",
                        path: source.relativePath,
                        line: source.line(of: member),
                        detail: "consumer invokes or references public Core \(operation.kind.rawValue) operation \(operation.name)"
                    ))
                }
            }
        }

        let topLevelOperations = coreOperations.filter { $0.kind == .topLevel }
        for node in source.nodes {
            if let reference = node.as(DeclReferenceExprSyntax.self),
               topLevelOperations.contains(where: { $0.name == reference.baseName.text })
            {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "direct-core-operation",
                    path: source.relativePath,
                    line: source.line(of: reference),
                    detail: "consumer references public Core top-level operation \(reference.baseName.text)"
                ))
            }

            let operatorName: String?
            if let binary = node.as(BinaryOperatorExprSyntax.self) {
                operatorName = binary.operator.text
            } else if let prefix = node.as(PrefixOperatorExprSyntax.self) {
                operatorName = prefix.operator.text
            } else if let postfix = node.as(PostfixOperatorExprSyntax.self) {
                operatorName = postfix.operator.text
            } else {
                operatorName = nil
            }
            if let operatorName,
               coreOperations.contains(where: { $0.name == operatorName })
            {
                findings.insert(Finding(
                    ruleID: "FG-006",
                    category: "direct-core-operator",
                    path: source.relativePath,
                    line: source.line(of: node),
                    detail: "consumer uses operator \(operatorName) implemented by a public Core operation"
                ))
            }
        }
    }

    let runtimeClientTypes: Set<String> = [
        "RuntimeCommandClient", "RuntimeQueryClient", "RuntimeStateClient",
    ]
    let typedClientOperations: [String: (
        dispatcherMethod: String,
        expectedKind: String?
    )] = [
        "RuntimeCommandClient.send": ("dispatch", "command"),
        "RuntimeQueryClient.fetch": ("dispatch", "query"),
        "RuntimeIngressClient.submit": ("dispatch", "ingress"),
        "RuntimeStateClient.subscribe": ("openStateRelay", nil),
        "RuntimeStateClient.subscribeToMenuCommands": ("openMenuCommandRelay", nil),
    ]
    let typedClientSignatures: [String: [String]] = [
        "RuntimeCommandClient.send": [
            "_:request", "to:key", "requestSchemaVersion:requestSchemaVersion",
            "responseSchemaVersion:responseSchemaVersion", "idempotencyKey:idempotencyKey",
        ],
        "RuntimeQueryClient.fetch": [
            "_:request", "from:key", "requestSchemaVersion:requestSchemaVersion",
            "responseSchemaVersion:responseSchemaVersion",
        ],
        "RuntimeIngressClient.submit": [
            "_:request", "to:key", "requestSchemaVersion:requestSchemaVersion",
            "responseSchemaVersion:responseSchemaVersion", "idempotencyKey:idempotencyKey",
        ],
        "RuntimeStateClient.subscribe": [
            "to:descriptor", "subscriptionSchemaVersion:subscriptionSchemaVersion",
            "stateSchemaVersion:stateSchemaVersion",
        ],
        "RuntimeStateClient.subscribeToMenuCommands": ["_:descriptor"],
    ]
    let typedClientCallLabels: [String: [String]] = [
        "RuntimeCommandClient.send": [
            "lease", "key", "expectedKind", "request", "requestSchemaVersion",
            "responseSchemaVersion", "idempotencyKey",
        ],
        "RuntimeQueryClient.fetch": [
            "lease", "key", "expectedKind", "request", "requestSchemaVersion",
            "responseSchemaVersion",
        ],
        "RuntimeIngressClient.submit": [
            "lease", "key", "expectedKind", "request", "requestSchemaVersion",
            "responseSchemaVersion", "idempotencyKey",
        ],
        "RuntimeStateClient.subscribe": [
            "lease", "descriptor", "subscriptionSchemaVersion", "stateSchemaVersion",
        ],
        "RuntimeStateClient.subscribeToMenuCommands": ["lease", "descriptor"],
    ]
    let typedClientParameterTypes: [String: [String]] = [
        "RuntimeCommandClient.send": [
            "Request", "RuntimeEndpointKey<Request,Response>", "RuntimeSchemaVersion?",
            "RuntimeSchemaVersion?", "RuntimeIdempotencyKey?",
        ],
        "RuntimeQueryClient.fetch": [
            "Request", "RuntimeEndpointKey<Request,Response>", "RuntimeSchemaVersion?",
            "RuntimeSchemaVersion?",
        ],
        "RuntimeIngressClient.submit": [
            "Request", "RuntimeEndpointKey<Request,Response>", "RuntimeSchemaVersion?",
            "RuntimeSchemaVersion?", "RuntimeIdempotencyKey?",
        ],
        "RuntimeStateClient.subscribe": [
            "RuntimeStateEndpointDescriptor<State>", "RuntimeSchemaVersion?",
            "RuntimeSchemaVersion?",
        ],
        "RuntimeStateClient.subscribeToMenuCommands": [
            "RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO>",
        ],
    ]
    let typedClientGenericClauses: [String: String] = [
        "RuntimeCommandClient.send": "<Request:Sendable,Response:Sendable>",
        "RuntimeQueryClient.fetch": "<Request:Sendable,Response:Sendable>",
        "RuntimeIngressClient.submit": "<Request:Sendable,Response:Sendable>",
        "RuntimeStateClient.subscribe": "<State:Sendable>",
        "RuntimeStateClient.subscribeToMenuCommands": "",
    ]
    let typedClientReturnTypes: [String: String] = [
        "RuntimeCommandClient.send": "Response",
        "RuntimeQueryClient.fetch": "Response",
        "RuntimeIngressClient.submit": "Response",
        "RuntimeStateClient.subscribe": "RuntimeStateStream<State>",
        "RuntimeStateClient.subscribeToMenuCommands":
            "RuntimeStateStream<ApplicationMenuCommandDTO>",
    ]
    let dispatcherSourcePath =
        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
    let applicationEndpointSourcePath =
        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
    let runtimeEndpointContractsPath =
        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeOperationContracts.swift"
    let runtimePolicyVocabularyPath =
        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimePolicyVocabulary.swift"
    let canonicalDispatcherFields = [
        "RuntimeCommandClient", "RuntimeQueryClient", "RuntimeIngressClient",
        "RuntimeStateClient",
    ].reduce(into: [String: [String: Set<String>]]()) { result, owner in
        result[owner] = canonicalStoredFields(
            owner: owner,
            path: dispatcherSourcePath,
            in: sources
        )
    }
    let canonicalApplicationClientFields = canonicalStoredFields(
        owner: "RuntimeApplicationClient",
        path: applicationEndpointSourcePath,
        in: sources
    )
    let runtimeFields = declaredFieldsByOwner["RuneScribeRuntime", default: [:]]
    var typedOperationCounts: [String: Int] = [:]
    var applicationOperationCounts: [String: Int] = [:]
    var applicationFactoryCount = 0
    let applicationClientContracts: [String: (
        field: String,
        member: String,
        parameterIdentity: String?,
        payloadName: String?,
        endpointLabel: String,
        resultUse: RuntimeResultUse
    )] = [
        "encode": ("command", "send", "_:value", "value", "to", .value),
        "decode": ("command", "send", "_:value", "value", "to", .value),
        "createCipher": ("command", "send", "_:value", "value", "to", .value),
        "renameCipher": ("command", "send", "_:value", "value", "to", .value),
        "deleteCipher": ("command", "send", "id:id", "id", "to", .discarded),
        "setActiveCipher": ("command", "send", "_:value", "value", "to", .discarded),
        "assignContact": ("command", "send", "_:value", "value", "to", .discarded),
        "createContact": ("command", "send", "_:value", "value", "to", .value),
        "updateContact": ("command", "send", "_:value", "value", "to", .value),
        "deleteContacts": ("command", "send", "ids:ids", "ids", "to", .discarded),
        "deleteAllImportedContacts": ("command", "send", nil, nil, "to", .discarded),
        "importContacts": ("command", "send", "_:value", "value", "to", .value),
        "requestSystemContacts": ("query", "fetch", nil, nil, "from", .value),
        "prepareCipherShare": ("command", "send", "_:value", "value", "to", .value),
        "prepareMessageShare": ("command", "send", "_:value", "value", "to", .value),
        "completeShareArtifact": ("command", "send", "_:value", "value", "to", .value),
        "releaseShareArtifact": ("command", "send", "id:id", "id", "to", .discarded),
        "importFile": ("command", "send", "_:value", "value", "to", .value),
        "importURL": ("command", "send", "_:value", "value", "to", .value),
        "confirmImport": ("command", "send", "_:value", "value", "to", .value),
        "cancelImport": ("command", "send", "id:id", "id", "to", .discarded),
        "dismissReceivedMessage": ("command", "send", "id:id", "id", "to", .discarded),
        "lock": ("command", "send", nil, nil, "to", .discarded),
        "verifyPIN": ("command", "send", "_:value", "value", "to", .value),
        "unlock": ("command", "send", "_:value", "value", "to", .value),
        "setPIN": ("command", "send", "_:value", "value", "to", .discarded),
        "changePIN": ("command", "send", "_:value", "value", "to", .discarded),
        "disablePIN": ("command", "send", "_:value", "value", "to", .discarded),
    ]

    for source in sources {
        for node in source.nodes {
            guard let function = node.as(FunctionDeclSyntax.self),
                  let owner = enclosingOperationOwnerName(node)
            else {
                continue
            }
            let calls = directCalls(in: function)
            let localBindings = localBindingNames(in: function)
            let typedClientOperationKey = "\(owner).\(function.name.text)"
            if let expected = typedClientOperations[typedClientOperationKey],
               isCanonicalOwnerMember(
                node,
                owner: owner,
                source: source,
                path: dispatcherSourcePath
               )
            {
                typedOperationCounts[typedClientOperationKey, default: 0] += 1
                let fields = canonicalDispatcherFields[owner, default: [:]]
                let parameterNames = Set(functionParameters(function).map(\.name))
                let parameterIdentities = functionParameterIdentities(function)
                let parameterTypes = functionParameterTypeTexts(function)
                let expectedIdentities = typedClientSignatures[
                    typedClientOperationKey,
                    default: []
                ]
                let expectedTypes = typedClientParameterTypes[
                    typedClientOperationKey,
                    default: []
                ]
                let signatureIsCanonical =
                    parameterIdentities.starts(with: expectedIdentities) &&
                    parameterTypes.starts(with: expectedTypes) &&
                    (function.genericParameterClause.map(compactSyntaxText) ?? "") ==
                        typedClientGenericClauses[typedClientOperationKey, default: ""] &&
                    function.signature.returnClause.map {
                        compactSyntaxText($0.type)
                    } == typedClientReturnTypes[typedClientOperationKey]
                let terminal = canonicalRuntimeTerminalCall(in: function)
                let canonicalCall = terminal.flatMap { terminal -> FunctionCallExprSyntax? in
                    let call = terminal.call
                    guard terminal.resultUse == .value,
                          terminal.sawTry, terminal.sawAwait,
                          let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                          member.declName.baseName.text == expected.dispatcherMethod,
                          declaredFieldName(
                            referencedBy: member.base,
                            fieldTypes: fields,
                            acceptedTypes: ["RuntimeOperationDispatcher"],
                            localBindings: localBindings
                          ) == "dispatcher"
                    else {
                        return nil
                    }
                    let exactLease: (ExprSyntax) -> Bool = { expression in
                        declaredFieldName(
                            referencedBy: expression,
                            fieldTypes: fields,
                            acceptedTypes: ["RuntimeClientLease"],
                            localBindings: localBindings
                        ) == "lease" && !parameterNames.contains("lease")
                    }
                    let argumentsAreCanonical: Bool
                    switch typedClientOperationKey {
                    case "RuntimeCommandClient.send", "RuntimeIngressClient.submit":
                        guard let expectedKind = expected.expectedKind else { return nil }
                        argumentsAreCanonical = exactCallArguments(
                            call,
                            labels: typedClientCallLabels[typedClientOperationKey, default: []],
                            predicates: [
                                exactLease,
                                { exactIdentifier($0, named: "key") },
                                { exactUnqualifiedMember($0, named: expectedKind) },
                                { exactIdentifier($0, named: "request") },
                                { exactNilCoalescing(
                                    $0,
                                    left: "requestSchemaVersion",
                                    right: ["key", "descriptor", "requestSchemaVersion"]
                                ) },
                                { exactNilCoalescing(
                                    $0,
                                    left: "responseSchemaVersion",
                                    right: ["key", "descriptor", "responseSchemaVersion"]
                                ) },
                                { exactIdentifier($0, named: "idempotencyKey") },
                            ]
                        )
                    case "RuntimeQueryClient.fetch":
                        argumentsAreCanonical = exactCallArguments(
                            call,
                            labels: typedClientCallLabels[typedClientOperationKey, default: []],
                            predicates: [
                                exactLease,
                                { exactIdentifier($0, named: "key") },
                                { exactUnqualifiedMember($0, named: "query") },
                                { exactIdentifier($0, named: "request") },
                                { exactNilCoalescing(
                                    $0,
                                    left: "requestSchemaVersion",
                                    right: ["key", "descriptor", "requestSchemaVersion"]
                                ) },
                                { exactNilCoalescing(
                                    $0,
                                    left: "responseSchemaVersion",
                                    right: ["key", "descriptor", "responseSchemaVersion"]
                                ) },
                            ]
                        )
                    case "RuntimeStateClient.subscribe":
                        argumentsAreCanonical = exactCallArguments(
                            call,
                            labels: typedClientCallLabels[typedClientOperationKey, default: []],
                            predicates: [
                                exactLease,
                                { exactIdentifier($0, named: "descriptor") },
                                { exactNilCoalescing(
                                    $0,
                                    left: "subscriptionSchemaVersion",
                                    right: ["descriptor", "subscriptionSchemaVersion"]
                                ) },
                                { exactNilCoalescing(
                                    $0,
                                    left: "stateSchemaVersion",
                                    right: ["descriptor", "stateSchemaVersion"]
                                ) },
                            ]
                        )
                    case "RuntimeStateClient.subscribeToMenuCommands":
                        argumentsAreCanonical = exactCallArguments(
                            call,
                            labels: typedClientCallLabels[typedClientOperationKey, default: []],
                            predicates: [
                                exactLease,
                                { exactIdentifier($0, named: "descriptor") },
                            ]
                        )
                    default:
                        argumentsAreCanonical = false
                    }
                    return argumentsAreCanonical ? call : nil
                }
                if !signatureIsCanonical || canonicalCall == nil
                {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "missing-runtime-dispatch-path",
                        path: source.relativePath,
                        line: source.line(of: function),
                        detail: "\(typedClientOperationKey) does not send every overload path through its declared runtime dispatcher"
                    ))
                }
            }
            if owner == "RuntimeApplicationClient",
               isCanonicalOwnerMember(
                node,
                owner: owner,
                source: source,
                path: applicationEndpointSourcePath
               ),
               memberIsExternallyVisible(function.modifiers, syntax: node)
            {
                applicationOperationCounts[function.name.text, default: 0] += 1
                let contract = applicationClientContracts[function.name.text]
                let terminal = canonicalRuntimeTerminalCall(in: function)
                let canonicalCall = terminal.flatMap { terminal -> FunctionCallExprSyntax? in
                    guard let contract,
                          terminal.resultUse == contract.resultUse,
                          terminal.sawTry, terminal.sawAwait,
                          functionParameterIdentities(function).starts(
                            with: contract.parameterIdentity.map { [$0] } ?? []
                          ),
                          let member = terminal.call.calledExpression.as(
                            MemberAccessExprSyntax.self
                          ),
                          member.declName.baseName.text == contract.member,
                          declaredFieldName(
                            referencedBy: member.base,
                            fieldTypes: canonicalApplicationClientFields,
                            acceptedTypes: runtimeClientTypes,
                            localBindings: localBindings
                          ) == contract.field,
                          !catalogSymbolIsShadowed(
                            at: Syntax(terminal.call),
                            in: function,
                            source: source
                          )
                    else {
                        return nil
                    }
                    let payloadPredicate: (ExprSyntax) -> Bool
                    if let payloadName = contract.payloadName {
                        payloadPredicate = { exactIdentifier($0, named: payloadName) }
                    } else {
                        payloadPredicate = { expression in
                            !symbolIsShadowed(
                                named: "RuntimeEmptyPayload",
                                canonicalPath: applicationEndpointSourcePath,
                                at: Syntax(expression),
                                in: function,
                                source: source
                            ) && exactUnqualifiedZeroArgumentCall(
                                expression,
                                named: "RuntimeEmptyPayload"
                            )
                        }
                    }
                    let argumentsAreCanonical = exactCallArguments(
                        terminal.call,
                        labels: ["_", contract.endpointLabel],
                        predicates: [
                            payloadPredicate,
                            { expression in
                                exactCatalogMemberExpression(
                                    expression,
                                    catalogName: "RuntimeApplicationEndpointCatalog",
                                    memberName: function.name.text
                                )
                            },
                        ]
                    )
                    return argumentsAreCanonical ? terminal.call : nil
                }
                if contract == nil || canonicalCall == nil
                {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "missing-runtime-dispatch-path",
                        path: source.relativePath,
                        line: source.line(of: function),
                        detail: "RuntimeApplicationClient.\(function.name.text) does not end every path in its canonical typed runtime client and endpoint"
                    ))
                }
            }

            if owner == "ModuleContext", function.name.text == "applicationClient",
               isCanonicalOwnerMember(
                node,
                owner: owner,
                source: source,
                path: applicationEndpointSourcePath
               )
            {
                applicationFactoryCount += 1
                let statements = Array(function.body?.statements ?? CodeBlockItemListSyntax([]))
                func exactLetBinding(
                    at index: Int,
                    named name: String
                ) -> PatternBindingSyntax? {
                    guard statements.indices.contains(index),
                          let declaration = statements[index].item.as(VariableDeclSyntax.self),
                          declaration.bindingSpecifier.text == "let",
                          declaration.bindings.count == 1,
                          let binding = declaration.bindings.first,
                          patternNames(binding.pattern) == [name],
                          binding.initializer != nil
                    else {
                        return nil
                    }
                    return binding
                }
                func exactSelfClientBinding(
                    _ binding: PatternBindingSyntax?,
                    method: String
                ) -> Bool {
                    guard let expression = binding?.initializer?.value,
                          let transparent = transparentRuntimeCall(in: expression),
                          transparent.sawTry, transparent.sawAwait,
                          let target = transparent.call.calledExpression.as(MemberAccessExprSyntax.self),
                          target.declName.baseName.text == method,
                          target.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
                    else {
                        return false
                    }
                    return exactCallArguments(
                        transparent.call,
                        labels: ["to"],
                        predicates: [{ exactIdentifier($0, named: "destination") }]
                    )
                }
                func exactStateBinding(
                    _ binding: PatternBindingSyntax?,
                    method: String,
                    label: String?,
                    endpoint: String
                ) -> Bool {
                    guard let expression = binding?.initializer?.value,
                          let transparent = transparentRuntimeCall(in: expression),
                          transparent.sawTry, transparent.sawAwait,
                          let target = transparent.call.calledExpression.as(MemberAccessExprSyntax.self),
                          target.declName.baseName.text == method,
                          target.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "state"
                    else {
                        return false
                    }
                    return !catalogSymbolIsShadowed(
                        at: Syntax(transparent.call),
                        in: function,
                        source: source
                    ) && exactCallArguments(
                        transparent.call,
                        labels: [label ?? "_"],
                        predicates: [{ expression in
                            exactCatalogMemberExpression(
                                expression,
                                catalogName: "RuntimeApplicationEndpointCatalog",
                                memberName: endpoint
                            )
                        }]
                    )
                }

                let destination = exactLetBinding(at: 0, named: "destination")
                let command = exactLetBinding(at: 1, named: "command")
                let query = exactLetBinding(at: 2, named: "query")
                let state = exactLetBinding(at: 3, named: "state")
                let applicationState = exactLetBinding(at: 4, named: "applicationState")
                let menuCommands = exactLetBinding(at: 5, named: "menuCommands")
                let destinationIsCanonical: Bool = {
                    guard let destination,
                          destination.typeAnnotation.map({
                            compactSyntaxText($0.type) == "RuntimeEndpointDestination"
                          }) == true,
                          let expression = destination.initializer?.value,
                          let call = expression.as(FunctionCallExprSyntax.self),
                          let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                          member.base == nil, member.declName.baseName.text == "role",
                          !symbolIsShadowed(
                            named: "RuntimeEndpointDestination",
                            canonicalPath: runtimeEndpointContractsPath,
                            at: Syntax(destination),
                            in: function,
                            source: source
                          ),
                          !symbolIsShadowed(
                            named: "RuneScribeRoles",
                            canonicalPath: runtimePolicyVocabularyPath,
                            at: Syntax(destination),
                            in: function,
                            source: source
                          )
                    else {
                        return false
                    }
                    return exactCallArguments(
                        call,
                        labels: ["_"],
                        predicates: [{ exactMemberChain(
                            $0,
                            names: ["RuneScribeRoles", "core"]
                        ) }]
                    )
                }()

                let constructorIsCanonical: Bool = {
                    guard statements.indices.contains(6),
                          let returnStatement = statements[6].item.as(ReturnStmtSyntax.self),
                          let expression = returnStatement.expression,
                          let call = canonicalDirectCall(in: expression),
                          call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ==
                            "RuntimeApplicationClient",
                          !symbolIsShadowed(
                            named: "RuntimeApplicationClient",
                            canonicalPath: applicationEndpointSourcePath,
                            at: Syntax(call),
                            in: function,
                            source: source
                          ),
                          exactCallArguments(
                            call,
                            labels: [
                                "command", "query", "applicationStateEnvelopes",
                                "menuCommandEnvelopes",
                            ],
                            predicates: [
                                { exactIdentifier($0, named: "command") },
                                { exactIdentifier($0, named: "query") },
                                { exactIdentifier($0, named: "applicationState") },
                                { exactIdentifier($0, named: "menuCommands") },
                            ]
                          )
                    else {
                        return false
                    }
                    return true
                }()
                let applicationFactoryIsCanonical = functionParameters(function).isEmpty &&
                    function.genericParameterClause == nil &&
                    function.signature.returnClause.map {
                        compactSyntaxText($0.type)
                    } == "RuntimeApplicationClient" &&
                    statements.count == 7 && destinationIsCanonical &&
                    exactSelfClientBinding(command, method: "commandClient") &&
                    exactSelfClientBinding(query, method: "queryClient") &&
                    exactSelfClientBinding(state, method: "stateClient") &&
                    exactStateBinding(
                        applicationState,
                        method: "subscribe",
                        label: "to",
                        endpoint: "applicationState"
                    ) && exactStateBinding(
                        menuCommands,
                        method: "subscribeToMenuCommands",
                        label: nil,
                        endpoint: "menuCommands"
                    ) && constructorIsCanonical
                if !applicationFactoryIsCanonical {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "missing-runtime-dispatch-path",
                        path: source.relativePath,
                        line: source.line(of: function),
                        detail: "applicationClient factory does not construct its result from canonical runtime command, query, and state bindings"
                    ))
                }
            }

            if owner == "RuneScribeRuntime", function.name.text == "submit" {
                let terminalCalls = terminalOutermostCalls(in: function)
                let reachesIngress = terminalCalls.count == 1 && terminalCalls.contains { call in
                    guard let target = callTarget(call), target.member == "submit" else { return false }
                    return declaredFieldName(
                        referencedBy: target.base,
                        fieldTypes: runtimeFields,
                        acceptedTypes: ["RuntimeHostIngressRail"],
                        localBindings: localBindings
                    ) == "hostIngress"
                }
                if function.body?.statements.count != 1 ||
                    containsEarlyExitOrConditionalFlow(
                        in: function,
                        allowingTerminalReturn: true
                    ) || !reachesIngress
                {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "missing-runtime-dispatch-path",
                        path: source.relativePath,
                        line: source.line(of: function),
                        detail: "Runtime.submit does not send every path directly into its declared RuntimeHostIngressRail"
                    ))
                }
            }

            if owner == "RuneScribeRuntime", function.name.text == "start" {
                let activateCalls = calls.filter { call in
                    guard let target = callTarget(call), target.member == "activate",
                          !hasConditionalAncestor(Syntax(call), before: Syntax(function))
                    else {
                        return false
                    }
                    return declaredFieldName(
                        referencedBy: target.base,
                        fieldTypes: runtimeFields,
                        acceptedTypes: ["RuntimeHostIngressRail"],
                        localBindings: localBindings
                    ) == "hostIngress"
                }
                let activationReachesDispatcher = activateCalls.count == 1 && activateCalls.allSatisfy {
                    activate in
                    let closure = activate.trailingClosure ?? activate.arguments.compactMap {
                        $0.expression.as(ClosureExprSyntax.self)
                    }.first
                    guard let closure, closure.statements.count == 1 else { return false }
                    let terminalCalls = terminalOutermostCalls(in: closure)
                    return terminalCalls.count == 1 && terminalCalls.contains { nested in
                        guard let target = callTarget(nested),
                              target.member == "dispatchHostIngress",
                              !hasConditionalAncestor(Syntax(nested), before: Syntax(closure))
                        else {
                            return false
                        }
                        return declaredFieldName(
                            referencedBy: target.base,
                            fieldTypes: runtimeFields,
                            acceptedTypes: ["RuntimeOperationDispatcher"],
                            localBindings: localBindings
                        ) == "dispatcher"
                    }
                }
                if !activationReachesDispatcher {
                    findings.insert(Finding(
                        ruleID: "FG-006",
                        category: "missing-runtime-dispatch-path",
                        path: source.relativePath,
                        line: source.line(of: function),
                        detail: "Runtime.start does not uniquely bind its declared ingress rail to its declared dispatcher"
                    ))
                }
            }
        }
    }

    for key in typedClientOperations.keys.sorted()
    where typedOperationCounts[key, default: 0] < 1 {
        findings.insert(Finding(
            ruleID: "FG-006",
            category: "missing-runtime-dispatch-path",
            path: dispatcherSourcePath,
            line: 1,
            detail: "canonical typed runtime operation \(key) is missing"
        ))
    }
    for name in applicationClientContracts.keys.sorted()
    where applicationOperationCounts[name, default: 0] < 1 {
        findings.insert(Finding(
            ruleID: "FG-006",
            category: "missing-runtime-dispatch-path",
            path: applicationEndpointSourcePath,
            line: 1,
            detail: "canonical RuntimeApplicationClient.\(name) operation is missing"
        ))
    }
    if applicationFactoryCount != 1 {
        findings.insert(Finding(
            ruleID: "FG-006",
            category: "missing-runtime-dispatch-path",
            path: applicationEndpointSourcePath,
            line: 1,
            detail: "canonical ModuleContext.applicationClient factory is missing or overloaded"
        ))
    }

    findings.formUnion(p04Findings(in: sources))

    return findings
}

private func run(options: Options) throws -> (ScannerOutput, Bool) {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: options.scanRoot.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        throw InvocationError.message("scan root is not a directory: \(options.scanRoot.path)")
    }
    guard fileManager.fileExists(
        atPath: options.scanRoot.appendingPathComponent("Packages/RuneScribeArchitecture").path,
        isDirectory: &isDirectory
    ) else {
        throw InvocationError.message("scan root does not contain Packages/RuneScribeArchitecture")
    }

    var paths = try sourceFiles(beneath: options.scanRoot, fromOverlay: false)
    if let fixtureRoot = options.fixtureRoot {
        guard fileManager.fileExists(atPath: fixtureRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw InvocationError.message("fixture root is not a directory: \(fixtureRoot.path)")
        }
        for (relativePath, path) in try sourceFiles(beneath: fixtureRoot, fromOverlay: true) {
            paths[relativePath] = path
        }
    }

    var parsed: [ParsedSource] = []
    var errors: [String] = []
    for path in paths.values.sorted(by: { $0.relativePath < $1.relativePath }) {
        do {
            let source = try String(contentsOf: path.fileURL, encoding: .utf8)
            let parsedSource = ParsedSource(path: path, source: source)
            let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: parsedSource.tree)
            for diagnostic in diagnostics {
                let line = parsedSource.converter.location(for: diagnostic.position).line
                errors.append("\(path.relativePath):\(line): parse error: \(diagnostic.message)")
            }
            parsed.append(parsedSource)
        } catch {
            errors.append("\(path.relativePath): source read failed: \(error)")
        }
    }
    errors.sort()

    let findings = sortedFindings(scan(parsed))
    let output = ScannerOutput(
        schemaVersion: "1.0",
        findings: findings,
        errors: errors,
        metadata: Metadata(
            engine: "SwiftSyntax/SwiftParser",
            analysisScope: "conservative fail-closed source-tree symbol and type-flow analysis",
            scannedSourceCount: parsed.count,
            overlaySourceCount: parsed.filter(\.fromOverlay).count,
            parseFailureCount: errors.count
        )
    )
    return (output, !errors.isEmpty)
}

do {
    let options = try parseOptions()
    let (output, failed) = try run(options: options)
    try emit(output)
    if failed { exit(3) }
} catch InvocationError.help {
    print(usage)
    exit(0)
} catch {
    writeStandardError("\(error)\n\(usage)")
    exit(64)
}

import AVFoundation
import Foundation
import ImageIO
import Metal
import MetalKit
import RuneScribeContracts
@_spi(RuntimeResourceHost) import RuneScribeRuntimeCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum RuntimeThemeBackgroundParameterError: Error, Equatable, Sendable {
    case emptyDocument
    case documentTooLarge
    case malformedDocument
    case unsupportedRenderer(String)
    case invalidField(String)
}

public enum RuntimeThemeBackgroundInstallationError: Error, Equatable, Sendable {
    case presentationClosed
    case invalidStaticBaseData
    case invalidReduceMotionData
    case invalidHighContrastData
    case invalidBackgroundReference
    case preparedBackgroundOwnerMismatch
    case preparedBackgroundAlreadyCommitted
}

enum RuntimeThemeDecodedResourceError: Error, Equatable, Sendable {
    case emptyData
    case encodedDataTooLarge
    case encodedCacheCapacityExceeded
    case unsupportedImage
    case invalidPixelDimensions
    case unsupportedPixelDepth
    case decodedResourceTooLarge
}

public enum RuntimeThemeImageReferenceError: Error, Equatable, Sendable {
    case presentationClosed
    case codexIdentityMismatch
    case resourceIdentityMismatch
    case roleMismatch
    case mediaTypeMismatch
    case integrityMismatch
    case encodedContentMismatch
    case pixelDimensionsMismatch
    case unsupportedImage
    case cacheCapacityExceeded
}

public enum RuntimeThemeImageKind: String, Equatable, Hashable, Sendable {
    case raster
    case vectorPDF = "vector-pdf"
}

private struct RuntimeThemeDecodedResourceKey: Hashable, Sendable {
    let codexID: CodexID?
    let resourceID: ThemeResourceID?
    let contentRevision: UInt64?
    let sha256: ThemeSHA256Digest
}

struct RuntimeThemeDecodedImageHandle: Sendable {
    fileprivate enum Kind: Equatable, Sendable {
        case raster
        case pdf
    }

    fileprivate let key: RuntimeThemeDecodedResourceKey
    fileprivate let kind: Kind
    let encodedByteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let decodedByteCount: Int
}

@MainActor
final class RuntimeThemeDecodedResourceCache: ObservableObject {
    static let maximumEncodedImageByteCount = 8 * 1_024 * 1_024
    static let maximumTotalEncodedImageByteCount = 64 * 1_024 * 1_024
    static let maximumPixelDimension = 4_096
    static let maximumDecodedByteCount = 64 * 1_024 * 1_024
    static let maximumEntryCount = 512

    private struct EncodedEntry {
        let data: Data
        let kind: RuntimeThemeDecodedImageHandle.Kind
        let pixelWidth: Int
        let pixelHeight: Int
        let decodedByteCount: Int
        var accessOrder: UInt64
    }

    private struct DecodedEntry {
        let image: CGImage?
        let decodedByteCount: Int
        var accessOrder: UInt64
    }

    private let encodedByteLimit: Int
    private let decodedByteLimit: Int
    private let entryLimit: Int
    private var encodedEntries: [RuntimeThemeDecodedResourceKey: EncodedEntry] = [:]
    private var decodedEntries: [RuntimeThemeDecodedResourceKey: DecodedEntry] = [:]
    private var retainedKeyCounts: [RuntimeThemeDecodedResourceKey: Int] = [:]
    private var accessOrder: UInt64 = 0
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private(set) var totalEncodedByteCount = 0
    private(set) var totalDecodedByteCount = 0
    private(set) var decodedImageCreationCount = 0
    private(set) var decodedImageValidationCount = 0

    var entryCount: Int { decodedEntries.count }

    var encodedEntryCount: Int { encodedEntries.count }

    var retainedEntryCount: Int { retainedKeyCounts.count }

    var decodedImageCount: Int {
        decodedEntries.values.lazy.filter { $0.image != nil }.count
    }

    init(
        maximumTotalEncodedImageByteCount: Int = RuntimeThemeDecodedResourceCache
            .maximumTotalEncodedImageByteCount,
        maximumDecodedByteCount: Int = RuntimeThemeDecodedResourceCache
            .maximumDecodedByteCount,
        maximumEntryCount: Int = RuntimeThemeDecodedResourceCache.maximumEntryCount
    ) {
        precondition(maximumTotalEncodedImageByteCount > 0)
        precondition(maximumDecodedByteCount > 0)
        precondition(maximumEntryCount > 0)
        encodedByteLimit = maximumTotalEncodedImageByteCount
        decodedByteLimit = maximumDecodedByteCount
        entryLimit = maximumEntryCount

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.purge()
            }
        }
        source.activate()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    func prepareImage(
        data: Data
    ) throws -> RuntimeThemeDecodedImageHandle {
        let sha256 = ThemeSHA256Digest(
            rawValue: RuntimeIntegrityDigest.sha256Hex(data)
        )!
        return try prepareImage(
            data: data,
            key: RuntimeThemeDecodedResourceKey(
                codexID: nil,
                resourceID: nil,
                contentRevision: nil,
                sha256: sha256
            ),
            expectedMediaType: nil
        )
    }

    fileprivate func prepareImage(
        data: Data,
        codexID: CodexID,
        resourceID: ThemeResourceID,
        contentRevision: UInt64,
        sha256: ThemeSHA256Digest,
        expectedMediaType: ThemeResourceMediaType
    ) throws -> RuntimeThemeDecodedImageHandle {
        try prepareImage(
            data: data,
            key: RuntimeThemeDecodedResourceKey(
                codexID: codexID,
                resourceID: resourceID,
                contentRevision: contentRevision,
                sha256: sha256
            ),
            expectedMediaType: expectedMediaType
        )
    }

    private func prepareImage(
        data: Data,
        key: RuntimeThemeDecodedResourceKey,
        expectedMediaType: ThemeResourceMediaType?
    ) throws -> RuntimeThemeDecodedImageHandle {
        guard !data.isEmpty else {
            throw RuntimeThemeDecodedResourceError.emptyData
        }
        guard data.count <= Self.maximumEncodedImageByteCount else {
            throw RuntimeThemeDecodedResourceError.encodedDataTooLarge
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions
        ),
        CGImageSourceGetCount(source) == 1,
        let type = CGImageSourceGetType(source) as String?
        else {
            throw RuntimeThemeDecodedResourceError.unsupportedImage
        }

        let kind: RuntimeThemeDecodedImageHandle.Kind
        let dimensions: (width: Int, height: Int)
        if type == "com.adobe.pdf" {
            guard expectedMediaType == nil || expectedMediaType == .pdf else {
                throw RuntimeThemeDecodedResourceError.unsupportedImage
            }
            kind = .pdf
            dimensions = try Self.pdfPixelDimensions(data: data)
        } else {
            guard Self.supportedRasterTypes.contains(type),
                  Self.matchesRasterMediaType(type, expected: expectedMediaType)
            else {
                throw RuntimeThemeDecodedResourceError.unsupportedImage
            }
            kind = .raster
            dimensions = try Self.rasterPixelDimensions(source: source)
        }
        let decodedByteCount = try Self.validatedDecodedByteCount(
            width: dimensions.width,
            height: dimensions.height
        )
        let handle = RuntimeThemeDecodedImageHandle(
            key: key,
            kind: kind,
            encodedByteCount: data.count,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            decodedByteCount: decodedByteCount
        )
        if var existing = encodedEntries[key] {
            guard existing.data == data,
                  existing.kind == kind,
                  existing.pixelWidth == dimensions.width,
                  existing.pixelHeight == dimensions.height,
                  existing.decodedByteCount == decodedByteCount
            else {
                throw RuntimeThemeDecodedResourceError.unsupportedImage
            }
            existing.accessOrder = nextAccessOrder()
            encodedEntries[key] = existing
            return handle
        }

        try evictEncodedToFit(
            encodedByteCount: data.count,
            addingEntry: true
        )
        encodedEntries[key] = EncodedEntry(
            data: data,
            kind: kind,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            decodedByteCount: decodedByteCount,
            accessOrder: nextAccessOrder()
        )
        totalEncodedByteCount += data.count
        return handle
    }

    func image(for data: Data) -> Image? {
        guard let handle = try? prepareImage(data: data) else { return nil }
        return image(for: handle)
    }

    func image(for handle: RuntimeThemeDecodedImageHandle) -> Image? {
        guard var encodedEntry = encodedEntries[handle.key] else { return nil }
        encodedEntry.accessOrder = nextAccessOrder()
        encodedEntries[handle.key] = encodedEntry
        if var entry = decodedEntries[handle.key] {
            entry.accessOrder = nextAccessOrder()
            decodedEntries[handle.key] = entry
            return entry.image.map(Self.swiftUIImage)
        }
        guard handle.decodedByteCount <= decodedByteLimit else {
            return nil
        }

        evictDecodedToFit(decodedByteCount: handle.decodedByteCount)
        guard let decodedImage = decode(handle) else {
            return nil
        }
        let actualByteCount = max(
            handle.decodedByteCount,
            Self.byteCount(of: decodedImage) ?? Int.max
        )
        guard actualByteCount <= decodedByteLimit else {
            return nil
        }
        evictDecodedToFit(decodedByteCount: actualByteCount)
        decodedEntries[handle.key] = DecodedEntry(
            image: decodedImage,
            decodedByteCount: actualByteCount,
            accessOrder: nextAccessOrder()
        )
        totalDecodedByteCount += actualByteCount
        decodedImageCreationCount += 1
        return Self.swiftUIImage(decodedImage)
    }

    func validateImage(_ handle: RuntimeThemeDecodedImageHandle) -> Bool {
        guard encodedEntries[handle.key] != nil,
              handle.decodedByteCount <= decodedByteLimit
        else { return false }
        return autoreleasepool {
            guard let decodedImage = decode(handle),
                  let byteCount = Self.byteCount(of: decodedImage),
                  max(handle.decodedByteCount, byteCount) <= decodedByteLimit
            else { return false }
            decodedImageValidationCount += 1
            return true
        }
    }

    func retain(_ handles: [RuntimeThemeDecodedImageHandle]) {
        for key in Set(handles.map(\.key)) {
            guard encodedEntries[key] != nil else { continue }
            retainedKeyCounts[key, default: 0] += 1
        }
    }

    func release(_ handles: [RuntimeThemeDecodedImageHandle]) {
        for key in Set(handles.map(\.key)) {
            guard let count = retainedKeyCounts[key] else { continue }
            if count > 1 {
                retainedKeyCounts[key] = count - 1
            } else {
                retainedKeyCounts.removeValue(forKey: key)
                removeEncodedEntry(for: key)
            }
        }
    }

    func purge() {
        decodedEntries.removeAll(keepingCapacity: false)
        totalDecodedByteCount = 0
        for key in Array(encodedEntries.keys) where retainedKeyCounts[key] == nil {
            removeEncodedEntry(for: key)
        }
    }

    fileprivate func discardIfUnretained(
        _ handles: [RuntimeThemeDecodedImageHandle]
    ) {
        for key in Set(handles.map(\.key)) where retainedKeyCounts[key] == nil {
            removeEncodedEntry(for: key)
        }
    }

    static func validatedDecodedByteCount(
        width: Int,
        height: Int
    ) throws -> Int {
        guard width > 0,
              height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension
        else {
            throw RuntimeThemeDecodedResourceError.invalidPixelDimensions
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(
            by: 4
        )
        guard !pixelOverflow,
              !byteOverflow,
              byteCount <= maximumDecodedByteCount
        else {
            throw RuntimeThemeDecodedResourceError.decodedResourceTooLarge
        }
        return byteCount
    }

    private static let supportedRasterTypes: Set<String> = [
        "public.png",
        "public.heic",
        "public.heif",
        "public.heics",
    ]

    private static let supportedHEIFTypes: Set<String> = [
        "public.heic",
        "public.heif",
        "public.heics",
    ]

    private static func matchesRasterMediaType(
        _ type: String,
        expected: ThemeResourceMediaType?
    ) -> Bool {
        switch expected {
        case nil:
            return true
        case .png:
            return type == "public.png"
        case .heif:
            return supportedHEIFTypes.contains(type)
        default:
            return false
        }
    }

    private static func rasterPixelDimensions(
        source: CGImageSource
    ) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw RuntimeThemeDecodedResourceError.invalidPixelDimensions
        }
        if let depth = properties[kCGImagePropertyDepth] as? NSNumber,
           !(1 ... 8).contains(depth.intValue) {
            throw RuntimeThemeDecodedResourceError.unsupportedPixelDepth
        }
        guard width.uint64Value <= UInt64(Int.max),
              height.uint64Value <= UInt64(Int.max)
        else {
            throw RuntimeThemeDecodedResourceError.invalidPixelDimensions
        }
        return (
            width: Int(width.uint64Value),
            height: Int(height.uint64Value)
        )
    }

    private static func pdfPixelDimensions(
        data: Data
    ) throws -> (width: Int, height: Int) {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages == 1,
              let page = document.page(at: 1)
        else {
            throw RuntimeThemeDecodedResourceError.unsupportedImage
        }
        let bounds = page.getBoxRect(.mediaBox).standardized
        let normalizedRotation = (Int(page.rotationAngle) % 360 + 360) % 360
        let swapsDimensions = normalizedRotation == 90
            || normalizedRotation == 270
        let width = swapsDimensions ? bounds.height : bounds.width
        let height = swapsDimensions ? bounds.width : bounds.height
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width <= CGFloat(Self.maximumPixelDimension),
              height <= CGFloat(Self.maximumPixelDimension)
        else {
            throw RuntimeThemeDecodedResourceError.invalidPixelDimensions
        }
        return (
            width: Int(ceil(width)),
            height: Int(ceil(height))
        )
    }

    private func decode(
        _ handle: RuntimeThemeDecodedImageHandle
    ) -> CGImage? {
        guard let encodedData = encodedEntries[handle.key]?.data else {
            return nil
        }
        switch handle.kind {
        case .raster:
            let options = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithData(
                encodedData as CFData,
                options
            ),
            let image = CGImageSourceCreateImageAtIndex(source, 0, options),
            image.width == handle.pixelWidth,
            image.height == handle.pixelHeight,
            (1 ... 8).contains(image.bitsPerComponent),
            let decodedData = image.dataProvider?.data,
            let byteCount = Self.byteCount(of: image),
            CFDataGetLength(decodedData) >= byteCount
            else { return nil }
            return image
        case .pdf:
            return Self.decodePDF(handle, encodedData: encodedData)
        }
    }

    private static func decodePDF(
        _ handle: RuntimeThemeDecodedImageHandle,
        encodedData: Data
    ) -> CGImage? {
        guard let provider = CGDataProvider(
            data: encodedData as CFData
        ),
        let document = CGPDFDocument(provider),
        let page = document.page(at: 1),
        let context = CGContext(
            data: nil,
            width: handle.pixelWidth,
            height: handle.pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: handle.pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { return nil }

        let drawingBounds = CGRect(
            x: 0,
            y: 0,
            width: handle.pixelWidth,
            height: handle.pixelHeight
        )
        context.clear(drawingBounds)
        context.concatenate(
            page.getDrawingTransform(
                .mediaBox,
                rect: drawingBounds,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func byteCount(of image: CGImage) -> Int? {
        let (byteCount, overflow) = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        return overflow ? nil : byteCount
    }

    private static func swiftUIImage(_ image: CGImage) -> Image {
        Image(decorative: image, scale: 1, orientation: .up)
    }

    private func evictDecodedToFit(decodedByteCount: Int) {
        while decodedEntries.count >= entryLimit
            || totalDecodedByteCount > decodedByteLimit - decodedByteCount {
            guard let leastRecentlyUsed = decodedEntries.min(
                by: { $0.value.accessOrder < $1.value.accessOrder }
            )?.key else { break }
            removeDecodedEntry(for: leastRecentlyUsed)
        }
    }

    private func evictEncodedToFit(
        encodedByteCount: Int,
        addingEntry: Bool
    ) throws {
        guard encodedByteCount <= encodedByteLimit else {
            throw RuntimeThemeDecodedResourceError.encodedCacheCapacityExceeded
        }
        while (addingEntry && encodedEntries.count >= entryLimit)
            || totalEncodedByteCount > encodedByteLimit - encodedByteCount {
            guard let leastRecentlyUsed = encodedEntries
                .filter({ retainedKeyCounts[$0.key] == nil })
                .min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key
            else {
                throw RuntimeThemeDecodedResourceError.encodedCacheCapacityExceeded
            }
            removeEncodedEntry(for: leastRecentlyUsed)
        }
    }

    private func removeDecodedEntry(for key: RuntimeThemeDecodedResourceKey) {
        guard let removed = decodedEntries.removeValue(forKey: key) else { return }
        totalDecodedByteCount -= removed.decodedByteCount
    }

    private func removeEncodedEntry(for key: RuntimeThemeDecodedResourceKey) {
        guard retainedKeyCounts[key] == nil,
              let removed = encodedEntries.removeValue(forKey: key)
        else { return }
        totalEncodedByteCount -= removed.data.count
        removeDecodedEntry(for: key)
    }

    private func nextAccessOrder() -> UInt64 {
        accessOrder &+= 1
        return accessOrder
    }
}

@MainActor
final class RuntimeThemeDecodedResourceReference: ObservableObject {
    private let cache: RuntimeThemeDecodedResourceCache
    private let handle: RuntimeThemeDecodedImageHandle?

    init(
        data: Data,
        cache: RuntimeThemeDecodedResourceCache
    ) {
        self.cache = cache
        handle = try? cache.prepareImage(data: data)
        if let handle {
            cache.retain([handle])
        }
    }

    var image: Image? {
        handle.flatMap(cache.image(for:))
    }

    deinit {
        guard let handle else { return }
        let cache = cache
        Task { @MainActor in
            cache.release([handle])
        }
    }
}

@MainActor
public final class RuntimeThemeImageReference: ObservableObject {
    public let codexID: CodexID
    public let resourceID: ThemeResourceID
    public let role: ThemeResourceRoleID
    public let mediaType: ThemeResourceMediaType
    public let integrity: ThemeResourceIntegrity
    public let contentRevision: UInt64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let kind: RuntimeThemeImageKind

    fileprivate let cache: RuntimeThemeDecodedResourceCache
    fileprivate let handle: RuntimeThemeDecodedImageHandle

    fileprivate init(
        codexID: CodexID,
        resourceID: ThemeResourceID,
        role: ThemeResourceRoleID,
        mediaType: ThemeResourceMediaType,
        integrity: ThemeResourceIntegrity,
        contentRevision: UInt64,
        handle: RuntimeThemeDecodedImageHandle,
        cache: RuntimeThemeDecodedResourceCache
    ) {
        self.codexID = codexID
        self.resourceID = resourceID
        self.role = role
        self.mediaType = mediaType
        self.integrity = integrity
        self.contentRevision = contentRevision
        pixelWidth = handle.pixelWidth
        pixelHeight = handle.pixelHeight
        kind = handle.kind == .pdf ? .vectorPDF : .raster
        self.cache = cache
        self.handle = handle
        cache.retain([handle])
    }

    public var pixelSize: ThemePixelSize? {
        integrity.pixelSize
    }

    public var image: Image? {
        cache.image(for: handle)
    }

    deinit {
        let cache = cache
        let handle = handle
        Task { @MainActor in
            cache.release([handle])
        }
    }
}

public struct RuntimeThemeBackgroundColor: Equatable, Hashable, Sendable {
    public let rawValue: String
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(rawValue: String) throws {
        guard rawValue.count == 7,
              rawValue.first == "#",
              rawValue == rawValue.uppercased(),
              let value = UInt32(rawValue.dropFirst(), radix: 16)
        else {
            throw RuntimeThemeBackgroundParameterError.invalidField("color")
        }
        self.rawValue = rawValue.uppercased()
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }
}

public struct RuntimeThemeBackgroundParameters: Equatable, Sendable {
    public static let maximumEncodedByteCount = 16 * 1_024
    public static let supportedRendererID = "fragment-rune-background"

    public let rendererID: String
    public let baseGradient: [RuntimeThemeBackgroundColor]
    public let bandFrequency: Double
    public let bandTimeScale: Double
    public let bandThreshold: [Double]
    public let bandColor: RuntimeThemeBackgroundColor
    public let bandStrength: Double
    public let columnFrequency: Double
    public let columnTimeScale: Double
    public let columnExponent: Double
    public let columnColor: RuntimeThemeBackgroundColor
    public let columnStrength: Double
    public let highlightColor: RuntimeThemeBackgroundColor
    public let highlightExponent: Double
    public let highlightStrength: Double
    public let vignetteStrength: Double
    public let shimmerTimeScale: Double
    public let shimmerFrequency: Double
    public let shimmerStrength: Double

    public static func decode(from data: Data) throws -> Self {
        guard !data.isEmpty else {
            throw RuntimeThemeBackgroundParameterError.emptyDocument
        }
        guard data.count <= maximumEncodedByteCount else {
            throw RuntimeThemeBackgroundParameterError.documentTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            throw RuntimeThemeBackgroundParameterError.malformedDocument
        }

        let parameterObject: [String: Any]
        let raw: RawParameters
        if let nested = root["rendererParameters"] as? [String: Any] {
            parameterObject = nested
            guard let envelope = try? JSONDecoder().decode(
                ParameterEnvelope.self,
                from: data
            ) else {
                throw RuntimeThemeBackgroundParameterError.malformedDocument
            }
            raw = envelope.rendererParameters
        } else {
            parameterObject = root
            guard let decoded = try? JSONDecoder().decode(
                RawParameters.self,
                from: data
            ) else {
                throw RuntimeThemeBackgroundParameterError.malformedDocument
            }
            raw = decoded
        }
        guard Set(parameterObject.keys) == RawParameters.expectedKeys else {
            throw RuntimeThemeBackgroundParameterError.malformedDocument
        }
        return try Self(raw: raw)
    }

    private init(raw: RawParameters) throws {
        guard raw.rendererID == Self.supportedRendererID else {
            throw RuntimeThemeBackgroundParameterError.unsupportedRenderer(
                raw.rendererID
            )
        }
        guard raw.baseGradient.count == 2 else {
            throw RuntimeThemeBackgroundParameterError.invalidField("baseGradient")
        }
        guard raw.bandThreshold.count == 2,
              Self.isBounded(raw.bandThreshold[0], -1 ... 1),
              Self.isBounded(raw.bandThreshold[1], -1 ... 1),
              raw.bandThreshold[0] < raw.bandThreshold[1]
        else {
            throw RuntimeThemeBackgroundParameterError.invalidField("bandThreshold")
        }

        try Self.require(raw.bandFrequency, in: 0.01 ... 256, field: "bandFrequency")
        try Self.require(raw.bandTimeScale, in: -16 ... 16, field: "bandTimeScale")
        try Self.require(raw.bandStrength, in: 0 ... 4, field: "bandStrength")
        try Self.require(raw.columnFrequency, in: 0.01 ... 256, field: "columnFrequency")
        try Self.require(raw.columnTimeScale, in: -16 ... 16, field: "columnTimeScale")
        try Self.require(raw.columnExponent, in: 0.25 ... 32, field: "columnExponent")
        try Self.require(raw.columnStrength, in: 0 ... 4, field: "columnStrength")
        try Self.require(raw.highlightExponent, in: 0.25 ... 32, field: "highlightExponent")
        try Self.require(raw.highlightStrength, in: 0 ... 4, field: "highlightStrength")
        try Self.require(raw.vignetteStrength, in: 0 ... 8, field: "vignetteStrength")
        try Self.require(raw.shimmerTimeScale, in: -16 ... 16, field: "shimmerTimeScale")
        try Self.require(raw.shimmerFrequency, in: 0.01 ... 256, field: "shimmerFrequency")
        try Self.require(raw.shimmerStrength, in: 0 ... 0.5, field: "shimmerStrength")

        rendererID = raw.rendererID
        baseGradient = try raw.baseGradient.map(RuntimeThemeBackgroundColor.init)
        bandFrequency = raw.bandFrequency
        bandTimeScale = raw.bandTimeScale
        bandThreshold = raw.bandThreshold
        bandColor = try RuntimeThemeBackgroundColor(rawValue: raw.bandColor)
        bandStrength = raw.bandStrength
        columnFrequency = raw.columnFrequency
        columnTimeScale = raw.columnTimeScale
        columnExponent = raw.columnExponent
        columnColor = try RuntimeThemeBackgroundColor(rawValue: raw.columnColor)
        columnStrength = raw.columnStrength
        highlightColor = try RuntimeThemeBackgroundColor(rawValue: raw.highlightColor)
        highlightExponent = raw.highlightExponent
        highlightStrength = raw.highlightStrength
        vignetteStrength = raw.vignetteStrength
        shimmerTimeScale = raw.shimmerTimeScale
        shimmerFrequency = raw.shimmerFrequency
        shimmerStrength = raw.shimmerStrength
    }

    private static func require(
        _ value: Double,
        in range: ClosedRange<Double>,
        field: String
    ) throws {
        guard isBounded(value, range) else {
            throw RuntimeThemeBackgroundParameterError.invalidField(field)
        }
    }

    private static func isBounded(
        _ value: Double,
        _ range: ClosedRange<Double>
    ) -> Bool {
        value.isFinite && range.contains(value)
    }

    private struct ParameterEnvelope: Decodable {
        let rendererParameters: RawParameters
    }

    private struct RawParameters: Decodable {
        static let expectedKeys: Set<String> = [
            "rendererID",
            "baseGradient",
            "bandFrequency",
            "bandTimeScale",
            "bandThreshold",
            "bandColor",
            "bandStrength",
            "columnFrequency",
            "columnTimeScale",
            "columnExponent",
            "columnColor",
            "columnStrength",
            "highlightColor",
            "highlightExponent",
            "highlightStrength",
            "vignetteStrength",
            "shimmerTimeScale",
            "shimmerFrequency",
            "shimmerStrength",
        ]

        let rendererID: String
        let baseGradient: [String]
        let bandFrequency: Double
        let bandTimeScale: Double
        let bandThreshold: [Double]
        let bandColor: String
        let bandStrength: Double
        let columnFrequency: Double
        let columnTimeScale: Double
        let columnExponent: Double
        let columnColor: String
        let columnStrength: Double
        let highlightColor: String
        let highlightExponent: Double
        let highlightStrength: Double
        let vignetteStrength: Double
        let shimmerTimeScale: Double
        let shimmerFrequency: Double
        let shimmerStrength: Double
    }
}

@MainActor
fileprivate struct RuntimeThemeBackgroundImage {
    let handle: RuntimeThemeDecodedImageHandle

    init(handle: RuntimeThemeDecodedImageHandle) {
        self.handle = handle
    }

    init?(
        data: Data,
        cache: RuntimeThemeDecodedResourceCache
    ) {
        guard let handle = try? cache.prepareImage(data: data) else { return nil }
        guard cache.validateImage(handle) else {
            cache.discardIfUnretained([handle])
            return nil
        }
        self.handle = handle
    }

    func image(using cache: RuntimeThemeDecodedResourceCache) -> Image? {
        cache.image(for: handle)
    }
}

fileprivate struct RuntimeThemeBackgroundConfiguration {
    let staticBase: RuntimeThemeBackgroundImage
    let reduceMotion: RuntimeThemeBackgroundImage
    let highContrast: RuntimeThemeBackgroundImage
    let parameters: RuntimeThemeBackgroundParameters?

    var imageHandles: [RuntimeThemeDecodedImageHandle] {
        [staticBase.handle, reduceMotion.handle, highContrast.handle]
    }
}

@MainActor
public final class RuntimePreparedThemeBackground {
    public let usesRendererParameters: Bool

    fileprivate let ownerID: ObjectIdentifier
    fileprivate let configuration: RuntimeThemeBackgroundConfiguration
    fileprivate let cache: RuntimeThemeDecodedResourceCache
    fileprivate var isCommitted = false

    fileprivate init(
        ownerID: ObjectIdentifier,
        configuration: RuntimeThemeBackgroundConfiguration,
        cache: RuntimeThemeDecodedResourceCache
    ) {
        self.ownerID = ownerID
        self.configuration = configuration
        self.cache = cache
        usesRendererParameters = configuration.parameters != nil
        cache.retain(configuration.imageHandles)
    }

    fileprivate func take(
        for ownerID: ObjectIdentifier
    ) throws -> RuntimeThemeBackgroundConfiguration {
        guard self.ownerID == ownerID else {
            throw RuntimeThemeBackgroundInstallationError
                .preparedBackgroundOwnerMismatch
        }
        guard !isCommitted else {
            throw RuntimeThemeBackgroundInstallationError
                .preparedBackgroundAlreadyCommitted
        }
        isCommitted = true
        return configuration
    }

    deinit {
        guard !isCommitted else { return }
        let cache = cache
        let handles = configuration.imageHandles
        Task { @MainActor in
            cache.release(handles)
        }
    }
}

private final class RuntimeNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func cancel() {
        NotificationCenter.default.removeObserver(token)
    }

    deinit {
        cancel()
    }
}

private struct RuntimeThemeExpectedImageIdentity {
    let resourceID: ThemeResourceID
    let role: ThemeResourceRoleID
    let mediaType: ThemeResourceMediaType
    let integrity: ThemeResourceIntegrity

    init(reference: ThemeResourceReference) {
        resourceID = reference.id
        role = reference.role
        mediaType = reference.mediaType
        integrity = reference.integrity
    }

    init(inventory: SharePresentationProviderResourceInventory) throws {
        resourceID = inventory.resourceID
        role = inventory.role
        mediaType = inventory.mediaType
        integrity = try ThemeResourceIntegrity(
            sha256: inventory.sha256,
            byteLength: inventory.byteLength,
            pixelSize: inventory.pixelSize
        )
    }
}

enum RuntimeThemeBackgroundPresentationVariant: Equatable, Sendable {
    case semanticFallback
    case staticBase
    case reduceMotion
    case highContrast
    case animated
}

@MainActor
public final class RuntimeApplicationResourcePresentation: ObservableObject {
    private let splashVideoSession: RuntimeApplicationResourceSession?
    private let metalLibrarySession: RuntimeApplicationResourceSession?
    private let decodedResourceCache: RuntimeThemeDecodedResourceCache

    @Published internal private(set) var splashPlayer: AVPlayer?
    @Published internal private(set) var metalResource: RuntimeMetalResource?
    @Published internal private(set) var themeBackgroundRevision: UInt64 = 0

    private var splashLease: RuntimeApplicationResourceLease?
    private var metalLease: RuntimeApplicationResourceLease?
    private var splashEventTask: Task<Void, Never>?
    private var metalEventTask: Task<Void, Never>?
    private var splashFallbackTask: Task<Void, Never>?
    private var splashEndObserver: RuntimeNotificationObserver?
    private var splashFinishCallback: (@MainActor () -> Void)?
    private var themeBackgroundConfiguration: RuntimeThemeBackgroundConfiguration?
    private var splashIsStarting = false
    private var metalIsStarting = false
    private var splashDidFinish = false
    private var isClosed = false

    public convenience init(
        splashVideo: RuntimeApplicationResourceSession?,
        metalLibrary: RuntimeApplicationResourceSession?
    ) {
        self.init(
            splashVideo: splashVideo,
            metalLibrary: metalLibrary,
            decodedResourceCache: RuntimeThemeDecodedResourceCache()
        )
    }

    init(
        splashVideo: RuntimeApplicationResourceSession?,
        metalLibrary: RuntimeApplicationResourceSession?,
        decodedResourceCache: RuntimeThemeDecodedResourceCache
    ) {
        splashVideoSession = splashVideo
        metalLibrarySession = metalLibrary
        self.decodedResourceCache = decodedResourceCache
    }

    public var hasSplashVideo: Bool {
        splashVideoSession != nil && !isClosed
    }

    public func makeSplashView(
        onFinish: @escaping @MainActor () -> Void
    ) -> AnyView {
        AnyView(
            RuntimeSplashPresentationView(
                presentation: self,
                onFinish: onFinish
            )
        )
    }

    public func makeMetalView() -> AnyView {
        AnyView(RuntimeMetalPresentationView(presentation: self))
    }

    public func makeThemeImageReference(
        resolvedResource: ResolvedThemeResourceDTO,
        expectedReference: ThemeResourceReference,
        expectedCodexID: CodexID,
        contentRevision: UInt64
    ) throws -> RuntimeThemeImageReference {
        try makeThemeImageReference(
            resolvedResource: resolvedResource,
            expected: RuntimeThemeExpectedImageIdentity(
                reference: expectedReference
            ),
            expectedCodexID: expectedCodexID,
            contentRevision: contentRevision
        )
    }

    public func makeThemeImageReference(
        resolvedResource: ResolvedThemeResourceDTO,
        expectedInventory: SharePresentationProviderResourceInventory,
        expectedCodexID: CodexID,
        contentRevision: UInt64
    ) throws -> RuntimeThemeImageReference {
        let expected: RuntimeThemeExpectedImageIdentity
        do {
            expected = try RuntimeThemeExpectedImageIdentity(
                inventory: expectedInventory
            )
        } catch {
            throw RuntimeThemeImageReferenceError.integrityMismatch
        }
        return try makeThemeImageReference(
            resolvedResource: resolvedResource,
            expected: expected,
            expectedCodexID: expectedCodexID,
            contentRevision: contentRevision
        )
    }

    private func makeThemeImageReference(
        resolvedResource: ResolvedThemeResourceDTO,
        expected: RuntimeThemeExpectedImageIdentity,
        expectedCodexID: CodexID,
        contentRevision: UInt64
    ) throws -> RuntimeThemeImageReference {
        guard !isClosed else {
            throw RuntimeThemeImageReferenceError.presentationClosed
        }
        guard resolvedResource.codexID == expectedCodexID else {
            throw RuntimeThemeImageReferenceError.codexIdentityMismatch
        }
        guard resolvedResource.resourceID == expected.resourceID else {
            throw RuntimeThemeImageReferenceError.resourceIdentityMismatch
        }
        guard resolvedResource.role == expected.role else {
            throw RuntimeThemeImageReferenceError.roleMismatch
        }
        guard resolvedResource.mediaType == expected.mediaType else {
            throw RuntimeThemeImageReferenceError.mediaTypeMismatch
        }
        guard resolvedResource.integrity == expected.integrity else {
            throw RuntimeThemeImageReferenceError.integrityMismatch
        }
        guard UInt64(resolvedResource.data.count) == expected.integrity.byteLength,
              RuntimeIntegrityDigest.sha256Hex(resolvedResource.data)
                == expected.integrity.sha256.rawValue
        else {
            throw RuntimeThemeImageReferenceError.encodedContentMismatch
        }

        let handle: RuntimeThemeDecodedImageHandle
        do {
            handle = try decodedResourceCache.prepareImage(
                data: resolvedResource.data,
                codexID: expectedCodexID,
                resourceID: expected.resourceID,
                contentRevision: contentRevision,
                sha256: expected.integrity.sha256,
                expectedMediaType: expected.mediaType
            )
        } catch RuntimeThemeDecodedResourceError.encodedCacheCapacityExceeded {
            throw RuntimeThemeImageReferenceError.cacheCapacityExceeded
        } catch RuntimeThemeDecodedResourceError.encodedDataTooLarge {
            throw RuntimeThemeImageReferenceError.cacheCapacityExceeded
        } catch {
            throw RuntimeThemeImageReferenceError.unsupportedImage
        }

        if let expectedPixelSize = expected.integrity.pixelSize,
           (handle.pixelWidth != Int(expectedPixelSize.width)
               || handle.pixelHeight != Int(expectedPixelSize.height))
        {
            decodedResourceCache.discardIfUnretained([handle])
            throw RuntimeThemeImageReferenceError.pixelDimensionsMismatch
        }
        guard decodedResourceCache.image(for: handle) != nil else {
            decodedResourceCache.discardIfUnretained([handle])
            throw RuntimeThemeImageReferenceError.cacheCapacityExceeded
        }
        return RuntimeThemeImageReference(
            codexID: expectedCodexID,
            resourceID: expected.resourceID,
            role: expected.role,
            mediaType: expected.mediaType,
            integrity: expected.integrity,
            contentRevision: contentRevision,
            handle: handle,
            cache: decodedResourceCache
        )
    }

    public func installThemeBackground(
        staticBaseData: Data,
        reduceMotionData: Data,
        highContrastData: Data,
        rendererParametersData: Data?
    ) throws {
        let prepared = try prepareThemeBackground(
            staticBaseData: staticBaseData,
            reduceMotionData: reduceMotionData,
            highContrastData: highContrastData,
            rendererParametersData: rendererParametersData
        )
        try commitThemeBackground(prepared)
    }

    public func prepareThemeBackground(
        staticBaseData: Data,
        reduceMotionData: Data,
        highContrastData: Data,
        rendererParametersData: Data?
    ) throws -> RuntimePreparedThemeBackground {
        guard !isClosed else {
            throw RuntimeThemeBackgroundInstallationError.presentationClosed
        }
        guard let staticBase = RuntimeThemeBackgroundImage(
            data: staticBaseData,
            cache: decodedResourceCache
        ) else {
            throw RuntimeThemeBackgroundInstallationError.invalidStaticBaseData
        }
        guard let reduceMotion = RuntimeThemeBackgroundImage(
            data: reduceMotionData,
            cache: decodedResourceCache
        ) else {
            decodedResourceCache.discardIfUnretained([staticBase.handle])
            throw RuntimeThemeBackgroundInstallationError.invalidReduceMotionData
        }
        guard let highContrast = RuntimeThemeBackgroundImage(
            data: highContrastData,
            cache: decodedResourceCache
        ) else {
            decodedResourceCache.discardIfUnretained([
                staticBase.handle,
                reduceMotion.handle,
            ])
            throw RuntimeThemeBackgroundInstallationError.invalidHighContrastData
        }

        let parameters = rendererParametersData.flatMap {
            try? RuntimeThemeBackgroundParameters.decode(from: $0)
        }
        return RuntimePreparedThemeBackground(
            ownerID: ObjectIdentifier(self),
            configuration: RuntimeThemeBackgroundConfiguration(
                staticBase: staticBase,
                reduceMotion: reduceMotion,
                highContrast: highContrast,
                parameters: parameters
            ),
            cache: decodedResourceCache
        )
    }

    public func prepareThemeBackground(
        staticBase: RuntimeThemeImageReference,
        reduceMotion: RuntimeThemeImageReference,
        highContrast: RuntimeThemeImageReference,
        rendererParametersData: Data?
    ) throws -> RuntimePreparedThemeBackground {
        guard !isClosed else {
            throw RuntimeThemeBackgroundInstallationError.presentationClosed
        }
        let references = [staticBase, reduceMotion, highContrast]
        guard references.allSatisfy({ $0.cache === decodedResourceCache }),
              Set(references.map(\.codexID)).count == 1,
              Set(references.map(\.contentRevision)).count == 1,
              staticBase.role == ThemeResourceRoles.backgroundStaticBase,
              (reduceMotion.role == ThemeResourceRoles.backgroundReduceMotion
                  || reduceMotion.role == ThemeResourceRoles.backgroundStaticBase),
              highContrast.role == ThemeResourceRoles.backgroundHighContrast
        else {
            throw RuntimeThemeBackgroundInstallationError
                .invalidBackgroundReference
        }
        let parameters = rendererParametersData.flatMap {
            try? RuntimeThemeBackgroundParameters.decode(from: $0)
        }
        return RuntimePreparedThemeBackground(
            ownerID: ObjectIdentifier(self),
            configuration: RuntimeThemeBackgroundConfiguration(
                staticBase: RuntimeThemeBackgroundImage(
                    handle: staticBase.handle
                ),
                reduceMotion: RuntimeThemeBackgroundImage(
                    handle: reduceMotion.handle
                ),
                highContrast: RuntimeThemeBackgroundImage(
                    handle: highContrast.handle
                ),
                parameters: parameters
            ),
            cache: decodedResourceCache
        )
    }

    public func commitThemeBackground(
        _ prepared: RuntimePreparedThemeBackground
    ) throws {
        guard !isClosed else {
            throw RuntimeThemeBackgroundInstallationError.presentationClosed
        }
        let configuration = try prepared.take(for: ObjectIdentifier(self))
        installThemeBackgroundConfiguration(
            configuration,
            alreadyRetained: true
        )
    }

    public func clearThemeBackground() {
        let releasedHandles = themeBackgroundConfiguration?.imageHandles ?? []
        themeBackgroundConfiguration = nil
        themeBackgroundRevision &+= 1
        decodedResourceCache.release(releasedHandles)
        stopMetal()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let releasedHandles = themeBackgroundConfiguration?.imageHandles ?? []
        themeBackgroundConfiguration = nil
        themeBackgroundRevision &+= 1
        decodedResourceCache.release(releasedHandles)
        let splashLease = clearSplashPresentation()
        let metalLease = clearMetalPresentation()
        await splashLease?.close()
        await metalLease?.close()
    }

    deinit {
        splashEventTask?.cancel()
        metalEventTask?.cancel()
        splashFallbackTask?.cancel()
    }

    func startSplash(
        onFinish: @escaping @MainActor () -> Void
    ) async {
        guard !isClosed, let splashVideoSession else {
            onFinish()
            return
        }
        guard splashPlayer == nil, !splashIsStarting, !splashDidFinish else {
            return
        }
        splashIsStarting = true
        splashFinishCallback = onFinish

        do {
            let lease = try await splashVideoSession.acquire()
            try Task.checkCancellation()
            guard !isClosed else {
                await lease.close()
                return
            }

            let player = AVPlayer(url: lease.url)
            player.actionAtItemEnd = .pause
            splashLease = lease
            splashPlayer = player
            let events = await lease.events()
            splashEventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard event == .revoked else { continue }
                    self?.finishSplash()
                }
            }
            configureAudioSession()
            let splashEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishSplash()
                }
            }
            self.splashEndObserver = RuntimeNotificationObserver(
                token: splashEndObserver
            )
            player.play()
            splashFallbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.finishSplash()
            }
        } catch is CancellationError {
            splashFinishCallback = nil
        } catch {
            finishSplash()
        }
        splashIsStarting = false
    }

    var splashIsActive: Bool {
        splashPlayer != nil && !splashDidFinish
    }

    var staticThemeBackgroundImage: Image? {
        themeBackgroundConfiguration?.staticBase.image(using: decodedResourceCache)
    }

    var reduceMotionThemeBackgroundImage: Image? {
        themeBackgroundConfiguration?.reduceMotion.image(
            using: decodedResourceCache
        )
    }

    var highContrastThemeBackgroundImage: Image? {
        themeBackgroundConfiguration?.highContrast.image(
            using: decodedResourceCache
        )
    }

    var themeBackgroundParameters: RuntimeThemeBackgroundParameters? {
        themeBackgroundConfiguration?.parameters
    }

    var themeDecodedResourceCache: RuntimeThemeDecodedResourceCache {
        decodedResourceCache
    }

    func themeBackgroundPresentationVariant(
        reduceMotion: Bool,
        increasedContrast: Bool
    ) -> RuntimeThemeBackgroundPresentationVariant {
        guard themeBackgroundConfiguration != nil else {
            return .semanticFallback
        }
        if increasedContrast {
            return .highContrast
        }
        if reduceMotion {
            return .reduceMotion
        }
        if themeBackgroundConfiguration?.parameters != nil,
           metalResource != nil {
            return .animated
        }
        return .staticBase
    }

    func finishSplash() {
        guard !splashDidFinish else { return }
        splashDidFinish = true
        let callback = splashFinishCallback
        let lease = clearSplashPresentation()
        if let lease {
            Task {
                await lease.close()
            }
        }
        callback?()
    }

    func startMetal() async {
        guard !isClosed,
              metalResource == nil,
              !metalIsStarting,
              let metalLibrarySession
        else { return }
        metalIsStarting = true
        defer { metalIsStarting = false }

        do {
            let lease = try await metalLibrarySession.acquire()
            do {
                try Task.checkCancellation()
            } catch {
                await lease.close()
                return
            }
            guard !isClosed,
                  themeBackgroundConfiguration?.parameters != nil,
                  let device = MTLCreateSystemDefaultDevice(),
                  let library = try? device.makeLibrary(URL: lease.url),
                  library.makeFunction(name: "vertex_fullscreen") != nil,
                  library.makeFunction(name: "fragment_rune_background") != nil
            else {
                await lease.close()
                return
            }

            metalLease = lease
            metalResource = RuntimeMetalResource(device: device, library: library)
            let events = await lease.events()
            metalEventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard event == .revoked else { continue }
                    self?.stopMetal()
                }
            }
        } catch {
            // Missing or revoked optional presentation resources degrade to a static header.
        }
    }

    private func clearSplashPresentation() -> RuntimeApplicationResourceLease? {
        splashEventTask?.cancel()
        splashEventTask = nil
        splashFallbackTask?.cancel()
        splashFallbackTask = nil
        splashEndObserver?.cancel()
        splashEndObserver = nil
        splashPlayer?.pause()
        splashPlayer?.replaceCurrentItem(with: nil)
        splashPlayer = nil
        splashFinishCallback = nil
        let lease = splashLease
        splashLease = nil
        return lease
    }

    private func clearMetalPresentation() -> RuntimeApplicationResourceLease? {
        metalEventTask?.cancel()
        metalEventTask = nil
        metalResource = nil
        let lease = metalLease
        metalLease = nil
        return lease
    }

    private func installThemeBackgroundConfiguration(
        _ configuration: RuntimeThemeBackgroundConfiguration,
        alreadyRetained: Bool = false
    ) {
        let replacedHandles = themeBackgroundConfiguration?.imageHandles ?? []
        if !alreadyRetained {
            decodedResourceCache.retain(configuration.imageHandles)
        }
        themeBackgroundConfiguration = configuration
        themeBackgroundRevision &+= 1
        decodedResourceCache.release(replacedHandles)
        if configuration.parameters == nil {
            stopMetal()
        }
    }

    private func stopMetal() {
        let lease = clearMetalPresentation()
        if let lease {
            Task {
                await lease.close()
            }
        }
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .ambient,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

private struct RuntimeApplicationResourcePresentationKey: EnvironmentKey {
    static let defaultValue: RuntimeApplicationResourcePresentation? = nil
}

public extension EnvironmentValues {
    var runtimeApplicationResourcePresentation: RuntimeApplicationResourcePresentation? {
        get { self[RuntimeApplicationResourcePresentationKey.self] }
        set { self[RuntimeApplicationResourcePresentationKey.self] = newValue }
    }
}

public struct RuntimeMetalBackground: View {
    @Environment(\.runtimeApplicationResourcePresentation)
    private var presentation

    public init() {}

    public var body: some View {
        Group {
            if let presentation {
                presentation.makeMetalView()
            } else {
                RuntimeThemeBackgroundFallback()
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RuntimeThemeBackgroundFallback: View {
    var body: some View {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

private struct RuntimeThemeBackgroundStaticView: View {
    let image: Image

    var body: some View {
        ZStack {
            RuntimeThemeBackgroundFallback()
            image
                .resizable()
                .scaledToFill()
        }
        .clipped()
    }
}

private struct RuntimeSplashPresentationView: View {
    @ObservedObject var presentation: RuntimeApplicationResourcePresentation
    let onFinish: @MainActor () -> Void
    @State private var showSkip = false

    var body: some View {
        ZStack {
            Color(red: 0.031, green: 0.039, blue: 0.118)
                .ignoresSafeArea()

            if let player = presentation.splashPlayer {
                RuntimeSplashVideoSurface(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()
                if showSkip, presentation.splashIsActive {
                    Button {
                        presentation.finishSplash()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color(red: 0.031, green: 0.039, blue: 0.118))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(
                                    Color(red: 0.831, green: 0.592, blue: 0.102)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                    .accessibilityLabel("Skip intro")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            presentation.finishSplash()
        }
        .task {
            await presentation.startSplash(onFinish: onFinish)
            guard presentation.splashIsActive else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, presentation.splashIsActive else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showSkip = true
            }
        }
    }
}

private struct RuntimeSplashVideoSurface {
    let player: AVPlayer
}

#if os(iOS)
extension RuntimeSplashVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> RuntimeSplashHostView {
        RuntimeSplashHostView(player: player)
    }

    func updateUIView(_ uiView: RuntimeSplashHostView, context: Context) {}

    static func dismantleUIView(_ uiView: RuntimeSplashHostView, coordinator: ()) {
        uiView.detachPlayer()
    }
}

private final class RuntimeSplashHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .clear
        playerLayer?.player = player
        playerLayer?.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func detachPlayer() {
        playerLayer?.player = nil
    }
}
#elseif os(macOS)
extension RuntimeSplashVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> RuntimeSplashHostView {
        RuntimeSplashHostView(player: player)
    }

    func updateNSView(_ nsView: RuntimeSplashHostView, context: Context) {}

    static func dismantleNSView(_ nsView: RuntimeSplashHostView, coordinator: ()) {
        nsView.detachPlayer()
    }
}

private final class RuntimeSplashHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func detachPlayer() {
        playerLayer.player = nil
    }
}
#endif

private struct RuntimeMetalPresentationView: View {
    @ObservedObject var presentation: RuntimeApplicationResourcePresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        selectedBackground
            .task(id: loadingIdentity) {
                guard !reduceMotion,
                      colorSchemeContrast != .increased,
                      presentation.themeBackgroundParameters != nil
                else { return }
                await presentation.startMetal()
            }
    }

    @ViewBuilder
    private var selectedBackground: some View {
        switch presentation.themeBackgroundPresentationVariant(
            reduceMotion: reduceMotion,
            increasedContrast: colorSchemeContrast == .increased
        ) {
        case .highContrast:
            if let image = presentation.highContrastThemeBackgroundImage {
                RuntimeThemeBackgroundStaticView(image: image)
            } else {
                RuntimeThemeBackgroundFallback()
            }
        case .reduceMotion:
            if let image = presentation.reduceMotionThemeBackgroundImage {
                RuntimeThemeBackgroundStaticView(image: image)
            } else {
                RuntimeThemeBackgroundFallback()
            }
        case .animated:
            if let parameters = presentation.themeBackgroundParameters,
               let resource = presentation.metalResource {
                RuntimeMetalSurface(
                    resource: resource,
                    parameters: parameters
                )
                .id(
                    RuntimeMetalSurfaceIdentity(
                        resource: ObjectIdentifier(resource),
                        revision: presentation.themeBackgroundRevision
                    )
                )
            } else {
                RuntimeThemeBackgroundFallback()
            }
        case .staticBase:
            if let image = presentation.staticThemeBackgroundImage {
                RuntimeThemeBackgroundStaticView(image: image)
            } else {
                RuntimeThemeBackgroundFallback()
            }
        case .semanticFallback:
            RuntimeThemeBackgroundFallback()
        }
    }

    private var loadingIdentity: RuntimeMetalLoadingIdentity {
        RuntimeMetalLoadingIdentity(
            revision: presentation.themeBackgroundRevision,
            reduceMotion: reduceMotion,
            increasedContrast: colorSchemeContrast == .increased
        )
    }
}

private struct RuntimeMetalLoadingIdentity: Equatable {
    let revision: UInt64
    let reduceMotion: Bool
    let increasedContrast: Bool
}

private struct RuntimeMetalSurfaceIdentity: Hashable {
    let resource: ObjectIdentifier
    let revision: UInt64
}

@MainActor
final class RuntimeMetalResource {
    let device: MTLDevice
    let library: MTLLibrary

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }
}

private struct RuntimeFragmentUniforms {
    var timeAndResolution: SIMD4<Float>
    var baseColorA: SIMD4<Float>
    var baseColorB: SIMD4<Float>
    var bandParameters: SIMD4<Float>
    var bandColorAndStrength: SIMD4<Float>
    var columnParameters: SIMD4<Float>
    var columnColor: SIMD4<Float>
    var highlightColorAndStrength: SIMD4<Float>
    var highlightAndVignette: SIMD4<Float>
    var shimmerParameters: SIMD4<Float>
}

enum RuntimeThemeBackgroundRendererABI {
    static let expectedFragmentUniformByteCount = 160

    static var actualFragmentUniformByteCount: Int {
        MemoryLayout<RuntimeFragmentUniforms>.stride
    }

    static var isValid: Bool {
        actualFragmentUniformByteCount == expectedFragmentUniformByteCount
    }
}

private extension RuntimeThemeBackgroundColor {
    var fragmentColor: SIMD4<Float> {
        SIMD4(Float(red), Float(green), Float(blue), 0)
    }
}

private extension RuntimeThemeBackgroundParameters {
    func makeFragmentUniforms(
        time: Float,
        resolutionX: Float,
        resolutionY: Float
    ) -> RuntimeFragmentUniforms {
        RuntimeFragmentUniforms(
            timeAndResolution: SIMD4(time, resolutionX, resolutionY, 0),
            baseColorA: baseGradient[0].fragmentColor,
            baseColorB: baseGradient[1].fragmentColor,
            bandParameters: SIMD4(
                Float(bandFrequency),
                Float(bandTimeScale),
                Float(bandThreshold[0]),
                Float(bandThreshold[1])
            ),
            bandColorAndStrength: SIMD4(
                Float(bandColor.red),
                Float(bandColor.green),
                Float(bandColor.blue),
                Float(bandStrength)
            ),
            columnParameters: SIMD4(
                Float(columnFrequency),
                Float(columnTimeScale),
                Float(columnExponent),
                Float(columnStrength)
            ),
            columnColor: columnColor.fragmentColor,
            highlightColorAndStrength: SIMD4(
                Float(highlightColor.red),
                Float(highlightColor.green),
                Float(highlightColor.blue),
                Float(highlightStrength)
            ),
            highlightAndVignette: SIMD4(
                Float(highlightExponent),
                Float(vignetteStrength),
                0,
                0
            ),
            shimmerParameters: SIMD4(
                Float(shimmerTimeScale),
                Float(shimmerFrequency),
                Float(shimmerStrength),
                0
            )
        )
    }
}

@MainActor
private final class RuntimeMetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let uniformsBuffer: MTLBuffer
    private let parameters: RuntimeThemeBackgroundParameters
    private let startDate = Date()

    init?(
        resource: RuntimeMetalResource,
        parameters: RuntimeThemeBackgroundParameters
    ) {
        guard RuntimeThemeBackgroundRendererABI.isValid else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThemeBackground"
        descriptor.vertexFunction = resource.library.makeFunction(
            name: "vertex_fullscreen"
        )
        descriptor.fragmentFunction = resource.library.makeFunction(
            name: "fragment_rune_background"
        )
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard descriptor.vertexFunction != nil,
              descriptor.fragmentFunction != nil,
              let commandQueue = resource.device.makeCommandQueue(),
              let pipelineState = try? resource.device.makeRenderPipelineState(
                  descriptor: descriptor
              ),
              let uniformsBuffer = resource.device.makeBuffer(
                  length: MemoryLayout<RuntimeFragmentUniforms>.stride,
                  options: .storageModeShared
              )
        else { return nil }

        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.uniformsBuffer = uniformsBuffer
        self.parameters = parameters
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(
                  descriptor: renderPassDescriptor
              ),
              let drawable = view.currentDrawable
        else { return }

        var uniforms = parameters.makeFragmentUniforms(
            time: Float(Date().timeIntervalSince(startDate)),
            resolutionX: Float(view.drawableSize.width),
            resolutionY: Float(view.drawableSize.height)
        )
        memcpy(
            uniformsBuffer.contents(),
            &uniforms,
            MemoryLayout<RuntimeFragmentUniforms>.stride
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private struct RuntimeMetalSurface {
    let resource: RuntimeMetalResource
    let parameters: RuntimeThemeBackgroundParameters

    @MainActor
    func makeCoordinator() -> RuntimeMetalRenderer? {
        RuntimeMetalRenderer(
            resource: resource,
            parameters: parameters
        )
    }

    @MainActor
    fileprivate func makeMetalView(
        _ coordinator: RuntimeMetalRenderer?
    ) -> MTKView {
        let view = MTKView(frame: .zero, device: resource.device)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(
            red: parameters.baseGradient[0].red,
            green: parameters.baseGradient[0].green,
            blue: parameters.baseGradient[0].blue,
            alpha: 1
        )
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = coordinator
        return view
    }

    @MainActor
    fileprivate static func dismantle(_ view: MTKView) {
        view.isPaused = true
        view.delegate = nil
        view.device = nil
    }
}

#if os(macOS)
extension RuntimeMetalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        makeMetalView(context.coordinator)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: RuntimeMetalRenderer?) {
        dismantle(nsView)
    }
}
#elseif os(iOS)
extension RuntimeMetalSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        makeMetalView(context.coordinator)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: RuntimeMetalRenderer?) {
        dismantle(uiView)
    }
}
#endif

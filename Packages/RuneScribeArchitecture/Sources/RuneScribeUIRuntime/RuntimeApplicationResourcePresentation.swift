import AVFoundation
import Foundation
import ImageIO
import Metal
import MetalKit
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
}

enum RuntimeThemeDecodedResourceError: Error, Equatable, Sendable {
    case emptyData
    case encodedDataTooLarge
    case unsupportedImage
    case invalidPixelDimensions
    case unsupportedPixelDepth
    case decodedResourceTooLarge
}

struct RuntimeThemeDecodedImageHandle: Sendable {
    fileprivate enum Kind: Sendable {
        case raster
        case pdf
    }

    fileprivate let encodedData: Data
    fileprivate let kind: Kind
    let encodedByteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let decodedByteCount: Int

    fileprivate var key: Data { encodedData }
}

@MainActor
final class RuntimeThemeDecodedResourceCache: ObservableObject {
    static let maximumEncodedImageByteCount = 8 * 1_024 * 1_024
    static let maximumPixelDimension = 4_096
    static let maximumDecodedByteCount = 64 * 1_024 * 1_024
    static let maximumEntryCount = 512
    private struct Entry {
        let image: CGImage?
        let decodedByteCount: Int
        var accessOrder: UInt64
    }

    private let decodedByteLimit: Int
    private let entryLimit: Int
    private var entries: [Data: Entry] = [:]
    private var retainedKeyCounts: [Data: Int] = [:]
    private var accessOrder: UInt64 = 0
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private(set) var totalDecodedByteCount = 0
    private(set) var decodedImageCreationCount = 0
    private(set) var decodedImageValidationCount = 0

    var entryCount: Int { entries.count }

    var decodedImageCount: Int {
        entries.values.lazy.filter { $0.image != nil }.count
    }

    init(
        maximumDecodedByteCount: Int = RuntimeThemeDecodedResourceCache
            .maximumDecodedByteCount,
        maximumEntryCount: Int = RuntimeThemeDecodedResourceCache.maximumEntryCount
    ) {
        precondition(maximumDecodedByteCount > 0)
        precondition(maximumEntryCount > 0)
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
            kind = .pdf
            dimensions = try Self.pdfPixelDimensions(data: data)
        } else {
            guard Self.supportedRasterTypes.contains(type) else {
                throw RuntimeThemeDecodedResourceError.unsupportedImage
            }
            kind = .raster
            dimensions = try Self.rasterPixelDimensions(source: source)
        }
        let decodedByteCount = try Self.validatedDecodedByteCount(
            width: dimensions.width,
            height: dimensions.height
        )
        return RuntimeThemeDecodedImageHandle(
            encodedData: data,
            kind: kind,
            encodedByteCount: data.count,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            decodedByteCount: decodedByteCount
        )
    }

    func image(for data: Data) -> Image? {
        guard let handle = try? prepareImage(data: data) else { return nil }
        return image(for: handle)
    }

    func image(for handle: RuntimeThemeDecodedImageHandle) -> Image? {
        if var entry = entries[handle.key] {
            entry.accessOrder = nextAccessOrder()
            entries[handle.key] = entry
            return entry.image.map(Self.swiftUIImage)
        }
        guard handle.decodedByteCount <= decodedByteLimit else {
            insertFailure(for: handle.key)
            return nil
        }

        evictToFit(decodedByteCount: handle.decodedByteCount)
        guard let decodedImage = decode(handle) else {
            insertFailure(for: handle.key)
            return nil
        }
        let actualByteCount = max(
            handle.decodedByteCount,
            Self.byteCount(of: decodedImage) ?? Int.max
        )
        guard actualByteCount <= decodedByteLimit else {
            insertFailure(for: handle.key)
            return nil
        }
        evictToFit(decodedByteCount: actualByteCount)
        entries[handle.key] = Entry(
            image: decodedImage,
            decodedByteCount: actualByteCount,
            accessOrder: nextAccessOrder()
        )
        totalDecodedByteCount += actualByteCount
        decodedImageCreationCount += 1
        return Self.swiftUIImage(decodedImage)
    }

    func validateImage(_ handle: RuntimeThemeDecodedImageHandle) -> Bool {
        guard handle.decodedByteCount <= decodedByteLimit else { return false }
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
                removeEntry(for: key)
            }
        }
    }

    func purge() {
        entries.removeAll(keepingCapacity: false)
        totalDecodedByteCount = 0
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
        switch handle.kind {
        case .raster:
            let options = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithData(
                handle.encodedData as CFData,
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
            return Self.decodePDF(handle)
        }
    }

    private static func decodePDF(
        _ handle: RuntimeThemeDecodedImageHandle
    ) -> CGImage? {
        guard let provider = CGDataProvider(
            data: handle.encodedData as CFData
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

    private func insertFailure(for key: Data) {
        evictToFit(decodedByteCount: 0)
        entries[key] = Entry(
            image: nil,
            decodedByteCount: 0,
            accessOrder: nextAccessOrder()
        )
    }

    private func evictToFit(decodedByteCount: Int) {
        while entries.count >= entryLimit
            || totalDecodedByteCount > decodedByteLimit - decodedByteCount {
            guard let leastRecentlyUsed = entries.min(
                by: { $0.value.accessOrder < $1.value.accessOrder }
            )?.key else { break }
            removeEntry(for: leastRecentlyUsed)
        }
    }

    private func removeEntry(for key: Data) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalDecodedByteCount -= removed.decodedByteCount
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
private struct RuntimeThemeBackgroundImage {
    let handle: RuntimeThemeDecodedImageHandle

    init?(
        data: Data,
        cache: RuntimeThemeDecodedResourceCache
    ) {
        guard let handle = try? cache.prepareImage(data: data),
              cache.validateImage(handle)
        else { return nil }
        self.handle = handle
    }

    func image(using cache: RuntimeThemeDecodedResourceCache) -> Image? {
        cache.image(for: handle)
    }
}

private struct RuntimeThemeBackgroundConfiguration {
    let staticBase: RuntimeThemeBackgroundImage
    let reduceMotion: RuntimeThemeBackgroundImage
    let highContrast: RuntimeThemeBackgroundImage
    let parameters: RuntimeThemeBackgroundParameters?

    var imageHandles: [RuntimeThemeDecodedImageHandle] {
        [staticBase.handle, reduceMotion.handle, highContrast.handle]
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

    public func installThemeBackground(
        staticBaseData: Data,
        reduceMotionData: Data,
        highContrastData: Data,
        rendererParametersData: Data?
    ) throws {
        guard !isClosed else {
            throw RuntimeThemeBackgroundInstallationError.presentationClosed
        }
        guard let staticBase = RuntimeThemeBackgroundImage(
            data: staticBaseData,
            cache: decodedResourceCache
        ) else {
            clearThemeBackground()
            throw RuntimeThemeBackgroundInstallationError.invalidStaticBaseData
        }
        guard let reduceMotion = RuntimeThemeBackgroundImage(
            data: reduceMotionData,
            cache: decodedResourceCache
        ) else {
            clearThemeBackground()
            throw RuntimeThemeBackgroundInstallationError.invalidReduceMotionData
        }
        guard let highContrast = RuntimeThemeBackgroundImage(
            data: highContrastData,
            cache: decodedResourceCache
        ) else {
            clearThemeBackground()
            throw RuntimeThemeBackgroundInstallationError.invalidHighContrastData
        }

        let staticConfiguration = RuntimeThemeBackgroundConfiguration(
            staticBase: staticBase,
            reduceMotion: reduceMotion,
            highContrast: highContrast,
            parameters: nil
        )
        let parameters: RuntimeThemeBackgroundParameters?
        if let rendererParametersData {
            do {
                parameters = try RuntimeThemeBackgroundParameters.decode(
                    from: rendererParametersData
                )
            } catch {
                installThemeBackgroundConfiguration(staticConfiguration)
                throw error
            }
        } else {
            parameters = nil
        }

        installThemeBackgroundConfiguration(
            RuntimeThemeBackgroundConfiguration(
                staticBase: staticBase,
                reduceMotion: reduceMotion,
                highContrast: highContrast,
                parameters: parameters
            )
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
        _ configuration: RuntimeThemeBackgroundConfiguration
    ) {
        let replacedHandles = themeBackgroundConfiguration?.imageHandles ?? []
        decodedResourceCache.retain(configuration.imageHandles)
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

import CoreGraphics
import Foundation

enum RuntimePDFResourceValidation {
    static func singlePageDimensions(
        _ data: Data
    ) -> (width: Double, height: Double)? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages == 1,
              let page = document.page(at: 1)
        else { return nil }
        let bounds = page.getBoxRect(.mediaBox)
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }
}

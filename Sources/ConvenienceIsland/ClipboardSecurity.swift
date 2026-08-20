import AppKit
import Foundation
import ImageIO

enum ClipboardSecurity {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @discardableResult
    static func writeSecret(_ value: String, to pasteboard: NSPasteboard) -> Int {
        let item = secretItem(value)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    static func secretItem(_ value: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setString("", forType: concealedType)
        item.setString("", forType: transientType)
        return item
    }

    static func isAllowedImageData(_ data: Data, byteLimit: Int, pixelLimit: Int) -> Bool {
        guard !data.isEmpty,
              data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        let widthValue = width.intValue
        let heightValue = height.intValue
        guard widthValue > 0, heightValue > 0 else { return false }
        let (pixels, overflow) = widthValue.multipliedReportingOverflow(by: heightValue)
        return !overflow && pixels <= pixelLimit
    }
}

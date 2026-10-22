import AppKit
import ImageIO
import NotchCore

/// The user's Codex pet as the agents' house draws it: the spritesheet scaled down to small cells, as a PNG data URL
/// for `room.setCodexPet`. Without a pet the page keeps its own drawn robot for Codex agents.
enum RoomCodexPet {
    /// A cell's width in the scaled sheet; its height keeps the sheet's own proportions (192 x 208 → 48 x 52).
    static let cellWidth = 48

    /// What identifies the pet on disk, so an unchanged one is not decoded again.
    static func stamp(_ pet: CodexPet) -> String {
        let date = (try? pet.sheet.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return pet.id + "|" + pet.sheet.path + "|" + String(date.timeIntervalSince1970)
    }

    /// `room.setCodexPet(...)`'s argument, or nil when the sheet cannot be read.
    static func payload(_ pet: CodexPet) -> String? {
        guard let source = CGImageSourceCreateWithURL(pet.sheet as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= CodexPet.columns * 8, image.height >= CodexPet.rows * 8 else { return nil }
        let cw = cellWidth
        let ch = max(8, Int((Double(image.height) / Double(CodexPet.rows)) / (Double(image.width) / Double(CodexPet.columns)) * Double(cw)))
        let w = cw * CodexPet.columns, h = ch * CodexPet.rows
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) else { return nil }
        let obj: [String: Any] = ["src": "data:image/png;base64," + png.base64EncodedString(), "cols": CodexPet.columns, "rows": CodexPet.rows,
                                  "cw": cw, "ch": ch, "name": pet.name]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

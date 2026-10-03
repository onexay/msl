// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import ImageIO
import MSLCore
import UniformTypeIdentifiers

/// Distro logos in Finder. WSL images declare a Windows icon in
/// /etc/wsl-distribution.conf (`[shortcut] icon = /usr/share/wsl/ubuntu.ico`).
/// msld converts it to .icns and gives the distro's ~/.msl/distros volume a custom icon
/// (`.VolumeIcon.icns` plus the FinderInfo "has custom icon" flag). Both live in
/// the guest's in-memory metadata store (nfsview.rs), never in the distro image.
enum DistroIcon {
    static func apply(record: DistroRecord, volume: URL) {
        guard let icon = iconPath(volume: volume) else { return }
        let src = volume.appendingPathComponent(String(icon.drop(while: { $0 == "/" })))
        guard let icns = icns(from: src) else {
            log("icon: could not convert \(icon) for \(record.name)")
            return
        }
        do {
            try icns.write(to: volume.appendingPathComponent(".VolumeIcon.icns"))
            setCustomIconFlag(volume)
            log("icon: \(record.name) uses \(icon)")
        } catch {
            log("icon: \(record.name): \(error.localizedDescription)")
        }
    }

    /// `[shortcut] icon` from the distro's /etc/wsl-distribution.conf.
    static func iconPath(volume: URL) -> String? {
        guard let text = try? String(contentsOf: volume.appendingPathComponent("etc/wsl-distribution.conf"), encoding: .utf8) else { return nil }
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            if section == "[shortcut]", let eq = line.firstIndex(of: "="),
               line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "icon" {
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// An .icns (16…512 px) from the largest frame of an .ico/.png.
    static func icns(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let best = (0..<count).max { a, b in width(source, a) < width(source, b) } ?? 0
        guard let image = CGImageSourceCreateImageAtIndex(source, best, nil) else { return nil }
        let out = NSMutableData()
        let sizes = [16, 32, 64, 128, 256, 512]
        guard let dest = CGImageDestinationCreateWithData(out, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for s in sizes {
            guard let scaled = scale(image, to: s) else { return nil }
            CGImageDestinationAddImage(dest, scaled, nil)
        }
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func width(_ source: CGImageSource, _ i: Int) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        return props?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    private static func scale(_ image: CGImage, to size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    /// FinderInfo with kHasCustomIcon (0x0400 in the Finder flags at offset 8).
    private static func setCustomIconFlag(_ url: URL) {
        var info = [UInt8](repeating: 0, count: 32)
        _ = info.withUnsafeMutableBytes { getxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        info[8] |= 0x04
        _ = info.withUnsafeBytes { setxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
    }
}

#!/usr/bin/env swift
import AppKit
import Foundation

/// TokenMon mascot on a full-bleed off-white square — visible in Spotlight / Finder
/// (pure black-on-white is stored as Monochrome and IconServices mounts a gray plate).
/// macOS applies the squircle mask, so the canvas is full-bleed with square corners.

func sourceImageURL() -> URL {
    let besideScript = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .appendingPathComponent("app-icon-source.png")
    if FileManager.default.fileExists(atPath: besideScript.path) {
        return besideScript
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Scripts/app-icon-source.png")
}

func loadSource() -> NSImage {
    let url = sourceImageURL()
    guard let image = NSImage(contentsOf: url) else {
        fputs("Missing source icon at \(url.path)\n", stderr)
        exit(1)
    }
    return image
}

func containedRect(imageSize: NSSize, in dest: NSRect) -> NSRect {
    let scale = min(dest.width / imageSize.width, dest.height / imageSize.height)
    let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return NSRect(
        x: dest.midX - drawSize.width / 2,
        y: dest.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
}

func drawIcon(size: Int, source: NSImage, path: String) {
    let pixels = CGFloat(size)
    let bytesPerPixel = 4
    let bytesPerRow = size * bytesPerPixel

    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Failed to create context for \(size)\n", stderr)
        return
    }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixels, height: pixels)).fill()

    // Keep the mascot inside the squircle safe area.
    let padding = pixels * 0.10
    let dest = NSRect(
        x: padding,
        y: padding,
        width: pixels - padding * 2,
        height: pixels - padding * 2
    )
    source.draw(
        in: containedRect(imageSize: source.size, in: dest),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    // Remap luminance onto a cool off-white + near-black so actool keeps RGB.
    let bgR: CGFloat = 0.995, bgG: CGFloat = 0.997, bgB: CGFloat = 1.0
    let inkR: CGFloat = 0.02, inkG: CGFloat = 0.02, inkB: CGFloat = 0.04
    guard let data = ctx.data else {
        fputs("Failed to read pixels for \(size)\n", stderr)
        return
    }
    let buffer = data.bindMemory(to: UInt8.self, capacity: size * bytesPerRow)
    for y in 0..<size {
        let row = y * bytesPerRow
        for x in 0..<size {
            let o = row + x * bytesPerPixel
            let r = CGFloat(buffer[o]) / 255
            let g = CGFloat(buffer[o + 1]) / 255
            let b = CGFloat(buffer[o + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let t = 1 - luma
            buffer[o]     = UInt8(((bgR * (1 - t) + inkR * t) * 255).rounded())
            buffer[o + 1] = UInt8(((bgG * (1 - t) + inkG * t) * 255).rounded())
            buffer[o + 2] = UInt8(((bgB * (1 - t) + inkB * t) * 255).rounded())
            buffer[o + 3] = 255
        }
    }

    guard let cgImage = ctx.makeImage() else {
        fputs("Failed to make image for \(size)\n", stderr)
        return
    }

    // Flattens to an opaque RGB PNG for IconServices.
    guard let rgbCtx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fputs("Failed to create opaque context for \(size)\n", stderr)
        return
    }
    rgbCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let opaque = rgbCtx.makeImage() else {
        fputs("Failed to make opaque image for \(size)\n", stderr)
        return
    }

    let rep = NSBitmapImageRep(cgImage: opaque)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to create PNG data for \(size)\n", stderr)
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("Saved \(path) (\(size)x\(size))")
    } catch {
        fputs("Failed to write \(path): \(error)\n", stderr)
    }
}

let sizes: [(size: Int, name: String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let source = loadSource()
for (pixels, name) in sizes {
    drawIcon(size: pixels, source: source, path: "\(outputDir)/\(name).png")
}

print("All icons generated to \(outputDir)")

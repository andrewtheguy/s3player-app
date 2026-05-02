#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let defaultCanvasSize = 1024

struct Contents: Encodable {
    let images: [IconImage]
    let info: Info
}

struct IconImage: Encodable {
    let appearances: [Appearance]?
    let filename: String
    let idiom: String
    let platform: String?
    let scale: String?
    let size: String
}

struct Appearance: Encodable {
    let appearance: String
    let value: String
}

struct Info: Encodable {
    let author: String
    let version: Int
}

struct MacIconSpec {
    let filename: String
    let size: String
    let scale: String
    let pixels: Int
}

let macIcons = [
    MacIconSpec(filename: "mac-icon-16.png", size: "16x16", scale: "1x", pixels: 16),
    MacIconSpec(filename: "mac-icon-16@2x.png", size: "16x16", scale: "2x", pixels: 32),
    MacIconSpec(filename: "mac-icon-32.png", size: "32x32", scale: "1x", pixels: 32),
    MacIconSpec(filename: "mac-icon-32@2x.png", size: "32x32", scale: "2x", pixels: 64),
    MacIconSpec(filename: "mac-icon-128.png", size: "128x128", scale: "1x", pixels: 128),
    MacIconSpec(filename: "mac-icon-128@2x.png", size: "128x128", scale: "2x", pixels: 256),
    MacIconSpec(filename: "mac-icon-256.png", size: "256x256", scale: "1x", pixels: 256),
    MacIconSpec(filename: "mac-icon-256@2x.png", size: "256x256", scale: "2x", pixels: 512),
    MacIconSpec(filename: "mac-icon-512.png", size: "512x512", scale: "1x", pixels: 512),
    MacIconSpec(filename: "mac-icon-512@2x.png", size: "512x512", scale: "2x", pixels: 1024),
]

extension IconImage {
    init(filename: String, idiom: String, platform: String? = nil, scale: String? = nil, size: String, appearances: [Appearance]? = nil) {
        self.appearances = appearances
        self.filename = filename
        self.idiom = idiom
        self.platform = platform
        self.scale = scale
        self.size = size
    }
}

func absoluteURL(for path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    if url.path.hasPrefix("/") {
        return url
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

func defaultOutputDirectory() -> URL {
    let scriptURL = absoluteURL(for: CommandLine.arguments[0]).standardizedFileURL
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    return repoRoot.appendingPathComponent("s3player-app/Assets.xcassets/AppIcon.appiconset")
}

let outDir = CommandLine.arguments.count > 1
    ? absoluteURL(for: CommandLine.arguments[1]).standardizedFileURL
    : defaultOutputDirectory()

func makeContext(size: Int) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    return CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 4 * size,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func savePNG(_ context: CGContext, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

func drawPlayTriangle(in context: CGContext, size: Int, color: CGColor) {
    let s = CGFloat(size)
    let centerX = s / 2 + s * 0.04
    let centerY = s / 2
    let height = s * 0.40
    let width = height * (sqrt(3) / 2) * 1.05

    let path = CGMutablePath()
    path.move(to: CGPoint(x: centerX + width / 2, y: centerY))
    path.addLine(to: CGPoint(x: centerX - width / 2, y: centerY + height / 2))
    path.addLine(to: CGPoint(x: centerX - width / 2, y: centerY - height / 2))
    path.closeSubpath()

    context.saveGState()
    context.setFillColor(color)
    context.setStrokeColor(color)
    context.setLineJoin(.round)
    context.setLineWidth(s * 0.10)
    context.addPath(path)
    context.drawPath(using: .fillStroke)
    context.restoreGState()
}

func drawWaves(in context: CGContext, size: Int, color: CGColor) {
    let s = CGFloat(size)
    let centerX = s * 0.38
    let centerY = s / 2

    context.saveGState()
    context.setStrokeColor(color)
    context.setLineCap(.round)

    let baseRadius = s * 0.32
    for index in 0..<3 {
        let radius = baseRadius + CGFloat(index) * s * 0.055
        let alpha = 0.35 - CGFloat(index) * 0.10
        let arc = CGMutablePath()
        arc.addArc(
            center: CGPoint(x: centerX, y: centerY),
            radius: radius,
            startAngle: -.pi / 4,
            endAngle: .pi / 4,
            clockwise: false
        )

        context.setAlpha(alpha)
        context.setLineWidth(s * 0.018)
        context.addPath(arc)
        context.strokePath()
    }

    context.restoreGState()
}

func fillGradient(in context: CGContext, size: Int, top: CGColor, bottom: CGColor) {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )
}

func renderLight(filename: String, size: Int) {
    let context = makeContext(size: size)
    let top = CGColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1)
    let bottom = CGColor(red: 0.90, green: 0.18, blue: 0.30, alpha: 1)
    fillGradient(in: context, size: size, top: top, bottom: bottom)
    drawWaves(in: context, size: size, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    drawPlayTriangle(in: context, size: size, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    savePNG(context, to: outDir.appendingPathComponent(filename))
}

func renderDark() {
    let context = makeContext(size: defaultCanvasSize)
    let top = CGColor(red: 0.18, green: 0.13, blue: 0.40, alpha: 1)
    let bottom = CGColor(red: 0.05, green: 0.05, blue: 0.18, alpha: 1)
    fillGradient(in: context, size: defaultCanvasSize, top: top, bottom: bottom)
    drawWaves(in: context, size: defaultCanvasSize, color: CGColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1))
    drawPlayTriangle(in: context, size: defaultCanvasSize, color: CGColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1))
    savePNG(context, to: outDir.appendingPathComponent("icon-dark.png"))
}

func renderTinted() {
    let context = makeContext(size: defaultCanvasSize)
    context.clear(CGRect(x: 0, y: 0, width: defaultCanvasSize, height: defaultCanvasSize))
    drawWaves(in: context, size: defaultCanvasSize, color: CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
    drawPlayTriangle(in: context, size: defaultCanvasSize, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    savePNG(context, to: outDir.appendingPathComponent("icon-tinted.png"))
}

func writeContentsJSON() throws {
    let contents = Contents(
        images: [
            IconImage(filename: "icon-light.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                filename: "icon-dark.png",
                idiom: "universal",
                platform: "ios",
                size: "1024x1024",
                appearances: [Appearance(appearance: "luminosity", value: "dark")]
            ),
            IconImage(
                filename: "icon-tinted.png",
                idiom: "universal",
                platform: "ios",
                size: "1024x1024",
                appearances: [Appearance(appearance: "luminosity", value: "tinted")]
            ),
        ] + macIcons.map { icon in
            IconImage(filename: icon.filename, idiom: "mac", scale: icon.scale, size: icon.size)
        },
        info: Info(author: "xcode", version: 1)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(contents)
    data.append(0x0A)
    try data.write(to: outDir.appendingPathComponent("Contents.json"), options: .atomic)
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

renderLight(filename: "icon-light.png", size: defaultCanvasSize)
renderDark()
renderTinted()

for icon in macIcons {
    renderLight(filename: icon.filename, size: icon.pixels)
}

try writeContentsJSON()
print("rendered icons to \(outDir.path)")

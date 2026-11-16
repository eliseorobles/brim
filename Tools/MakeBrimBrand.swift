// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

// Generates Brim's artwork into Resources/Brand/, the folder the build reads
// the app icon, the adaptive icon and the menu bar glyph from. A design pass
// replaces these files later at the same paths; nothing else needs to change.
//
//   AppIcon-Default.png   1024 px app icon (the .icns and iconset are made
//                         from it at build time by Tools/MakeIcon.swift)
//   AppIcon.icon/         Icon Composer bundle compiled by actool into the
//                         adaptive (Liquid Glass) icon on macOS 26 and later
//   logo.png              the bare mark, black on transparent: the menu bar
//                         template glyph and the in-app BrandMark come from it
//
// The mark is a bowl filled to its brim under a wider rim bar. All three files
// are drawn from the one geometry below, so they always agree.
//
// Usage: swift Tools/MakeBrimBrand.swift [output-folder]
import AppKit

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : scriptDir.deletingLastPathComponent().appendingPathComponent("Resources/Brand")

// MARK: - Geometry (1024-unit canvas, y down, as in the SVG)

struct Mark {
    // The rim: a rounded bar wider than the bowl.
    static let rim = CGRect(x: 212, y: 310, width: 600, height: 56)
    static let rimRadius: CGFloat = 28
    // The bowl, filled to the brim: flat top, rounded bottom.
    static let bowlTop: CGFloat = 410
    static let bowlLeft: CGFloat = 262
    static let bowlRight: CGFloat = 762
    static let bowlShoulder: CGFloat = 580
    static let bowlBottom: CGFloat = 710

    static var svgPath: String {
        "M\(i(bowlLeft)) \(i(bowlTop)) H\(i(bowlRight)) "
            + "C\(i(bowlRight)) \(i(bowlShoulder)) 652 \(i(bowlBottom)) 512 \(i(bowlBottom)) "
            + "C372 \(i(bowlBottom)) \(i(bowlLeft)) \(i(bowlShoulder)) \(i(bowlLeft)) \(i(bowlTop)) Z"
    }

    private static func i(_ value: CGFloat) -> String { String(Int(value)) }

    /// The mark as AppKit paths in a y-up space of `size` points, scaled by
    /// `scale` about the canvas center.
    static func paths(size: CGFloat, scale: CGFloat = 1) -> [NSBezierPath] {
        let k = size / 1024 * scale
        let offset = (size - 1024 * k) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: offset + x * k, y: size - (offset + y * k))
        }
        let rimRect = NSRect(x: offset + rim.minX * k, y: size - (offset + rim.maxY * k),
                             width: rim.width * k, height: rim.height * k)
        let rimPath = NSBezierPath(roundedRect: rimRect, xRadius: rimRadius * k, yRadius: rimRadius * k)
        let bowl = NSBezierPath()
        bowl.move(to: p(bowlLeft, bowlTop))
        bowl.line(to: p(bowlRight, bowlTop))
        bowl.curve(to: p(512, bowlBottom), controlPoint1: p(bowlRight, bowlShoulder), controlPoint2: p(652, bowlBottom))
        bowl.curve(to: p(bowlLeft, bowlTop), controlPoint1: p(372, bowlBottom), controlPoint2: p(bowlLeft, bowlShoulder))
        bowl.close()
        return [rimPath, bowl]
    }
}

// Placeholder palette: deep blue to teal.
let topColor = NSColor(srgbRed: 0.18, green: 0.32, blue: 0.86, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.05, green: 0.66, blue: 0.70, alpha: 1)

// MARK: - Rendering

func canvas(_ px: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create a \(px) px canvas")
    }
    rep.size = NSSize(width: px, height: px)
    return (rep, ctx)
}

func render(_ px: Int, _ draw: (CGFloat) -> Void) -> Data {
    let (rep, ctx) = canvas(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    return data
}

/// The finished app icon: the macOS icon grid's 824-pt rounded body with a
/// soft shadow, the gradient, and the white mark.
let appIcon = render(1024) { size in
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    topColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: topColor, ending: bottomColor)?.draw(in: shape, angle: -90)
    NSColor.white.setFill()
    for path in Mark.paths(size: size, scale: 0.8) { path.fill() }
}

/// The bare mark for template use: only its alpha matters.
let logo = render(1024) { size in
    NSColor.black.setFill()
    for path in Mark.paths(size: size) { path.fill() }
}

func hex(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB)!
    return String(format: "%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
}

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect x="\(Int(Mark.rim.minX))" y="\(Int(Mark.rim.minY))" width="\(Int(Mark.rim.width))" \
height="\(Int(Mark.rim.height))" rx="\(Int(Mark.rimRadius))" fill="#FFFFFF"/>
  <path d="\(Mark.svgPath)" fill="#FFFFFF"/>
</svg>

"""

let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:\(hex(topColor))",
      "srgb:\(hex(bottomColor))"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "brim-mark.svg",
          "name" : "BrimMark",
          "position" : {
            "scale" : 1.0,
            "translation-in-points" : [ 0, 0 ]
          }
        }
      ],
      "name" : "Mark",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""

func write(_ data: Data, _ relative: String) throws {
    let url = outDir.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    if (try? Data(contentsOf: url)) != data {
        try data.write(to: url)
    }
    print("  \(url.path)")
}

do {
    print("Brim brand artwork:")
    try write(appIcon, "AppIcon-Default.png")
    try write(logo, "logo.png")
    try write(Data(svg.utf8), "AppIcon.icon/Assets/brim-mark.svg")
    try write(Data(iconJSON.utf8), "AppIcon.icon/icon.json")
} catch {
    FileHandle.standardError.write(Data("MakeBrimBrand: \(error)\n".utf8))
    exit(1)
}

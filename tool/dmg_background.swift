// Renders the DMG installer background (660x460): light gradient,
// drag arrow, copyright line.
// Layout (top-left origin) matches the Finder window configured by
// tool/make_dmg.sh:
//   app icon 101..229 x / Applications 431..559 x, icons y 166..294
//   arrow centered on x=330 at icon-center height y=230, copyright y~316
// Usage: swift tool/dmg_background.swift <out.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift dmg_background.swift <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let W = 660.0, H = 460.0
let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocusFlipped(true)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Light vertical gradient backdrop.
let top = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)
let bottom = NSColor(calibratedRed: 0.84, green: 0.87, blue: 0.93, alpha: 1)
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [top.cgColor, bottom.cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: H), options: [])

// Arrow: curved swoosh from the app icon toward Applications.
// Centered around x=270, y=170.
let accent = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1)
ctx.setStrokeColor(accent.cgColor)
ctx.setFillColor(accent.cgColor)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Shaft: gentle S-curve.
ctx.setLineWidth(8)
ctx.move(to: CGPoint(x: 234, y: 184))
ctx.addCurve(to: CGPoint(x: 280, y: 178), control1: CGPoint(x: 250, y: 168), control2: CGPoint(x: 266, y: 170))
ctx.strokePath()

// Head: curved chevron instead of a solid triangle.
ctx.setLineWidth(8)
ctx.move(to: CGPoint(x: 284, y: 166))
ctx.addQuadCurve(to: CGPoint(x: 297, y: 178), control: CGPoint(x: 290, y: 170))
ctx.addQuadCurve(to: CGPoint(x: 284, y: 189), control: CGPoint(x: 290, y: 186))
ctx.strokePath()

let para = NSMutableParagraphStyle()
para.alignment = .center

// Copyright line just below the icons (icons span y 166..294).
let copyright = NSAttributedString(string: "Copyright © sudo8.com", attributes: [
    .font: NSFont.systemFont(ofSize: 17, weight: .regular),
    .foregroundColor: NSColor.black.withAlphaComponent(0.55),
    .paragraphStyle: para,
])
copyright.draw(in: NSRect(x: 70, y: 308, width: 400, height: 24))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("error: png encode failed\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: args[1]))
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

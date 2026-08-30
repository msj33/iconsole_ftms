import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_app_icon.swift <output-png-path>\n", stderr)
    exit(2)
}

let outputPath = CommandLine.arguments[1]
let canvasSize: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize))

image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Could not create graphics context.\n", stderr)
    exit(3)
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let outerRect = NSRect(x: 64, y: 64, width: canvasSize - 128, height: canvasSize - 128)
let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 210, yRadius: 210)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.34, green: 0.14, blue: 0.78, alpha: 1.0),
    NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.56, alpha: 1.0),
    NSColor(calibratedRed: 0.02, green: 0.07, blue: 0.21, alpha: 1.0)
])
gradient?.draw(in: outerPath, relativeCenterPosition: NSPoint(x: -0.35, y: 0.85))

let glowTop = NSBezierPath(ovalIn: NSRect(x: 220, y: 620, width: 420, height: 320))
NSColor(calibratedRed: 0.98, green: 0.27, blue: 0.95, alpha: 0.18).setFill()
glowTop.fill()

let glowBottom = NSBezierPath(ovalIn: NSRect(x: 360, y: 160, width: 520, height: 330))
NSColor(calibratedRed: 0.10, green: 0.82, blue: 0.99, alpha: 0.18).setFill()
glowBottom.fill()

NSColor(calibratedWhite: 1.0, alpha: 0.22).setStroke()
outerPath.lineWidth = 14
outerPath.stroke()

func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

let wheelColor = NSColor(calibratedRed: 0.11, green: 0.83, blue: 1.0, alpha: 0.98)
let accentWheelColor = NSColor(calibratedRed: 0.99, green: 0.34, blue: 0.89, alpha: 0.95)
let frameColor = NSColor(calibratedRed: 0.84, green: 0.93, blue: 1.0, alpha: 0.98)

let leftWheelOuter = NSBezierPath(ovalIn: NSRect(x: 170, y: 210, width: 280, height: 280))
let rightWheelOuter = NSBezierPath(ovalIn: NSRect(x: 574, y: 210, width: 280, height: 280))
stroke(leftWheelOuter, color: wheelColor, width: 28)
stroke(rightWheelOuter, color: wheelColor, width: 28)

let leftWheelInner = NSBezierPath(ovalIn: NSRect(x: 216, y: 256, width: 188, height: 188))
let rightWheelInner = NSBezierPath(ovalIn: NSRect(x: 620, y: 256, width: 188, height: 188))
stroke(leftWheelInner, color: accentWheelColor, width: 10)
stroke(rightWheelInner, color: accentWheelColor, width: 10)

let frame = NSBezierPath()
frame.move(to: NSPoint(x: 310, y: 350))
frame.line(to: NSPoint(x: 460, y: 530))
frame.line(to: NSPoint(x: 635, y: 530))
frame.line(to: NSPoint(x: 720, y: 350))
frame.move(to: NSPoint(x: 460, y: 530))
frame.line(to: NSPoint(x: 535, y: 350))
frame.move(to: NSPoint(x: 635, y: 530))
frame.line(to: NSPoint(x: 695, y: 615))
frame.move(to: NSPoint(x: 695, y: 615))
frame.line(to: NSPoint(x: 785, y: 650))
frame.move(to: NSPoint(x: 430, y: 560))
frame.line(to: NSPoint(x: 360, y: 615))
stroke(frame, color: frameColor, width: 26)

let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 548, y: 770))
bolt.line(to: NSPoint(x: 470, y: 770))
bolt.line(to: NSPoint(x: 555, y: 645))
bolt.line(to: NSPoint(x: 505, y: 645))
bolt.line(to: NSPoint(x: 586, y: 522))
bolt.line(to: NSPoint(x: 576, y: 620))
bolt.line(to: NSPoint(x: 636, y: 620))
bolt.close()
NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.27, alpha: 1.0).setFill()
bolt.fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let textAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 84, weight: .heavy),
    .foregroundColor: NSColor(calibratedRed: 0.79, green: 0.95, blue: 1.0, alpha: 0.92),
    .paragraphStyle: paragraph
]
let text = NSAttributedString(string: "iFTMS", attributes: textAttributes)
text.draw(in: NSRect(x: 0, y: 82, width: canvasSize, height: 100))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
    fputs("Could not encode PNG.\n", stderr)
    exit(4)
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true,
    attributes: nil
)
do {
    try png.write(to: outputURL)
} catch {
    fputs("Could not write PNG: \(error.localizedDescription)\n", stderr)
    exit(5)
}

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon.png"
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext
cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func gradient(_ path: NSBezierPath, _ top: UInt32, _ bottom: UInt32) {
    cg.saveGState()
    path.addClip()
    NSGradient(starting: color(top), ending: color(bottom))!.draw(in: path.bounds, angle: -90)
    cg.restoreGState()
}
let tile = NSBezierPath(roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848), xRadius: 190, yRadius: 190)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: color(0x17212B, 0.20).cgColor)
color(0xE9EDF0).setFill()
tile.fill()
cg.restoreGState()
gradient(tile, 0xFAFCFD, 0xDFE6EB)
color(0xFFFFFF, 0.85).setStroke()
tile.lineWidth = 3
tile.stroke()
let body = NSBezierPath(roundedRect: NSRect(x: 332, y: 170, width: 360, height: 684), xRadius: 142, yRadius: 142)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 26, color: color(0x0B1520, 0.32).cgColor)
color(0x18222D).setFill()
body.fill()
cg.restoreGState()
gradient(body, 0x364452, 0x18212B)
color(0xFFFFFF, 0.22).setStroke()
body.lineWidth = 3
body.stroke()
let inset = NSBezierPath(roundedRect: NSRect(x: 344, y: 182, width: 336, height: 660), xRadius: 132, yRadius: 132)
color(0x070C13, 0.45).setStroke()
inset.lineWidth = 2
inset.stroke()
for (y, top, bottom) in [
    (CGFloat(700), UInt32(0xFF7970), UInt32(0xED3F4B)), (CGFloat(512), UInt32(0xFFD56A), UInt32(0xF2A321)),
    (CGFloat(324), UInt32(0x62E5B1), UInt32(0x20B67E)),
] {
    let rim = NSBezierPath(ovalIn: NSRect(x: 432, y: y - 80, width: 160, height: 160))
    gradient(rim, 0x101821, 0x46525B)
    let well = NSBezierPath(ovalIn: NSRect(x: 438, y: y - 74, width: 148, height: 148))
    color(0x0C141C).setFill()
    well.fill()
    let lens = NSBezierPath(ovalIn: NSRect(x: 448, y: y - 64, width: 128, height: 128))
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 14, color: color(bottom, 0.32).cgColor)
    color(bottom).setFill()
    lens.fill()
    cg.restoreGState()
    gradient(lens, top, bottom)
    color(0xFFFFFF, 0.24).setStroke()
    lens.lineWidth = 2
    lens.stroke()
    color(0xFFFFFF, 0.42).setFill()
    NSBezierPath(ovalIn: NSRect(x: 477, y: y + 31, width: 49, height: 13)).fill()
}
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: url)
print("Created " + output)

import AppKit
import Foundation

// Draws the MyParrot app icon: a chibi parrot wearing headphones (matches the
// in-app mascot). build-app.sh / iconutil turn the .iconset into .icns.

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
    }
    // coordinates use a 32x32 space, y measured from TOP
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x/32*s, y: s - y/32*s) }
    func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: (cx-rx)/32*s, y: s-(cy+ry)/32*s, width: 2*rx/32*s, height: 2*ry/32*s)).fill()
    }
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) { oval(cx, cy, r, r, c) }
    func rrect(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rad: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: (cx-w/2)/32*s, y: s-(cy+h/2)/32*s, width: w/32*s, height: h/32*s),
                     xRadius: rad/32*s, yRadius: rad/32*s).fill()
    }
    func tri(_ a: NSPoint, _ b: NSPoint, _ cc: NSPoint, _ c: NSColor) {
        c.setFill(); let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.line(to: cc); p.close(); p.fill()
    }
    func band(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ lw: CGFloat, _ c: NSColor) {
        c.setStroke()
        let p = NSBezierPath()
        p.appendArc(withCenter: NSPoint(x: cx/32*s, y: s - cy/32*s), radius: rad/32*s, startAngle: 18, endAngle: 162)
        p.lineWidth = lw/32*s; p.lineCapStyle = .round; p.stroke()
    }

    let blue = col(55, 138, 221)
    let dark = col(40, 40, 38)

    // background: rounded square, light blue
    col(230, 241, 251).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s*0.22, yRadius: s*0.22).fill()

    // body + belly
    oval(16, 21, 9, 10, blue)
    oval(16, 23, 5.5, 7, col(181, 212, 245))
    // crest feathers
    tri(P(13, 2.5), P(15.5, 8), P(10.5, 8), col(239, 159, 39))
    tri(P(17, 2), P(19.5, 8), P(14.5, 8), col(186, 117, 23))
    // head
    circle(16, 12, 8, blue)
    // eyes
    circle(13, 11.5, 2, .white); circle(13.4, 11.8, 1, col(4, 44, 83))
    circle(19, 11.5, 2, .white); circle(18.6, 11.8, 1, col(4, 44, 83))
    // beak (apex down)
    tri(P(14.3, 14), P(17.7, 14), P(16, 18), col(216, 90, 48))
    // headphones: band + ear cups
    band(16, 12, 10, 1.8, dark)
    rrect(6.8, 13, 3, 5, 1.3, dark)
    rrect(25.2, 13, 3, 5, 1.3, dark)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in specs {
    if let data = draw(size: size) {
        try? data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
print("iconset 寫到 \(out)")

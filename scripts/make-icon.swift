// Draws Remora's app icon — a remora riding under a shark, on the Stoatworks navy — and writes
// Resources/AppIcon.icns. Drawn from scratch: the menu-bar icon is the SF Symbol `fish`, but
// Apple's SF Symbols licence does not allow them in app icons.
//
//   swift scripts/make-icon.swift              # writes Resources/AppIcon.icns
//   swift scripts/make-icon.swift preview.png  # also writes the 1024 px master there
import AppKit

let navy = NSColor(srgbRed: 0x0f / 255, green: 0x1b / 255, blue: 0x2d / 255, alpha: 1)
let navyLight = NSColor(srgbRed: 0x1d / 255, green: 0x33 / 255, blue: 0x52 / 255, alpha: 1)
let paper = NSColor(srgbRed: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf4 / 255, alpha: 1)
let cyan = NSColor(srgbRed: 0x4c / 255, green: 0xc9 / 255, blue: 0xf0 / 255, alpha: 1)

func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

/// The shark in scene points (the scene is placed on the tile in `render`): side on, snout to
/// the right, dorsal fin up, crescent tail at the left.
func sharkBody() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pt(905, 610))                                                            // snout
    p.curve(to: pt(760, 690), controlPoint1: pt(880, 660), controlPoint2: pt(830, 688))
    p.curve(to: pt(600, 704), controlPoint1: pt(700, 694), controlPoint2: pt(650, 700))
    p.curve(to: pt(505, 868), controlPoint1: pt(575, 760), controlPoint2: pt(535, 835))  // dorsal fin
    p.curve(to: pt(458, 700), controlPoint1: pt(488, 812), controlPoint2: pt(470, 750))
    p.curve(to: pt(232, 640), controlPoint1: pt(380, 690), controlPoint2: pt(300, 665))
    p.curve(to: pt(112, 800), controlPoint1: pt(190, 690), controlPoint2: pt(145, 755))  // upper lobe
    p.curve(to: pt(178, 615), controlPoint1: pt(140, 720), controlPoint2: pt(160, 655))
    p.curve(to: pt(128, 495), controlPoint1: pt(160, 575), controlPoint2: pt(142, 530))  // lower lobe
    p.curve(to: pt(238, 596), controlPoint1: pt(172, 540), controlPoint2: pt(210, 575))
    p.curve(to: pt(560, 546), controlPoint1: pt(330, 562), controlPoint2: pt(450, 538))  // belly
    p.curve(to: pt(840, 575), controlPoint1: pt(680, 554), controlPoint2: pt(780, 560))
    p.curve(to: pt(905, 610), controlPoint1: pt(880, 588), controlPoint2: pt(900, 600))
    p.close()
    return p
}

/// The shark's pectoral fin, swept back from under its head.
func sharkFin() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pt(660, 560))
    p.curve(to: pt(585, 418), controlPoint1: pt(640, 510), controlPoint2: pt(615, 455))
    p.curve(to: pt(752, 568), controlPoint1: pt(665, 450), controlPoint2: pt(720, 510))
    p.close()
    return p
}

/// Eye, gill slits and mouth, cut out of the shark in navy.
func sharkDetails() -> [(NSBezierPath, Bool)] {
    var out: [(NSBezierPath, Bool)] = [(NSBezierPath(ovalIn: NSRect(x: 818, y: 618, width: 22, height: 22)), true)]
    for x: CGFloat in [712, 738, 764] {
        let g = NSBezierPath()
        g.move(to: pt(x, 585))
        g.curve(to: pt(x + 4, 655), controlPoint1: pt(x - 9, 607), controlPoint2: pt(x - 7, 633))
        g.lineWidth = 9
        out.append((g, false))
    }
    let mouth = NSBezierPath()
    mouth.move(to: pt(878, 594))
    mouth.curve(to: pt(800, 582), controlPoint1: pt(850, 584), controlPoint2: pt(825, 580))
    mouth.lineWidth = 8
    out.append((mouth, false))
    return out
}

/// A remora in its own unit space: 1 long, nose at x = 1, tail at x = 0, back up.
func remoraBody() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pt(1.00, -0.010))                                                     // lower jaw, jutting
    p.curve(to: pt(0.95, 0.045), controlPoint1: pt(0.99, 0.020), controlPoint2: pt(0.975, 0.040))
    p.curve(to: pt(0.62, 0.085), controlPoint1: pt(0.85, 0.075), controlPoint2: pt(0.72, 0.085)) // the disc
    p.curve(to: pt(0.14, 0.022), controlPoint1: pt(0.45, 0.085), controlPoint2: pt(0.25, 0.040))
    p.line(to: pt(0.02, 0.105))                                                      // upper tail lobe
    p.curve(to: pt(0.07, 0.000), controlPoint1: pt(0.05, 0.060), controlPoint2: pt(0.07, 0.030))
    p.curve(to: pt(0.02, -0.105), controlPoint1: pt(0.07, -0.030), controlPoint2: pt(0.05, -0.060))
    p.line(to: pt(0.14, -0.022))                                                     // lower tail lobe
    p.curve(to: pt(0.55, -0.075), controlPoint1: pt(0.27, -0.045), controlPoint2: pt(0.42, -0.075))
    p.curve(to: pt(0.93, -0.040), controlPoint1: pt(0.72, -0.075), controlPoint2: pt(0.86, -0.060))
    p.curve(to: pt(1.00, -0.010), controlPoint1: pt(0.96, -0.030), controlPoint2: pt(0.99, -0.020))
    p.close()
    return p
}

/// The long second dorsal fin and the anal fin facing it, towards the tail.
func remoraFins() -> [NSBezierPath] {
    let dorsal = NSBezierPath()
    dorsal.move(to: pt(0.50, 0.066))
    dorsal.curve(to: pt(0.22, 0.048), controlPoint1: pt(0.45, 0.112), controlPoint2: pt(0.28, 0.104))
    dorsal.line(to: pt(0.20, 0.030))
    dorsal.close()
    let anal = NSBezierPath()
    anal.move(to: pt(0.48, -0.062))
    anal.curve(to: pt(0.22, -0.046), controlPoint1: pt(0.43, -0.108), controlPoint2: pt(0.28, -0.100))
    anal.line(to: pt(0.20, -0.028))
    anal.close()
    return [dorsal, anal]
}

/// The sucking disc's slats along the top of the head, the eye, mouth and a pectoral fin.
func remoraDetails() -> [(NSBezierPath, Bool)] {
    var out: [(NSBezierPath, Bool)] = []
    for i in 0..<8 {
        let x = 0.66 + CGFloat(i) * 0.034
        let top = 0.085 - (x - 0.62) / (0.95 - 0.62) * 0.040   // the head's top line, roughly
        let s = NSBezierPath()
        s.move(to: pt(x, top - 0.004))
        s.line(to: pt(x + 0.006, top - 0.026))
        s.lineWidth = 0.010
        out.append((s, false))
    }
    out.append((NSBezierPath(ovalIn: NSRect(x: 0.868, y: -0.006, width: 0.034, height: 0.034)), true))
    let mouth = NSBezierPath()
    mouth.move(to: pt(0.985, -0.012))
    mouth.line(to: pt(0.925, -0.018))
    mouth.lineWidth = 0.009
    out.append((mouth, false))
    let pec = NSBezierPath()
    pec.move(to: pt(0.80, -0.030))
    pec.curve(to: pt(0.69, -0.058), controlPoint1: pt(0.76, -0.034), controlPoint2: pt(0.72, -0.048))
    pec.lineWidth = 0.012
    out.append((pec, false))
    return out
}

func drawCutouts(_ items: [(NSBezierPath, Bool)], _ t: AffineTransform?, scale: CGFloat) {
    navy.set()
    for (path, filled) in items {
        let p = path.copy() as! NSBezierPath
        if let t { p.transform(using: t) }
        if filled { p.fill() } else { p.lineWidth = path.lineWidth * scale; p.lineCapStyle = .round; p.stroke() }
    }
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)   // draw in 1024-point space at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // The macOS icon grid: an 824 pt rounded square inset 100 pt, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    navy.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: navyLight, ending: navy)!.draw(in: tilePath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()

    // The scene, scaled and moved so the shark and remora sit in the middle of the tile.
    let scene = NSAffineTransform()
    scene.translateX(by: 512, yBy: 512)
    scene.scale(by: 0.9)
    scene.translateX(by: -508, yBy: -640)
    scene.concat()

    // The shark first, then the remora on top with a navy border, so the two read apart.
    cyan.setFill()
    sharkBody().fill()
    sharkFin().fill()
    drawCutouts(sharkDetails(), nil, scale: 1)

    // Under the shark's belly, its disc against it.
    var t = AffineTransform(translationByX: 262, byY: 512)
    t.rotate(byDegrees: -1.5)
    t.scale(400)
    let parts = [remoraBody()] + remoraFins()
    for part in parts { part.transform(using: t) }
    navy.setStroke()
    for part in parts { part.lineWidth = 18; part.lineJoinStyle = .round; part.stroke() }
    paper.setFill()
    for part in parts { part.fill() }
    drawCutouts(remoraDetails(), t, scale: 400)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("RemoraIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
if CommandLine.arguments.count > 1 {
    try! render(1024).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")

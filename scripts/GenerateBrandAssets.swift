// ============================================================================
// GenerateBrandAssets — the single source of truth for VibeRouter's brand marks.
//
// There is no rasterizer on the build machines (no rsvg-convert / magick /
// cairosvg), so the artwork is defined here as CoreGraphics drawing code and
// rendered on demand. Run it to regenerate every brand asset at once:
//
//   swiftc -O -o /tmp/genbrand scripts/GenerateBrandAssets.swift && /tmp/genbrand
//
// The mark is a "converge" glyph: three provider lines funnel into one line
// that terminates in a port dot — VibeRouter multiplexing many AI providers onto
// one local port. Everything is derived from one geometry definition so the
// Dock icon, the menu bar template, the About chip, the web BrandMark, and the
// favicons cannot drift apart.
//
// It also writes build/preview.png, a contact sheet of every asset at its true
// pixel size (plus a 3x pixel-exact blowup) for eyeballing before committing.
// ============================================================================
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

/// Matches --accent / --accent-hi in management-ui/src/styles/app.css, widened
/// at both ends so the fill reads as a gradient rather than a flat block.
enum Palette {
    static let top = CGColor(srgbRed: 139 / 255, green: 132 / 255, blue: 1.0, alpha: 1)
    static let bottom = CGColor(srgbRed: 87 / 255, green: 78 / 255, blue: 216 / 255, alpha: 1)
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
}

// MARK: - Glyph geometry

/// The mark, on a 100x100 design grid with y growing downward.
///
/// Several variants, because thin strokes and a fine fan stop resolving as the
/// displayed size drops. They are the *same* mark throughout — three lines
/// merging into one — progressively coarsened rather than replaced, so the
/// family resemblance holds from 16px to 1024px. See `styleFor(display:)`.
struct GlyphStyle {
    var stroke: CGFloat
    /// Vertical distance from the centre line to the outer input lines.
    var spread: CGFloat
    /// x where the outer inputs stop running straight and begin curving in.
    var flexX: CGFloat
    /// x where all three inputs have become one line.
    var mergeX: CGFloat
    var lineStartX: CGFloat
    var dotX: CGFloat
    /// 0 omits the port dot entirely (the 16pt slots, where it cannot resolve).
    var dotRadius: CGFloat
    var fan: Bool
    /// Fraction of the badge's inner square the mark occupies. Smaller marks
    /// need more of it to stay legible.
    var markScale: CGFloat
    /// Merge the outer inputs with a straight diagonal instead of an S-curve.
    /// The curve's gentle tangents smear across a handful of pixels, so at 16px
    /// a hard diagonal is what actually stays readable.
    var straightMerge: Bool = false
    /// Idle state: the port dot becomes a ring instead of a disc.
    var hollowDot: Bool = false

    static let full = GlyphStyle(
        stroke: 9, spread: 28, flexX: 32, mergeX: 54,
        lineStartX: 10, dotX: 82, dotRadius: 9, fan: true, markScale: 0.66
    )

    /// Small sizes keep the fan — dropping to a bare line-and-dot cost the mark
    /// all family resemblance and read as a pin. Instead: heavier stroke, wider
    /// spread so the three lines still separate, and more of the badge.
    static let small = GlyphStyle(
        stroke: 13, spread: 32, flexX: 34, mergeX: 62,
        lineStartX: 8, dotX: 85, dotRadius: 11, fan: true, markScale: 0.74
    )

    /// Only for the 16pt slots, where even a wide fan turns to mush: three bars
    /// merging into one on hard diagonals, no port dot (it cannot resolve
    /// alongside a 2px stroke), filling nearly the whole tile.
    static let tiny = GlyphStyle(
        stroke: 15, spread: 33, flexX: 42, mergeX: 76,
        lineStartX: 4, dotX: 96, dotRadius: 0, fan: true, markScale: 0.88,
        straightMerge: true
    )

    /// The 18pt menu bar template, where running vs stopped must be obvious at a
    /// glance. State is a filled disc vs a hollow ring, so the dot has to be big
    /// enough that the ring's hole stays wider than the stroke at 18px — hole is
    /// ~3.2px against a ~2.2px stroke here. Bigger than that and the dot reads as
    /// a lollipop that swamps the fan; `.small` proportions would close up solid.
    static let menuBar = GlyphStyle(
        stroke: 12, spread: 32, flexX: 24, mergeX: 48,
        lineStartX: 3, dotX: 80, dotRadius: 17, fan: true, markScale: 1.0
    )
}

func drawGlyph(in ctx: CGContext, box: CGRect, style: GlyphStyle, color: CGColor) {
    let s = box.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * s, y: box.minY + y * s)
    }

    let r = style.dotRadius * s
    let hasDot = style.dotRadius > 0
    // The trunk stops at the dot's edge: with a filled dot the join is
    // seamless, and with the idle ring the round cap meets the band cleanly
    // instead of poking into the hollow. With no dot the trunk runs to dotX.
    let trunkEndX = style.dotX - style.dotRadius

    let lines = CGMutablePath()
    lines.move(to: p(style.lineStartX, 50))
    lines.addLine(to: p(trunkEndX, 50))

    if style.fan {
        // Each outer input runs straight, then merges into the trunk.
        let run = (style.mergeX - style.flexX) * 0.5
        for dy in [-style.spread, style.spread] {
            let y = 50 + dy
            lines.move(to: p(style.lineStartX, y))
            lines.addLine(to: p(style.flexX, y))
            if style.straightMerge {
                lines.addLine(to: p(style.mergeX, 50))
            } else {
                // Horizontal tangent at both ends, so the merge looks aimed
                // rather than kinked. Controls at 0.5x the run give a
                // symmetric S.
                lines.addCurve(
                    to: p(style.mergeX, 50),
                    control1: p(style.flexX + run, y),
                    control2: p(style.mergeX - run, 50)
                )
            }
        }
    }

    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(style.stroke * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(lines)
    ctx.strokePath()

    if hasDot {
        let center = p(style.dotX, 50)
        let dot = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        if style.hollowDot {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(style.stroke * s)
            ctx.strokeEllipse(in: dot)
        } else {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: dot)
        }
    }
    ctx.restoreGState()
}

/// Picks the variant by *display* size, not raster size — a 2x asset has twice
/// the pixels of the slot it is shown in, so it still has to survive at 1x
/// legibility. Thresholds set by inspecting build/preview.png.
func styleFor(display pt: Int) -> GlyphStyle {
    if pt <= 20 { return .tiny }
    if pt <= 40 { return .small }
    return .full
}

/// Fraction of the canvas the squircle fills. 0.805 matches Apple's
/// 824-in-1024 icon grid, which is what makes the Dock icon sit at the same
/// visual weight as its neighbours. The small slots claw back some of that
/// margin because at 16px the grid's 20% padding is most of the legibility
/// budget — Apple's own small slots do the same.
func insetFor(display pt: Int) -> CGFloat {
    if pt <= 20 { return 0.94 }
    if pt <= 40 { return 0.88 }
    return 0.805
}

// MARK: - Squircle

/// Superellipse approximation of the macOS app-icon silhouette. Sampled rather
/// than expressed as Béziers because at these raster sizes the sampling error
/// is invisible and the shape stays exact by construction.
func squircle(in rect: CGRect, exponent n: CGFloat = 5, samples: Int = 2048) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let e = 2 / n
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), e)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Canvas

func makeContext(_ size: Int) -> CGContext { makeContext(width: size, height: size) }

func makeContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    // Flip to a top-left origin so the design grid reads naturally.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// The full badge: squircle, gradient, soft sheen, rim light, glyph.
/// `inset` is the fraction of the canvas the squircle occupies — 0.805 matches
/// Apple's 824-in-1024 icon grid so the Dock icon sits at native weight, while
/// favicons go near full-bleed because tab pixels are scarce.
func renderBadge(size: Int, inset: CGFloat, shadow: Bool, style: GlyphStyle) -> CGImage {
    let ctx = makeContext(size)
    let dim = CGFloat(size)
    let side = dim * inset
    let shape = CGRect(x: (dim - side) / 2, y: (dim - side) / 2, width: side, height: side)
    let path = squircle(in: shape)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    if shadow {
        // Tight and low-contrast: enough to seat the icon on a light background
        // without the diffuse grey halo that reads as dirt.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: dim * 0.008),
            blur: dim * 0.012,
            color: CGColor(srgbRed: 0.07, green: 0.06, blue: 0.16, alpha: 0.22)
        )
        ctx.setFillColor(Palette.bottom)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [Palette.top, Palette.bottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: shape.midX, y: shape.minY),
        end: CGPoint(x: shape.midX, y: shape.maxY),
        options: []
    )
    // Soft top sheen — a diffuse light source, not the glossy dome of the old
    // icon.
    let sheen = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: shape.midX, y: shape.minY - side * 0.10), startRadius: 0,
        endCenter: CGPoint(x: shape.midX, y: shape.minY - side * 0.10), endRadius: side * 0.9,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Inner rim light, clipped to the shape so only the inward half of the
    // stroke survives and the silhouette stays crisp.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15))
    ctx.setLineWidth(max(1, dim * 0.007) * 2)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    let markSide = side * style.markScale
    let mark = CGRect(
        x: shape.midX - markSide / 2, y: shape.midY - markSide / 2,
        width: markSide, height: markSide
    )
    drawGlyph(in: ctx, box: mark, style: style, color: Palette.white)
    return ctx.makeImage()!
}

/// Bare mark on transparency: the menu bar template and the accent-chip glyph,
/// both of which supply their own background.
func renderMark(size: Int, style: GlyphStyle, color: CGColor = Palette.white) -> CGImage {
    let ctx = makeContext(size)
    let dim = CGFloat(size)
    let side = dim * 0.94
    let box = CGRect(x: (dim - side) / 2, y: (dim - side) / 2, width: side, height: side)
    drawGlyph(in: ctx, box: box, style: style, color: color)
    return ctx.makeImage()!
}

/// Resamples to a real N-px bitmap. Needed before any nearest-neighbour blowup:
/// magnifying the 128px source directly would show a smooth 128px grid, not the
/// coarse 18px grid the menu bar actually rasterizes to.
func downsample(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

/// Draws an already-rendered image into a y-flipped context the right way up.
/// Every context here has a top-left origin, and a bare `ctx.draw` would paint
/// the bitmap upside down.
func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext, smooth: Bool = true) {
    ctx.saveGState()
    ctx.interpolationQuality = smooth ? .high : .none
    ctx.translateBy(x: 0, y: rect.midY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -rect.midY)
    ctx.draw(image, in: rect)
    ctx.restoreGState()
}

// MARK: - Encoding

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("encode failed \(url.path)") }
    print("  \(url.lastPathComponent) (\(image.width)px)")
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// Minimal PNG-payload ICO container (Vista+; every current browser reads it).
func writeICO(_ images: [CGImage], to url: URL) {
    func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func u32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    var header = u16(0) + u16(1) + u16(images.count)
    let payloads = images.map { pngData($0) }
    var offset = 6 + 16 * images.count
    for (image, payload) in zip(images, payloads) {
        // 0 means 256 in the ICO directory.
        header += Data([UInt8(image.width == 256 ? 0 : image.width)])
        header += Data([UInt8(image.height == 256 ? 0 : image.height)])
        header += Data([0, 0])
        header += u16(1) + u16(32)
        header += u32(payload.count) + u32(offset)
        offset += payload.count
    }
    var out = header
    for payload in payloads { out += payload }
    try! out.write(to: url)
    print("  \(url.lastPathComponent) (\(images.map(\.width).map(String.init).joined(separator: "/")))")
}

// MARK: - Emit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let swiftRes = root.appendingPathComponent("src/Sources/Resources")
let webAssets = root.appendingPathComponent("management-ui/src/assets")
let webPublic = root.appendingPathComponent("management-ui/public")
let build = root.appendingPathComponent("build")
let iconset = build.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

print("App icon")
let heroIcon = renderBadge(size: 1024, inset: 0.805, shadow: true, style: .full)
writePNG(heroIcon, to: root.appendingPathComponent("icon.png"))

print("Iconset")
// iconutil needs both the logical and @2x file for each slot. `display` is the
// point size the slot is shown at, which is what drives the glyph variant.
let slots: [(String, Int, Int)] = [
    ("icon_16x16", 16, 16), ("icon_16x16@2x", 32, 16),
    ("icon_32x32", 32, 32), ("icon_32x32@2x", 64, 32),
    ("icon_128x128", 128, 128), ("icon_128x128@2x", 256, 128),
    ("icon_256x256", 256, 256), ("icon_256x256@2x", 512, 256),
    ("icon_512x512", 512, 512), ("icon_512x512@2x", 1024, 512),
]
for (name, px, display) in slots {
    writePNG(
        renderBadge(
            size: px, inset: insetFor(display: display), shadow: true,
            style: styleFor(display: display)
        ),
        to: iconset.appendingPathComponent("\(name).png")
    )
}

// Compile the iconset immediately. Leaving this as a separate manual step meant
// regenerating the artwork silently left the Dock icon on the old .icns, since
// that is the file Info.plist (CFBundleIconFile) actually points at.
let icns = swiftRes.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
let icnsSize = (try! FileManager.default.attributesOfItem(atPath: icns.path)[.size] as! NSNumber)
print("  AppIcon.icns (\(slots.count) slots, \(icnsSize.intValue / 1024) KB)")

// Menu bar: an 18pt template, where running vs stopped reads as a filled vs
// hollow port dot. Same silhouette weight either way, so the bar never shifts.
print("Menu bar templates")
var idle = GlyphStyle.menuBar
idle.hollowDot = true
writePNG(renderMark(size: 128, style: .menuBar), to: swiftRes.appendingPathComponent("icon-active.png"))
writePNG(renderMark(size: 128, style: idle), to: swiftRes.appendingPathComponent("icon-inactive.png"))

// The accent-chip glyph, drawn at 18-36px by the web topbar, the login gate,
// and the About panel. `.small` keeps the fan and the port dot at those sizes.
print("Chip glyph")
let glyph = renderMark(size: 512, style: .small)
writePNG(glyph, to: swiftRes.appendingPathComponent("glyph.png"))
writePNG(glyph, to: webAssets.appendingPathComponent("glyph.png"))

print("Favicons")
let favicon = renderBadge(size: 64, inset: 0.98, shadow: false, style: styleFor(display: 32))
let appleTouch = renderBadge(size: 180, inset: 0.98, shadow: false, style: styleFor(display: 180))
writePNG(favicon, to: webPublic.appendingPathComponent("favicon-32.png"))
writePNG(appleTouch, to: webPublic.appendingPathComponent("apple-touch-icon.png"))
writeICO(
    [16, 32, 48].map {
        renderBadge(size: $0, inset: 0.98, shadow: false, style: styleFor(display: $0))
    },
    to: webPublic.appendingPathComponent("favicon.ico")
)

// management-ui/index.html carries its icons as data URIs, not as links to
// public/: vite-plugin-singlefile emits one self-contained HTML file, and
// scripts/build-cliproxy-plus.sh ships only that file into the Go binary — a
// <link href="/favicon.ico"> would 404 there. Patched in place here so the
// inline copies cannot drift from the files on disk.
print("Inline data URIs")
let indexURL = root.appendingPathComponent("management-ui/index.html")
var html = try! String(contentsOf: indexURL, encoding: .utf8)

/// Replaces the href of the <link> tag whose attributes contain `marker`.
func patchHref(_ html: String, marker: String, base64: String) -> String {
    guard let tagStart = html.range(of: "<link rel=\"\(marker)\"") else {
        fatalError("index.html: no <link rel=\"\(marker)\"> to patch")
    }
    guard let hrefStart = html.range(of: "href=\"", range: tagStart.upperBound..<html.endIndex),
          let hrefEnd = html.range(of: "\"", range: hrefStart.upperBound..<html.endIndex)
    else {
        fatalError("index.html: <link rel=\"\(marker)\"> has no href")
    }
    return html.replacingCharacters(
        in: hrefStart.upperBound..<hrefEnd.lowerBound,
        with: "data:image/png;base64,\(base64)"
    )
}

html = patchHref(html, marker: "icon", base64: pngData(favicon).base64EncodedString())
html = patchHref(html, marker: "apple-touch-icon", base64: pngData(appleTouch).base64EncodedString())
try! html.write(to: indexURL, atomically: true, encoding: .utf8)
print("  management-ui/index.html (favicon + apple-touch-icon)")

// MARK: - Preview contact sheet

func drawLabel(_ text: String, at point: CGPoint, ctx: CGContext, color: CGColor) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(cgColor: color)!,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.saveGState()
    // Text has to be un-flipped: the context has a top-left origin.
    ctx.translateBy(x: point.x, y: point.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let lightBG = CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
let darkBG = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)

/// Contact sheet for judging the marks before committing: every asset at its
/// true pixel size, plus a pixel-exact (nearest-neighbour) blowup to a constant
/// box so the 16px tile is as inspectable as the 256px one.
func writePreview(to url: URL) {
    let width = 1560, height = 1080
    let ctx = makeContext(width: width, height: height)
    let zoomBox = 150

    ctx.setFillColor(lightBG)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: 640))
    ctx.setFillColor(darkBG)
    ctx.fill(CGRect(x: 0, y: 640, width: width, height: height - 640))

    // --- Dock / Finder badges, light background.
    drawLabel("APP ICON — native size, then pixel-exact blowup", at: CGPoint(x: 24, y: 34), ctx: ctx, color: Palette.black)
    var x = 24
    for size in [16, 32, 48, 64, 128, 256] {
        let img = renderBadge(
            size: size, inset: insetFor(display: size), shadow: true,
            style: styleFor(display: size)
        )
        let box = max(zoomBox, size)
        // Native, bottom-aligned on a common baseline.
        drawImage(
            img,
            in: CGRect(x: x + (box - size) / 2, y: 60 + (256 - size), width: size, height: size),
            ctx: ctx
        )
        drawImage(
            img, in: CGRect(x: x, y: 336, width: box, height: box), ctx: ctx, smooth: false
        )
        drawLabel("\(size)px", at: CGPoint(x: x, y: 336 + box + 18), ctx: ctx, color: Palette.black)
        x += box + 24
    }

    // --- Menu bar templates, as macOS renders them: the PNG's alpha tinted to
    // the bar's foreground colour, so both polarities must work.
    drawLabel("MENU BAR 18pt — running (filled) vs stopped (hollow)", at: CGPoint(x: 24, y: 690), ctx: ctx, color: Palette.white)
    var mx = 24
    for style in [GlyphStyle.menuBar, idle] {
        for (bg, fg) in [(lightBG, Palette.black), (darkBG, Palette.white)] {
            // 128px downsampled to 18, exactly as macOS treats the shipped
            // asset — a native 18px render would flatter it unfairly.
            let img = downsample(renderMark(size: 128, style: style, color: fg), to: 18)
            let swatch = CGRect(x: mx, y: 715, width: zoomBox + 60, height: zoomBox + 24)
            ctx.setFillColor(bg)
            ctx.fill(swatch)
            drawImage(img, in: CGRect(x: mx + 16, y: 715 + 12, width: 18, height: 18), ctx: ctx)
            drawImage(
                img,
                in: CGRect(x: mx + 48, y: 715 + 12, width: zoomBox - 24, height: zoomBox - 24),
                ctx: ctx, smooth: false
            )
            mx += zoomBox + 60 + 16
        }
        mx += 32
    }

    // --- The accent chip, as the web topbar (34px), login gate (52px), and
    // About panel (64px) compose it: gradient chip + white glyph.
    drawLabel("ACCENT CHIP — topbar 34 / gate 52 / about 64", at: CGPoint(x: 24, y: 930), ctx: ctx, color: Palette.white)
    var cx = 24
    for chip in [34, 52, 64] {
        let rect = CGRect(x: CGFloat(cx), y: 955, width: CGFloat(chip), height: CGFloat(chip))
        ctx.saveGState()
        ctx.addPath(squircle(in: rect, exponent: 4))
        ctx.clip()
        let g = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [Palette.top, Palette.bottom] as CFArray, locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            g, start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY), options: []
        )
        ctx.restoreGState()
        // Mirrors .brand-mark img { width: 18px } inside a 34px chip.
        let inner = rect.insetBy(dx: rect.width * 0.235, dy: rect.width * 0.235)
        drawGlyph(in: ctx, box: inner, style: .small, color: Palette.white)
        cx += chip + 40
    }

    writePNG(ctx.makeImage()!, to: url)
}

print("Preview")
writePreview(to: build.appendingPathComponent("preview.png"))

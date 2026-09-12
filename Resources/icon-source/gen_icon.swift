import AppKit
import CoreGraphics

let size: CGFloat = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)

guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    let r = CGFloat((h >> 16) & 0xFF) / 255
    let g = CGFloat((h >> 8) & 0xFF) / 255
    let b = CGFloat(h & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: a)
}

// MARK: - Squircle background (Big Sur-style superellipse approximation)

func squirclePath(in rect: CGRect, cornerFactor: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = min(rect.width, rect.height) * cornerFactor
    path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
    return path
}

let bgPath = squirclePath(in: rect, cornerFactor: 0.2237)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let colors = [hex(0x2FD3C6), hex(0x3A4CC7)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// Soft top sheen: a smooth radial falloff (no hard edges) for gentle glass-like depth.
let sheenColors = [hex(0xFFFFFF, 0.22), hex(0xFFFFFF, 0.0)] as CFArray
let sheenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheenColors, locations: [0, 1])!
ctx.drawRadialGradient(
    sheenGradient,
    startCenter: CGPoint(x: size * 0.5, y: size * 1.05),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.5, y: size * 1.05),
    endRadius: size * 0.95,
    options: []
)

// Subtle darkening vignette at the bottom edge for grounding.
let vignetteColors = [hex(0x000000, 0.0), hex(0x0B1A3A, 0.16)] as CFArray
let vignetteGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: vignetteColors, locations: [0, 1])!
ctx.drawLinearGradient(
    vignetteGradient,
    start: CGPoint(x: 0, y: size * 0.35),
    end: CGPoint(x: 0, y: 0),
    options: []
)

ctx.restoreGState()

// MARK: - Martini glass glyph

let cx = size * 0.5
let glassTopY = size * 0.60      // rim height
let glassBottomApexY = size * 0.345 // bowl apex (tip)
let rimHalfWidth = size * 0.235
let stemBottomY = size * 0.215
let stemWidth = size * 0.028
let footY = size * 0.175
let footHalfWidth = size * 0.115

ctx.saveGState()
// soft drop shadow for the whole glyph
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: hex(0x0B1A3A, 0.35))

// Bowl (triangle with gently concave sides for a classic martini silhouette)
let bowl = CGMutablePath()
bowl.move(to: CGPoint(x: cx - rimHalfWidth, y: glassTopY))
bowl.addQuadCurve(
    to: CGPoint(x: cx, y: glassBottomApexY),
    control: CGPoint(x: cx - rimHalfWidth * 0.32, y: (glassTopY + glassBottomApexY) * 0.52)
)
bowl.addQuadCurve(
    to: CGPoint(x: cx + rimHalfWidth, y: glassTopY),
    control: CGPoint(x: cx + rimHalfWidth * 0.32, y: (glassTopY + glassBottomApexY) * 0.52)
)
bowl.closeSubpath()

// Stem
let stem = CGMutablePath()
stem.addRoundedRect(
    in: CGRect(x: cx - stemWidth / 2, y: stemBottomY, width: stemWidth, height: glassBottomApexY - stemBottomY + 4),
    cornerWidth: stemWidth / 2, cornerHeight: stemWidth / 2
)

// Foot
let foot = CGMutablePath()
foot.addRoundedRect(
    in: CGRect(x: cx - footHalfWidth, y: footY, width: footHalfWidth * 2, height: size * 0.026),
    cornerWidth: size * 0.013, cornerHeight: size * 0.013
)

let glass = CGMutablePath()
glass.addPath(bowl)
glass.addPath(stem)
glass.addPath(foot)

ctx.setFillColor(hex(0xFFFFFF, 0.98))
ctx.addPath(glass)
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

// Liquid fill (subtle, suggests a drink) — clipped to bowl interior, soft-edged at the surface.
ctx.saveGState()
ctx.addPath(bowl)
ctx.clip()
let liquidTopY = glassTopY - size * 0.085
let liquidColors = [hex(0x2FD3C6, 0.55), hex(0x2FD3C6, 0.92)] as CFArray
let liquidGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: liquidColors, locations: [0, 1])!
ctx.drawLinearGradient(
    liquidGradient,
    start: CGPoint(x: 0, y: liquidTopY + size * 0.03),
    end: CGPoint(x: 0, y: liquidTopY - size * 0.03),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
ctx.restoreGState()

// Rim highlight line
ctx.saveGState()
ctx.setStrokeColor(hex(0xFFFFFF, 0.9))
ctx.setLineWidth(size * 0.010)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: cx - rimHalfWidth * 0.98, y: glassTopY))
ctx.addLine(to: CGPoint(x: cx + rimHalfWidth * 0.98, y: glassTopY))
ctx.strokePath()
ctx.restoreGState()

// Olive garnish (coral) with a toothpick, resting on the rim to the right
let oliveCenter = CGPoint(x: cx + rimHalfWidth * 0.40, y: glassTopY + size * 0.006)
let oliveRadius = size * 0.052

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: hex(0x0B1A3A, 0.30))

// toothpick
ctx.setStrokeColor(hex(0xFFFFFF, 0.95))
ctx.setLineWidth(size * 0.014)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: oliveCenter.x - oliveRadius * 0.7, y: oliveCenter.y + oliveRadius * 0.7))
ctx.addLine(to: CGPoint(x: oliveCenter.x + oliveRadius * 1.7, y: oliveCenter.y + oliveRadius * 1.7))
ctx.strokePath()

// olive body
ctx.setFillColor(hex(0xFF6A52))
ctx.addEllipse(in: CGRect(x: oliveCenter.x - oliveRadius, y: oliveCenter.y - oliveRadius, width: oliveRadius * 2, height: oliveRadius * 2))
ctx.fillPath()

// olive highlight
ctx.setFillColor(hex(0xFFFFFF, 0.35))
ctx.addEllipse(in: CGRect(x: oliveCenter.x - oliveRadius * 0.45, y: oliveCenter.y + oliveRadius * 0.05, width: oliveRadius * 0.7, height: oliveRadius * 0.5))
ctx.fillPath()
ctx.restoreGState()

// MARK: - Export

guard let image = ctx.makeImage() else { fatalError("no image") }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no png data") }

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")

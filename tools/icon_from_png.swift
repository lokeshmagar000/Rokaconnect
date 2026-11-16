// Turns the 1024px Rokaconnect icon PNG (rounded tile with a clear margin) into the Android icon layers.
// Usage: swift tools/icon_from_png.swift <icon.png> <out-dir>
// Writes: android_full_1024.png (tile, no margin), android_bg_432.png (tile colour), android_fg_432.png (tile, safe-zone sized)
import AppKit

let args = CommandLine.arguments
let src = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!, 0, nil)!
let out = args[2]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Finds the opaque tile: first row/column whose middle pixel is solid.
func bitmap(_ img: CGImage) -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (ctx, ctx.data!.assumingMemoryBound(to: UInt8.self))
}
let (pixelCtx, px) = bitmap(src)          // keep the context alive so its pixels stay valid
let w = src.width
/// True where the tile is: opaque and not the white page around it.
func isTile(_ x: Int, _ y: Int) -> Bool { let i = (y * w + x) * 4; return px[i + 3] > 250 && (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) < 600 }
var inset = 0
while inset < w / 2 && !isTile(inset, w / 2) { inset += 1 }          // left edge of the tile
let tile = CGRect(x: inset, y: inset, width: w - 2 * inset, height: w - 2 * inset)
// tile colour: average of a few pixels just inside the left edge, middle height
var rgb = [0.0, 0.0, 0.0]
for dy in -20...20 { let i = ((w / 2 + dy) * w + inset + 12) * 4; for k in 0..<3 { rgb[k] += Double(px[i + k]) / 255 / 41 } }
print("tile inset \(inset)px, edge colour", rgb.map { String(format: "%.3f", $0) })

func save(_ size: Int, _ name: String, _ draw: (CGContext, CGFloat) -> Void) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
let cropped = src.cropping(to: tile)!
let bg = CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)

// legacy square icon: the tile filling the whole image (launchers round it themselves)
save(1024, "android_full_1024.png") { ctx, s in
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: s, height: s))
}
// adaptive background: the tile colour
save(432, "android_bg_432.png") { ctx, s in ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s)) }
// adaptive foreground: tile at 80% so the artwork sits inside the safe zone and the tile corners get masked off
save(432, "android_fg_432.png") { ctx, s in
    let t = s * 0.80
    ctx.draw(cropped, in: CGRect(x: (s - t) / 2, y: (s - t) / 2, width: t, height: t))
}
withExtendedLifetime(pixelCtx) {}

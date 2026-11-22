// Renders an SVG to a square PNG with a transparent background, using AppKit's own SVG support.
// Usage: swift scripts/render-svg.swift IN.svg OUT.png SIZE
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
    FileHandle.standardError.write("usage: render-svg.swift IN.svg OUT.png SIZE\n".data(using: .utf8)!)
    exit(2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("render-svg: can't read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))

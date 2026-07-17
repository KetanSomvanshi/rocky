// Renders Rocky the Eridian (the alien skin) onto a rounded dark square, for
// use as the "Start Rocky" launcher's app icon. Compiled together with
// RockyCore.swift so it can call the real sprite-drawing code — the icon
// stays in sync with the skin automatically.
//
// Usage: render-icon <output.png>   (writes a 2048x2048 PNG)
import AppKit

let size = 1024.0

// Rocky's own view draws with isFlipped == true (y grows downward, like the
// rest of the sprite's coordinate math assumes); a plain lockFocus() context
// is bottom-left-origin and renders the sprite upside down, so draw into a
// flipped image instead.
let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
    // Background: a soft rounded square in Rocky's signature dark, so the
    // icon reads consistently against any Spotlight/Dock background.
    NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    // Inset so the sprite doesn't touch the rounded corners. `.idle` (no
    // bounce/lean offset) keeps it centred for a static icon.
    let inset = size * 0.10
    let spriteRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    Cat.draw(in: spriteRect, tint: rockyTint, expr: .idle, tick: 0, skin: .eridian)
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments[1]
try! png.write(to: URL(fileURLWithPath: outPath))

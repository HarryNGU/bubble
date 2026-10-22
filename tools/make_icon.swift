// Renders the app icon PNG: swift tools/make_icon.swift out.png
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.16, green: 0.17, blue: 0.24, alpha: 1),
           ending: NSColor(red: 0.07, green: 0.07, blue: 0.11, alpha: 1))!.draw(in: bg, angle: -90)
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 262, y: 262, width: 500, height: 500)).fill()
// Electric blue, matching the app's default theme.
NSGradient(starting: NSColor(red: 0x1F / 255, green: 0x5B / 255, blue: 1, alpha: 1),
           ending: NSColor(red: 0, green: 0xB8 / 255, blue: 1, alpha: 1))!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 297, y: 297, width: 430, height: 430)), angle: 60)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

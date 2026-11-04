import AppKit
import Foundation

// Package the unchanged illustration into the same 824 / 1024 visible footprint
// measured in native macOS application icons. Padding remains transparent.
let sourceURL=URL(fileURLWithPath:CommandLine.arguments[1])
let outputURL=URL(fileURLWithPath:CommandLine.arguments[2])
let source=NSImage(contentsOf:sourceURL)!
let sourceRep=NSBitmapImageRep(data:try Data(contentsOf:sourceURL))!
let w=sourceRep.pixelsWide, h=sourceRep.pixelsHigh
source.size=NSSize(width:w,height:h)
var bounds=NSRect.null
for y in 0..<h {
    for x in 0..<w where (sourceRep.colorAt(x:x,y:y)?.alphaComponent ?? 0)>=0.5 {
        bounds=bounds.union(NSRect(x:x,y:y,width:1,height:1))
    }
}
precondition(!bounds.isNull)
let target=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
target.size=NSSize(width:1024,height:1024)
let scale=824 / max(bounds.width,bounds.height)
let size=NSSize(width:bounds.width*scale,height:bounds.height*scale)
let destination=NSRect(x:(1024-size.width)/2,y:(1024-size.height)/2,width:size.width,height:size.height)
let crop=NSRect(x:bounds.minX,y:CGFloat(h)-bounds.maxY,width:bounds.width,height:bounds.height)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:target)
NSColor.clear.setFill(); NSRect(x:0,y:0,width:1024,height:1024).fill(using:.copy)
NSGraphicsContext.current?.imageInterpolation = .high
source.draw(in:destination,from:crop,operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
try target.representation(using:.png,properties:[:])!.write(to:outputURL)
print("App icon packaged: 1024px transparent canvas; 824px artwork footprint")

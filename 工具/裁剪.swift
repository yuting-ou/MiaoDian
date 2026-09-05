import AppKit
// 裁剪 <in> <out> <x> <y> <w> <h>（像素坐标，左上原点）。colorAt 读取，配合对比度测量（NSBitmapImageRep 同源）
let a = CommandLine.arguments
guard a.count >= 7, let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: a[1]))) ?? Data()),
      let x = Int(a[3]), let y = Int(a[4]), let w = Int(a[5]), let h = Int(a[6]) else { exit(1) }
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for py in 0..<h { for px in 0..<w {
	if let c = rep.colorAt(x: x+px, y: y+py) { out.setColor(c, atX: px, y: py) }
}}
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))

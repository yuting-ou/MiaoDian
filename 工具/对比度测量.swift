// 截图区域对比度实测（仅开发工具，不进应用源码树）
// 用法：swiftc 工具/对比度测量.swift -o /tmp/contrast && /tmp/contrast <png> [x y w h]
// 不带区域参数则整图。原理：CGImage 直读 RGBA 字节（colorAt 对 screencapture 格式会失效）；
// 文字像素是亮度分布的少数派极值簇，背景是多数派簇；
// WCAG 对比度 = (L_bg+0.05)/(L_text+0.05)，自动判明暗底，附 p5/p50/p95 供复核。
// 判据：正文 ≥4.5:1（AA），关键数字 ≥7:1（AAA）。
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
	print("读不到图片"); exit(1)
}

var x = 0, y = 0, w = image.width, h = image.height
if args.count >= 6, let ax = Int(args[2]), let ay = Int(args[3]), let aw = Int(args[4]), let ah = Int(args[5]) {
	x = ax; y = ay; w = aw; h = ah
}
w = min(w, image.width - x); h = min(h, image.height - y)
guard w > 10, h > 10 else { print("区域太小"); exit(1) }

// 画进已知格式的上下文，逐字节取 RGBA
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
	space: CGColorSpace(name: CGColorSpace.sRGB)!,
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.translateBy(x: 0, y: CGFloat(h))
ctx.scaleBy(x: 1, y: -1)
ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
guard let data = ctx.data else { exit(1) }
let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

func lin(_ c: UInt8) -> Double {
	let v = Double(c) / 255
	return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

var lums: [Double] = []
lums.reserveCapacity(w * h)
for row in 0..<h {
	for col in 0..<w {
		let i = (row * w + col) * 4
		lums.append(0.2126 * lin(bytes[i]) + 0.7152 * lin(bytes[i + 1]) + 0.0722 * lin(bytes[i + 2]))
	}
}
lums.sort()
let p5 = lums[lums.count * 5 / 100]
let p50 = lums[lums.count / 2]
let p95 = lums[lums.count * 95 / 100]
let darkSpread = p50 - p5
let lightSpread = p95 - p50
let textL = darkSpread > lightSpread ? p5 : p95
let ratio = (max(textL, p50) + 0.05) / (min(textL, p50) + 0.05)
print(String(format: "p5=%.3f p50=%.3f p95=%.3f 文字簇=%@ 对比度=%.2f:1 (AA 4.5 / AAA 7)",
	p5, p50, p95, darkSpread > lightSpread ? "暗" : "亮", ratio))

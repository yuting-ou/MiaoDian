// 截图区域对比度实测（仅开发工具，不进应用源码树）
// 用法：swiftc 工具/对比度测量.swift -o /tmp/contrast && /tmp/contrast <png> <x> <y> <w> <h>
// 原理：取区域内像素亮度分布——文字像素是少数派极值簇，背景是多数派簇；
// 报告 WCAG 对比度 = (L_bg+0.05)/(L_text+0.05)（自动判明暗底），并给 p5/p50/p95 亮度供人工复核。
// 判据：正文 ≥4.5:1（AA），关键数字 ≥7:1（AAA）。
import AppKit

let args = CommandLine.arguments
guard args.count >= 6,
      let image = NSImage(contentsOfFile: args[1]),
      let rep = NSBitmapImageRep(data: image.tiffRepresentation!),
      let x = Int(args[2]), let y = Int(args[3]), let w = Int(args[4]), let h = Int(args[5]) else {
	print("用法: contrast <png> <x> <y> <w> <h>")
	exit(1)
}

func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double {
	func lin(_ c: CGFloat) -> Double {
		let v = Double(c)
		return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

var lums: [Double] = []
lums.reserveCapacity(w * h)
for py in y..<min(y + h, rep.pixelsHigh) {
	for px in x..<min(x + w, rep.pixelsWide) {
		guard let c = rep.colorAt(x: px, y: py) else { continue }
		lums.append(luminance(c.redComponent, c.greenComponent, c.blueComponent))
	}
}
guard lums.count > 100 else { print("样本不足"); exit(1) }
lums.sort()
let p5 = lums[lums.count * 5 / 100]
let p50 = lums[lums.count / 2]
let p95 = lums[lums.count * 95 / 100]
// 少数派簇判文字：若低端 5% 与中位数差距大于高端 5% 与中位数差距，文字在暗端，反之在亮端
let darkSpread = p50 - p5
let lightSpread = p95 - p50
let textL = darkSpread > lightSpread ? p5 : p95
let bgL = p50
let ratio = (max(textL, bgL) + 0.05) / (min(textL, bgL) + 0.05)
print(String(format: "p5=%.3f p50=%.3f p95=%.3f 文字簇=%@ 对比度=%.2f:1 (AA 4.5 / AAA 7)",
	p5, p50, p95, darkSpread > lightSpread ? "暗" : "亮", ratio))

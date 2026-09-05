// 妙电应用图标生成器（仅开发工具，不进应用源码树——build.sh 只收集 ChargeMonitor/ChargeMonitor/**）
// 用法：swiftc 工具/生成图标.swift -o /tmp/genicon && /tmp/genicon /tmp/icon_1024.png
// 设计：苹果图标网格（1024 画布、824 内容、超椭圆 squircle）+ 液态玻璃语言——
// 浅色渐变底板上浮一枚玻璃电池舱，绿色电量填充、圆角闪电、镜面高光与柔影，与面板重设计同一套材质观感
import AppKit

let canvas: CGFloat = 1024

// ---- 工具 ----

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
	CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// 超椭圆 squircle（苹果图标轮廓，指数 ~5）
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
	let path = CGMutablePath()
	let steps = 720
	let a = rect.width / 2, b = rect.height / 2
	for i in 0...steps {
		let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
		let ct = cos(t), st = sin(t)
		let x = rect.midX + a * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / exponent)
		let y = rect.midY + b * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / exponent)
		if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
	}
	path.closeSubpath()
	return path
}

func drawGradient(_ ctx: CGContext, colors: [CGColor], locations: [CGFloat], from: CGPoint, to: CGPoint, clip: CGPath) {
	ctx.saveGState()
	ctx.addPath(clip)
	ctx.clip()
	let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
	ctx.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	ctx.restoreGState()
}

func drawRadial(_ ctx: CGContext, colors: [CGColor], locations: [CGFloat], center: CGPoint, radius: CGFloat, clip: CGPath) {
	ctx.saveGState()
	ctx.addPath(clip)
	ctx.clip()
	let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
	ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
	ctx.restoreGState()
}

// 圆角矩形（连续曲率近似：标准圆角即可，尺寸大时肉眼无差）
func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
	CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// 上游 AppIcon.icon 的圆角闪电路径（viewBox 339×552，y 轴向下），仿射变换进画布
func boltPath(scale: CGFloat, center: CGPoint) -> CGPath {
	let p = CGMutablePath()
	// SVG 坐标 → 画布坐标：左上原点，先平移缩放
	func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
		CGPoint(x: center.x + (x - 339 / 2) * scale, y: center.y + (y - 552 / 2) * scale)
	}
	p.move(to: pt(0, 303.854))
	p.addCurve(to: pt(13.7375, 316.591), control1: pt(0, 310.969), control2: pt(5.25252, 316.591))
	p.addLine(to: pt(156.228, 316.591))
	p.addLine(to: pt(80.565, 521.339))
	p.addCurve(to: pt(107.108, 535.809), control1: pt(72.7525, 541.974), control2: pt(93.7676, 552.469))
	p.addLine(to: pt(332.575, 253.436))
	p.addCurve(to: pt(338.145, 240.149), control1: pt(336.128, 249.039), control2: pt(338.145, 244.969))
	p.addCurve(to: pt(324.408, 227.411), control1: pt(338.145, 233.284), control2: pt(332.893, 227.411))
	p.addLine(to: pt(181.995, 227.411))
	p.addLine(to: pt(257.58, 22.7413))
	p.addCurve(to: pt(231.115, 8.36629), control1: pt(265.47, 2.02878), control2: pt(244.455, -8.46624))
	p.addLine(to: pt(5.57001, 290.566))
	p.addCurve(to: pt(0, 303.854), control1: pt(2.0175, 295.214), control2: pt(0, 299.284))
	p.closeSubpath()
	return p
}

// ---- 画布 ----

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
	bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
	colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext

// 统一翻转到左上原点（与 SVG/设计稿同坐标系）
ctx.translateBy(x: 0, y: canvas)
ctx.scaleBy(x: 1, y: -1)

let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = squirclePath(in: iconRect)

// 1) 底板：冷薄荷绿纵向渐变——加深一档，让白色玻璃舱浮得出来（浅底白舱对比不足是 v2 的主因）
drawGradient(ctx,
	colors: [srgb(238, 248, 240), srgb(206, 232, 214), srgb(168, 210, 182)],
	locations: [0, 0.55, 1],
	from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924), clip: squircle)

// 2) 底板环境光：左上角一抹冷白高光，模拟天光
drawRadial(ctx,
	colors: [srgb(255, 255, 255, 0.85), srgb(255, 255, 255, 0)],
	locations: [0, 1], center: CGPoint(x: 330, y: 260), radius: 560, clip: squircle)

// 3) 电池舱后方的绿色环境辉光：让"能量"从玻璃里透出来
drawRadial(ctx,
	colors: [srgb(48, 209, 88, 0.30), srgb(48, 209, 88, 0)],
	locations: [0, 1], center: CGPoint(x: 470, y: 512), radius: 420, clip: squircle)

// ---- 玻璃电池舱 ----
let capsule = CGRect(x: 196, y: 352, width: 600, height: 300)
let capsuleRadius: CGFloat = 150
let capsulePath = roundedPath(capsule, radius: capsuleRadius)
// 正极小帽：紧贴舱体右缘（留 2pt 缝防穿帮），同玻璃材质
let terminal = CGRect(x: 794, y: 442, width: 46, height: 120)
let terminalPath = roundedPath(terminal, radius: 23)

// 4) 舱体投影：柔和悬浮影
ctx.saveGState()
ctx.addPath(capsulePath)
ctx.addPath(terminalPath)
ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 52, color: srgb(30, 60, 40, 0.22))
ctx.setFillColor(srgb(255, 255, 255, 0.01))
ctx.fillPath()
ctx.restoreGState()

// 5) 舱体玻璃壳：半透明白渐变（上亮下暗=厚度感）
drawGradient(ctx,
	colors: [srgb(255, 255, 255, 0.9), srgb(255, 255, 255, 0.5), srgb(228, 242, 234, 0.62)],
	locations: [0, 0.5, 1],
	from: CGPoint(x: 512, y: capsule.minY), to: CGPoint(x: 512, y: capsule.maxY), clip: capsulePath)
drawGradient(ctx,
	colors: [srgb(255, 255, 255, 0.9), srgb(255, 255, 255, 0.5), srgb(228, 242, 234, 0.62)],
	locations: [0, 0.5, 1],
	from: CGPoint(x: 817, y: terminal.minY), to: CGPoint(x: 817, y: terminal.maxY), clip: terminalPath)
// 舱体外缘淡轮廓：与浅色底板拉开对比，玻璃体不再"融"进背景
ctx.saveGState()
ctx.addPath(capsulePath)
ctx.addPath(terminalPath)
ctx.setStrokeColor(srgb(70, 115, 88, 0.4))
ctx.setLineWidth(5)
ctx.strokePath()
ctx.restoreGState()
// 舱体内底反射：底部一道淡绿反光（玻璃厚度里弹回来的桌面光）
ctx.saveGState()
ctx.addPath(capsulePath)
ctx.clip()
drawGradient(ctx,
	colors: [srgb(150, 220, 170, 0), srgb(150, 220, 170, 0.5)],
	locations: [0, 1],
	from: CGPoint(x: 0, y: capsule.maxY - 110), to: CGPoint(x: 0, y: capsule.maxY - 14),
	clip: CGPath(rect: capsule.insetBy(dx: -20, dy: -20), transform: nil))
ctx.restoreGState()

// 6) 电量填充：舱内左侧 78% 绿色玻璃条，亮绿渐变+顶部镜面高光
let inset: CGFloat = 34
let fillFull = capsule.insetBy(dx: inset, dy: inset)
let fillRect = CGRect(x: fillFull.minX, y: fillFull.minY, width: fillFull.width * 0.78, height: fillFull.height)
let fillPath = roundedPath(fillRect, radius: fillFull.height / 2)
drawGradient(ctx,
	colors: [srgb(96, 235, 138), srgb(52, 208, 96), srgb(30, 168, 68)],
	locations: [0, 0.55, 1],
	from: CGPoint(x: 0, y: fillRect.minY), to: CGPoint(x: 0, y: fillRect.maxY), clip: fillPath)
// 填充条上半镜面高光
ctx.saveGState()
ctx.addPath(fillPath)
ctx.clip()
drawGradient(ctx,
	colors: [srgb(255, 255, 255, 0.5), srgb(255, 255, 255, 0)],
	locations: [0, 1],
	from: CGPoint(x: 0, y: fillRect.minY), to: CGPoint(x: 0, y: fillRect.midY + 20), clip: fillPath)
ctx.restoreGState()
// 绿缘辉光：能量从填充右端透进空舱的玻璃里
drawRadial(ctx,
	colors: [srgb(52, 208, 96, 0.5), srgb(52, 208, 96, 0)],
	locations: [0, 1], center: CGPoint(x: fillRect.maxX, y: fillRect.midY), radius: 150, clip: capsulePath)

// 7) 舱体内壁描边：上缘亮线（玻璃受光边）+ 整体淡轮廓
ctx.saveGState()
ctx.addPath(capsulePath)
ctx.setLineWidth(7)
ctx.replacePathWithStrokedPath()
ctx.clip()
drawGradient(ctx,
	colors: [srgb(255, 255, 255, 0.95), srgb(255, 255, 255, 0.15), srgb(120, 150, 130, 0.35)],
	locations: [0, 0.5, 1],
	from: CGPoint(x: 0, y: capsule.minY), to: CGPoint(x: 0, y: capsule.maxY),
	clip: CGPath(rect: capsule.insetBy(dx: -10, dy: -10), transform: nil))
ctx.restoreGState()

// 8) 闪电：白色玻璃质感，居中压在舱体上；投影收紧、绿色背光减弱防发糊
let bolt = boltPath(scale: 0.5, center: CGPoint(x: 512, y: 496))
ctx.saveGState()
ctx.addPath(bolt)
ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 16, color: srgb(18, 110, 48, 0.4))
ctx.setFillColor(srgb(255, 255, 255, 0.98))
ctx.fillPath()
ctx.restoreGState()
// 闪电顶部微高光
ctx.saveGState()
ctx.addPath(bolt)
ctx.clip()
drawGradient(ctx,
	colors: [srgb(226, 242, 231), srgb(255, 255, 255, 0)],
	locations: [0, 1],
	from: CGPoint(x: 0, y: 320), to: CGPoint(x: 0, y: 470),
	clip: CGPath(rect: CGRect(x: 380, y: 300, width: 280, height: 200), transform: nil))
ctx.restoreGState()

// 9) 舱体顶部镜面反射：沿上缘柔和渐隐的天光带（液态玻璃掠射感），不用硬边光带避免留脏痕
ctx.saveGState()
ctx.addPath(capsulePath)
ctx.clip()
drawGradient(ctx,
	colors: [srgb(255, 255, 255, 0.65), srgb(255, 255, 255, 0)],
	locations: [0, 1],
	from: CGPoint(x: 0, y: capsule.minY + 8), to: CGPoint(x: 0, y: capsule.minY + 96),
	clip: CGPath(rect: capsule.insetBy(dx: -20, dy: -20), transform: nil))
ctx.restoreGState()

// 10) squircle 顶缘亮线：图标玻璃砖的受光上缘
ctx.saveGState()
ctx.addPath(squircle)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
drawGradient(ctx,
	colors: [srgb(255, 255, 255, 0.9), srgb(255, 255, 255, 0)],
	locations: [0, 0.35],
	from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924),
	clip: CGPath(rect: iconRect.insetBy(dx: -20, dy: -20), transform: nil))
ctx.restoreGState()

// 输出
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("written: \(outPath)")

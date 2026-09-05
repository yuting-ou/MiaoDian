// 妙电应用图标生成器（真实液态玻璃版）
// 用法：swiftc 工具/生成图标.swift -o /tmp/genicon && caffeinate -u -t 30 /tmp/genicon /tmp/icon_1024.png
//   （屏幕必须唤醒且未锁：捕获的是真实合成画面；产出 1024 PNG 后用 sips+iconutil 转 icns）
//
// 为什么是"双窗口+屏区捕获"而不是离屏渲染（均为实测结论）：
//   1) ImageRenderer 不渲染 glassEffect——玻璃层整个消失；
//   2) macOS 的液态玻璃采样的是窗口背后的合成内容（桌面），不是同窗口内的兄弟视图——
//      单窗口里玻璃会去折射壁纸（灰雾/串色）；
//   3) 透明玻璃窗整窗会带一层暗底，且暗底跟随 GlassEffectContainer 的矩形 frame——
//      容器收缩到电池包围盒并 mask 到电池轮廓，暗底才不污染底板。
//   所以：底窗画底板（不透明，含绿色电量"液体"），顶窗透明只画玻璃壳与闪电；
//   玻璃经 window server 真实折射底窗内容，再截该屏区——得到系统材质管线的真实渲染。
import AppKit
import SwiftUI
import ScreenCaptureKit

let canvas: CGFloat = 1024

// sRGB 色值助手（参数 0~1）
func c(_ r: Double, _ g: Double, _ b: Double, _ o: Double = 1) -> Color {
	Color(.sRGB, red: r, green: g, blue: b, opacity: o)
}

// ---- 几何（苹果图标网格：1024 画布、824 内容、连续曲率 squircle）----

let tileRadius: CGFloat = 185
let capsuleRect = CGRect(x: 196, y: 352, width: 600, height: 300)
let terminalRect = CGRect(x: 794, y: 442, width: 46, height: 120)
let chargeRect: CGRect = {
	let inset: CGFloat = 40
	let full = capsuleRect.insetBy(dx: inset, dy: inset)
	return CGRect(x: full.minX, y: full.minY, width: full.width * 0.82, height: full.height)
}()
// 玻璃容器包围盒（舱∪帽，外留 3pt 边缘高光）
let glassBBox = CGRect(x: 180, y: 336, width: 680, height: 332)

// 上游圆角闪电路径（viewBox 339×552，y 轴向下）
func boltPath(scale: CGFloat, center: CGPoint) -> CGPath {
	let p = CGMutablePath()
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

// ---- 图层 ----

// 底板：薄荷渐变 + 天光 + 舱后绿色辉光 + 右下冷色光斑 + 电量绿液胶囊。
// 明暗结构是给玻璃折射准备的"细节"——纯平渐变看不出弯折；
// 电量是画在底板里的"液体"，由玻璃壳折射后自带弯折边缘，比 tint 染玻璃更鲜亮。
struct TileLayer: View {
	var body: some View {
		LinearGradient(
			colors: [c(226/255, 244/255, 231/255), c(186/255, 222/255, 197/255), c(138/255, 192/255, 158/255)],
			startPoint: .top, endPoint: .bottom)
			.overlay(
				RadialGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
				               center: UnitPoint(x: 330/1024, y: 260/1024), startRadius: 0, endRadius: 560)
			)
			.overlay(
				RadialGradient(colors: [c(130/255, 255/255, 175/255, 1.0),
				                        c(70/255, 235/255, 120/255, 0.55),
				                        c(48/255, 209/255, 88/255, 0)],
				               center: UnitPoint(x: 420/1024, y: 502/1024), startRadius: 0, endRadius: 400)
			)
			.overlay(
				RadialGradient(colors: [c(120/255, 190/255, 230/255, 0.35),
				                        c(120/255, 190/255, 230/255, 0)],
				               center: UnitPoint(x: 760/1024, y: 800/1024), startRadius: 0, endRadius: 380)
			)
			.overlay(
				LinearGradient(colors: [c(105/255, 250/255, 145/255), c(28/255, 205/255, 82/255)],
				               startPoint: .top, endPoint: .bottom)
					.frame(width: chargeRect.width - 12, height: chargeRect.height - 12)
					.clipShape(Capsule())
					.position(x: chargeRect.midX, y: chargeRect.midY)
					.blur(radius: 2)
			)
			.overlay(
				// 弯月面：液面右缘凸出一颗"正要滴落"的肚，电量边界不再是死板的圆头
				Circle()
					.fill(c(60/255, 225/255, 110/255))
					.frame(width: 56, height: 56)
					.position(x: chargeRect.maxX - 14, y: chargeRect.midY + 6)
					.blur(radius: 2)
			)
			.overlay(
				// 液体气泡：两颗亮泡浮在绿液里，被玻璃壳折射后自带液态感
				ZStack {
					Circle().fill(c(225/255, 255/255, 235/255, 1.0))
						.frame(width: 52, height: 52).position(x: 330, y: 450)
					Circle().fill(c(225/255, 255/255, 235/255, 0.95))
						.frame(width: 26, height: 26).position(x: 590, y: 575)
				}
				.blur(radius: 1)
			)
			.overlay(
				// 斜向光带：只掠舱上缘，给透镜一条可弯折的明暗线（强了像划痕）
				LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.16), Color.white.opacity(0)],
				               startPoint: .init(x: 0, y: 0), endPoint: .init(x: 1, y: 1))
					.frame(width: 1200, height: 70)
					.rotationEffect(.degrees(38))
					.position(x: 512, y: 400)
					.blur(radius: 20)
			)
			.overlay(
				// 焦散影：玻璃舱在底板上投下的柔影，下缘被壳折射后厚玻璃感立现
				Ellipse()
					.fill(c(40/255, 90/255, 60/255, 0.35))
					.frame(width: capsuleRect.width * 0.92, height: 90)
					.position(x: capsuleRect.midX, y: capsuleRect.maxY + 34)
					.blur(radius: 26)
			)
			.overlay(
				// 液面高光：绿液顶部一条镜面反光带
				LinearGradient(colors: [c(220/255, 255/255, 230/255, 0.85), c(220/255, 255/255, 230/255, 0)],
				               startPoint: .top, endPoint: .bottom)
					.frame(width: chargeRect.width - 60, height: 34)
					.clipShape(Capsule())
					.position(x: chargeRect.midX - 10, y: chargeRect.minY + 26)
					.blur(radius: 6)
			)
			.clipShape(RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
			.frame(width: canvas, height: canvas)
	}
}

// 电池轮廓遮罩：舱体与正极帽的并集（bbox 局部坐标）
struct BatterySilhouette: Shape {
	func path(in rect: CGRect) -> Path {
		var p = Path()
		func local(_ r: CGRect) -> CGRect {
			CGRect(x: r.minX - glassBBox.minX, y: r.minY - glassBBox.minY, width: r.width, height: r.height)
		}
		p.addRoundedRect(in: local(capsuleRect), cornerSize: CGSize(width: 150, height: 150))
		p.addRoundedRect(in: local(terminalRect).insetBy(dx: -3, dy: -3), cornerSize: CGSize(width: 26, height: 26))
		return p
	}
}

// 玻璃层：外壳清玻璃 + 正极帽 + 白闪电（内容在玻璃之上）。
// 闪电的 shadow 会强制窗口进入离屏合成——没有它玻璃根本不进捕获（实测）。
struct GlassLayer: View {
	var body: some View {
		ZStack {
			GlassEffectContainer(spacing: 24) {
				ZStack {
					Capsule()
						.frame(width: capsuleRect.width, height: capsuleRect.height)
						.position(x: capsuleRect.midX - glassBBox.minX, y: capsuleRect.midY - glassBBox.minY)
						.glassEffect(.regular, in: .capsule)
					Capsule()
						.frame(width: terminalRect.width, height: terminalRect.height)
						.position(x: terminalRect.midX - glassBBox.minX, y: terminalRect.midY - glassBBox.minY)
						.glassEffect(.regular.tint(Color.white.opacity(0.30)), in: .capsule)
				}
			}
			.frame(width: glassBBox.width, height: glassBBox.height)
			.position(x: glassBBox.midX, y: glassBBox.midY)
			// 容器矩形自带暗底：裁到电池轮廓，暗底不污染底板
			.mask(
				BatterySilhouette()
					.fill()
					.frame(width: glassBBox.width, height: glassBBox.height)
					.position(x: glassBBox.midX, y: glassBBox.midY)
			)
			Path(boltPath(scale: 0.5, center: CGPoint(x: 512, y: 496)))
				.fill(Color(white: 0.99))
				.shadow(color: c(18/255, 110/255, 48/255, 0.4), radius: 8, y: 6)
		}
		.frame(width: canvas, height: canvas)
	}
}

// ---- 双窗口捕获 ----

final class CaptureDelegate: NSObject, NSApplicationDelegate {
	let outPath: String
	var tileWindow: NSWindow?
	var glassWindow: NSWindow?
	init(outPath: String) { self.outPath = outPath }

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.appearance = NSAppearance(named: .aqua)
		// 放左上角空区：避开 Dock（底部）与菜单栏（顶 25pt），整窗必须在屏内——
		// 玻璃采样屏外区域会得到黑底，整窗发灰
		let screenH = NSScreen.main?.frame.height ?? 1117
		let originY: CGFloat = 80
		let frame = CGRect(x: 60, y: originY, width: canvas, height: canvas)

		let tile = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		tile.isOpaque = true
		tile.backgroundColor = .black
		tile.hasShadow = false
		tile.level = .screenSaver
		tile.contentView = NSHostingView(rootView: TileLayer())
		tile.makeKeyAndOrderFront(nil)

		let glass = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		glass.isOpaque = false
		glass.backgroundColor = .clear
		glass.hasShadow = false
		glass.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
		glass.contentView = NSHostingView(rootView: GlassLayer())
		glass.makeKeyAndOrderFront(nil)

		self.tileWindow = tile
		self.glassWindow = glass

		// 等材质稳定合成，再把光标挪开、截该屏区
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
			guard let self else { exit(1) }
			let topLeftY = screenH - originY - canvas
			CGWarpMouseCursorPosition(CGPoint(x: screenH * 0.5, y: 40))
			// SCK 抓整屏再裁剪（screencapture -R 区域模式在本机不稳定）
			SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
				guard let display = content?.displays.first else {
					FileHandle.standardError.write("找不到显示器：\(String(describing: error))（屏幕是否唤醒？）\n".data(using: .utf8)!)
					exit(1)
				}
				let filter = SCContentFilter(display: display, excludingWindows: [])
				let config = SCStreamConfiguration()
				let px = 2 // Retina
				config.width = display.width * px
				config.height = display.height * px
				SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
					guard let full = image else {
						FileHandle.standardError.write("捕获失败：\(String(describing: error))（检查屏幕录制权限）\n".data(using: .utf8)!)
						exit(1)
					}
					let crop = CGRect(x: frame.minX * CGFloat(px), y: topLeftY * CGFloat(px),
					                  width: canvas * CGFloat(px), height: canvas * CGFloat(px))
					guard let src = full.cropping(to: crop) else {
						FileHandle.standardError.write("裁剪区域越界\n".data(using: .utf8)!)
						exit(1)
					}
					DispatchQueue.main.async {
						self.saveMasked(src, to: self.outPath)
						exit(0)
					}
				}
			}
		}
	}

	// 缩放到 1024、转 sRGB 并套 squircle 遮罩（顶窗透明角漏出的壁纸不进图标）
	@MainActor
	func saveMasked(_ cg: CGImage, to path: String) {
		let side = Int(canvas)
		let cs = CGColorSpace(name: CGColorSpace.sRGB)!
		let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
		                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		let mask = CGPath(roundedRect: CGRect(x: 99, y: 99, width: 826, height: 826),
		                  cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
		ctx.addPath(mask)
		ctx.clip()
		ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
		let out = ctx.makeImage()!
		let rep = NSBitmapImageRep(cgImage: out)
		let data = rep.representation(using: .png, properties: [:])!
		try! data.write(to: URL(fileURLWithPath: path))
		print("written: \(path)")
	}
}

// ---- 入口 ----

let outPath = CommandLine.arguments.dropFirst().first ?? "/tmp/icon_1024.png"
let app = NSApplication.shared
let delegate = CaptureDelegate(outPath: outPath)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

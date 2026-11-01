import AppKit

// 自绘菜单栏电池图标：填充宽度精确对应电量
// 样式对齐 macOS 27 原生菜单栏电池（用户 2026-10-31 实拍指定）：
// 填充贴壳满血（上下不缩进）、接电时画壳内插头（双爪朝上，从填充里打孔透底色），
// 接电态也是单色模板图随系统染色；只有低电量保留红色警示（非模板）
enum MenuBarIconRenderer {
	private static var cache: [String: NSImage] = [:]

	static func batteryImage(percent: Int, isPluggedIn: Bool, isLowBattery: Bool) -> NSImage {
		let clamped = max(0, min(100, percent))
		let key = "\(clamped)-\(isPluggedIn)-\(isLowBattery)"
		if let cached = cache[key] { return cached }

		let image = draw(percent: clamped, isPluggedIn: isPluggedIn, isLowBattery: isLowBattery)
		cache[key] = image
		return image
	}

	private static func draw(percent: Int, isPluggedIn: Bool, isLowBattery: Bool) -> NSImage {
		let size = NSSize(width: 25, height: 13)
		// 只有低电量走彩色（红），接电不再染绿——原生的接电态就是单色
		let isColored = isLowBattery
		let image = NSImage(size: size, flipped: false) { _ in
			let outlineColor = isColored
				? NSColor.secondaryLabelColor
				: NSColor.black.withAlphaComponent(0.45)
			let fillColor: NSColor = isLowBattery ? .systemRed : .black

			// 电池壳体（留出右侧电极的空间）
			let bodyRect = NSRect(x: 0.5, y: 1.5, width: 21, height: 10)
			let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.5, yRadius: 2.5)
			bodyPath.lineWidth = 1
			outlineColor.setStroke()
			bodyPath.stroke()

			// 右侧电极
			let capRect = NSRect(x: 22.5, y: 4.7, width: 1.8, height: 3.6)
			let capPath = NSBezierPath(roundedRect: capRect, xRadius: 0.9, yRadius: 0.9)
			outlineColor.setFill()
			capPath.fill()

			// 电量填充：上下只留描边线宽（贴壳满血），同原生的填充画法
			let inset: CGFloat = 1
			let maxFillWidth = bodyRect.width - inset * 2
			let fillWidth = max(0, maxFillWidth * CGFloat(percent) / 100)
			if fillWidth > 0.5 {
				let fillRect = NSRect(
					x: bodyRect.minX + inset,
					y: bodyRect.minY + inset,
					width: fillWidth,
					height: bodyRect.height - inset * 2
				)
				let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.3, yRadius: 1.3)
				fillColor.setFill()
				fillPath.fill()
			}

			// 接电插头：对齐原生「壳内插头」。填充装得下整个插头时只打孔
			// （透出底色，即原生 80% 接电的样子）；插头跨在填充边上或完全落在
			// 空芯里时，改画标签色实心插头并镞出周边间隙，任何电量下都可读
			if isPluggedIn {
				let plugRect = NSRect(
					x: bodyRect.midX - 1.85,
					y: bodyRect.midY - 3.1,
					width: 3.7,
					height: 6.2
				)
				let plug = plugPath(in: plugRect)
				let context = NSGraphicsContext.current
				let fillRight = bodyRect.minX + inset + fillWidth
				let fullyInside = fillRight >= plugRect.maxX
				let fullyOutside = fillRight <= plugRect.minX

				context?.compositingOperation = .destinationOut
				NSColor.black.setFill()
				plug.fill()
				if !fullyInside && !fullyOutside {
					NSColor.black.setStroke()
					plug.lineWidth = 2.0
					plug.lineJoinStyle = .round
					plug.stroke()
				}
				context?.compositingOperation = .sourceOver
				if !fullyInside {
					NSColor.labelColor.setFill()
					plug.fill()
				}
			}

			return true
		}
		image.isTemplate = !isColored
		return image
	}

	// 双爪朝上的电源插头：双爪 + 圆角身 + 短柄，归一化坐标设计（y 向下），
	// 映射到目标矩形。三块矩形取并集，形状比例按原生实拍量得（总高约为壳高的六成）
	private static func plugPath(in rect: NSRect) -> NSBezierPath {
		let path = NSBezierPath()
		let prongWidth: CGFloat = 0.34
		let prongDepth: CGFloat = 0.30
		let stemWidth: CGFloat = 0.30
		let stemDepth: CGFloat = 0.28
		let bodyTop: CGFloat = 0.24
		let bodyBottom: CGFloat = 0.76

		// 双爪（外缘与插头身齐平，中间留一道能透底色的缝）
		path.append(NSBezierPath(rect: NSRect(
			x: rect.minX + 0.02 * rect.width,
			y: rect.minY + (1 - prongDepth) * rect.height,
			width: prongWidth * rect.width,
			height: prongDepth * rect.height
		)))
		path.append(NSBezierPath(rect: NSRect(
			x: rect.minX + (1 - 0.02 - prongWidth) * rect.width,
			y: rect.minY + (1 - prongDepth) * rect.height,
			width: prongWidth * rect.width,
			height: prongDepth * rect.height
		)))
		// 圆角身
		path.append(NSBezierPath(roundedRect: NSRect(
			x: rect.minX,
			y: rect.minY + (1 - bodyBottom) * rect.height,
			width: rect.width,
			height: (bodyBottom - bodyTop) * rect.height
		), xRadius: 0.3, yRadius: 0.3))
		// 短柄
		path.append(NSBezierPath(rect: NSRect(
			x: rect.minX + (0.5 - stemWidth / 2) * rect.width,
			y: rect.minY,
			width: stemWidth * rect.width,
			height: stemDepth * rect.height
		)))
		return path
	}
}

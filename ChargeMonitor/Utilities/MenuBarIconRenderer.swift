import AppKit

// 自绘菜单栏电池图标：填充宽度精确对应电量
// 普通状态输出模板图由系统自动染色；充电时绿色填充、低电量红色填充，
// 轮廓用动态系统色（绘制时按菜单栏深浅色自动解析）
enum MenuBarIconRenderer {
	private static var cache: [String: NSImage] = [:]
	
	static func batteryImage(percent: Int, isCharging: Bool, isLowBattery: Bool, shimmerPhase: Double? = nil) -> NSImage {
		let clamped = max(0, min(100, percent))
		// 带流光相位的帧不进缓存（相位连续变化，小图重绘开销可忽略）
		if let shimmerPhase {
			return draw(percent: clamped, isCharging: isCharging, isLowBattery: isLowBattery, shimmerPhase: shimmerPhase)
		}
		
		let key = "\(clamped)-\(isCharging)-\(isLowBattery)"
		if let cached = cache[key] { return cached }
		
		let image = draw(percent: clamped, isCharging: isCharging, isLowBattery: isLowBattery, shimmerPhase: nil)
		cache[key] = image
		return image
	}
	
	private static func draw(percent: Int, isCharging: Bool, isLowBattery: Bool, shimmerPhase: Double?) -> NSImage {
		let size = NSSize(width: 25, height: 13)
		// 充电（绿）和低电量（红）用彩色图，其余用模板图随系统染色
		// 低电量判断由调用方传入，与全局警示条件统一（靠电池供电且 ≤20%）
		let isColored = isCharging || isLowBattery
		let image = NSImage(size: size, flipped: false) { _ in
			// 彩色模式下用动态系统色，绘制时按当前外观解析深浅色
			let outlineColor = isColored
				? NSColor.secondaryLabelColor
				: NSColor.black.withAlphaComponent(0.45)
			// 非充电时的填充色（充电走绿色渐变，不用这个）
			let fillColor: NSColor = isLowBattery ? .systemRed : .black
			
			// 电池壳体（留出右侧电极的空间）
			let bodyRect = NSRect(x: 0.5, y: 1.5, width: 21, height: 10)
			let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)
			bodyPath.lineWidth = 1
			outlineColor.setStroke()
			bodyPath.stroke()
			
			// 右侧电极
			let capRect = NSRect(x: 22.5, y: 4.7, width: 1.8, height: 3.6)
			let capPath = NSBezierPath(roundedRect: capRect, xRadius: 0.9, yRadius: 0.9)
			outlineColor.setFill()
			capPath.fill()
			
			// 电量填充
			let inset: CGFloat = 2
			let maxFillWidth = bodyRect.width - inset * 2
			let fillWidth = max(0, maxFillWidth * CGFloat(percent) / 100)
			if fillWidth > 0.5 {
				let fillRect = NSRect(
					x: bodyRect.minX + inset,
					y: bodyRect.minY + inset,
					width: fillWidth,
					height: bodyRect.height - inset * 2
				)
				let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.6, yRadius: 1.6)
				if isCharging {
					// 充电用上浅下深的绿色渐变，更有光泽感
					let gradient = NSGradient(
						starting: NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.32, alpha: 1),
						ending: NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.45, alpha: 1)
					)
					gradient?.draw(in: fillPath, angle: 90)
				} else {
					fillColor.setFill()
					fillPath.fill()
				}
				
				// 流光：一道柔边高光沿填充区从左到右扫过
				if let shimmerPhase, isCharging, fillWidth > 3 {
					NSGraphicsContext.current?.saveGraphicsState()
					fillPath.addClip()
					let bandWidth: CGFloat = 8
					let travel = fillRect.width + bandWidth * 2
					let bandRect = NSRect(
						x: fillRect.minX - bandWidth + travel * CGFloat(shimmerPhase),
						y: fillRect.minY,
						width: bandWidth,
						height: fillRect.height
					)
					let shine = NSGradient(colors: [
						NSColor.white.withAlphaComponent(0),
						NSColor.white.withAlphaComponent(0.8),
						NSColor.white.withAlphaComponent(0)
					])
					shine?.draw(in: bandRect, angle: 0)
					NSGraphicsContext.current?.restoreGraphicsState()
				}
			}
			
			// 充电闪电：自绘折线路径，先用加粗描边镞空出周边间隙，
			// 再用主标签色填实心闪电，任何电量下都清晰
			if isCharging {
				let boltRect = NSRect(
					x: bodyRect.midX - 3.1,
					y: bodyRect.midY - 4.6,
					width: 6.2,
					height: 9.2
				)
				let bolt = boltPath(in: boltRect)
				let context = NSGraphicsContext.current
				
				context?.compositingOperation = .destinationOut
				NSColor.black.setStroke()
				NSColor.black.setFill()
				bolt.lineWidth = 2.4
				bolt.lineJoinStyle = .round
				bolt.stroke()
				bolt.fill()
				
				context?.compositingOperation = .sourceOver
				(isColored ? NSColor.labelColor : NSColor.black).setFill()
				bolt.fill()
			}
			
			return true
		}
		image.isTemplate = !isColored
		return image
	}
	
	// 经典闪电折线：归一化坐标设计，映射到目标矩形
	private static func boltPath(in rect: NSRect) -> NSBezierPath {
		// (x, y) 为设计坐标，y 向下：顶点 → 左中 → 中枪 → 底尖 → 右中 → 中枪
		let designPoints: [(CGFloat, CGFloat)] = [
			(0.62, 0.0),
			(0.00, 0.58),
			(0.42, 0.58),
			(0.36, 1.00),
			(1.00, 0.41),
			(0.56, 0.41)
		]
		
		let path = NSBezierPath()
		for (index, point) in designPoints.enumerated() {
			let target = NSPoint(
				x: rect.minX + point.0 * rect.width,
				y: rect.minY + (1 - point.1) * rect.height
			)
			if index == 0 {
				path.move(to: target)
			} else {
				path.line(to: target)
			}
		}
		path.close()
		return path
	}
}

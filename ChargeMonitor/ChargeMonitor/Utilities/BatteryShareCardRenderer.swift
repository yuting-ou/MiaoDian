import AppKit

// 电池体检分享卡片：把评分 + 关键指标渲染成一张漂亮图片，供用户存图分享
// 纯 AppKit 离屏绘制，不依赖界面；与面板体检同一套配色
enum BatteryShareCardRenderer {
	struct CardData {
		let score: Int
		let verdict: String
		let healthPercent: Int?
		let cycleCount: Int?
		let temperatureC: Double?
		let generatedAt: Date
	}

	static func render(_ data: CardData) -> NSImage {
		let size = NSSize(width: 600, height: 380)
		let image = NSImage(size: size, flipped: false) { rect in
			// 渐变背景：按分数选主色调，从深到浅斜向铺满
			let accent = scoreColor(data.score)
			let bg = NSGradient(colors: [
				accent.blended(withFraction: 0.55, of: .black) ?? accent,
				accent.blended(withFraction: 0.15, of: .black) ?? accent
			])
			bg?.draw(in: rect, angle: 120)

			let white = NSColor.white

			// 顶部品牌行
			drawText("妙电 · 电池体检", at: NSPoint(x: 40, y: 312), size: 20, weight: .semibold, color: white.withAlphaComponent(0.9))

			// 大分数
			drawText("\(data.score)", at: NSPoint(x: 38, y: 200), size: 96, weight: .bold, color: white)
			drawText("分", at: NSPoint(x: 190, y: 214), size: 28, weight: .medium, color: white.withAlphaComponent(0.85))
			drawText(data.verdict, at: NSPoint(x: 40, y: 168), size: 22, weight: .medium, color: white.withAlphaComponent(0.95))

			// 右上角环形分数
			drawRing(score: data.score, center: NSPoint(x: 490, y: 250), radius: 62, color: white)

			// 底部指标行
			var metrics: [(String, String)] = []
			if let health = data.healthPercent { metrics.append(("健康度", "\(health)%")) }
			if let cycles = data.cycleCount { metrics.append(("循环次数", "\(cycles)")) }
			if let temp = data.temperatureC { metrics.append(("温度", String(format: "%.1f°C", temp))) }

			let columnWidth: CGFloat = 520 / CGFloat(max(1, metrics.count))
			for (index, metric) in metrics.enumerated() {
				let x = 40 + columnWidth * CGFloat(index)
				drawText(metric.1, at: NSPoint(x: x, y: 86), size: 24, weight: .semibold, color: white)
				drawText(metric.0, at: NSPoint(x: x, y: 62), size: 13, weight: .regular, color: white.withAlphaComponent(0.7))
			}

			// 生成时间脚注
            drawText(Self.dateFormatter.string(from: data.generatedAt), at: NSPoint(x: 40, y: 28), size: 12, weight: .regular, color: white.withAlphaComponent(0.6))

			return true
		}
		return image
	}

	// 把卡片写到临时目录，返回文件 URL（PNG）
	static func writePNG(_ image: NSImage, filenamePrefix: String = "电池体检") -> URL? {
		guard let tiff = image.tiffRepresentation,
			let rep = NSBitmapImageRep(data: tiff),
			let png = rep.representation(using: .png, properties: [:]) else { return nil }
		let name = "\(filenamePrefix)-\(fileFormatter.string(from: Date())).png"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
		do {
			try png.write(to: url)
			return url
		} catch {
			DiagnosticLog.failureOnce("share-card-write-failed", category: "BatteryShareCardRenderer", "分享卡片写入失败：\(error.localizedDescription)")
			return nil
		}
	}

	// MARK: - 绘制辅助

	// 分档用 BatteryCheckup.tier 统一判定（色值因跨框架仍用 NSColor，但分档不再重复）
	private static func scoreColor(_ score: Int) -> NSColor {
		switch BatteryCheckup.tier(for: score) {
		case .excellent: return NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.40, alpha: 1)
		case .good: return NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.60, alpha: 1)
		case .aging: return NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.15, alpha: 1)
		case .poor: return NSColor(calibratedRed: 0.80, green: 0.30, blue: 0.30, alpha: 1)
		}
	}

	private static func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
		let attributes: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: size, weight: weight),
			.foregroundColor: color
		]
		text.draw(at: point, withAttributes: attributes)
	}

	private static func drawRing(score: Int, center: NSPoint, radius: CGFloat, color: NSColor) {
		let track = NSBezierPath()
		track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
		track.lineWidth = 8
		color.withAlphaComponent(0.2).setStroke()
		track.stroke()

		// 手动多段线画进度弧：从顶部 90° 顺时针（角度递减）扫过 score% 周，
		// 全程用 Double 计算再转回坐标，避开 CGFloat/Double 混算与 appendArc 方向双重坑
		let fraction = min(max(Double(score) / 100, 0), 1)
		guard fraction > 0 else { return }
		let steps = 96
		let cx = Double(center.x), cy = Double(center.y), r = Double(radius)
		let progress = NSBezierPath()
		for i in 0...steps {
			let t = Double(i) / Double(steps)
			let angleRad = (90 - 360 * fraction * t) * Double.pi / 180
			let point = NSPoint(x: cx + r * cos(angleRad), y: cy + r * sin(angleRad))
			if i == 0 { progress.move(to: point) } else { progress.line(to: point) }
		}
		progress.lineWidth = 8
		progress.lineCapStyle = .round
		progress.lineJoinStyle = .round
		color.setStroke()
		progress.stroke()
	}

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm 生成"
		return formatter
	}()

	private static let fileFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter
	}()
}

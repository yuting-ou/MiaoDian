import AppKit

// 菜单栏电量走势迷你曲线：把近 24 小时的 SOC 采样浓缩成一条极小 sparkline
// 只画曲线本身（约 32×13），百分比数字由 SwiftUI 那边拼在右侧，便于自动适配深浅色
enum MenuBarSparklineRenderer {
	static func image(percents: [Int], isLow: Bool) -> NSImage {
		let size = NSSize(width: 32, height: 13)
		let image = NSImage(size: size, flipped: false) { _ in
			guard percents.count >= 2 else { return true }
			let maxV = percents.max() ?? 100
			let minV = percents.min() ?? 0
			// 电量波动小时给个下限，免得几个百分点被拉成剧烈起伏
			let range = max(maxV - minV, 10)

			let lineColor: NSColor = isLow ? .systemRed : .secondaryLabelColor
			let path = NSBezierPath()
			for (index, percent) in percents.enumerated() {
				let x = size.width * CGFloat(index) / CGFloat(percents.count - 1)
				let normalized = CGFloat(percent - minV) / CGFloat(range)
				let y = 2 + normalized * (size.height - 4)
				let point = NSPoint(x: x, y: y)
				if index == 0 { path.move(to: point) } else { path.line(to: point) }
			}
			path.lineWidth = 1.3
			path.lineJoinStyle = .round
			lineColor.setStroke()
			path.stroke()

			// 末端当前点，突出"现在"
			if let last = percents.last {
				let normalized = CGFloat(last - minV) / CGFloat(range)
				let end = NSPoint(x: size.width, y: 2 + normalized * (size.height - 4))
				let dot = NSBezierPath(ovalIn: NSRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4))
				lineColor.setFill()
				dot.fill()
			}
			return true
		}
		// 非低电用模板图随系统染色；低电已是红色，保持原样
		image.isTemplate = !isLow
		return image
	}
}

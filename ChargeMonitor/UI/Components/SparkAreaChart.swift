import SwiftUI

// 面板迷你曲线的通用组件：中点二次曲线平滑 + 渐变填充 + 末端光点
// 功耗/温度/健康趋势三条曲线此前是三份雷同的 Canvas 代码，统一收拢到这里；
// 传入 hoverLabel 即获得"悬停查数值"能力（游标竖线 + 数值气泡）
struct SparkAreaChart: View {
	let values: [Double]
	let color: Color
	// range 下限：波动极小时防止把毫厘抖动画成惊涛骇浪
	var minRange: Double = 1.0
	// 曲线所占纵向区域（底部位置与高度，均为比例值）
	var bandBottom: CGFloat = 0.88
	var bandHeight: CGFloat = 0.72
	// 悬停时的说明文字（传入点位下标）；nil 表示不启用悬停
	var hoverLabel: ((Int) -> String)? = nil
	
	@State private var hoverIndex: Int? = nil
	
	var body: some View {
		GeometryReader { geo in
			chartCanvas
				.onContinuousHover { phase in
					guard hoverLabel != nil, values.count >= 2, geo.size.width > 0 else { return }
					switch phase {
					case .active(let location):
						let raw = Int((location.x / geo.size.width * CGFloat(values.count - 1)).rounded())
						hoverIndex = min(max(raw, 0), values.count - 1)
					case .ended:
						hoverIndex = nil
					}
				}
		}
	}
	
	private var chartCanvas: some View {
		Canvas { context, size in
			guard values.count >= 2, let maxV = values.max(), let minV = values.min() else { return }
			let range = max(maxV - minV, minRange)
			
			let points = values.enumerated().map { index, value -> CGPoint in
				let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
				let normalized = (value - minV) / range
				let y = size.height * (bandBottom - bandHeight * CGFloat(normalized))
				return CGPoint(x: x, y: y)
			}
			
			// 中点二次曲线平滑
			var linePath = Path()
			linePath.move(to: points[0])
			for index in 1..<points.count {
				let previous = points[index - 1]
				let current = points[index]
				let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
				linePath.addQuadCurve(to: mid, control: previous)
			}
			if let last = points.last {
				linePath.addLine(to: last)
			}
			
			var fillPath = linePath
			fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
			fillPath.addLine(to: CGPoint(x: 0, y: size.height))
			fillPath.closeSubpath()
			
			context.fill(
				fillPath,
				with: .linearGradient(
					Gradient(colors: [color.opacity(0.3), color.opacity(0.02)]),
					startPoint: .zero,
					endPoint: CGPoint(x: 0, y: size.height)
				)
			)
			context.stroke(linePath, with: .color(color), lineWidth: 1.5)
			
			// 曲线末端标记当前位置：实心小圆点 + 淡色光晕
			if let last = points.last {
				let halo = Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8))
				context.fill(halo, with: .color(color.opacity(0.25)))
				let dot = Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4))
				context.fill(dot, with: .color(color))
			}
			
			// 悬停游标：竖线 + 落点圆 + 数值气泡
			if let index = hoverIndex, index < points.count, let label = hoverLabel?(index) {
				let point = points[index]
				var cursor = Path()
				cursor.move(to: CGPoint(x: point.x, y: 2))
				cursor.addLine(to: CGPoint(x: point.x, y: size.height))
				context.stroke(cursor, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
				
				let marker = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
				context.fill(marker, with: .color(color))
				
				let resolved = context.resolve(
					Text(label)
						.font(.system(size: 9, weight: .medium).monospacedDigit())
						.foregroundStyle(Color.primary)
				)
				let textSize = resolved.measure(in: size)
				// 气泡贴顶显示，水平方向夹在图内不出界
				let bubbleWidth = textSize.width + 10
				let bubbleX = min(max(point.x - bubbleWidth / 2, 0), size.width - bubbleWidth)
				let bubbleRect = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: textSize.height + 4)
				context.fill(
					Path(roundedRect: bubbleRect, cornerRadius: 4),
					with: .color(color.opacity(0.16))
				)
				context.draw(resolved, at: CGPoint(x: bubbleRect.midX, y: bubbleRect.midY), anchor: .center)
			}
		}
	}
}

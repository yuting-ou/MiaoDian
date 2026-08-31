import AppKit
import SwiftUI

// 面板入场级联动画：按 step 档位递增延迟，让头部、各卡片、控制行错峰依次“落位”，
// 而非整块齐发——像控制中心元素逐个到位那种层次感。单列/双列共用，未入场时下移+缩小+淡出
struct CascadeIn: ViewModifier {
	let step: Int
	let active: Bool
	// 首块与每块间隔的延迟（秒）；档位封顶避免卡片多时尾部拖得太晚
	private var delay: Double { min(Double(step) * 0.038, 0.3) }
	
	func body(content: Content) -> some View {
		content
			.opacity(active ? 1 : 0)
			.offset(y: active ? 0 : 14)
			// 用轻微缩放替代 blur 做“聚焦感”：blur 是逐帧高斯模糊，多卡片同时入场会掉帧；
			// scale 走 GPU 变换几乎零开销，丝滑得多（见项目 numericText/持续动画掉帧的同类教训）
			.scaleEffect(active ? 1 : 0.96, anchor: .top)
			// 更长更柔的弹簧（阻尼 0.9 基本不回弹），配 blendDuration 让插值更连贯不顿挫
			.animation(.spring(response: 0.5, dampingFraction: 0.9, blendDuration: 0.1).delay(active ? delay : 0), value: active)
	}
}

enum PopoverLayout {
	static let horizontalPadding: CGFloat = 16
	static let bodyFontSize: CGFloat = 12
	static let rowHeight: CGFloat = 22
	static let rowHorizontalPadding: CGFloat = 10
	static let rowVerticalPadding: CGFloat = 3
	static let sectionSpacing: CGFloat = 4
	static let rowCornerRadius: CGFloat = 8
}

struct PopoverInfoLine: View {
	private let text: String
	
	init(_ text: String) {
		self.text = text
	}
	
	var body: some View {
		Text(text)
			.font(.system(size: PopoverLayout.bodyFontSize, weight: .regular))
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, PopoverLayout.rowVerticalPadding)
	}
}

// 区块小标题
struct PopoverSectionHeader: View {
	private let title: String
	
	init(_ title: String) {
		self.title = title
	}
	
	var body: some View {
		Text(title)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(.secondary)
			.padding(.top, 2)
	}
}

// 可折叠区块的标题行：标题 + 尾部附件 + 折叠箭头，点击整行切换
// 面板卡片多了以后一屏放不下，不常看的图表收起来省地方
struct CollapsibleSectionHeader<Accessory: View>: View {
	let title: String
	let isCollapsed: Bool
	let onToggle: () -> Void
	@ViewBuilder var accessory: Accessory
	
	var body: some View {
		Button(action: onToggle) {
			HStack(spacing: 4) {
				PopoverSectionHeader(title)
				Spacer()
				accessory
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .semibold))
					.foregroundStyle(.tertiary)
					.rotationEffect(.degrees(isCollapsed ? -90 : 0))
					.padding(.leading, 2)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

// 圆角卡片容器：连续曲率圆角 + 发丝线描边，更贴近系统控制中心质感
struct PopoverCard<Content: View>: View {
	private let content: Content
	
	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			content
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(Color(nsColor: .quaternarySystemFill))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
		)
	}
}

// 图标 + 标签 + 右对齐值的信息行
struct PopoverInfoRow: View {
	let item: BatteryInfoItem
	
	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: item.symbol)
				.font(.system(size: 11, weight: .medium))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(item.iconTint ?? Color.secondary)
				.frame(width: 16)
			
			Text(item.label)
				.font(.system(size: PopoverLayout.bodyFontSize))
				.foregroundStyle(.secondary)
			
			Spacer(minLength: 12)
			
			// 等宽数字避免刷新时左右跳动。转场用淡入淡出而非 numericText 数字滚动：
			// 这些值每 2 秒就变，numericText 会不断生成插值字形位图，
			// 实测内存会以每分钟几十 MB 的速度持续膨胀；淡入淡出没有逐帧插值字形
			Text(item.value)
				.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium).monospacedDigit())
				.foregroundStyle(item.valueTint ?? Color.primary)
				.lineLimit(1)
				.minimumScaleFactor(0.7)
				.contentTransition(.opacity)
				.animation(.easeInOut(duration: 0.3), value: item.value)
		}
		.padding(.vertical, 3)
		.help(item.helpText ?? item.value)
	}
}

struct PopoverActionRow: View {
	private let title: String
	private let icon: NSImage?
	private let systemImageName: String?
	private let showsChevron: Bool
	private let action: () -> Void

	init(_ title: String, icon: NSImage? = nil, systemImageName: String? = nil, showsChevron: Bool = false, action: @escaping () -> Void) {
		self.title = title
		self.icon = icon
		self.systemImageName = systemImageName
		self.showsChevron = showsChevron
		self.action = action
	}
	
	var body: some View {
		Button(action: action) {
			HoverHighlightRow {
				HStack(spacing: 6) {
					if let icon {
						Image(nsImage: icon)
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
							.cornerRadius(4)
					} else if let systemImageName {
						Image(systemName: systemImageName)
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(.secondary)
							.frame(width: 16)
					}
					Text(title)
						.font(.system(size: PopoverLayout.bodyFontSize, weight: .regular))
						.foregroundStyle(.primary)

					Spacer(minLength: 8)

					if showsChevron {
						Image(systemName: "chevron.right")
							.font(.system(size: 8, weight: .semibold))
							.foregroundStyle(.tertiary)
					}
				}
				.frame(maxWidth: .infinity, minHeight: PopoverLayout.rowHeight, alignment: .leading)
				.padding(.horizontal, PopoverLayout.rowHorizontalPadding)
				.contentShape(Rectangle())
			}
		}
		.buttonStyle(.plain)
	}
}

struct HoverHighlightRow<Content: View>: View {
	private let content: Content
	@State private var isHovering = false
	
	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}
	
	var body: some View {
		content
			.background(
				RoundedRectangle(cornerRadius: PopoverLayout.rowCornerRadius, style: .continuous)
					.fill(isHovering ? Color.primary.opacity(0.08) : .clear)
			)
			.onHover { isHovering = $0 }
	}
}

import AppKit
import SwiftUI

// 面板入场级联动画：按 step 档位递增延迟，让头部、各卡片、控制行错峰依次”落位”，
// 而非整块齐发——像控制中心元素逐个到位那种层次感。单列/双列共用，未入场时下移+缩小+淡出。
// 「减少动态效果」开启时直接呈现终态：不位移、不缩放、不淡入，也不挂动画（可读性安全网必须接住）
struct CascadeIn: ViewModifier {
	let step: Int
	let active: Bool
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	// 首块与每块间隔的延迟（秒）；档位封顶避免卡片多时尾部拖得太晚
	private var delay: Double { min(Double(step) * 0.038, 0.3) }
	
	@ViewBuilder
	func body(content: Content) -> some View {
		if reduceMotion {
			content
		} else {
			content
				.opacity(active ? 1 : 0)
				.offset(y: active ? 0 : 14)
				// 用轻微缩放替代 blur 做”聚焦感”：blur 是逐帧高斯模糊，多卡片同时入场会掉帧；
				// scale 走 GPU 变换几乎零开销，丝滑得多（见项目 numericText/持续动画掉帧的同类教训）
				.scaleEffect(active ? 1 : 0.96, anchor: .top)
				// 更长更柔的弹簧（阻尼 0.9 基本不回弹），配 blendDuration 让插值更连贯不顿挫
				.animation(.spring(response: 0.5, dampingFraction: 0.9, blendDuration: 0.1).delay(active ? delay : 0), value: active)
		}
	}
}

enum PopoverLayout {
	static let horizontalPadding: CGFloat = 16
	static let bodyFontSize: CGFloat = 12
	static let rowHeight: CGFloat = 22
	static let rowHorizontalPadding: CGFloat = 10
	static let rowVerticalPadding: CGFloat = 3
	static let sectionSpacing: CGFloat = 3
	static let rowCornerRadius: CGFloat = 8
	// 信息行两列布局：标签列宽按最长标签（"剩余可用时间"6 字 @11.5pt）定，
	// 值从这条线起左对齐——值列左缘不再随值长短锯齿化
	static let infoLabelColumnWidth: CGFloat = 64
	static let infoValueFontSize: CGFloat = 12.5
}

/// 面板字阶（唯一来源，替代散在 12 个文件里的 135 处硬编码 `.font(.system(size:))`）。
///
/// 第一性原理：**层次由字号、颜色、位置承担，字重是最后手段**。苹果的面板几乎不用
/// semibold 去喊"这是数字"——Settings 的行、活动监视器的列表都是 regular 值 +
/// secondary 标签。我们此前的做法相反：19 行信息行的值全部 semibold、8pt 角标加粗、
/// 头部 27pt bold 圆角，满屏都在"提高音量"，层次反而糊掉，读起来累。
///
/// 字重预算（写死，新增文字按这个取，不许再发明第三种）：
/// - `.regular`：一切正文、数值、辅文、角标、图例。等宽数字 + 固定列宽已经保证可扫读。
/// - `.medium`：只给"一张卡里唯一需要被强调的那个数字"（当前功率、体检分）。
/// - `.semibold`：只给四处——区块标题、头部主数字、**表格的值列**（表格靠字重分列）、
///   **按钮标题**（苹果按钮惯例）。除此之外一律 regular。
/// - `.bold`：**一律不用**。圆角设计（`.rounded`）本身已有辨识度，bold 只是噪音。
///
/// 字阶 5 档 + 两个角色档：8（角标）→ 9.5（辅文）→ 11（标签/正文）→ 12.5（主数值）→ 27/15（头部），
/// 外加 **label 11.5**（信息行标签，与 `PopoverLayout.infoLabelColumnWidth` 绑定）与 **10.5**（表格/徽章正文）。
/// 原散落的 10 / 13 / 14 归并到 caption / primary；10.5 与 11.5 是角色档，保留原值只降字重。
/// 图表轴、表格、悬停提示里仍有一些字面量字号（9/10/11/12）——那是角色专用，不硬塞进公共档。
nonisolated enum PanelText {
	static let micro: CGFloat = 8
	static let caption: CGFloat = 9.5
	static let secondary: CGFloat = 11
	static let primary: CGFloat = 12.5
	static let display: CGFloat = 27
	static let displaySub: CGFloat = 15
	/// 信息行标签档。**与 `PopoverLayout.infoLabelColumnWidth` 绑定**：
	/// 那个列宽按"最长标签 6 字 @11.5pt"定，改这里不改列宽会把值列左缘撕锯齿
	static let label: CGFloat = 11.5
}

struct PopoverInfoLine: View {
	private let text: String
	
	init(_ text: String) {
		self.text = text
	}
	
	var body: some View {
		Text(text)
			.font(.system(size: PanelText.secondary, weight: .regular))
			.foregroundStyle(GlassTokens.labelOnGlass)
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
			.font(.system(size: PanelText.secondary, weight: .semibold))
			// 区块标题只用 labelOnGlass：想"再退一步"而叠 opacity 是违纪——
			// GlassTokens 证明线是 primary@0.85（最坏 4.5:1），再叠 0.75 就掉到 0.64。
			// "退后"靠字号与留白承担，不靠透明度（系统 .secondary 同样不行，2.7:1）
			.foregroundStyle(GlassTokens.labelOnGlass)
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
					.font(.system(size: PanelText.micro, weight: .regular))
					.foregroundStyle(.tertiary)
					.rotationEffect(.degrees(isCollapsed ? -90 : 0))
					.padding(.leading, 2)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

// 圆角卡片容器：26 上是玻璃板的极淡分区+发丝线（不各自成玻璃，内容对比度由外壳统一柔化）；
// 15–25 上保持原 quaternarySystemFill+描边质感。内边距维持 10/7——信息密度不得因玻璃倒退
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
		.padding(.vertical, 3)   // v2.1.2：7→6→5→4→3，12 张卡共省 ~96pt（面板必须整块落在 Dock 之上）
		.frame(maxWidth: .infinity, alignment: .leading)
		.cardSection()
	}
}

// 图标 + 标签列 + 值列左对齐的信息行（v2.1.2 观感整改）
// 撤掉彩色后，"标签 vs 值"和"值 vs 值"都失去了区分手段——右对齐的长短值还会把值列左缘
// 撕成锯齿，眼睛没法纵向扫描。改法：标签固定列宽左对齐、值从固定列起点左对齐，
// 层次靠**颜色与列位置**承担（标签 secondary、值 primary），字重一律 regular——
// 19 行值全 semibold 的年代，每行都在喊，层次反而糊掉（见 PanelText 的字重预算）。
// 彩色小字坐玻璃面不达 AA，见测试「文字色锁」，所以区分不给颜色，给明度与位置。
struct PopoverInfoRow: View {
	let item: BatteryInfoItem

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: item.symbol)
				.font(.system(size: PanelText.secondary, weight: .regular))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(item.iconTint ?? Color.secondary)
				.frame(width: 16)

			Text(item.label)
				.font(.system(size: PanelText.label))
				// 标签不可以用系统 .secondary：GlassTokens 记着"secondary 在透底上最坏 2.7:1 不达 AA，
				// primary 85% 最坏 4.5:1 达标"。所以层次不给明度差，给**位置差**（固定列宽 + 左对齐），
				// 亮暗只保留 85%→100% 这一档（值 .primary），可扫读性由等宽数字与列位保证
				.foregroundStyle(GlassTokens.labelOnGlass)
				.lineLimit(1)
				.minimumScaleFactor(0.8)
				.frame(width: PopoverLayout.infoLabelColumnWidth, alignment: .leading)

			// 等宽数字避免刷新时左右跳动。曾用 numericText 数字滚动，实测内存以每分钟几十 MB
			// 的速度膨胀（逐帧生成插值字形位图），已永久禁用；淡入淡出没这个毛病，但它会把整树
			// 布局按帧拖起来——所以只留给"事件行"，判据见 item.animatesOnChange
			Text(item.value)
				.font(.system(size: PanelText.primary, weight: .regular).monospacedDigit())
				.foregroundStyle(.primary)  // 值文字恒走已证明的自适应色；异常语义在文案里（玻璃优先裁决）
				// 两行上限：值里带语义标记（「（偏低）」「疑似慢充」等）时，
				// 单行截断会把标记切掉——等于"文案说了但看不见"，比原来的染色更糟
				.lineLimit(2)
				.minimumScaleFactor(0.85)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentTransition(.opacity)
				// 每拍都会重算出不同文本的行不挂淡变（PROGRESS.md 轮17 同进程配对：留淡变时一次
				// 发布 830 轮布局/358ms，撤掉后 2 轮/82ms）。数字照常即时更新，只是不再交叉淡入
				.animation(item.animatesOnChange ? .easeInOut(duration: PanelMotion.valueFadeSeconds) : nil, value: item.value)
		}
		.padding(.vertical, 1.5) // v2.1.2：3→2→1.5（面板高度受屏幕可用高约束）
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
			GlassRow {
				HStack(spacing: 6) {
					if let icon {
						Image(nsImage: icon)
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
							.cornerRadius(4)
					} else if let systemImageName {
						Image(systemName: systemImageName)
							.font(.system(size: PanelText.secondary, weight: .regular))
							.foregroundStyle(GlassTokens.labelOnGlass)
							.frame(width: 16)
					}
					Text(title)
						.font(.system(size: PanelText.secondary, weight: .regular))
						.foregroundStyle(.primary)

					Spacer(minLength: 8)

					if showsChevron {
						Image(systemName: "chevron.right")
							.font(.system(size: PanelText.micro, weight: .regular))
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

// 可交互玻璃行：控制行/警示行的统一底。26 上常态即淡玻璃药丸（按钮可供性写在材质上），
// interactive 玻璃自己响应悬停与按压的镜面高光；15–25 退回原悬停灰底行为
struct GlassRow<Content: View>: View {
	private let content: Content
	@State private var isHovering = false
	
	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}
	
	var body: some View {
		if #available(macOS 26.0, *) {
			// v1.24.1 浓 tint 药丸：行文字坐 tint（控制行自成才，不再依赖 v1.24.0 的整块卡纱垫板）
			content.controlPillGlass()
		} else {
			content
				.background(
					RoundedRectangle(cornerRadius: PopoverLayout.rowCornerRadius, style: .continuous)
						.fill(isHovering ? Color.primary.opacity(0.08) : .clear)
				)
				.onHover { isHovering = $0 }
		}
	}
}

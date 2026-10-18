import AppKit
import SwiftUI

// 面板入场级联动画：按 step 档位递增延迟，让头部、各卡片、控制行错峰依次”落位”，
// 而非整块齐发——像控制中心元素逐个到位那种层次感。单列/双列共用，未入场时下移+缩小+淡出。
// 「减少动态效果」开启时直接呈现终态：不位移、不缩放、不淡入，也不挂动画（可读性安全网必须接住）
struct CascadeIn: ViewModifier {
	let step: Int
	let active: Bool
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	// 首块与每块间隔的延迟（秒）；档位封顶避免卡片多时尾部拖得太晚。
	// ↓ 2026-10-16 定数依据（面板显示后 2 秒的宿主重排轮次与主线程忙时）：
	//   · 消融在 /tmp 整棵源码副本上做（轮17 先例：开关不进产码），**一臂一进程、一进程一棵树、严格交替 3 轮**：
	//     基线 3 344 轮/1 041 ms｜全撤入场 173/269｜把手层整棵不挂 3 400/1 039｜探针整棵不挂 3 360/1 035
	//     ⇒ 重排弹簧族与把手/探针**都不是账**（这与轮17/18 的旧线索相反）；
	//   · 账在"入场动画在飞多久"。但**不是干净的单变量**——本组同时改了 response、步长与封顶，
	//     并去掉了 blendDuration，未逐项分离；且"块数"也不是完全无关（22 块不错峰 747ms、
	//     只留 2 块原时长 692ms），只是都比不上砍时长：本组常数 1 543 轮/618 ms。
	//   · 产码侧可复跑验证（不依赖 /tmp）：`bash 工具/滚动成本.sh idle yes decay` 三轮
	//     t=0 簇 3 208→1 520 轮、前 2 秒忙时 1 045–1 058→607–673 ms、+10s 簇 1 400→1 014 轮。
	//   · 注意：错峰只在**每进程第一次打开**生效（`BatteryPopoverView.hasPlayedCascade` 之后 step 归零），
	//     所以步长/封顶那半只影响首开，response 那半每次打开都吃得到。
	//   · 观感（入场变快变硬）**未经用户眼睛验收，不得据此发布**。
	private var delay: Double { min(Double(step) * 0.019, 0.15) }
	
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
				// 阻尼 0.9 基本不回弹；response 0.5→0.25 的实测依据见上方 delay 注释
				.animation(.spring(response: 0.25, dampingFraction: 0.9).delay(active ? delay : 0), value: active)
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
	/// 面板内所有"面"（卡片／头部／编辑模式提示条）的左右内边距，**一个数**。
	/// 原先卡片 10、头部 12、编辑条 10 并存 ⇒ 头部整列比下面的卡右移 2pt，
	/// 首行读数与卡片标题不在一条竖线上
	static let faceHorizontalPadding: CGFloat = 10
	/// 图标列宽与"图标→文字"间距，**信息行/控制行/菜单行/状态行共用**。
	/// 原先信息行 HStack spacing 8、其余三处 6 ⇒ 同一列文字差 2pt 对不齐
	///
	/// **面板的两条竖线（v2.9.21 用户指出底部 4 行错位后定下的规矩）**：
	/// 挂了图标列的行，文字落在 面内缩+16+6 = 面内缩+22；不挂的落在 面内缩。
	/// 前者是**数据行**（卡内读数、高耗电应用、状态行），后者是**标题级**
	/// （卡片标题、折叠行标题、控制行动作）。控制行原本也挂了图标 ⇒ 它的文字
	/// 比正上方 时段用电/24小时电量/功耗曲线 整条右移 22pt，跨组扫读就是"没对齐"。
	/// 所以控制行的四个动作**不挂图标**：动作名自解释，图标不携带信息。
	static let iconColumnWidth: CGFloat = 16
	static let iconTextGap: CGFloat = 6
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
		.padding(.horizontal, PopoverLayout.faceHorizontalPadding)
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
/// 图标光学重心微调表。
///
/// 依据：`bash 工具/离屏验收.sh symbols`（8× 超采样扫墨迹包围盒，量"墨迹中心 − 布局框中心"）。
/// 名册 24 个符号：**17 个 dx = 0.00、5 个 −0.06，只有下面两个 ≥ 0.25pt**，
/// 所以只登记这两个——其余进表就是在拟合噪声。
///
/// **口径**：只量 `PanelText.secondary`（11pt）这一档。洞察卡（12/9pt）、事件时间轴
/// 与续航换算（9.5pt）也走 16pt 图标列，但偏心量随字号缩放，拿 11pt 的数填进去是假精度，
/// 所以那三处**故意不补偿**。
///
/// 用 `.offset` 不用 `.padding`：offset 只改渲染不改布局，
/// 所以卡片的声明高、折行预测、`PanelCardHeights` 全都不受影响。
enum PanelIconOptics {
	/// 水平微调（pt，正=右移）。dy 全 ≤0.25pt 且各符号基线一致，不做纵向表
	nonisolated static func dx(_ symbol: String) -> CGFloat {
		switch symbol {
		case "thermometer.medium": return -0.56      // 电池温度：墨迹偏右 0.56pt
		case "bolt.badge.clock": return -0.62        // 充电记录行：墨迹偏右 0.62pt
		default: return 0
		}
	}
}

struct PopoverInfoRow: View {
	let item: BatteryInfoItem

	var body: some View {
		HStack(spacing: PopoverLayout.iconTextGap) {
			Image(systemName: item.symbol)
				.font(.system(size: PanelText.secondary, weight: .regular))
				.symbolRenderingMode(.hierarchical)
				// 图标色是**预算**，不是装饰：常态一律 labelOnGlass（与信息行/控制行同一个证明过的色），
				// 只有携带语义的 tint 才染色（当前只有充电器行：橙=没认过的头，绿=已识别）。
				// 原先 16 条行各配一个固定色相，颜色不编码任何信息，红/橙还伪装成警示态
				.foregroundStyle(item.iconTint ?? GlassTokens.labelOnGlass)
				.frame(width: PopoverLayout.iconColumnWidth)
				.offset(x: PanelIconOptics.dx(item.symbol))

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

/// 菜单项：`.action(标题, SF Symbol, 动作)` 或 `.divider`
enum PanelMenuItem {
	case action(String, String, () -> Void)
	case divider
}

/// 用 AppKit 弹原生菜单。
///
/// 为什么不用 SwiftUI 的 `Menu`：行的**视觉**得交给 `Menu` 的 label 摆位，而
/// `borderlessButton` 按自己的内容缩进放 label。常数灰背景上逐行量过三种写法：
///   玻璃套在 label 里 → 药丸完全不画（`Menu` 不合成 label 内部的玻璃层）；
///   玻璃施在控件外圈 → 药丸高 16.00pt，同排其它行 23.00pt；
///   `GeometryReader` 钉死宽高 → 面与高都对了（12.0..571.5pt / 23.00pt），
///   但**图标与文字仍比同排三行靠左 6.5pt**（首墨 16.0pt vs 22.5/24.0/24.5pt）。
/// 即"框对得上、列对不上"，而那个偏移来自控件内部、没有可钉的公开尺寸。
///
/// 换成 AppKit 后，行就是上下几行用的**同一个** `PopoverActionRow`：
/// 几何由构造保证，不需要补偿常量，也不需要靠我盯放大图判断"看起来齐了"。
@MainActor
final class PanelMenuPresenter: NSObject {
	static let shared = PanelMenuPresenter()
	private var actions: [() -> Void] = []

	@objc private func fire(_ sender: NSMenuItem) {
		guard sender.tag >= 0, sender.tag < actions.count else { return }
		actions[sender.tag]()
	}

	func popUp(_ items: [PanelMenuItem]) {
		actions.removeAll(keepingCapacity: true)
		let menu = NSMenu()
		for item in items {
			switch item {
			case .divider:
				menu.addItem(.separator())
			case .action(let title, let symbol, let handler):
				let entry = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
				entry.target = self
				entry.tag = actions.count
				entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
				actions.append(handler)
				menu.addItem(entry)
			}
		}
		// view 传 nil 时 location 是屏幕坐标（左下原点），NSEvent.mouseLocation 正是同一坐标系。
		// 这个 SDK 的 `at:` 不是可选型，没有"传 nil 就用鼠标位置"的写法可用
		menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
		// 闭包捕获的是 configurationManager/export* 这一整批上下文，菜单关掉后没有理由再持有
		actions.removeAll(keepingCapacity: true)
	}
}

/// 控制行的「更多」一格：视觉复用 `PopoverActionRow`（同一个视图、同一套几何），
/// 点击弹 AppKit 原生菜单。低频动作收在这里，控制行不再用 8 行吃掉面板约 1/4 高度
struct PopoverMenuRow: View {
	private let title: String
	private let items: [PanelMenuItem]

	init(_ title: String, items: [PanelMenuItem]) {
		self.title = title
		self.items = items
	}

	var body: some View {
		PopoverActionRow(title, showsChevron: true) {
			PanelMenuPresenter.shared.popUp(items)
		}
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
				HStack(spacing: PopoverLayout.iconTextGap) {
					if let icon {
						// 应用图标也走同一条图标列（原先是 20pt）：高耗电应用卡的文字
						// 因此比其它卡右移 4pt，跨卡扫读时整列错位
						Image(nsImage: icon)
							.resizable()
							.scaledToFit()
							.frame(width: PopoverLayout.iconColumnWidth, height: PopoverLayout.iconColumnWidth)
							.cornerRadius(4)
					} else if let systemImageName {
						Image(systemName: systemImageName)
							.font(.system(size: PanelText.secondary, weight: .regular))
							.foregroundStyle(GlassTokens.labelOnGlass)
							.frame(width: PopoverLayout.iconColumnWidth)
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

// 可交互玻璃行：控制行/警示行/菜单行的统一底。26 上常态即淡玻璃药丸（按钮可供性写在材质上），
// interactive 玻璃自己响应悬停与按压的镜面高光；15–25 退回原悬停灰底行为
struct GlassRow<Content: View>: View {
	private let content: Content

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

	@State private var isHovering = false
}

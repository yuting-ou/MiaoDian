enum GlassMetrics {
	nonisolated static let shellCornerRadius: CGFloat = 12
	nonisolated static let cardCornerRadius: CGFloat = 12
	nonisolated static let rowCornerRadius: CGFloat = 10
}

extension View {
	/// 面板外壳：26 与控件/徽章统一为 glassEffect（同一液态玻璃材质系统），
	/// 白色 tint 作亮度地板——玻璃跟随壁纸，地板托住对比度（材质直跟壁纸实测 1.7~2.5:1 不达标）；
	/// 深色外观自适应补黑。15–25 用 regularMaterial（无玻璃 API，降级质感）
	func panelShell() -> some View { modifier(PanelShellModifier()) }

	/// 卡片分区：26 极淡填充+发丝线（内容对比度由外壳玻璃统一柔化，分区本身不再加模糊层）；
	/// 15–25 原 quaternarySystemFill+0.06 描边，观感与玻璃化之前完全一致
	func cardSection() -> some View { modifier(CardSectionModifier()) }

	/// 控制行玻璃药丸（v1.24.1）：clear interactive 玻璃 + 浓 tint（GlassTokens.controlPillTint）。
	/// v1.24.0 曾把控制行整体垫一块卡纱板——板下壁纸亮部幽灵穿透，与上方浮卡的玻璃语言割裂
	/// （用户实测「格格不入」）；改行自成才：每行一颗玻璃药丸浮在壳层上，与控件玻璃同族，
	/// 文字坐药丸 tint，对比度由证明锁定。15–25 壳层自带材质地板，行保持原悬停灰底不加面
	func controlPillGlass() -> some View { modifier(ControlPillGlassModifier()) }

	/// 可交互控件玻璃：26 clear+interactive（悬停高光、按压弹性，"液态"的灵魂在反馈）；
	/// 15–25 不施玻璃，由调用方保留原悬停灰底行为
	@ViewBuilder func controlGlass(in shape: GlassControlShape = .rect) -> some View {
		if #available(macOS 26.0, *) {
			switch shape {
			case .rect:
				glassEffect(.clear.interactive(), in: .rect(cornerRadius: GlassMetrics.rowCornerRadius))
			case .circle:
				glassEffect(.clear.interactive(), in: .circle)
			}
		} else {
			self
		}
	}

	/// 仪表玻璃底：头部圆环仪表下垫 clear 玻璃圆（仪器是控件不是内容，允许上玻璃）；15–25 无
	@ViewBuilder func gaugeGlassBase() -> some View {
		if #available(macOS 26.0, *) {
			glassEffect(.clear, in: .circle)
		} else {
			self
		}
	}

	/// 头部/图表容器分区：26 与卡片同款发丝分区（它们本无容器，降级路径保持"无"以复刻原观感）
	@ViewBuilder func glassSection() -> some View {
		if #available(macOS 26.0, *) {
			cardSection()
		} else {
			self
		}
	}

	/// 着色玻璃图标块（蓝牙设备等）：26 clear+tint；15–25 原实色 16% 圆角底
	@ViewBuilder func tintedTile(_ color: Color, cornerRadius: CGFloat) -> some View {
		if #available(macOS 26.0, *) {
			glassEffect(.clear.tint(color.opacity(0.5)), in: .rect(cornerRadius: cornerRadius))
		} else {
			background(
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
					.fill(color.opacity(0.16))
			)
		}
	}
}

enum GlassControlShape {
	case rect, circle
}

/// "关闭"按钮样式：26 玻璃胶囊、15–25 系统淡底——曲线窗口空态用
struct CloseButtonStyle: ButtonStyle {
	@ViewBuilder
	func makeBody(configuration: Configuration) -> some View {
		if #available(macOS 26.0, *) {
			configuration.label
				.padding(.horizontal, 14)
				.padding(.vertical, 6)
				.glassEffect(.regular.interactive(), in: .capsule)
		} else {
			configuration.label
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
				)
		}
	}
}

/// 着色玻璃徽章：26 clear 玻璃+语义色 tint（绿/红是"带信息的颜色"，tint 只染色不夺读）；
/// 15–25 原 Capsule 实色 13% 底。文字色始终用语义色本身，保证辨识度
struct GlassBadge: View {
	let color: Color
	let systemImage: String?
	let text: String

	init(symbol: String? = nil, text: String, color: Color) {
		self.systemImage = symbol
		self.text = text
		self.color = color
	}

	var body: some View {
		HStack(spacing: 3) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: 9, weight: .bold))
			}
			Text(text)
				.font(.system(size: 10.5, weight: .medium))
		}
		.foregroundStyle(color)
		.padding(.horizontal, 7)
		.padding(.vertical, 2.5)
		.modifier(BadgeBackground(color: color))
	}
}

private struct BadgeBackground: ViewModifier {
	let color: Color

	func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			// clear 玻璃不吃淡色，tint 浓度给到 0.5 才压得住壁纸杂色
			content.glassEffect(.clear.tint(color.opacity(0.5)), in: .capsule)
		} else {
			content.background(Capsule().fill(color.opacity(0.13)))
		}
	}
}

// 面板外壳实现：三档=苹果原生玻璃三选一（v1.24.0，档位见 PanelMaterial.shellGlassVariant）。
// 液态玻璃=原生 .clear、均衡=原生 .regular、厚重=原生 .regular+浓 tint——档差由材质本体承担，
// 不再是同块玻璃调 alpha。26 路径不再手绘顶边高光/底部内阴影：原生玻璃自带边缘镜面与厚度，
// 叠画反成"假玻璃"痕迹（15–25 降级路径无玻璃 API，保留原材质语汇）。
// 「降低透明度」显式分支：不透明纯色底，不走玻璃（对比度退化为常数，必达标）。
private struct PanelShellModifier: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

	// 材质档位直读服务单例（MainActor）：设置里切换材质后，面板下次渲染即跟随；
	// 目检注入口 MIAODIAN_DEBUG_MATERIAL 覆盖配置档位（2.0.0 移除）
	private var material: PanelMaterial {
		if let debug = PanelMaterial.debugOverride { return debug }
		return AppServices.shared.configurationManager.configuration.panelMaterial
	}

	@ViewBuilder
	func body(content: Content) -> some View {
		let isDark = colorScheme == .dark
		let shape = RoundedRectangle(cornerRadius: GlassMetrics.shellCornerRadius, style: .continuous)
		if reduceTransparency {
			content.background(
				shape.fill(Color(nsColor: .windowBackgroundColor))
			)
		} else if #available(macOS 26.0, *) {
			let floor = GlassTokens.shellFloorTint(isDark: isDark, material: material)
			let floorColor = isDark ? Color.black.opacity(floor.alpha) : Color.white.opacity(floor.alpha)
			// 档位=原生玻璃变体；壳层 tint 浓度>0 时施（浅色液态玻璃/均衡为 0 = 纯原生素颜）
			switch material.shellGlassVariant {
			case .clear:
				if floor.alpha > 0 {
					content.glassEffect(.clear.tint(floorColor), in: shape)
				} else {
					content.glassEffect(.clear, in: shape)
				}
			case .regular:
				if floor.alpha > 0 {
					content.glassEffect(.regular.tint(floorColor), in: shape)
				} else {
					content.glassEffect(.regular, in: shape)
				}
			case .regularTinted:
				content.glassEffect(.regular.tint(floorColor), in: shape)
			}
		} else {
			content
				.background(.regularMaterial, in: shape)
				.overlay(alignment: .top) { specular }
				.overlay(alignment: .bottom) { bottomShade }
		}
	}

	/// 顶边镜面高光（仅 15–25 降级路径）：~1pt 亮线向下渐隐（26pt 内衰减到 0），
	/// 纯加光不改变文字对比度判定。26 路径的原生玻璃自带边缘镜面，不再叠画
	private var specular: some View {
		LinearGradient(
			colors: [.white.opacity(0.32), .white.opacity(0)],
			startPoint: .top, endPoint: .bottom
		)
		.frame(height: 26)
		.clipShape(.rect(cornerRadius: GlassMetrics.shellCornerRadius))
		.frame(maxWidth: .infinity)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	/// 底部极淡内阴影（仅 15–25 降级路径）：与顶边高光一起给"一块玻璃"厚度暗示
	private var bottomShade: some View {
		LinearGradient(
			colors: [.black.opacity(0), .black.opacity(0.05)],
			startPoint: .top, endPoint: .bottom
		)
		.frame(height: 14)
		.clipShape(.rect(cornerRadius: GlassMetrics.shellCornerRadius))
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

// 控制行玻璃药丸的实现：拿 colorScheme 选 tint 色（浅白/深黑），浓度数值在 GlassTokens
private struct ControlPillGlassModifier: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme

	func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			let isDark = colorScheme == .dark
			let tint = GlassTokens.controlPillTint(isDark: isDark)
			let tintColor = isDark ? Color.black.opacity(tint.alpha) : Color.white.opacity(tint.alpha)
			content
				.glassEffect(.clear.tint(tintColor).interactive(), in: .rect(cornerRadius: GlassMetrics.rowCornerRadius))
		} else {
			content
		}
	}
}

// 卡片分区的具体实现做成 ViewModifier：为了拿 @Environment——
// 「增加对比度」开启时发丝线与淡填充加倍（Apple 的可读性安全网必须接住）
private struct CardSectionModifier: ViewModifier {
	@Environment(\.colorSchemeContrast) private var contrast
	@Environment(\.colorScheme) private var colorScheme

	// 材质档位直读服务单例（MainActor）：与面板外壳同源（含目检注入口），设置切换后即时跟随
	private var material: PanelMaterial {
		if let debug = PanelMaterial.debugOverride { return debug }
		return AppServices.shared.configurationManager.configuration.panelMaterial
	}

	func body(content: Content) -> some View {
		let increased = contrast == .increased
		let isDark = colorScheme == .dark
		// 填充 token 与证明测试同源（GlassTokens.cardSectionFill，材质档位化 v1.20.0）
		let fill = GlassTokens.cardSectionFill(increased: increased, isDark: isDark, material: material)
		let stroke = increased ? 0.22 : 0.09
		if #available(macOS 26.0, *) {
			content
				.background(
					RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius, style: .continuous)
						.fill(fill)
				)
				.overlay(
					RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius, style: .continuous)
						.strokeBorder(Color.primary.opacity(stroke), lineWidth: 1)
				)
		} else {
			content
				.background(
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(Color(nsColor: .quaternarySystemFill))
				)
				.overlay(
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.strokeBorder(Color.primary.opacity(increased ? 0.16 : 0.06), lineWidth: 1)
				)
		}
	}
}

/// 时段热力图配色：24 格时段图与用电日历共用同一套热力语言（此前两文件各一份逐字重复）
enum HeatmapPalette {
	// 淡绿 → 绿 → 橙，越深越耗电；0 用电极淡底
	nonisolated static func cellColor(_ level: Double) -> Color {
		if level <= 0.001 { return Color.secondary.opacity(0.12) }
		let clamped = min(max(level, 0), 1)
		let hue = 0.33 - 0.25 * clamped   // 0.33 绿 → 0.08 橙红
		return Color(hue: hue, saturation: 0.75, brightness: 0.85, opacity: 0.35 + 0.6 * clamped)
	}
}

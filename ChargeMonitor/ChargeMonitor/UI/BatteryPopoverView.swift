import AppKit
import SwiftUI

struct BatteryPopoverView: View {
	@ObservedObject var monitor: BatteryMonitor
	@ObservedObject var configurationManager: ConfigurationManager
	@ObservedObject var historyRecorder: BatteryHistoryRecorder
	@ObservedObject var alertController: BatteryAlertController
	/// 卡片本体整卡拖拽。卡片区内部滚动时必须关掉：竖向滚动手势与
	/// simultaneousGesture 的 DragGesture 抢同一段 pan，用户想滚却把卡提起来。
	/// 滚动模式下只保留把手（minimumDistance=0）作为明示抓取点。
	var allowsCardDrag: Bool = true
	/// 非 nil = 面板总高预算（可视区扣 chrome 后）。卡片区在内部 ScrollView 里滚，
	/// **外壳/头部/控制行固定**——整块玻璃跟着滚会每帧重采样材质，是掉帧大户。
	/// nil = 装得下，不启内部滚动。
	var cardBudgetHeight: CGFloat? = nil
	// 「减少动态效果」安全网：入场动画直接终态（见 CascadeIn 与容器淡入分支）
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	
	// 面板打开期间已分好列的卡片：后到的新卡只追加到较矮列，已有卡不滑动不换位，
	// 避免曲线数据陆续到位时整个面板在眼皮底下洗牌；关闭面板后清空，下次打开重新配平。
	// 自动模式保持 v1.13 贪心双列——高度门已证实行式密铺出厂态超屏（+12%起），列式是物理最优
	@State private var assignedLeft: [CardID] = []
	@State private var assignedRight: [CardID] = []
	// 进入编辑/开始拖拽时播种的行表：与工作副本一致则「完成」禁用（未改动不落盘，
	// 防止"进编辑什么都不动、保存后列式变行式平白长高一截"）
	@State private var layoutSeed: PanelLayout? = nil
	// 入场动画开关：面板打开时从 false→true 驱动淡入上滑，关闭时复位供下次重播
	@State private var didAppear = false
	// 首次打开播错峰级联，之后每次打开整块淡入（高频开关面板不看腻）
	@State private var playCascade = false
	// "复制报告"的行内成功反馈
	@State private var reportCopied = false
	// 华容道布局编辑：编辑布局模式瘦身为隐藏管理（眼睛+托盘）。
	// 常态长按拖拽：拖动中实时预览补位，松手直接落盘（无"完成"按钮）
	@State private var isEditingLayout = false
	@State private var layoutDraft = PanelLayout()
	@State private var trayExpanded = false
	// 常态拖拽状态机：nil = 未在拖
	@State private var dragState: CardDragState? = nil
	// 拖动中的落点指示线（全局坐标；nil=不显示）
	@State private var dropIndicator: (x: CGFloat, y: CGFloat, width: CGFloat)? = nil
	// 拖动预览中的布局（其他卡片据此实时让位）；nil = 无预览
	@State private var previewLayout: PanelLayout? = nil
	// 悬停中的把手（微放大反馈）
	@State private var isHandleHovering: String? = nil
	// frame 表：引用宿主；滚动期探针静默写表，拖拽期才发变更通知（120Hz 关键）
	@ObservedObject private var frameStore = CardFrameStore()
	// 滚动活动：头部 TimelineView 在滚动期间退静帧
	@ObservedObject private var scrollActivity = PanelScrollActivity.shared
	// "本会话只播一次级联"挂类型上：面板每次打开销毁重建，@State 撑不住跨打开
	private static var hasPlayedCascade = false

	// 跨列卡（华容网格 v3）：横向内容在半宽里被截断的三张，按卡型静态判定、不可配置。
	// 华容道的本质是把要紧的块塞进有界的框——块型只有系统知道的这一种，用户只管阅读序与去留
	private static let wideCardIDs: Set<String> = Set(
		[CardID.dailySummary, CardID.chargeHistory, CardID.energyApps].map(\.layoutID)
	)
	
	var body: some View {
		let configuration = configurationManager.configuration
		// 健康趋势曲线能显示时，信息行里的文字版趋势就不再重复展示
		let showsHealthCurve = configuration.enabledOptions.contains(.healthTrend) && historyRecorder.healthSamples.count >= 2
		let formatter = BatteryInfoFormatter(
			snapshot: monitor.snapshot,
			configuration: configuration,
			drainEstimate: monitor.drainEstimate,
			healthTrend: showsHealthCurve ? nil : historyRecorder.healthTrend,
			sleepDrain: historyRecorder.lastSleepDrain,
			chargerProfile: historyRecorder.currentChargerProfile,
			chargerStats: historyRecorder.currentChargerPowerStats,
			omitsTimeEstimates: true
		)
		let powerItems = formatter.makeItems(in: .power)
		let batteryItems = formatter.makeItems(in: .battery)
		// 按语义顺序枚举当前可见卡片；≥ 5 张就拉宽面板双列，否则窄单列
		let cards = visibleCards(configuration, showsHealthCurve: showsHealthCurve, powerItems: powerItems, batteryItems: batteryItems)
		let twoColumns = cards.count >= 5
		// 宽面板时体检评分搬进头部右侧的空白区，不再占卡片位。
		// v1.18.0：显示判定走 showsHeaderCheckup——「面板显示」开关此前对角标无效果（静默失败）
		let checkup = configuration.showsHeaderCheckup(hasHealth: monitor.snapshot.healthPercent != nil) ? BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			highSocDwellShare: historyRecorder.todayUsage?.highSocDwellShare
		) : nil
		// 「面板显示」隐藏过滤（v1.18.1）：宽面板行路径靠 normalize 剔除隐藏卡，
		// 窄面板两列配平路径此前没有任何 hidden 过滤——隐藏的卡在窄面板复活。
		// 在渲染入口单点过滤（visibleCards 保持纯"开关∧数据"语义，不掺布局维度；
		// twoColumns 阈值保持旧口径，避免隐藏卡触发宽窄模式翻转）。
		let hiddenIDs = configuration.panelLayout?.hidden ?? []
		let displayCards = PanelFlow.removingHidden(
			twoColumns ? cards.filter { $0.id != .checkup } : cards,
			hidden: hiddenIDs
		) { $0.id.layoutID }
		let cardIDs = displayCards.map(\.id)
		let availableIDs = Set(cardIDs.map(\.layoutID))
		// 预先算好分列与"控制行"的级联档位（供入场错峰动画与 onAppear 固化共用）
		let split = mergedColumns(displayCards, left: assignedLeft, right: assignedRight)
		// 华容网格 v4 双路径：自定义布局/编辑/拖拽走显式行存储（渲染即存储，预览=落盘=重开）；
		// 纯自动模式走会话冻结的贪心双列独立堆叠（高度最优、不洗牌——高度门已证明
		// 行式对齐密铺出厂态超屏 +12% 起，列式是物理最优）
		let usingRows = twoColumns && (isEditingLayout || dragState != nil || configuration.panelLayout != nil)
		let rowSource: PanelLayout = previewLayout
			?? (isEditingLayout || dragState != nil ? layoutDraft : nil)
			?? configuration.panelLayout
			?? PanelLayout()
		let segments: [PanelFlow.Segment] = usingRows
			? PanelFlow.renderSegments(
				PanelFlow.normalize(rowSource, known: Set(CardID.allCases.map(\.layoutID))).effectiveRows,
				available: availableIDs
			)
			: []
		let controlStep = max(segments.count, max(split.left.count, split.right.count)) + 1
		
		VStack(alignment: .leading, spacing: 8) {
			BatteryHeaderView(
				snapshot: monitor.snapshot,
				drainEstimate: monitor.drainEstimate,
				lowBatteryThreshold: configuration.lowBatteryThresholdPercent,
				hotTemperatureThreshold: configuration.highTemperatureThresholdC,
				checkup: twoColumns ? checkup : nil,
				adapterName: twoColumns && checkup == nil ? chargerHeadline?.0 : nil,
				adapterDetail: twoColumns && checkup == nil ? chargerHeadline?.1 : nil
			)
			.modifier(CascadeIn(step: 0, active: didAppear))

			// 编辑模式 chrome 过渡（v1.18.6）：提示条+按钮组淡入淡出+上缘滑入滑出，
			// 取代 if 硬切——进出编辑模式不再"啪一下"。「减少动态效果」直给终态。
			// v1.24.0 坐卡纱：液态玻璃/均衡档壳层=纯原生素颜玻璃（无地板 tint），
			// 直露文字最坏对比度不保证——文字层全部坐卡面（可读性证明的锁定边界）
			if isEditingLayout {
				HStack(spacing: 8) {
					// v1.18.2 文案对齐现实：编辑模式 v1.17.2 起不再显示把手（与控制条叠影），
					// 拖拽在常态面板直接进行——旧文案"拖把手调整位置"指向不存在的操作
					Text("点「眼睛」隐藏卡片，「宽窄」调整占行；重排卡片回到常态拖 ≡ 把手")
						.font(.system(size: 9))
						.foregroundStyle(GlassTokens.labelOnGlass)
					Spacer()
					if configurationManager.configuration.panelLayout != nil {
						Button {
							resetLayout()
						} label: {
							Text("重置")
								.font(.system(size: 11))
								.foregroundStyle(GlassTokens.labelOnGlass)
						}
						.buttonStyle(.plain)
					}
					Button {
						exitLayoutEdit(save: false)
					} label: {
						Text("取消")
							.font(.system(size: 11))
							.foregroundStyle(GlassTokens.labelOnGlass)
					}
					.buttonStyle(.plain)
					Button {
						exitLayoutEdit(save: true)
					} label: {
						Text("完成")
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(.primary)  // 可供性由玻璃药丸材质承担，不靠字色
					}
					.buttonStyle(.plain)
				}
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.cardSection()
				.transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
			}

			// 卡片区：装不下时包竖向 ScrollView（外壳/头/控固定）。
			// 触控板路径必须走 SwiftUI ScrollView——自管 NSHostingView 当 document 时
			// 若测量高度被钳成视口，会出现「完全划不动」。120Hz 优化叠在：
			// CardFrameStore 静默写表 + PanelScrollActivity 滚动中头部静帧 +
			// PanelHostingView 关掉内部 ScrollView 的橡皮筋。
			// 拖拽把手时 scrollDisabled：触控板 pan 不与 DragGesture 争位移
			if cardBudgetHeight != nil {
				ScrollView(.vertical) {
					cardRegion(
						twoColumns: twoColumns,
						usingRows: usingRows,
						segments: segments,
						rowSource: rowSource,
						split: split,
						cardIDs: cardIDs,
						configuration: configuration,
						powerItems: powerItems,
						batteryItems: batteryItems,
						showsHealthCurve: showsHealthCurve
					)
					.coordinateSpace(name: BoardSpace.name)
					// 滚动中不禁全局动画：液态玻璃/药丸/级联需要动效生命。
					// 掉帧靠 monitor 暂缓发布 + 卸掉陪滚探针，不靠阉割动效。
				}
				.scrollDisabled(dragState != nil)
				// 系统 overlay 滚动条（与橡皮筋同属苹果手感）；单一写法，勿再叠 showsIndicators
				.scrollIndicators(.automatic)
				.frame(maxHeight: .infinity)
			} else {
				cardRegion(
					twoColumns: twoColumns,
					usingRows: usingRows,
					segments: segments,
					rowSource: rowSource,
					split: split,
					cardIDs: cardIDs,
					configuration: configuration,
					powerItems: powerItems,
					batteryItems: batteryItems,
					showsHealthCurve: showsHealthCurve
				)
				.coordinateSpace(name: BoardSpace.name)
			}

			// v1.24.1 控制行回归玻璃家族：去掉 v1.24.0 的整块卡纱垫板——板下壁纸亮部幽灵穿透，
			// 与上方浮卡的玻璃语言割裂（用户实测「格格不入」）。每行自成一颗粒 tint 玻璃药丸
			// （GlassRow→controlPillGlass），文字坐药丸 tint，对比度由证明锁（浅黑字/深白字 ≥7 AAA）
			controlRows
				.modifier(CascadeIn(step: cascadeStep(controlStep), active: didAppear))
		}
		.padding(.horizontal, 12)
		.padding(.top, 12)
		.padding(.bottom, 8)
		.frame(width: twoColumns ? 584 : 292, height: cardBudgetHeight, alignment: .top)
		// 面板外壳：ultraThinMaterial+亮度地板（见 GlassStyle）。ignoresSafeArea 让外壳
		// 顶满窗口——否则 SwiftUI 会避让隐形标题栏的安全区，面板顶部出现约 28pt 空档
		.panelShell()
		.ignoresSafeArea()
		// 调试会话标记：程序化弹出的面板常驻不关（截图会话），没有它就无法与
		// 用户手中的正式面板区分——曾因此让用户对着调试实例报"点击外部不关闭"
		.overlay(alignment: .topLeading) {
			if ProcessInfo.processInfo.environment["MIAODIAN_DEBUG_OPEN_PANEL"] != nil {
				Text("调试")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(.black.opacity(0.85))  // 调试标记：白字坐实橙底只有 2.2:1，改深字（实心底，非玻璃）
					.padding(.horizontal, 5)
					.padding(.vertical, 2)
					.background(Capsule().fill(.orange))
					.padding(.leading, 4)
					.allowsHitTesting(false)
			}
		}
		// 容器只留一层极快的背景淡入（纯 opacity，不做 scale 避免与内部 CascadeIn 的缩放叠加）；
		// “浮现”观感完全交给内部各块的级联动画，单一时序才不会两套动画叠加相互干扰。
		// 「减少动态效果」：直接终态，无淡入
		.opacity(didAppear || reduceMotion ? 1 : 0)
		.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: didAppear)
			.onAppear {
				monitor.startPolling()
				// 打开面板先复位滚动态：避免上次残留 isScrolling 让动效永久静帧
				scrollActivity.reset()
				monitor.defersUISnapshot = false
				// 用户可能刚在系统设置里改过通知权限，每次打开面板重新查
				alertController.refreshAuthorizationStatus()
				let next = mergedColumns(displayCards, left: assignedLeft, right: assignedRight)
				assignedLeft = next.left
				assignedRight = next.right
				// 本会话第一次打开播错峰级联，之后 cascadeStep 全归零、整块同时落位
				playCascade = !Self.hasPlayedCascade
				Self.hasPlayedCascade = true
				// 置 true 触发入场：容器自带淡入动画，内部各块由 CascadeIn 按档位落位
				didAppear = true
			}
			.onChange(of: scrollActivity.isScrolling) { _, scrolling in
				// 滚动中暂缓 monitor 的 @Published 快照；停手后补发
				monitor.defersUISnapshot = scrolling
				if !scrolling {
					monitor.flushPendingUISnapshot()
				}
			}
			.onChange(of: cardIDs) {
				// 卡片增减时把最新分列结果固化下来，已有卡片的归属不变
				let configuration = configurationManager.configuration
				let showsHealthCurve = configuration.enabledOptions.contains(.healthTrend) && historyRecorder.healthSamples.count >= 2
				let cards = visibleCards(configuration, showsHealthCurve: showsHealthCurve, powerItems: powerItems, batteryItems: batteryItems)
				let display = PanelFlow.removingHidden(
					cards.count >= 5 ? cards.filter { $0.id != .checkup } : cards,
					hidden: configuration.panelLayout?.hidden ?? []
				) { $0.id.layoutID }
				let split = mergedColumns(display, left: assignedLeft, right: assignedRight)
				assignedLeft = split.left
				assignedRight = split.right
			}
			.onDisappear {
				// 编辑中直接关面板：按取消处理（不落盘半成品布局）
				if isEditingLayout { exitLayoutEdit(save: false) }
				// 拖拽中直接关面板：丢弃半成品预览与拖拽态（卡死兜底恢复通道，v1.17.1）
				dragState = nil
				previewLayout = nil
				frameStore.publishesChanges = false
				monitor.stopPolling()
				// 下次打开时重新配平，避免上一次的历史分配越积越歪
				assignedLeft = []
				assignedRight = []
				// 复位入场动画标志，下次打开才会重新淡入
				didAppear = false
			}
	}
	
	// MARK: - 卡片区（可选包在内部 ScrollView 里）

	/// 卡片 + 编辑隐藏托盘。高度不够时由 body 外面的 ScrollView 包住；
	/// 这里不感知滚动，只负责布局本身（与非滚动路径同一份代码）。
	@ViewBuilder
	private func cardRegion(
		twoColumns: Bool,
		usingRows: Bool,
		segments: [PanelFlow.Segment],
		rowSource: PanelLayout,
		split: (left: [CardID], right: [CardID]),
		cardIDs: [CardID],
		configuration: AppConfiguration,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem],
		showsHealthCurve: Bool
	) -> some View {
		if twoColumns {
			// 头部玻璃板分区自带下缘，旧的细分隔线退场——层级交给材质，不靠发丝线。
			// 卡片不再各自成玻璃（避免玻璃汤+内容糊底），故无需 GlassEffectContainer
			if usingRows {
				// 华容网格 v5（v1.17.3 丝滑重排）：卡片以自身为身份平铺进自定义密铺
				// Layout——预览重排 = 坐标重算 + 容器弹簧全员滑行。此前行栈以段落内容
				// 为身份，重排一改行形态，段内卡片连树销毁、新视图在终点凭空出现
				// （无位移动画），用户看到的就是跳格子卡顿。
				// 把手仍走独立浮层（handleLayer，v1.17.1 不死手结构）。
				// v1.18.3 绘制序保证：拖动中被拖卡排到源序列末尾——id 不变只换序，
				// 视图平移不重建（身份法则）；Layout 不重排子视图语义序（按 plan 对号），
				// 但 SwiftUI 绘制按子视图声明序，被拖卡因此恒在最上层，滑行交叉不穿帮。
				let orderedIDs = PanelFlow.dragTopmost(
					PanelFlow.flatCardIDs(segments), dragging: dragState?.card
				)
				PanelMasonryLayout(segments: segments, emptyHeight: isEditingLayout ? 40 : 0) {
					ForEach(orderedIDs, id: \.self) { cardID in
						if let card = CardID(rawValue: cardID) {
							cardSlot(
								card,
								layoutValue: rowSource,
								powerItems: powerItems,
								batteryItems: batteryItems,
								configuration: configuration,
								showsHealthCurve: showsHealthCurve
							)
							.frame(maxWidth: .infinity, alignment: .leading)
							.masonryCard(cardID)
						}
					}
				}
				.animation(
					PanelMotionGate.allowsRepackAnimations(
						isScrolling: scrollActivity.isScrolling,
						isDragging: dragState != nil
					) && !reduceMotion ? .spring(response: 0.34, dampingFraction: 0.88) : nil,
					value: rowSource
				)
				// 滚动中把把手层整棵摘掉：opacity=0 的 GeometryReader 仍在布局树里陪滚
				.overlay {
					if PanelMotionGate.allowsRepackAnimations(
						isScrolling: scrollActivity.isScrolling,
						isDragging: dragState != nil
					) && !isEditingLayout {
						handleLayer(segments)
					}
				}
			} else {
				HStack(alignment: .top, spacing: 10) {
					cardColumn(true, columns: split, available: Set(cardIDs), powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
					cardColumn(false, columns: split, available: Set(cardIDs), powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
				}
			}
		} else {
			ForEach(Array(cardIDs.enumerated()), id: \.element) { index, id in
				cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
					.modifier(CascadeIn(step: cascadeStep(index + 1), active: didAppear))
			}
		}

		// 编辑模式的隐藏托盘：被藏起的卡片在这里，点 + 放回右列
		// v1.24.0 坐卡纱（壳层无直露文字）
		if isEditingLayout, !layoutDraft.hidden.isEmpty {
			hiddenTray
				.cardSection()
		}
	}

	// MARK: - 卡片枚举与自适应分列
	
	private enum CardID: String, Hashable, CaseIterable {
		case powerInfo, batteryInfo, checkup, dailySummary, socChart, healthTrend
		case powerChart, temperatureChart, bluetooth, chargeHistory, powerEvents, energyApps
		case usageCalendar, habitInsight, hourlyDrain
		case runtimeScenarios, batteryIdentity

		// 华容道布局的持久化 id（case 名）；编辑模式的中文标题
		var layoutID: String { rawValue }
		var title: String {
			switch self {
			case .powerInfo: return "充电协议与功率"
			case .batteryInfo: return "电池状态"
			case .checkup: return "电池体检"
			case .dailySummary: return "今日用电"
			case .socChart: return "24小时电量"
			case .healthTrend: return "健康度趋势"
			case .powerChart: return "功耗曲线"
			case .temperatureChart: return "温度曲线"
			case .bluetooth: return "蓝牙外设"
			case .chargeHistory: return "充电记录"
			case .powerEvents: return "电源事件"
			case .energyApps: return "高耗电应用"
			case .usageCalendar: return "用电日历"
			case .habitInsight: return "洞察"
			case .hourlyDrain: return "时段用电"
			case .runtimeScenarios: return "续航换算"
			case .batteryIdentity: return "电池身份证"
			}
		}
	}
	
	// 当前能显示出来的卡片及其预估高度（按自然阅读顺序）；高度用于自动模式的贪心配平。
	// 行式自定义布局不消费高度（显式行渲染），两者互不干扰
	private func visibleCards(
		_ configuration: AppConfiguration,
		showsHealthCurve: Bool,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem]
	) -> [(id: CardID, height: CGFloat)] {
		let options = configuration.enabledOptions
		var result: [(CardID, CGFloat)] = []
		// 语义分簇排序（v1.10.0）：充电中 → 电池健康 → 用电行为 → 外设与事件。
		// 同簇相邻，扫读不跳；簇间靠配平算法自然留出间隙。仅调顺序，不动任何出现条件与高度
		// —— 充电中：协议/档位/功率/充电器 + 这次和历史的充电记录
		if !powerItems.isEmpty { result.append((.powerInfo, 22 + 26 * CGFloat(powerItems.count))) }
		if options.contains(.chargeHistory), !historyRecorder.recentSessions.isEmpty {
			result.append((.chargeHistory, cardHeight(.chargeHistory, expanded: 50 + 40 * CGFloat(min(3, historyRecorder.recentSessions.count)))))
		}
		// —— 电池健康：状态/体检/身份证/保养建议/温度/趋势 ——
		if !batteryItems.isEmpty { result.append((.batteryInfo, 22 + 26 * CGFloat(batteryItems.count))) }
		if options.contains(.batteryCheckup), monitor.snapshot.healthPercent != nil { result.append((.checkup, 58)) }
		// 电池身份证：静态出厂信息，有跳变记录时多留一行状态位
		if options.contains(.batteryIdentity), let identity = monitor.batteryIdentity, identity.isMeaningful {
			let jumpExtra: CGFloat = socJumpCount30d > 0 ? 26 : 0
			result.append((.batteryIdentity, cardHeight(.batteryIdentity, expanded: 104 + jumpExtra)))
		}
		if options.contains(.habitInsight), !habitInsights.isEmpty {
			result.append((.habitInsight, cardHeight(.habitInsight, expanded: 40 + 22 * CGFloat(habitInsights.count))))
		}
		if options.contains(.temperatureChart), monitor.temperatureSamples.count >= 2 { result.append((.temperatureChart, cardHeight(.temperatureChart, expanded: 96))) }
		if options.contains(.healthTrend), showsHealthCurve { result.append((.healthTrend, cardHeight(.healthTrend, expanded: 142))) }
		// —— 用电行为：今日/日历/时段/24h/功耗/续航换算/高耗电 ——
		if options.contains(.dailySummary), let usage = historyRecorder.todayUsage,
		   usage.drainedPercent > 0 || usage.chargedPercent > 0 {
			result.append((.dailySummary, cardHeight(.dailySummary, expanded: historyRecorder.dailyHistory.count >= 2 ? 135 : 92)))
		}
		if options.contains(.usageCalendar), historyRecorder.dailyHistory.count >= 3 {
			result.append((.usageCalendar, cardHeight(.usageCalendar, expanded: 128)))
		}
		if options.contains(.hourlyDrainChart), historyRecorder.hourlyDrainStats.accumulatedDays >= 3 {
			result.append((.hourlyDrain, cardHeight(.hourlyDrainChart, expanded: 96)))
		}
		if options.contains(.socChart), historyRecorder.socSamples.count >= 2 { result.append((.socChart, cardHeight(.socChart, expanded: 120))) }
		if options.contains(.powerChart), monitor.powerSamples.count >= 2 { result.append((.powerChart, cardHeight(.powerChart, expanded: 102))) }
		// 续航换算：只在电池模式且有掉电估算时出现
		if options.contains(.runtimeScenarios), monitor.snapshot.powerSource == .battery,
			let estimate = monitor.drainEstimate, estimate.percentPerHour > 0,
			monitor.snapshot.stateOfChargePercent != nil {
			result.append((.runtimeScenarios, cardHeight(.runtimeScenarios, expanded: 118)))
		}
		if options.contains(.significantEnergyApps) {
			let energyExtra = weeklyAppEnergy.isEmpty ? 0 : 22 + 20 * CGFloat(weeklyAppEnergy.count)
			result.append((.energyApps, 44 + 26 * CGFloat(max(1, min(3, monitor.significantEnergyApps.count))) + energyExtra))
		}
		// —— 外设与事件 ——
		if options.contains(.powerEvents), !historyRecorder.powerEvents.isEmpty {
			result.append((.powerEvents, cardHeight(.powerEvents, expanded: 44 + 26 * CGFloat(min(6, historyRecorder.powerEvents.count)))))
		}
		if options.contains(.bluetoothDevices), !monitor.bluetoothDevices.isEmpty {
			result.append((.bluetooth, 40 + 34 * CGFloat(monitor.bluetoothDevices.count)))
		}
		return result.map { (id: $0.0, height: $0.1) }
	}

	// 可折叠卡片折起后只剩一行标题，配平时按 32pt 算，否则按展开高度
	private func cardHeight(_ option: DisplayOption, expanded: CGFloat) -> CGFloat {
		configurationManager.configuration.collapsedCards.contains(option.rawValue) ? 32 : expanded
	}

	// 贪心配平：按顺序把每张卡片塞进当前较矮的那列，不管哪些卡片出现都能两列收齐
	private func balancedSplit(_ cards: [(id: CardID, height: CGFloat)]) -> (left: [CardID], right: [CardID]) {
		var left: [CardID] = []
		var right: [CardID] = []
		var leftHeight: CGFloat = 0
		var rightHeight: CGFloat = 0
		for card in cards {
			if leftHeight <= rightHeight {
				left.append(card.id)
				leftHeight += card.height
			} else {
				right.append(card.id)
				rightHeight += card.height
			}
		}
		return (left, right)
	}

	// 沿用面板打开期间已有的分列：还在场的卡片保持原列原顺序，新到的追加到当前较矮列，
	// 消失的卡片剔除；首次（无历史分配）直接走贪心配平
	private func mergedColumns(
		_ cards: [(id: CardID, height: CGFloat)],
		left: [CardID],
		right: [CardID]
	) -> (left: [CardID], right: [CardID]) {
		let valid = Set(cards.map(\.id))
		let knownLeft = left.filter { valid.contains($0) }
		let knownRight = right.filter { valid.contains($0) }
		if knownLeft.isEmpty, knownRight.isEmpty {
			return balancedSplit(cards)
		}

		let heightByID = Dictionary(cards.map { ($0.id, $0.height) }, uniquingKeysWith: { a, _ in a })
		var resultLeft = knownLeft
		var resultRight = knownRight
		var leftHeight = knownLeft.reduce(0) { $0 + (heightByID[$1] ?? 0) }
		var rightHeight = knownRight.reduce(0) { $0 + (heightByID[$1] ?? 0) }

		let placed = Set(knownLeft + knownRight)
		for card in cards where !placed.contains(card.id) {
			if leftHeight <= rightHeight {
				resultLeft.append(card.id)
				leftHeight += card.height
			} else {
				resultRight.append(card.id)
				rightHeight += card.height
			}
		}
		return (resultLeft, resultRight)
	}

	/// 自动模式单列渲染（v1.13 原样）：贪心配平的独立双列堆叠
	private func cardColumn(
		_ column: Bool,
		columns: (left: [CardID], right: [CardID]),
		available: Set<CardID>,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem],
		configuration: AppConfiguration,
		showsHealthCurve: Bool
	) -> some View {
		let ids = column ? columns.left : columns.right
		// 条件不可见的卡片（数据门槛未满足等）跳过渲染，位置保留
		let visible = ids.filter { available.contains($0) }
		return VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(visible.enumerated()), id: \.element) { index, id in
				cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
					.modifier(CascadeIn(step: cascadeStep(index + 1), active: didAppear))
			}
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
	}

	private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 8, weight: .bold))
				.foregroundStyle(GlassTokens.labelOnGlass)
				.frame(width: 16, height: 16)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(Text(label))
	}

	/// 隐藏托盘：点 + 放回（追加阅读序末尾，位置可再拖微调）。
	/// v1.24.0 自身已坐卡纱（调用处 .cardSection()），内部无需再加面
	private var hiddenTray: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("已隐藏的卡片（点 + 放回阅读序末尾）")
				.font(.system(size: 9))
				.foregroundStyle(GlassTokens.labelOnGlass)
			ForEach(Array(layoutDraft.hidden.enumerated()), id: \.element) { _, id in
				HStack {
					Text(CardID(rawValue: id)?.title ?? id)
						.font(.system(size: 11))
						.foregroundStyle(.primary)
					Spacer()
					Button {
						applyLayout(PanelFlow.unhide(layoutDraft, card: id))
					} label: {
						Image(systemName: "plus.circle.fill")
							.font(.system(size: 12))
							.foregroundStyle(Color.accentColor)
					}
					.buttonStyle(.plain)
				}
				.padding(.vertical, 2)
				// 行插拔转场（v1.18.6）：隐藏入托/放回出托走淡变，配合 applyLayout 的 withAnimation
				.transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
			}
		}
		.padding(8)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// 应用布局变更到工作副本
	private func applyLayout(_ layout: PanelLayout) {
		// 编辑模式内的布局改动（隐藏/宽窄）走弹簧——卡片滑出让位、托盘插行不再硬切（v1.18.6）
		withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
			layoutDraft = layout
		}
	}

	// MARK: - 华容网格：格子渲染与拖拽

	/// 拖拽把手浮层（v1.17.1 拖拽不死手）：平铺一层把手浮在卡片上，身份恒等于卡自身，
	/// 位置由 frameStore 探针实时驱动——预览重排只改坐标、永不销毁视图，挂在把手上的
	/// 进行中 DragGesture 全程存活（此前把手随卡片进行结构，行/段身份一翻手势即死）。
	/// 卡 frame 是**板面坐标系**，减去浮层容器在同一坐标系的原点换算成层内坐标；
	/// y+14 = 把手胶囊中心与卡顶的视觉间距（对齐旧版 ZStack(.top) + padding(3) 的落点）。
	private func handleLayer(_ segments: [PanelFlow.Segment]) -> some View {
		GeometryReader { geo in
			let origin = geo.frame(in: .named(BoardSpace.name)).origin
			ZStack(alignment: .topLeading) {
				ForEach(PanelFlow.flatCardIDs(segments), id: \.self) { cardID in
					if let frame = frameStore.frames[cardID], let card = CardID(rawValue: cardID) {
						dragHandle(card)
							.position(x: frame.midX - origin.x, y: frame.minY - origin.y + 14)
							// 仅布局重排（拖拽/折叠）时跟手弹簧；滚动时 frame 表不变，不会触发
							.animation(.spring(response: 0.24, dampingFraction: 0.92), value: frameStore.frames[cardID])
					}
				}
			}
			// 落点指示线：拖动中画在将要插入的缝隙上（全局坐标换算到层内，同把手一套算法）
			if dragState != nil, let ind = dropIndicator {
				Capsule()
					.fill(Color.accentColor)
					.frame(width: max(24, ind.width), height: 2)
					.position(x: ind.x - origin.x + ind.width / 2, y: ind.y - origin.y)
					.allowsHitTesting(false)
				.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
			}
		}
		// 编辑模式隐藏把手浮层：控制条（眼睛/宽窄）也在卡顶居中，旧版把手被控制条盖住
		// 看不见；浮层化后若不跟着藏，≡ 会叠画在控制条上（v1.17.2 视觉修正）。
		// 交互层早已禁用（allowsHitTesting），这里补齐视觉一致。
		.opacity(isEditingLayout ? 0 : 1)
		.allowsHitTesting(!isEditingLayout)
	}

	/// 单卡槽位：内容 + frame 探针 + 编辑模式眼睛。正被拖动的卡 offset 跟手 + 浮起；
	/// 其余卡在布局变化时弹簧让位。把手不在槽内（见 handleLayer）。
	private func cardSlot(
		_ id: CardID,
		layoutValue: PanelLayout,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem],
		configuration: AppConfiguration,
		showsHealthCurve: Bool
	) -> some View {
		let isDragged = dragState?.card == id.layoutID
		let allowRepack = PanelMotionGate.allowsRepackAnimations(
			isScrolling: scrollActivity.isScrolling,
			isDragging: dragState != nil
		)
		return ZStack(alignment: .top) {
			cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
				.background {
					// 滚动中不挂 frame 探针（GeometryReader 陪滚）；拖拽中仍要
					if !scrollActivity.isScrolling || dragState != nil {
						CardFrameProbe(id: id.layoutID, store: frameStore)
					}
				}
			if isEditingLayout {
				cardControls(id)
			}
		}
		.scaleEffect(isDragged ? 1.04 : 1.0)
		.shadow(color: isDragged ? .black.opacity(0.28) : .clear, radius: 18, y: 8)
		.offset(x: isDragged ? (dragState?.translation.width ?? 0) : 0,
				y: isDragged ? (dragState?.translation.height ?? 0) : 0)
		.zIndex(isDragged ? 10 : 0)
		// 抓住卡片任意处即可拖（10pt 阈值避开误触；把手保留，作为"这里可以拖"的明示）。
		.simultaneousGesture(
			dragGesture(for: id, minimumDistance: 10),
			including: allowsCardDrag ? .all : .none
		)
		// 滚动中关掉重排/折叠弹簧，只保留抓起动效——装饰动画不与120Hz 滚动抢帧
		.animation(allowRepack ? .spring(response: 0.34, dampingFraction: 0.88) : nil, value: layoutValue)
		.animation(.spring(response: 0.26, dampingFraction: 0.82), value: isDragged)
		.animation(
			(dragState == nil && allowRepack) ? .spring(response: 0.30, dampingFraction: 0.86) : nil,
			value: dragState?.translation ?? .zero
		)
		.animation(
			(reduceMotion || !allowRepack) ? nil : .spring(response: 0.30, dampingFraction: 0.86),
			value: configuration.collapsedCards
		)
	}

	/// 拖拽手势（把手与卡片本体共用一套状态机）。
	/// 坐标空间 = BoardSpace（与探针一致）：pointer 与 frame 表同系，resolve 才对得上。
	/// 把手 minimumDistance=0：按住即拖，它是明示的"抓取点"；
	/// 卡片本体 minimumDistance=10 且走 simultaneousGesture（v2.1.2 人体工学）：
	/// 直觉是抓住卡片拖而不是去瞄小把手，但 10pt 阈值 + 不抢零位移点击，
	/// 保证卡片内的折叠箭头、按钮、图表 hover 照常响应——只有真拖起来才归它
	private func dragGesture(for id: CardID, minimumDistance: CGFloat) -> some Gesture {
		DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named(BoardSpace.name))
			.onChanged { drag in
				if dragState == nil {
					// 拖动开始：播种工作副本（自定义布局或会话冻结双列）并固化起始 frame
					let known = Set(CardID.allCases.map(\.layoutID))
					layoutSeed = PanelFlow.normalize(
						configurationManager.configuration.panelLayout ?? PanelLayout(
							rows: PanelFlow.alignColumns(left: assignedLeft.map(\.layoutID), right: assignedRight.map(\.layoutID))
						),
						known: known
					)
					layoutDraft = layoutSeed ?? PanelLayout()
					// 拖拽期让 frame 表发变更：把手层才能跟上预览重排的坐标
					frameStore.publishesChanges = true
					dragState = CardDragState(
						card: id.layoutID,
						translation: drag.translation,
						originFrame: frameStore.frames[id.layoutID] ?? .zero,
						// 起拖点=手指真实位置：落点跟手（旧实现用卡片中心，200pt 高的卡偏 ~100pt）
						startPoint: drag.startLocation
					)
				} else if dragState?.card != id.layoutID {
					// 幽灵拖拽守卫（v1.17.1）：已有别的卡在拖时，本手势不得改写它的 translation
					return
				}
				dragState?.translation = drag.translation
				updatePreview()
			}
			.onEnded { _ in finishDrag(from: id) }
	}

	/// 拖动中：按当前落点更新预览布局——其余卡片实时让位（行插入点预览）。
	/// 位移始终以拖动开始瞬间的 frame 为基准（拖动开始时已固化进 originFrame），
	/// 预览重排刷新 frame 表也不回灌落点计算——防反馈振荡
	private func updatePreview() {
		guard let drag = dragState, drag.isDragging else { return }
		let table = frameStore.snapshotTable()
		guard let target = CardDropResolver.resolve(point: drag.pointer, table: table, excluding: drag.card) else {
			// 出界/无锚点：清指示线与预览——松手不得提交上一合法落点（丢弃回弹语义）
			dropIndicator = nil
			previewLayout = nil
			return
		}
		dropIndicator = CardDropResolver.indicatorLine(for: target, table: table, excluding: drag.card)
		let base = previewLayout ?? layoutDraft
		let candidate = PanelFlow.insertLayout(base, card: drag.card, target: target)
		if candidate != base { previewLayout = candidate }
	}

	/// 松手：提交拖拽中已经算好的预览布局。
	/// **不再用 frame 表重解落点**——探针在布局动画中异步写表，松手时可能是预览前旧序，
	/// 重解会落错槽或静默丢弃；previewLayout 就是最后一次合法 target 的插入结果。
	private func finishDrag(from id: CardID? = nil) {
		defer {
			if id == nil || dragState?.card == id?.layoutID {
				dragState = nil
				previewLayout = nil
				dropIndicator = nil
				frameStore.publishesChanges = false
			}
		}
		guard let drag = dragState, drag.isDragging,
			  id.map({ drag.card == $0.layoutID }) ?? true,
			  let preview = previewLayout else { return }
		layoutDraft = preview
		configurationManager.snapshotLayoutForUndo()
		configurationManager.setPanelLayout(PanelFlow.normalize(preview, known: Set(CardID.allCases.map(\.layoutID))))
	}

	/// 常驻拖拽把手：六点把手胶囊，DragGesture 独占（无兄弟手势竞争）。
	/// 按住即进入拖拽态，落点实时驱动其他卡片让位，松手落盘。
	/// v1.13.0 回归修复：把手此前只挂在拖动中的卡上，常态无处可抓，拖拽实际无法发起
	private func dragHandle(_ id: CardID) -> some View {
		Image(systemName: "line.3.horizontal")
			.font(.system(size: 9, weight: .semibold))
			.foregroundStyle(GlassTokens.labelOnGlass.opacity(0.45))
			.padding(5)
			// v2.1.2 观感：常驻白色胶囊底让每张图片上顶着一个浮块、还压在首行"标签与值之间"，
			// 读起来像卡片内容。底改成 hover/拖动时才出现，常态只剩一枚淡符号——
			// 位置与可抓取性不变（v1.13 的回归是"常态无处可抓"，不是"常态可见"）
			.background(Capsule().fill(.ultraThinMaterial).opacity(isHandleHovering == id.layoutID || dragState?.card == id.layoutID ? 1 : 0))
			.padding(3)
			// 热区放大到视觉尺寸的 ~2.5 倍（原 ≈25pt 圆点：按住把手本身就要瞄，
			// 是"不顺手"的另一半）。视觉不变，只把可抓取范围向外扩 9pt
			.contentShape(Circle().inset(by: -9))
			.opacity(dragState?.card == id.layoutID ? 0 : 1)
			// 把手浮现/隐没过渡（v1.18.6）：抓起隐没、松手浮现走快速淡变——旧版无动画瞬跳
			.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dragState?.card == id.layoutID)
			// v1.18.3：拖动中禁止沿途把手 hover 亮起（指针拖卡划过谁谁就放大 1.3，视觉噪音），
			// 且拖动开始后不再写入新 hover 态（松手后旧卡不带着 1.3 复活）
			.onHover { h in
				guard dragState == nil else { return }
				isHandleHovering = h ? id.layoutID : nil
			}
			.scaleEffect(isHandleHovering == id.layoutID && dragState == nil ? 1.3 : 1.0)
			.animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHandleHovering == id.layoutID && dragState == nil)
			.gesture(dragGesture(for: id, minimumDistance: 0))
			.help("拖动调整这张卡片的位置")
	}

	/// 编辑模式每卡的控制条：隐藏（眼睛）+ 宽窄（宽块↔半宽，代价实时可见自己买单）
	private func cardControls(_ id: CardID) -> some View {
		HStack(spacing: 2) {
			controlButton("eye.slash", label: "隐藏") { applyLayout(PanelFlow.hide(layoutDraft, card: id.layoutID)) }
			let rows = layoutDraft.effectiveRows
			let isWide = PanelFlow.locate(rows, id: id.layoutID).map { rows[$0.row].count == 1 } ?? false
			if isWide {
				// 当前独占整行 → 收窄（并回相邻行；无处可并则不显示此键）
				if let narrowed = PanelFlow.toggleWide(layoutDraft, card: id.layoutID) {
					controlButton("rectangle.compress.vertical", label: "收窄为半宽") { applyLayout(narrowed) }
				}
			} else {
				// 半宽 → 拉宽独占整行（高度代价实时可见）
				controlButton("rectangle.expand.vertical", label: "拉宽独占整行") {
					if let widened = PanelFlow.toggleWide(layoutDraft, card: id.layoutID) {
						applyLayout(widened)
					}
				}
			}
		}
		.padding(.horizontal, 4)
		.padding(.vertical, 2)
		.background(Capsule().fill(.ultraThinMaterial))
		.padding(4)
	}

	/// 进入编辑布局：以当前生效布局（自定义或会话冻结双列对齐成行）播种工作副本
	private func enterLayoutEdit() {
		let known = Set(CardID.allCases.map(\.layoutID))
		layoutSeed = PanelFlow.normalize(
			configurationManager.configuration.panelLayout ?? PanelLayout(
				rows: PanelFlow.alignColumns(left: assignedLeft.map(\.layoutID), right: assignedRight.map(\.layoutID))
			),
			known: known
		)
		layoutDraft = layoutSeed ?? PanelLayout()
		// chrome/卡片控制条随弹簧过渡（v1.18.6，取代 if 硬切）
		withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
			isEditingLayout = true
		}
	}

	/// 退出编辑：改动过才落盘（面板关闭时 onDisappear 兜底按取消处理）
	private func exitLayoutEdit(save: Bool) {
		if save, let seed = layoutSeed {
			let normalized = PanelFlow.normalize(layoutDraft, known: Set(CardID.allCases.map(\.layoutID)))
			// 未改动不落盘：防止"进编辑什么都不动，保存后列式对齐变行式平白长高"
			if normalized != seed {
				configurationManager.setPanelLayout(normalized)
			}
		}
		withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
			isEditingLayout = false
		}
		trayExpanded = false
		layoutSeed = nil
	}

	/// 一键重置：清掉自定义布局回自动模式。
	/// 必须走 restoreDefaultLayout（先快照再清）——直接 clear 会让用户无法撤销。
	private func resetLayout() {
		layoutDraft = PanelLayout()
		configurationManager.restoreDefaultLayout()
		isEditingLayout = false
	}

	@ViewBuilder
	private func cardView(
		_ id: CardID,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem],
		configuration: AppConfiguration,
		showsHealthCurve: Bool
	) -> some View {
		switch id {
		case .powerInfo: powerInfoCard(powerItems)
		case .batteryInfo: batteryInfoCard(batteryItems)
		case .checkup: checkupCard(configuration)
		case .habitInsight: habitInsightCard(configuration)
		case .dailySummary: dailySummaryCard(configuration)
		case .usageCalendar: usageCalendarCard(configuration)
		case .socChart: socChartCard(configuration)
		case .healthTrend: healthTrendCard(configuration, showsHealthCurve: showsHealthCurve)
		case .powerChart: powerChartCard(configuration)
		case .temperatureChart: temperatureChartCard(configuration)
		case .bluetooth: bluetoothCard(configuration)
		case .chargeHistory: chargeHistoryCard(configuration)
		case .powerEvents: powerEventsCard(configuration)
		case .energyApps: energyAppsCard(configuration)
		case .hourlyDrain: hourlyDrainCard(configuration)
		case .runtimeScenarios: runtimeScenariosCard(configuration)
		case .batteryIdentity: batteryIdentityCard(configuration)
		}
	}
	
	// MARK: - 卡片拼装（单列/双列共用同一套条件）
	
	@ViewBuilder
	private func powerInfoCard(_ powerItems: [BatteryInfoItem]) -> some View {
		if !powerItems.isEmpty {
			PopoverCard {
				ForEach(powerItems) { PopoverInfoRow(item: $0) }
			}
		}
	}
	
	@ViewBuilder
	private func batteryInfoCard(_ batteryItems: [BatteryInfoItem]) -> some View {
		if !batteryItems.isEmpty {
			PopoverCard {
				ForEach(batteryItems) { PopoverInfoRow(item: $0) }
			}
		}
	}
	
	@ViewBuilder
	private func checkupCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.batteryCheckup),
		   let checkup = BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			highSocDwellShare: historyRecorder.todayUsage?.highSocDwellShare
		   ) {
			BatteryCheckupSection(checkup: checkup)
		}
	}
	
	@ViewBuilder
	private func dailySummaryCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.dailySummary), let usage = historyRecorder.todayUsage,
		   usage.drainedPercent > 0 || usage.chargedPercent > 0 {
			DailySummarySection(
				usage: usage,
				chargeCount: todayChargeCount,
				history: historyRecorder.dailyHistory,
				isCollapsed: isCardCollapsed(.dailySummary),
				onToggle: { toggleCard(.dailySummary) }
			)
		}
	}
	
	// 最近 30 天电量跳变次数（身份证卡片与校准提醒共用同一口径）
	private var socJumpCount30d: Int {
		UsagePatternAnalyzer.socJumpCount(historyRecorder.socJumpEvents, withinDays: 30, now: Date())
	}

	// 续航换算：电池模式下把当前掉电速度换算成各场景还能撑多久
	@ViewBuilder
	private func runtimeScenariosCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.runtimeScenarios),
			monitor.snapshot.powerSource == .battery,
			let estimate = monitor.drainEstimate, estimate.percentPerHour > 0,
			let soc = monitor.snapshot.stateOfChargePercent {
			RuntimeScenarioSection(
				estimate: estimate,
				socPercent: soc,
				isCollapsed: isCardCollapsed(.runtimeScenarios),
				onToggle: { toggleCard(.runtimeScenarios) }
			)
		}
	}

	// 电池身份证：出厂静态信息 + 电量计跳变状态
	@ViewBuilder
	private func batteryIdentityCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.batteryIdentity),
			let identity = monitor.batteryIdentity, identity.isMeaningful {
			BatteryIdentitySection(
				identity: identity,
				maxCapacityMAh: monitor.snapshot.maxCapacityMAh,
				jumpCount30d: socJumpCount30d,
				needsCalibration: UsagePatternAnalyzer.gaugeNeedsCalibration(jumpCount: socJumpCount30d),
				isCollapsed: isCardCollapsed(.batteryIdentity),
				onToggle: { toggleCard(.batteryIdentity) }
			)
		}
	}

	// 充电习惯建议（有可用洞察才显示）；先看习惯规律，再看热叠加，最后看当前充电器是否偏慢
	// 洞察链 v2：四条洞察线的可用项全收（不再只挑第一条说），按优先级排列
	private var habitInsights: [ChargingHabitInsight] {
		let base = ChargingHabitAnalyzer.analyze(
			events: historyRecorder.powerEvents,
			dailyHistory: historyRecorder.dailyHistory,
			snapshot: monitor.snapshot
		)
		let careHolding = configurationManager.configuration.enabledOptions.contains(.chargeCareReminder)
			&& alertController.isOptimizedChargingHolding
		let heat = UsagePatternAnalyzer.heatUsageOverlapInsight(
			drain: historyRecorder.hourlyDrainStats,
			temp: historyRecorder.hourlyTempStats
		).map { ChargingHabitInsight(message: $0, symbol: "thermometer.sun.fill") }
		let charger = ChargingHabitAnalyzer.analyzeCharger(
			snapshot: monitor.snapshot,
			currentCharger: historyRecorder.currentChargerProfile,
			knownChargers: historyRecorder.chargerProfiles
		)
		return UsagePatternAnalyzer.chargingInsights(
			habitBase: base,
			careHolding: careHolding,
			careThresholdPercent: configurationManager.configuration.chargeCareThresholdPercent,
			heatOverlap: heat,
			chargerInsight: charger,
			// 静默真的生效过才用"已不再重复提醒"的措辞（读不到签名的机器不承诺）
			careSilencedBySystemHold: alertController.hasSilencedCareForSystemHold,
			dwellInsight: DwellTracking.trackingInsight(history: historyRecorder.dailyHistory),
			storageInsight: StorageGuide.advice(
				socPercent: monitor.snapshot.stateOfChargePercent,
				isOnAC: monitor.snapshot.powerSource == .powerAdapter
			).map { ChargingHabitInsight(message: $0, symbol: "archivebox.fill") },
			trickleInsight: TrickleNotice.liveNotice(
				socPercent: monitor.snapshot.stateOfChargePercent,
				isCharging: monitor.snapshot.isCharging
			)
		)
	}
	
	@ViewBuilder
	private func habitInsightCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.habitInsight), !habitInsights.isEmpty {
			HabitInsightSection(insights: habitInsights)
		}
	}
	
	@ViewBuilder
	private func usageCalendarCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.usageCalendar), historyRecorder.dailyHistory.count >= 3 {
			UsageCalendarSection(
				history: historyRecorder.dailyHistory,
				isCollapsed: isCardCollapsed(.usageCalendar),
				onToggle: { toggleCard(.usageCalendar) }
			)
		}
	}
	
	@ViewBuilder
	private func socChartCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.socChart), historyRecorder.socSamples.count >= 2 {
			SOCChartSection(
				samples: historyRecorder.socSamples,
				lowThreshold: configuration.lowBatteryThresholdPercent,
				isCollapsed: isCardCollapsed(.socChart),
				onToggle: { toggleCard(.socChart) }
			)
		}
	}
	
	@ViewBuilder
	private func healthTrendCard(_ configuration: AppConfiguration, showsHealthCurve: Bool) -> some View {
		if configuration.enabledOptions.contains(.healthTrend), showsHealthCurve {
			HealthTrendSection(
				// 只画电池更换之后的样本：换电池前的旧曲线与新电池不可比
				samples: historyRecorder.trendHealthSamples,
				isCollapsed: isCardCollapsed(.healthTrend),
				onToggle: { toggleCard(.healthTrend) }
			)
		}
	}
	
	@ViewBuilder
	private func powerChartCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.powerChart), monitor.powerSamples.count >= 2 {
			PowerChartSection(
				samples: monitor.powerSamples,
				isCollapsed: isCardCollapsed(.powerChart),
				onToggle: { toggleCard(.powerChart) }
			)
		}
	}
	
	@ViewBuilder
	private func temperatureChartCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.temperatureChart), monitor.temperatureSamples.count >= 2 {
			TemperatureChartSection(
				samples: monitor.temperatureSamples,
				thresholdC: configuration.highTemperatureThresholdC,
				isCollapsed: isCardCollapsed(.temperatureChart),
				onToggle: { toggleCard(.temperatureChart) }
			)
		}
	}
	
	@ViewBuilder
	private func bluetoothCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.bluetoothDevices), !monitor.bluetoothDevices.isEmpty {
			BluetoothDevicesSection(
				devices: monitor.bluetoothDevices,
				lowThreshold: configuration.deviceLowThresholdPercent
			)
		}
	}
	
	@ViewBuilder
	private func chargeHistoryCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.chargeHistory), !historyRecorder.recentSessions.isEmpty {
			ChargeHistorySection(
				sessions: historyRecorder.recentSessions,
				isCollapsed: isCardCollapsed(.chargeHistory),
				onToggle: { toggleCard(.chargeHistory) },
				onSelect: openChargeCurve,
				chargerNames: Dictionary(
					historyRecorder.chargerProfiles.map { ($0.key, $0.displayName) },
					uniquingKeysWith: { first, _ in first }
				)
			)
		}
	}

	// 打开充电曲线独立窗口；控制器内部已激活应用确保窗口浮到最上层（与"设置"同一套做法）
	private func openChargeCurve(_ session: ChargeSession) {
		ChargeCurveSelection.shared.startDate = session.startDate
		ChargeCurveWindowController.shared.show(historyRecorder: historyRecorder)
	}
	
	@ViewBuilder
	private func powerEventsCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.powerEvents), !historyRecorder.powerEvents.isEmpty {
			PowerEventTimelineSection(
				events: historyRecorder.powerEvents,
				isCollapsed: isCardCollapsed(.powerEvents),
				onToggle: { toggleCard(.powerEvents) }
			)
		}
	}
	
	// 应用耗电"本周累计"排行：最近 7 天按累计秒数取前三（不足 1 分钟的不入榜）；
	// 附活跃峰值时段（小时分布是长期滚动的习惯画像，比单周样本更稳）
	private var weeklyAppEnergy: [(name: String, seconds: Double, window: String?)] {
		var keys = Set<String>()
		for offset in 0..<7 {
			if let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) {
				keys.insert(Self.weeklyKeyFormatter.string(from: date))
			}
		}
		return historyRecorder.appEnergy
			.compactMap { record -> (name: String, seconds: Double, window: String?)? in
				let seconds = record.seconds(within: keys)
				guard seconds >= 60 else { return nil }
				let window = UsagePatternAnalyzer.peakActivityWindow(secondsByHour: record.secondsByHour ?? [])
					.map { "\($0.start)–\($0.end) 点" }
				return (record.name, seconds, window)
			}
			.sorted { $0.seconds > $1.seconds }
			.prefix(3)
			.map { (name: $0.name, seconds: $0.seconds, window: $0.window) }
	}

	private static let weeklyKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// 与历史 dayKey 主键同源的 POSIX 公历
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()

	@ViewBuilder
	private func hourlyDrainCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.hourlyDrainChart), historyRecorder.hourlyDrainStats.accumulatedDays >= 3 {
			HourlyDrainSection(
				stats: historyRecorder.hourlyDrainStats,
				isCollapsed: isCardCollapsed(.hourlyDrainChart),
				onToggle: { toggleCard(.hourlyDrainChart) }
			)
		}
	}

	@ViewBuilder
	private func energyAppsCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.significantEnergyApps) {
			SignificantEnergySection(
				apps: monitor.significantEnergyApps,
				isWarmingUp: !monitor.isEnergyScanWarmedUp,
				weeklyTop: weeklyAppEnergy,
				onRevealInFinder: revealInFinder(url:)
			)
		}
	}
	
	// 今天的充电次数：已归档的今日会话 + 进行中的这次
	// （含已充满但未拔电的存活会话——它还没归档，但确实充过）
	private var todayChargeCount: Int {
		let finished = historyRecorder.recentSessions.filter { Calendar.current.isDateInToday($0.startDate) }.count
		let ongoing = (monitor.snapshot.isCharging || historyRecorder.isChargingSessionAlive) ? 1 : 0
		return finished + ongoing
	}
	
	// 图表卡片折叠状态（随配置持久化）
	private func isCardCollapsed(_ option: DisplayOption) -> Bool {
		configurationManager.configuration.collapsedCards.contains(option.rawValue)
	}
	
	private func toggleCard(_ option: DisplayOption) {
		configurationManager.toggleCardCollapsed(option)
	}
	
	// 级联档位：playCascade=false 时全部归零，各块同时落位（无错峰延迟）
	private func cascadeStep(_ step: Int) -> Int {
		playCascade ? step : 0
	}

	// 状态行是否存在：决定"状态 vs 动作"那条分节线画不画
	private var hasControlStateRows: Bool {
		(configurationManager.configuration.enabledOptions.contains(.alerts)
			&& alertController.isNotificationPermissionDenied)
			|| monitor.snapshot.isSystemChargeHeld
	}

	// 动作组之间的小间距（不加文字标题：控制行栈已占近 1/4 面板高，再加标题只会更长）
	private var controlGroupGap: some View {
		Spacer().frame(height: 4)
	}

	private var controlRows: some View {
		// v1.24.1 行距 4：药丸各自成件后留出玻璃缝隙（贴死会连成一条，失去"浮在玻璃上"的节奏）
		VStack(spacing: 3) {
			// 开了提醒但系统不给发通知：提醒实际收不到，给个显眼的入口去开权限
			if configurationManager.configuration.enabledOptions.contains(.alerts),
			   alertController.isNotificationPermissionDenied {
				notificationPermissionWarning
			}
			// C2 系统共存：系统「优化电池充电」正在按住充电——解释"插着电为何不在充"，
			// 并给一键通道去系统电池页（用户想接管/想立刻充满时知道门在哪）
			if monitor.snapshot.isSystemChargeHeld {
				systemChargeHoldRow
			}
			// v2.1.2 观感：状态行（权限未开 / 系统暂缓充电）与动作行分组——
			// 前者是"现在发生了什么"，后者是"你可以做什么"，同形同权重时状态行读起来像第 8 个按钮
			if hasControlStateRows {
				Divider()
					.padding(.vertical, 2)
			}
			// 设置已迁到独立设置窗口，这里只负责打开它；
			// 30+ 开关在窗口里按组分区（可搜索、带帮助），比面板子菜单好用得多。
			// 必须用 SettingsLink：sendAction(showSettingsWindow:) 在 NSHostingView 宿主里被系统
			// 拒绝（运行时 Fault "Please use SettingsLink"，实测在案）；simultaneousGesture 补激活——
			// LSUIElement 应用不抢前台，不激活的话设置窗口会埋在其他 App 后面。
			// buttonStyle(.plain) 剥掉 SettingsLink 自带的链接态底色——行观感必须与其他控制行完全一致
			// 华容网格：进编辑模式重排/隐藏卡片（仅双列面板提供——当前会话配平出两列即满足）
			if !assignedLeft.isEmpty || !assignedRight.isEmpty {
				PopoverActionRow("隐藏卡片", systemImageName: "eye.slash") {
					enterLayoutEdit()
				}
			}

			SettingsLink {
				GlassRow {
					HStack(spacing: 6) {
						Image(systemName: "gear")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(GlassTokens.labelOnGlass)
							.frame(width: 16)
						Text("设置")
							.font(.system(size: PopoverLayout.bodyFontSize, weight: .regular))
							.foregroundStyle(.primary)
						Spacer(minLength: 8)
					}
					.frame(maxWidth: .infinity, minHeight: PopoverLayout.rowHeight, alignment: .leading)
					.padding(.horizontal, PopoverLayout.rowHorizontalPadding)
					.contentShape(Rectangle())
				}
			}
			.buttonStyle(.plain)
			.simultaneousGesture(TapGesture().onEnded {
				NSApp.activate(ignoringOtherApps: true)
			})
			
			controlGroupGap
			PopoverActionRow("导出报告", systemImageName: "square.and.arrow.up") {
				exportReport()
			}

			PopoverActionRow(reportCopied ? "已复制" : "复制报告",
							 systemImageName: reportCopied ? "checkmark.circle.fill" : "doc.on.doc") {
				copyReport()
			}

			PopoverActionRow("导出数据 (CSV)", systemImageName: "tablecells") {
				exportCSV()
			}
			
			// 体检分可算时才提供“生成分享卡片”
			if batteryCheckup != nil {
				PopoverActionRow("生成体检卡片", systemImageName: "photo.badge.checkmark") {
					exportShareCard()
				}
			}
			
			controlGroupGap
			PopoverActionRow("电池设置", systemImageName: "slider.horizontal.3") {
				openBatterySettings()
			}
			
			PopoverActionRow("退出", systemImageName: "power") {
				NSApplication.shared.terminate(nil)
			}
			.keyboardShortcut("q")
		}
	}

	private func openBatterySettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery") else { return }
		NSWorkspace.shared.open(url)
	}
	
	// 系统暂缓状态行：复用规范控制行组件 PopoverActionRow——文字/图标走证明过的 label 色。
	// 手写彩色小字坐玻璃药丸面在任意壁纸最坏只有 2.2~2.4:1（远低 AA 4.5，见测试「控制行文字色锁」），
	// 语义由 pause.circle 图标与文字本身承担，不靠颜色承担。
	// 悬停说明把归因留余地：该位只证到"系统在暂停充电"，最常见原因是优化电池充电，
	// 但温度保护/充电上限同样会让系统停充——不把原因说死（诚实边界）
	private var systemChargeHoldRow: some View {
		PopoverActionRow("系统正在暂缓充电 · 点按打开电池设置", systemImageName: "pause.circle") {
			openBatterySettings()
		}
		.help("插着电但没在充电：通常是 macOS「优化电池充电」把你按在 80% 附近；电池温度保护或你设的充电上限也会让系统暂停充电。想立刻充满：系统设置 → 电池，临时关闭「优化电池充电」。")
	}
	
	private var notificationPermissionWarning: some View {
		Button(action: openNotificationSettings) {
			GlassRow {
				HStack(spacing: 6) {
					Image(systemName: "bell.slash.fill")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(Color.orange)
						.frame(width: 16)
					Text("通知权限未开启，提醒收不到 · 点此开启")
						.font(.system(size: 11))
						.foregroundStyle(.primary)  // 文字走证明过的色，紧迫性由橙色图标承担（彩色小字坐药丸面不达 AA）
						.lineLimit(1)
						.minimumScaleFactor(0.8)
				}
				.frame(maxWidth: .infinity, minHeight: PopoverLayout.rowHeight, alignment: .leading)
				.padding(.horizontal, PopoverLayout.rowHorizontalPadding)
				.contentShape(Rectangle())
			}
		}
		.buttonStyle(.plain)
	}
	
	private func openNotificationSettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
		NSWorkspace.shared.open(url)
	}
	
	private func revealInFinder(url: URL?) {
		guard let url else { return }
		NSWorkspace.shared.activateFileViewerSelecting([url])
	}
	
	// 生成纯文本报告写入临时目录，并在访达中选中
	private func exportReport() {
		let report = buildReport()
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		let fileName = "电池报告-\(formatter.string(from: Date())).txt"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
		
		do {
			try report.write(to: url, atomically: true, encoding: .utf8)
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} catch {
			DiagnosticLog.failureOnce("export-report-failed", category: "BatteryPopoverView", "导出报告写入失败：\(error.localizedDescription)")
			showExportAlert(body: "无法写入报告文件：\(error.localizedDescription)")
		}
	}
	
	// 复制纯文本报告到剪贴板；与"导出报告"同源，只是落点不同
	private func copyReport() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(buildReport(), forType: .string)
		// 静默成功没法确认是否生效，行内反馈 1.5 秒
		reportCopied = true
		Task {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			reportCopied = false
		}
	}
	
	private func buildReport() -> String {
		BatteryReportBuilder(
			snapshot: monitor.snapshot,
			configuration: configurationManager.configuration,
			drainEstimate: monitor.drainEstimate,
			healthSamples: historyRecorder.healthSamples,
			sessions: historyRecorder.recentSessions,
			bluetoothDevices: monitor.bluetoothDevices,
			dailyHistory: historyRecorder.dailyHistory,
			chargerProfiles: historyRecorder.chargerProfiles,
			lastSleepDrain: historyRecorder.lastSleepDrain,
			powerEvents: historyRecorder.powerEvents,
			identity: monitor.batteryIdentity,
			socJumpCount30d: socJumpCount30d
		).build()
	}
	
	// 生成 CSV 数据写入临时目录，并在访达中选中；与"导出报告"互补——
	// 报告是人读的摘要，CSV 是给表格/脚本分析用的原数据
	private func exportCSV() {
		let csv = BatteryDataExporter.csv(
			sessions: historyRecorder.recentSessions,
			dailyHistory: historyRecorder.dailyHistory,
			healthSamples: historyRecorder.healthSamples,
			socSamples: historyRecorder.socSamples,
			powerEvents: historyRecorder.powerEvents
		)

		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		let fileName = "电池数据-\(formatter.string(from: Date())).csv"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

		do {
			try csv.write(to: url, atomically: true, encoding: .utf8)
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} catch {
			DiagnosticLog.failureOnce("export-csv-failed", category: "BatteryPopoverView", "导出 CSV 写入失败：\(error.localizedDescription)")
			showExportAlert(body: "无法写入 CSV 文件：\(error.localizedDescription)")
		}
	}
	
	// 当前体检评分（供头部展示与分享卡片共用）
	// 头部右槽的兜底内容：体检关掉时显示"接的是哪只充电器"（名字 + 协议·额定）
	private var chargerHeadline: (String, String?)? {
		guard monitor.snapshot.powerSource == .powerAdapter else { return nil }
		let profile = historyRecorder.currentChargerProfile
		// 认不出是哪只充电器时宁可留空：兜底写"已接通电源"会和头部左侧那行
		// "已接通电源 · 未充电"在同一行里重复两遍（自查抓出）
		guard let name = profile?.displayName ?? monitor.snapshot.adapterName, !name.isEmpty else { return nil }
		var detailParts: [String] = []
		if let proto = monitor.snapshot.chargingProtocol { detailParts.append(proto) }
		if let rated = profile?.ratedWatts ?? monitor.snapshot.adapterRatedWatts, rated > 0 {
			detailParts.append("额定\(rated)W")
		}
		return (name, detailParts.isEmpty ? nil : detailParts.joined(separator: " · "))
	}

	private var batteryCheckup: BatteryCheckup? {
		guard configurationManager.configuration.enabledOptions.contains(.batteryCheckup) else { return nil }
		return BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			highSocDwellShare: historyRecorder.todayUsage?.highSocDwellShare
		)
	}
	
	// 生成体检分享卡片（PNG）写入临时目录，并在访达中选中
	private func exportShareCard() {
		guard let checkup = batteryCheckup else { return }
		let card = BatteryShareCardRenderer.render(BatteryShareCardRenderer.CardData(
			score: checkup.score,
			verdict: checkup.verdict,
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			generatedAt: Date()
		))
		if let url = BatteryShareCardRenderer.writePNG(card) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} else {
			showExportAlert(body: "体检卡片写入失败，请查看诊断日志。")
		}
	}

	// 导出类操作的失败反馈：静默失败会让用户以为按钮坏了（与存档导入同一审计）
	private func showExportAlert(body: String) {
		let alert = NSAlert()
		alert.messageText = "导出失败"
		alert.informativeText = body
		alert.alertStyle = .warning
		alert.addButton(withTitle: "好")
		alert.runModal()
	}
}

import Foundation

/// 面板动效参数（纯常量，进测试面）。
/// 纪律：液态玻璃的生命感靠「持续、便宜、隔离」的小动画，不靠整树弹簧；
/// 丝滑 = 提高小动效采样率 + 收紧转场时长，而不是加更多动画。
nonisolated enum PanelMotion {
	/// 头部呼吸/波浪/流光/热脉冲限帧。12fps 省电但发涩；30fps 对
	/// 小面积几何位移已经跟手，且远低于 120Hz 滚动帧预算。
	nonisolated static let timelineFPS: Double = 30
	nonisolated static var timelineInterval: Double { 1.0 / timelineFPS }

	/// 慢速呼吸档：只改透明度或做 ±5% 以内微缩放的脉动，人眼看不出步进，没必要跟位置类
	/// 动画一样跑 30fps。**准入由 `interval(forPeriod:)` 判定，不是调用方自选**——
	/// 周期 <2s 的脉冲（如高温边框 0.8–1.6s）15fps 只剩 12 帧一圈，会发起涩；
	/// 那是警示通道的节奏本身，不许为省重算牺牲掉。
	nonisolated static let breathFPS: Double = 15
	nonisolated static var breathInterval: Double { 1.0 / breathFPS }
	/// 周期到帧率的档位规则：够慢（≥breathEligiblePeriod）才走慢速档，否则按位置类 30fps。
	nonisolated static let breathEligiblePeriod: Double = 2.0
	nonisolated static func interval(forPeriod period: Double) -> Double {
		period >= breathEligiblePeriod ? breathInterval : timelineInterval
	}

	// MARK: 充电呼吸点的形状参数（v2.9.13 收窄）
	//
	// 原来是 0.90↔1.15 / 周期 1.8s：在一颗 4.5pt 的光点上做 25% 的缩放摆动，
	// 读起来是「它自己在缩」而不是「它活着」——幅度越小的元素越不该大动作。
	// 现在缩放只留 ±5%，把生命感交回透明度（仍在 0…1 内波动）。
	// 周期取 2.0s 而不是更慢，有两道锁：
	// ①警示通道排序——低电呼吸 2.2s 必须仍是全场最沉（`BatteryVisualResolver.lowBreathPeriod`）；
	// ②别与波面/流光的慢档 2.4s 撞成同一周期——三处读同一把墙钟，1:1 会永久锁相。
	nonisolated static let dotPeriodSeconds: Double = 2.0
	nonisolated static let dotScaleMin: CGFloat = 0.96
	nonisolated static let dotScaleMax: CGFloat = 1.06
	nonisolated static let dotOpacityMin: Double = 0.60
	nonisolated static let dotOpacityMax: Double = 0.95

	/// 呼吸相位 0…1（墙钟秒 t、周期 period）。t=0 取 0.5 只保证波形对称，
	/// 不代表"面板打开那刻从中位起"——t 是绝对墙钟，打开时刻的相位是任意的
	nonisolated static func breathPhase(_ t: Double, period: Double) -> Double {
		0.5 + 0.5 * sin(t * 2 * .pi / period)
	}

	nonisolated static func dotScale(_ phase: Double) -> CGFloat {
		dotScaleMin + (dotScaleMax - dotScaleMin) * CGFloat(phase)
	}

	nonisolated static func dotOpacity(_ phase: Double) -> Double {
		dotOpacityMin + (dotOpacityMax - dotOpacityMin) * phase
	}

	/// 卡片重排/折叠：稍长弹簧，阻尼偏高 → 少回弹、更「沉稳跟手」
	nonisolated static let cardRepack = "spring(response:0.34,damping:0.88)"
	/// 抓起/放下：更快收束
	nonisolated static let cardGrab = "spring(response:0.26,damping:0.82)"
	/// 数值淡入淡出：0.2s，避免多行同时 0.3s 交叉淡化叠成滚动外的顿
	nonisolated static let valueFadeSeconds: Double = 0.2
}

/// 动效门（纯函数）：滚动中是否允许跑非拖拽类弹簧/折叠动画。
/// 拖拽跟手动画始终允许——那是交互本身，不是装饰。
nonisolated enum PanelMotionGate {
	/// 滚动期间是否把**充电通道的持续动画**停下（呼吸点/波面退各自静态帧，弧端流光整层不画）。
	///
	/// 只管**充电通道**的三处墙钟动画（呼吸点、波面、弧端流光——三处都只在充电态挂载，
	/// 电池常态一处也不跑，这也是本机在电池上量不到该改动收益的原因）；玻璃、药丸、
	/// 级联入场照旧有生命——它们是响应式而非持续型，不驱动逐帧求值。
	///
	/// **警示通道刻意不进门**（热脉冲、低电呼吸）：它们的语义就在节奏里（越烫越急），
	/// 本文件另一处立过的规矩是"警示不为省重算让路"——滚动帧预算不该拿警示信息去换。
	/// 定相不够：TimelineView 即使内容不变也仍要每拍求值，所以必须走"无 TimelineView"的那条分支
	/// （与各动画的「减少动态效果」静态分支同一条，不再造第二套静态态）。
	nonisolated static func holdsDecorativeAnimation(isScrolling: Bool) -> Bool { isScrolling }

	nonisolated static func allowsRepackAnimations(isScrolling: Bool, isDragging: Bool) -> Bool {
		if isDragging { return true }
		return !isScrolling
	}
}

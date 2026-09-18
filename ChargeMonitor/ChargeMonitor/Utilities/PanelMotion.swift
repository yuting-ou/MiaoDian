import Foundation

/// 面板动效参数（纯常量，进测试面）。
/// 纪律：液态玻璃的生命感靠「持续、便宜、隔离」的小动画，不靠整树弹簧；
/// 丝滑 = 提高小动效采样率 + 收紧转场时长，而不是加更多动画。
nonisolated enum PanelMotion {
	/// 头部呼吸/波浪/流光/热脉冲限帧。12fps 省电但发涩；30fps 对
	/// 小面积几何位移已经跟手，且远低于 120Hz 滚动帧预算。
	nonisolated static let timelineFPS: Double = 30
	nonisolated static var timelineInterval: Double { 1.0 / timelineFPS }

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
	nonisolated static func allowsRepackAnimations(isScrolling: Bool, isDragging: Bool) -> Bool {
		if isDragging { return true }
		return !isScrolling
	}
}

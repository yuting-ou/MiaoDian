import Foundation

/// 滚动手感（纯函数）：区分触控板与鼠标滚轮。
///
/// 触控板 `hasPreciseScrollingDeltas=true`，系统按像素滚动已跟手，一律原样放过。
/// 鼠标滚轮是行步进（一格约 ±1），在玻璃卡片区里「转很多圈才动一点」——
/// 换算成像素步长后合成精确滚动事件，让滚轮与触控板走同一条像素路径。
nonisolated enum ScrollFeel {
	/// 鼠标滚轮一格（deltaY=±1）对应的垂直像素。
	/// 校准：SwiftUI ScrollView 默认行高偏小，密集卡片下用户体感是「不动」；
	/// 60pt/格 ≈ 一次中等幅度翻过 1–2 张卡，与系统原生列表的滚轮手感同量级。
	nonisolated static let mousePixelStep: CGFloat = 60

	/// 幅度地板：惯性尾巴（|delta|→0）不放大，避免与系统惯性叠成过冲。
	nonisolated static let minWheelDelta: CGFloat = 0.15

	/// 是否应放大：仅非精确滚动（鼠标滚轮）且幅度有效。
	nonisolated static func shouldAmplify(hasPreciseScrollingDeltas: Bool, deltaY: CGFloat) -> Bool {
		!hasPreciseScrollingDeltas && abs(deltaY) >= minWheelDelta
	}

	/// 鼠标滚轮 deltaY → 像素位移。
	/// 符号与 `scrollingDeltaY` 一致（系统已按「自然滚动」偏好预处理方向），合成事件沿用即可。
	nonisolated static func pixelDelta(forWheel deltaY: CGFloat, step: CGFloat = mousePixelStep) -> CGFloat {
		deltaY * step
	}
}

/// 滚动静默判定（纯函数，进测试面）：触控板 bounds 变化停手多久视为 idle
nonisolated enum PanelScrollIdle {
	/// 最后一次 bounds 变化后静默多久视为停手。
	///
	/// **不是"手感阈值"，是"翻转代价阈值"**：一次 true→false 翻转要把卡片区的 frame 探针与
	/// 把手层重新挂载，并让头部墙钟动画换回活帧。
	///
	/// 同一份量具、同一份代码只差这个数字（`bash 工具/滚动成本.sh 10 40`：改常量→重编量具→各跑一次；
	/// 离屏口径、主线程 CPU；**单位是"每格"=一次位移 + 其后 150ms 排空**，不是每帧——
	/// 一格会摊成十几帧，除以帧数就把尖峰糊平了）：
	/// → 80ms 取值：150ms 一格滚动 = 每格 2 次翻转，每格均值 54.1ms · p50 37.7 · p95 151.7 · 占空 36% · 整段翻转 80 次
	/// → 400ms 取值：几乎不再翻转（整段 1 次），每格均值 10.1ms · p50 6.6 · p95 10.2 · 占空 7% · 整段翻转 1 次
	/// p95 从 152ms 掉到 10ms 是这条改动的全部意义：p95 那种尖峰就是用户手里的"一卡一卡"。
	///
	/// **已知没覆盖到**：一格停 500ms 以上的极慢滚（两种取值都是每格 110~131ms、42 次翻转，因为每格照样两次翻转）——
	/// 阈值再往上抬只是推迟同样的代价，真要修的是"翻转不该让整块卡区重建"，记在 v2.9.15 下一轮。
	/// 代价：停手后约 0.4 秒内仍按滚动态处理（把手暂不显、数据补发延后一拍）。醒来按"剩余时间"睡
	/// （见 `sleepNanoseconds`），所以这个 0.4 秒不是 0.4~0.8 秒的随机数。拖卡不受影响——
	/// `allowsRepackAnimations` 在 dragging 时恒允许。
	nonisolated static let idleMilliseconds: UInt64 = 400
	nonisolated static var idleNanoseconds: UInt64 { idleMilliseconds * 1_000_000 }

	nonisolated static func shouldClearScrolling(elapsedNanoseconds: UInt64) -> Bool {
		elapsedNanoseconds >= idleNanoseconds
	}

	/// 静默任务这一轮该睡多久：**睡到"最后一次滚动 + 阈值"那一刻**，不是固定再睡一整轮。
	///
	/// 固定睡 400ms 的实际恢复窗口是 400~800ms（醒来发现还差一点就再睡一整轮），
	/// 等于把"停手后多久把手回来"变成随机数。剩余量由纯函数给出，测试面才钉得住这条。
	/// 返回 0 = 已到点，醒来立刻判定并清位（不是忙等：调用方随后就退出）。
	/// 入参是整数纳秒而不是秒：这函数的输出直接喂 `Task.sleep`，走 Double 会让"0.15 秒"
	/// 这种字面量在二进制里差一个零头，断言就变成在测浮点误差。
	/// 时间戳倒挂（休眠唤醒后 `Date` 回退）由调用方 `max(0, …)` 兜，不在这条纯函数里。
	nonisolated static func sleepNanoseconds(elapsedSinceLastActivityNanoseconds elapsed: UInt64) -> UInt64 {
		elapsed >= idleNanoseconds ? 0 : idleNanoseconds - elapsed
	}
}

/// 纵向弹性策略（纯函数）：到顶/到底是否允许橡皮筋回弹。
/// 橡皮筋是 macOS/苹果手感的一部分（液态玻璃面板也靠它「有生命」）。
/// 回弹默认**保留**（v2.9.15 复核：掉帧的大头不在弹性上，在滚动状态翻转引发的
/// 卡片区重建与逐帧求值的墙钟动画——那两处已各自处理；这里再动只是拿苹果手感换测量噪声）。
nonisolated enum PanelScrollElasticity {
	nonisolated static let allowsVerticalBounce = true
}

/// 滚动文档几何（纯函数）：测量后如何撑高 document、如何钳制 scroll offset。
/// updateNSView 每次数据刷新都会重测——若先把 hosting 高度打成 10 再量，
/// clipView 会把 origin 钳回 0，用户看到「滑到中间又被拽回顶部」。
nonisolated enum PanelScrollGeometry {
	/// document 高：至少与视口同高（装不满也不留空转），否则取测量高
	nonisolated static func documentHeight(measured: CGFloat, viewport: CGFloat) -> CGFloat {
		max(measured, max(viewport, 0))
	}

	/// 把将要保留的 scrollY 钳进 [0, content-viewport]
	nonisolated static func clampedScrollY(current: CGFloat, contentHeight: CGFloat, viewport: CGFloat) -> CGFloat {
		let maxY = max(0, contentHeight - max(viewport, 0))
		return min(max(current, 0), maxY)
	}
}

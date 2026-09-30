import Foundation

// 历史采集用的时钟。
//
// 拆分前每个域都在方法体里直接 `Date()` / `Calendar.current`——要测"跨午夜那一觉怎么记"
// 就得等到真跨午夜。现在时间从构造器进来，测试给一个可推进的假钟就能把状态机走完。
//
// 为什么日历也一起注入：日键（dayKey）是按日历算的，只钉住时刻不钉住日历，
// 时区/历法一变断言就飘——这正是 AGENTS.md 记的"极端时区 4 条断言会红"的根因类型。
nonisolated struct HistoryClock {
	var now: () -> Date
	var calendar: Calendar

	init(now: @escaping () -> Date, calendar: Calendar = .current) {
		self.now = now
		self.calendar = calendar
	}

	/// 生产：跟着系统走。
	/// 写成**计算属性**而不是 `static let`：HistoryClock 里有个闭包，不是 Sendable，
	/// 静态存储会在 Swift 6 严格并发下报 MutableGlobalVariable（CI 的全量审计正跑这个模式）。
	/// 计算属性没有共享存储，也就没有这条诊断；每次取只是构造一个结构体，可忽略。
	static var live: HistoryClock { HistoryClock(now: { Date() }) }
}

/// 可推进的假钟。测试专用，但放在生产模块里是故意的：
/// 它让"每个域都能被喂时间"这件事有个公共写法，而不是每份测试各造一个盒子
final class MutableHistoryClock {
	private var current: Date
	private let calendar: Calendar

	init(_ start: Date, calendar: Calendar = .current) {
		self.current = start
		self.calendar = calendar
	}

	var clock: HistoryClock {
		HistoryClock(now: { [self] in current }, calendar: calendar)
	}

	func advance(_ interval: TimeInterval) {
		current = current.addingTimeInterval(interval)
	}

	func set(_ date: Date) {
		current = date
	}
}

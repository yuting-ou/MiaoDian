import Foundation

// 电源事件时间线的行折叠（纯函数，供单测）。
// 目的：插拔电密集时（实测 11:34–11:52 之间四条"接上电源"）逐条列出既占满卡高又零信息增量，
// 把**相邻且同类型**的事件折成一行「接上电源 ×4 · 11:34–11:52」。
// 红线：只折相邻、不跨类型合并——把插拔插折成"接上电源×2 + 拔掉电源×1"会谎报事件顺序，
// 而事件顺序正是这张卡存在的理由（排查"电去哪了"）。
nonisolated enum PowerEventTimeline {
	/// 相邻同类事件折成一行的最大间隔：超过它就不折。
	/// 相隔几小时的两次"接上电源"是两个独立事件（用户正是来查"我到底什么时候插拔过电"），
	/// 把它们折成「×2 · 09:00–18:00」会把两次插电视觉上抹成一次插了很久——那是谎报。
	nonisolated static let coalesceMaxGap: TimeInterval = 30 * 60

	nonisolated struct Row: Equatable, Sendable {
		let kind: PowerEventKind
		let count: Int
		/// 这一簇里最早的一次
		let earliest: Date
		/// 这一簇里最近的一次
		let latest: Date
	}

	/// 输入按时间升序（存档原样），输出按"最近在前"排列的折叠行。
	/// 先从最新端开始遍历再折，保证"相邻"是用户看到的那个相邻。
	static func coalesce(_ events: [PowerEvent]) -> [Row] {
		var rows: [Row] = []
		for event in events.sorted(by: { $0.date < $1.date }).reversed() {
			if let last = rows.last,
				last.kind == event.kind,
				last.earliest.timeIntervalSince(event.date) <= coalesceMaxGap {
				// 同类型且间隔够近：计数 +1，最早时间外扩（latest 不变，遍历顺序就是由新到旧）
				rows[rows.count - 1] = Row(kind: last.kind, count: last.count + 1,
				                           earliest: event.date, latest: last.latest)
			} else {
				rows.append(Row(kind: event.kind, count: 1, earliest: event.date, latest: event.date))
			}
		}
		return rows
	}

	/// 时间列文案：单条只写时刻；折叠多条写"最早–最近"。
	/// 日期怎么写由调用方注入（面板要区分今天/昨天/日期，测试只要 HH:mm）——
	/// 纯函数不碰 Calendar，也不许自己发明一套日期格式
	static func timeText(_ row: Row, dateText: (Date) -> String) -> String {
		guard row.count > 1 else { return dateText(row.latest) }
		return "\(dateText(row.earliest))–\(dateText(row.latest))"
	}

	/// 悬停说明：折叠是显示折叠，不是数据删除——逐条时刻必须还能看到
	static func helpText(_ row: Row, times: [Date], dateText: (Date) -> String) -> String {
		guard row.count > 1 else { return "" }
		return "共 \(row.count) 次：" + times.map(dateText).joined(separator: "、")
	}

	/// 取回某一簇的真实时刻（同类且落在簇的时间区间内），供悬停说明与"数据没丢"断言
	static func times(in events: [PowerEvent], of row: Row) -> [Date] {
		events.filter { $0.kind == row.kind && $0.date >= row.earliest && $0.date <= row.latest }
			.map(\.date)
			.sorted()
	}
}

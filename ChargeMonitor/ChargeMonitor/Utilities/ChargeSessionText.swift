// 充电会话文字格式化：纯逻辑，从 EventAndDeviceSections 切出——
// 视图文件因 SwiftUIMacros 进不了测试编译面，被单测直测的纯函数必须自立文件。
import Foundation

enum ChargeSessionText {
	nonisolated static func detailText(session: ChargeSession, chargerName: String?) -> String {
		var text = "\(dateText(session.startDate)) · \(session.durationMinutes)分钟"
		if session.peakInputW >= 1 {
			text += String(format: " · 峰值%.0fW", session.peakInputW)
		}
		// 多只充电器的用户：列表行说清哪次是哪只充的（认不出/旧记录无键则省略）
		if let chargerName, !chargerName.isEmpty {
			text += " · \(chargerName)"
		}
		return text
	}

	// 供单测直测（nonisolated 静态）
	nonisolated static func detail(_ session: ChargeSession, chargerName: String? = nil) -> String {
		detailText(session: session, chargerName: chargerName)
	}
	
	// 时间戳人性化：今天/昨天只显示时刻，更早才显示日期
	nonisolated static func dateText(_ date: Date) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) {
			return "今天 " + timeFormatter.string(from: date)
		}
		if calendar.isDateInYesterday(date) {
			return "昨天 " + timeFormatter.string(from: date)
		}
		return dateFormatter.string(from: date)
	}
	
	nonisolated static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
	
	nonisolated static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "MM-dd HH:mm"
		return formatter
	}()
}

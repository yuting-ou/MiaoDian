import Foundation

// 续航场景：以"最近一小时掉电速度"为基准的相对强度系数
// 系数是相对当前混合使用强度的倍率（当前 = 1.0），而非绝对瓦数——
// 绝对功率因机型/亮度/外设差异太大，相对倍率在每台机器上都自洽
nonisolated enum RuntimeScenario: CaseIterable, Hashable, Sendable {
	// 网页、文档、聊天等轻度使用：负载轻、经常空闲
	case lightUse
	// 视频播放：解码 + 屏幕常亮，功耗稳定
	case videoPlayback
	// 视频会议：摄像头上行编解码 + 屏幕共享，最重的典型场景
	case videoCall

	var title: String {
		switch self {
		case .lightUse: return "轻度使用"
		case .videoPlayback: return "视频播放"
		case .videoCall: return "视频会议"
		}
	}

	// SF Symbol 名称（纯字符串，不依赖 SwiftUI）
	var symbolName: String {
		switch self {
		case .lightUse: return "text.book.closed"
		case .videoPlayback: return "play.tv"
		case .videoCall: return "video.fill"
		}
	}

	var drainMultiplier: Double {
		switch self {
		case .lightUse: return 0.65
		case .videoPlayback: return 1.25
		case .videoCall: return 1.7
		}
	}
}

// 续航换算：剩余电量 ÷（当前掉电速度 × 场景系数）→ 各场景还能撑多少分钟
// 纯函数，掉电估算（DrainRateEstimator）负责"当前速度"，这里只做换算
nonisolated enum RuntimeScenarioEstimator {
	// 某场景的剩余分钟数；掉速或电量无效时返回 nil
	static func minutesRemaining(socPercent: Int, percentPerHour: Double, multiplier: Double) -> Int? {
		let effectiveRate = percentPerHour * multiplier
		guard socPercent > 0, effectiveRate > 0 else { return nil }
		return Int(Double(socPercent) / effectiveRate * 60)
	}

	// 全部场景的换算结果（供卡片按场景顺序展示）
	static func estimates(socPercent: Int, percentPerHour: Double) -> [(scenario: RuntimeScenario, minutes: Int)] {
		RuntimeScenario.allCases.compactMap { scenario in
			minutesRemaining(socPercent: socPercent, percentPerHour: percentPerHour, multiplier: scenario.drainMultiplier)
				.map { (scenario, $0) }
		}
	}
}

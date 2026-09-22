import Foundation

/// C5 存放模式引导（纯提示，不做任何充放控制）。
/// 门控：只在「插着电且偏高」或「已落在存放电量带」时给一句；其余沉默。
nonisolated enum StorageGuide {
	/// 存放建议电量带（锂电长期存放共识区间，产品文案用）
	nonisolated static let storedSOCRange: ClosedRange<Int> = 45...65

	nonisolated static func advice(socPercent: Int?, isOnAC: Bool) -> String? {
		guard let soc = socPercent, (0...100).contains(soc) else { return nil }
		if isOnAC && soc >= 80 {
			return "若要长期存放，建议充到 45–65% 再拔电"
		}
		if !isOnAC, storedSOCRange.contains(soc) {
			// 文案必须与门控带一致：45/65 落在带内就不能写成「约 50–60%」
			return "当前电量在存放建议带（45–65%）"
		}
		return nil
	}
}

/// H1 健康度口径披露（可溯源透镜）：用户问「为什么和系统设置不一样」时有答案。
nonisolated enum HealthCaliber {
	/// 健康行 help：口径 + 允许的差异 + 估计项指向体检卡
	nonisolated static func disclosure(
		hasDesignCapacity: Bool,
		hasRawMaxCapacity: Bool
	) -> String {
		let basis: String
		if hasDesignCapacity && hasRawMaxCapacity {
			basis = "按 AppleRawMaxCapacity ÷ 设计容量 直算"
		} else if hasDesignCapacity {
			basis = "按当前最大容量 ÷ 设计容量 直算"
		} else {
			basis = "读不到容量分子分母时本行不显示"
		}
		return "\(basis)；与系统「电池健康」可能相差 1–2 个百分点（口径与刷新周期不同）。循环/温度/驻留读不到时，体检分会含估计项并在卡上标明。"
	}
}

/// C4 涓流：面板侧「当前正在涓流」的一句话（诚实边界：不承诺可控）。
nonisolated enum TrickleNotice {
	nonisolated static func liveNotice(socPercent: Int?, isCharging: Bool) -> ChargingHabitInsight? {
		guard isCharging,
			  let phase = UsagePatternAnalyzer.chargingPhase(socPercent: socPercent),
			  phase == .trickle
		else { return nil }
		return ChargingHabitInsight(
			message: "系统涓流中：\(phase.explanation)",
			symbol: "drop.fill"
		)
	}
}

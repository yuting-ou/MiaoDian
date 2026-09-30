import AppKit
import Combine
import Foundation

// 充电会话的记录、续接与归档。
// 会话说不出「是谁充的」——身份键由充电器域提供，由门面在每拍传进来。
@MainActor
final class ChargeSessionRecorder: ObservableObject {
	// 会话键、上限与断档判定窗口
	nonisolated private static let sessionsKey = "chargeSessions"
	nonisolated private static let activeSessionKey = "activeChargeSession"
	nonisolated private static let maxSessions = 20
	// 恢复的会话离上次落盘超过这个时长，视为中间拔过电源，不再续接
	nonisolated private static let resumeGapSeconds: TimeInterval = 30 * 60
	// 曲线点数上限：正常充一次最多百来个点，超出说明电量在临界值反复横跳，不再记
	nonisolated private static let maxCurvePoints = 200

	@Published private(set) var recentSessions: [ChargeSession] = []
	private var activeSession: ChargeSession?
	// 从磁盘恢复的会话需要先检查时间断档，再决定续接还是归档
	private var restoredSessionNeedsGapCheck = false
	// 活动会话是否存活（供"今日充电次数"统计：已充满但未拔电也算充过）
	var isChargingSessionAlive: Bool { activeSession != nil }
	// 活动会话是否存活（供"今日充电次数"统计：已充满但未拔电也算充过）
	private var lastActiveSessionSave = Date.distantPast

	private let persistence: HistoryPersistence
	// 时间从构造器进来：测试给一个可推进的假钟就能把跨午夜/断档这类状态机走完
	private let clock: HistoryClock

	init(persistence: HistoryPersistence, clock: HistoryClock = .live) {
		self.clock = clock
		self.persistence = persistence
	}

	// 落盘转发（与拆分前的写法保持一致，调用点不用改）
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { persistence.load(type, key: key) }
	private func save<T: Encodable>(_ value: T, key: String) { persistence.save(value, key: key) }


	// 从磁盘恢复的会话只有“中间没拔过电”才配续接：
	// 离上次落盘太久视为中间拔过电，旧会话该归档，避免两段充电被粘成一条
	nonisolated static func shouldResumeRestoredSession(_ session: ChargeSession, now: Date) -> Bool {
		now.timeIntervalSince(session.endDate) <= resumeGapSeconds
	}

	// 过滤插拔瞬间的无效会话：时长不足 2 分钟且电量没涨的不值得归档
	nonisolated static func isSessionWorthArchiving(_ session: ChargeSession) -> Bool {
		session.durationMinutes >= 2 || session.endPercent > session.startPercent
	}

	// 会话归档判定：只在真正拔电时结束会话——优化充电的暂停（仍插着电）不算结束
	nonisolated static func shouldArchiveActiveSession(powerSource: PowerSourceType) -> Bool {
		powerSource != .powerAdapter
	}

	func updateChargeSession(_ snapshot: BatterySnapshot, chargerKey: String?) {
		let isChargingNow = snapshot.powerSource == .powerAdapter && snapshot.isCharging

		if isChargingNow {
			let percent = snapshot.stateOfChargePercent ?? 0
			let inputW = snapshot.adapterInputPowerW ?? snapshot.chargingPowerW ?? 0

			// 从磁盘恢复的会话先过断档判定，再决定续接还是归档
			if restoredSessionNeedsGapCheck {
				restoredSessionNeedsGapCheck = false
				if let restored = activeSession, !Self.shouldResumeRestoredSession(restored, now: clock.now()) {
					activeSession = nil
					finalizeSession(restored)
				}
			}

			if var session = activeSession {
				let percentChanged = session.endPercent != percent
				session.endDate = clock.now()
				session.endPercent = percent
				session.peakInputW = max(session.peakInputW, inputW)
				// 首帧可能还没认出充电器（无名头要等几秒），认出来后补记
				if session.chargerKey == nil { session.chargerKey = chargerKey }
				// 电量变化时记一个曲线点，事后能看出这次充电是先快后慢还是全程稳定
				if percentChanged, (session.curve?.count ?? 0) < Self.maxCurvePoints {
					var curve = session.curve ?? []
					curve.append(ChargePoint(
						minuteOffset: Int(session.endDate.timeIntervalSince(session.startDate) / 60),
						percent: percent
					))
					session.curve = curve
				}
				activeSession = session
				// 进行中的会话定期落盘，应用中途退出也不丢这段记录
				if percentChanged || clock.now().timeIntervalSince(lastActiveSessionSave) >= 60 {
					persistActiveSession(session)
				}
			} else {
				let session = ChargeSession(
					startDate: clock.now(),
					endDate: clock.now(),
					startPercent: percent,
					endPercent: percent,
					peakInputW: inputW,
					curve: [ChargePoint(minuteOffset: 0, percent: percent)],
					chargerKey: chargerKey
				)
				activeSession = session
				persistActiveSession(session)
			}
		} else if let session = activeSession {
			// 优化充电会在 80% 附近反复暂停——暂停但仍插着电不算"这次充电结束"，
			// 会话保持存活（时长/曲线只在充电帧推进，不受暂停影响）；真正拔电才归档
			guard Self.shouldArchiveActiveSession(powerSource: snapshot.powerSource) else { return }
			activeSession = nil
			restoredSessionNeedsGapCheck = false
			persistence.remove(key: Self.activeSessionKey)
			finalizeSession(session)
		}
	}

	private func finalizeSession(_ session: ChargeSession) {
		guard Self.isSessionWorthArchiving(session) else { return }

		recentSessions.append(session)
		if recentSessions.count > Self.maxSessions {
			recentSessions.removeFirst(recentSessions.count - Self.maxSessions)
		}
		save(recentSessions, key: Self.sessionsKey)
	}

	private func persistActiveSession(_ session: ChargeSession) {
		lastActiveSessionSave = clock.now()
		save(session, key: Self.activeSessionKey)
	}

	// MARK: - 自己的加载与恢复（键归本域，门面不越权拆包）

	func loadFromDisk() {
		recentSessions = load([ChargeSession].self, key: Self.sessionsKey) ?? []
		// 上次退出时若正在充电，把进行中的会话捡回来，中途退出不丢记录
		activeSession = load(ChargeSession.self, key: Self.activeSessionKey)
		restoredSessionNeedsGapCheck = activeSession != nil
	}

	func restore(from archive: BatteryHistoryArchive) {
		recentSessions = archive.sessions
		save(recentSessions, key: Self.sessionsKey)
	}
}

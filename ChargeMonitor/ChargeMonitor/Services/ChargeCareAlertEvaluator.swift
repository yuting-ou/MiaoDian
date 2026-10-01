import Foundation

// 保养拔电提醒的状态判定（从 `BatteryAlertController.evaluateChargeCare` 抽出，纯逻辑）。
//
// 为什么单独抽：`BatteryAlertController.init` 第一件事就是 `UNUserNotificationCenter.current().delegate = self`
// ＋注册通知类别，而 `run_tests.sh` 编出来的是裸二进制（无 bundle 上下文）——在测试面里构造 controller
// 会当场抛 NSException，把全部 1485 项一起带走（本项目在 `工具/滚动成本.sh` 的注释里实测过）。
// 所以顺序只能是"先把不碰 UN 的判定搬出来"，判定侧因此才第一次可测。
//
// **这一层不碰任何副作用**：不读 UserDefaults、不取当前时间、不发通知。三者都由调用方读好后
// 当值传进来（`now` 与 `snoozeUntil`），发送动作也留给 Controller——它握有"只有发成功才把
// 状态置位"的语义（`if send(...) { … = true }`），本层只回答"该不该发"。
//
// 三条不许在拆分中静默弄丢的语义（其中第 1 条就在这个函数里，见下面逐条注释）：
// ① 系统保养标记的**拔电重置不许被保养提醒开关挡住**——`observed` 的推进刻意先于开关 guard；
// ② 健康里程碑的基准在开关关闭时照常抬（**本轮冻结，不在这里**）；
// ③ 周/月报无内容也记账（**本轮冻结，不在这里**）。

nonisolated struct ChargeCareAlertEvaluator {
	/// 调用方持有的持久化状态（进出都是值，evaluator 不自己写盘）
	struct State: Equatable {
		/// 「本插电会话内系统已在保养线处按住」——锁存标记，不是逐帧现算
		var didObserveSystemHoldAtLine: Bool
		/// 洞察侧只读的静默事实：静默机制确实生效过（对洞察措辞负责，与"要不要发"解耦）
		var hasSilencedCareForSystemHold: Bool
		/// 本段是否已提醒过（发送成功才置位）
		var didNotifyChargeCare: Bool
	}

	/// 一次判定的全部显式输入。**没有默认值**——调用方漏传一个就是编译错误，
	/// 不会静默退化成"旧行为"（v2.9.16 那条"同一判断抄第二遍"的教训）。
	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var isReminderEnabled: Bool
		var thresholdPercent: Int
		var state: State
		/// 用户点过"延后"的到期时刻（nil = 没延过后）
		var snoozeUntil: Date?
		/// 当前时间（由调用方的 clock 提供，evaluator 不自己取）
		var now: Date
	}

	/// 判定结果：新状态 + 是否该发。
	struct Result: Equatable {
		var state: State
		var shouldSend: Bool
	}

	/// 判定入口。逐条语义与搬运前一致：
	/// - 共存标记的推进**先于**开关与 soc guard：关着保养提醒拔电仍要清掉旧会话标记，
	///   否则「关提醒拔电 → 再插电 → 再开提醒」会顶着上一会话的 `true` 静默掉本该发的提醒。
	/// - 系统暂缓（`isSystemChargeHeld`）且电平贴保养线 ±3% 时抑制用户提醒；
	///   暂缓电平明显高于线（系统会充过线）→ 提醒必须保留。
	/// - 只在"充电中、未充满、电量过线"时发；重置条件看**拔没拔电源**而非"在不在充电"——
	///   系统优化充电会在保养线附近反复暂停/恢复，若暂停就重置，插一晚会被反复提醒。
	/// - snooze 未过期不发；发送由调用方执行，只有成功才置 `didNotifyChargeCare`。
	static func evaluate(_ input: Input) -> Result {
		var state = input.state
		let snapshot = input.snapshot

		// ① 共存标记：无条件推进（拔电一律清零，插电且系统贴线按住则置位并锁存）
		let wasObserved = state.didObserveSystemHoldAtLine
		state.didObserveSystemHoldAtLine = systemHoldCoveringCareLine(
			previouslyObserved: wasObserved,
			snapshot: snapshot,
			threshold: input.thresholdPercent
		)
		if state.didObserveSystemHoldAtLine, !wasObserved {
			// 本机签名可读且已覆盖保养线：静默机制真的在生效，洞察才可据实措辞
			state.hasSilencedCareForSystemHold = true
		}

		guard input.isReminderEnabled else { return Result(state: state, shouldSend: false) }
		guard let soc = snapshot.stateOfChargePercent else { return Result(state: state, shouldSend: false) }
		let threshold = input.thresholdPercent

		if snapshot.isCharging, !snapshot.isFull, soc >= threshold {
			guard !state.didNotifyChargeCare else { return Result(state: state, shouldSend: false) }
			guard !state.didObserveSystemHoldAtLine else { return Result(state: state, shouldSend: false) }
			// 用户点过"延后"：到点前闭嘴，到点后重新提醒（didNotify 已在延后时重置）
			guard !isChargeCareSnoozed(snoozeUntil: input.snoozeUntil, now: input.now)
			else { return Result(state: state, shouldSend: false) }
			return Result(state: state, shouldSend: true)
		} else if snapshot.powerSource != .powerAdapter || soc < threshold - 5 {
			state.didNotifyChargeCare = false
		}
		return Result(state: state, shouldSend: false)
	}

	// MARK: - 从 Controller 原样搬来的纯函数（行为逐字保持，供单测与 evaluator 共用）

	/// 保养线附近的暂停边沿判定：上一帧在充、这一帧停了、仍插着电且电量贴着保养线（±3%）
	static func isCarePauseEdge(previousCharging: Bool, snapshot: BatterySnapshot, threshold: Int) -> Bool {
		guard previousCharging, !snapshot.isCharging,
			snapshot.powerSource == .powerAdapter, !snapshot.isFull,
			let soc = snapshot.stateOfChargePercent
		else { return false }
		return abs(soc - threshold) <= 3
	}

	nonisolated static let systemHoldCareTolerance = 3

	/// 系统暂缓电平是否覆盖保养线：贴线 ±3% 才算"系统在做同一件事"；
	/// 明显高于线（系统会充过线）→ 不覆盖，提醒保留；明显低于线（系统更严）→ 提醒本就够不着，
	/// 按"不覆盖"保守处理，不误伤
	static func isHoldCoveringCareLine(heldSoc: Int?, threshold: Int) -> Bool {
		guard let heldSoc else { return false }
		return abs(heldSoc - threshold) <= systemHoldCareTolerance
	}

	/// 「本插电会话内系统已在保养线处按住」标记的状态转移。
	/// 拔电一律清零（**重置不得被保养提醒开关挡住**，否则跨会话陈旧置位会吞掉本该发的提醒）；
	/// 插电且系统按住且电平贴线 → 置位；其余保持（置位是锁存的，不是逐帧现算）
	static func systemHoldCoveringCareLine(
		previouslyObserved: Bool,
		snapshot: BatterySnapshot,
		threshold: Int
	) -> Bool {
		guard snapshot.powerSource == .powerAdapter else { return false }
		if snapshot.isSystemChargeHeld,
			isHoldCoveringCareLine(heldSoc: snapshot.stateOfChargePercent, threshold: threshold) {
			return true
		}
		return previouslyObserved
	}

	/// 延后窗口：未到期就静音。到期时刻阈值取"严格小于"（到点那一瞬即解禁）
	static func isChargeCareSnoozed(snoozeUntil: Date?, now: Date) -> Bool {
		guard let snoozeUntil else { return false }
		return now < snoozeUntil
	}
}

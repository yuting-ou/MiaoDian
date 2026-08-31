import Foundation
import IOKit.pwr_mgt

final class SleepController {
	// IOPMAssertionCreate/Release 本身线程安全；标记 nonisolated(unsafe) 让 deinit
	//（Swift 6 里是非隔离上下文）也能走同一条释放路径。deinit 意味着再无其他引用，无并发
	nonisolated(unsafe) private var systemSleepAssertionID: IOPMAssertionID?
	nonisolated(unsafe) private var displaySleepAssertionID: IOPMAssertionID?

	func setPreventSleepEnabled(_ enabled: Bool) {
		if enabled {
			enableSleepPrevention()
			return
		}

		disableSleepPrevention()
	}

	private func enableSleepPrevention() {
		disableSleepPrevention()
		systemSleepAssertionID = createAssertion(
			type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
			name: "ChargeMonitor preventing idle system sleep" as CFString
		)
		displaySleepAssertionID = createAssertion(
			type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
			name: "ChargeMonitor preventing idle display sleep" as CFString
		)
	}

	nonisolated private func disableSleepPrevention() {
		releaseAssertion(&systemSleepAssertionID)
		releaseAssertion(&displaySleepAssertionID)
	}

	private func createAssertion(type: CFString, name: CFString) -> IOPMAssertionID? {
		var id: IOPMAssertionID = 0
		let result = IOPMAssertionCreateWithName(
			type,
			IOPMAssertionLevel(kIOPMAssertionLevelOn),
			name,
			&id
		)
		guard result == kIOReturnSuccess else { return nil }
		return id
	}

	nonisolated private func releaseAssertion(_ assertionID: inout IOPMAssertionID?) {
		guard let id = assertionID else { return }
		IOPMAssertionRelease(id)
		assertionID = nil
	}

	deinit {
		disableSleepPrevention()
	}
}

import AppKit
import Darwin
import Foundation

struct SignificantEnergyApp: Identifiable {
	let id: String
	let pid: pid_t
	let name: String
	let bundleIdentifier: String
	let bundleURL: URL?
	let icon: NSImage?
	let energyImpact: Double
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
nonisolated private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t, _ responsible: UnsafeMutablePointer<pid_t>) -> Int32

// 高耗电应用采样：进程 rusage 差分 → bundle 聚合 → EMA 平滑 + 滞回判定
// 采样要扫全系统进程，是面板打开期间最重的一步——放 actor 上执行与主线程解耦；
// 在场应用列表（NSWorkspace 要求主线程访问）由主线程快照后传入
actor SignificantEnergyReader {
	// 主线程快照的在场应用：仅含参与统计的常规 .app
	struct RunningAppStub: Sendable {
		let pid: pid_t
		let bundleIdentifier: String
		let bundlePath: String?
		let displayName: String?
		let bundleURL: URL?
	}

	// 一轮采样的结果：bundle → 当前 EMA 影响值，已按影响值降序
	struct ImpactEntry: Sendable {
		let bundleIdentifier: String
		let impact: Double
	}

	// 一轮扫描的完整回执：结果 + 暖机是否完成。
	// 样本攒够 minSamplesToShow 之前列表必空——那是"还没测出来"，
	// 不是"没有耗电大户"，界面必须能区分这两件事（新用户第一次打开就撞上）
	struct EnergyScan: Sendable {
		let entries: [ImpactEntry]
		let warmupComplete: Bool
	}

	// 暖机判定（纯函数，供单测）：帧数攒够才算测完一轮
	nonisolated static func isWarmupComplete(framesObserved: Int, minFrames: Int) -> Bool {
		framesObserved >= minFrames
	}

	private struct ProcessMetrics: Sendable {
		let cpuTimeSeconds: Double
		let wakeups: UInt64
		let diskReadBytes: UInt64
		let diskWriteBytes: UInt64
	}

	private struct EnergyState: Sendable {
		var ema: Double
		var sampleCount: Int
		var isSignificant: Bool
	}

	private var previousByPid: [pid_t: ProcessMetrics] = [:]
	private var previousTimestamp: TimeInterval?
	private var stateByBundleId: [String: EnergyState] = [:]
	// 已观察帧数（跨面板开关累计）：暖机进度
	private var framesObserved = 0

	private let alpha: Double = 0.05
	private let appearThreshold: Double = 1.5
	private let disappearThreshold: Double = 1.0
	private let minPerProcessImpact: Double = 0.5
	private let minSamplesToShow: Int = 50

	private let cpuWeight: Double = 1.0
	private let wakeupWeight: Double = 0.02
	private let diskWeight: Double = 1.0e-7

	private static let ignoredBundleIdPrefixes: [String] = [
		"com.apple.preference",
		"com.apple.systempreferences",
		"com.apple.controlcenter",
		"com.apple.notificationcenterui"
	]

	// 主线程调用：收集当前在场且参与统计的应用
	@MainActor
	static func currentRunningAppStubs() -> [RunningAppStub] {
		NSWorkspace.shared.runningApplications.compactMap { app in
			guard
				!app.isTerminated,
				app.activationPolicy == .regular,
				let bundleIdentifier = app.bundleIdentifier,
				!isIgnored(bundleIdentifier),
				app.bundleURL?.pathExtension == "app"
			else { return nil }
			return RunningAppStub(
				pid: app.processIdentifier,
				bundleIdentifier: bundleIdentifier,
				bundlePath: app.bundleURL?.path,
				displayName: app.localizedName,
				bundleURL: app.bundleURL
			)
		}
	}

	private static func isIgnored(_ bundleIdentifier: String) -> Bool {
		ignoredBundleIdPrefixes.contains { bundleIdentifier.hasPrefix($0) }
	}

	// 一轮差分采样：与上一轮的 pid 指标相减折算影响值，聚合到 bundle 后更新 EMA；
	// 首轮没有时间差，只记基准不出结果
	func computeImpacts(apps: [RunningAppStub]) -> EnergyScan {
		framesObserved += 1
		let now = ProcessInfo.processInfo.systemUptime
		let appsByBundlePath = Dictionary(
			apps.compactMap { stub in stub.bundlePath.map { ($0, stub.bundleIdentifier) } },
			uniquingKeysWith: { first, _ in first }
		)
		let dt: TimeInterval? = previousTimestamp.map { now - $0 }.flatMap { $0 > 0 ? $0 : nil }

		let currentByPid = sampleAllProcesses()
		var energyByBundleId: [String: Double] = [:]
		if let dt {
			energyByBundleId = aggregatedEnergyImpact(dt: dt, currentByPid: currentByPid, appsByBundlePath: appsByBundlePath)
		}
		previousByPid = currentByPid
		previousTimestamp = now

		updateState(bundleIds: apps.map(\.bundleIdentifier), energyByBundleId: energyByBundleId)
		let results = significantEntries()
		cleanupState(keeping: Set(apps.map(\.bundleIdentifier)))
		return EnergyScan(entries: results, warmupComplete: Self.isWarmupComplete(framesObserved: framesObserved, minFrames: minSamplesToShow))
	}

	private func sampleAllProcesses() -> [pid_t: ProcessMetrics] {
		var result: [pid_t: ProcessMetrics] = [:]
		for pid in listAllPids() {
			guard let metrics = readProcessMetrics(pid: pid) else { continue }
			result[pid] = metrics
		}
		return result
	}

	private func aggregatedEnergyImpact(
		dt: TimeInterval,
		currentByPid: [pid_t: ProcessMetrics],
		appsByBundlePath: [String: String]
	) -> [String: Double] {
		var energyByBundleId: [String: Double] = [:]

		for (pid, current) in currentByPid {
			guard let previous = previousByPid[pid] else { continue }
			let impact = energyImpact(current: current, previous: previous, dt: dt)
			guard impact >= minPerProcessImpact else { continue }

			guard let bundleId = resolveOwningBundleIdentifier(pid: pid, appsByBundlePath: appsByBundlePath) else { continue }
			energyByBundleId[bundleId, default: 0] += impact
		}

		return energyByBundleId
	}

	private func updateState(bundleIds: [String], energyByBundleId: [String: Double]) {
		for bundleId in bundleIds {
			guard !bundleId.isEmpty else { continue }

			let currentEnergy = energyByBundleId[bundleId] ?? 0
			let prev = stateByBundleId[bundleId] ?? EnergyState(ema: currentEnergy, sampleCount: 0, isSignificant: false)

			let ema = alpha * currentEnergy + (1 - alpha) * prev.ema
			let sampleCount = prev.sampleCount + 1

			let isSignificant: Bool = {
				if prev.isSignificant { return ema >= disappearThreshold }
				return ema >= appearThreshold
			}()

			stateByBundleId[bundleId] = EnergyState(ema: ema, sampleCount: sampleCount, isSignificant: isSignificant)
		}
	}

	private func significantEntries() -> [ImpactEntry] {
		stateByBundleId
			.compactMap { bundleId, state in
				guard state.sampleCount >= minSamplesToShow, state.isSignificant else { return nil }
				return ImpactEntry(bundleIdentifier: bundleId, impact: state.ema)
			}
			.sorted { $0.impact > $1.impact }
	}

	private func cleanupState(keeping bundleIds: Set<String>) {
		stateByBundleId = stateByBundleId.filter { bundleIds.contains($0.key) }
	}

	private func resolveOwningBundleIdentifier(
		pid: pid_t,
		appsByBundlePath: [String: String]
	) -> String? {
		if let bundleId = bundleIdentifierFromProcess(pid: pid, appsByBundlePath: appsByBundlePath) {
			return bundleId
		}

		guard let responsiblePid = responsiblePid(for: pid), responsiblePid != pid else { return nil }
		return bundleIdentifierFromProcess(pid: responsiblePid, appsByBundlePath: appsByBundlePath)
	}

	private func bundleIdentifierFromProcess(
		pid: pid_t,
		appsByBundlePath: [String: String]
	) -> String? {
		guard
			let execPath = processPath(pid: pid),
			let rootAppPath = rootAppBundlePath(from: execPath)
		else { return nil }

		return appsByBundlePath[rootAppPath]
	}

	private func rootAppBundlePath(from execPath: String) -> String? {
		let components = execPath.split(separator: "/").map(String.init)

		for (index, component) in components.enumerated() where component.hasSuffix(".app") {
			let path = components.prefix(index + 1).joined(separator: "/")
			return path.isEmpty ? nil : "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		}

		return nil
	}

	private func responsiblePid(for pid: pid_t) -> pid_t? {
		var responsible: pid_t = 0
		let result = responsibility_get_pid_responsible_for_pid(pid, &responsible)
		guard result == 0, responsible > 0 else { return nil }
		return responsible
	}

	private func energyImpact(current: ProcessMetrics, previous: ProcessMetrics, dt: TimeInterval) -> Double {
		let cpuDelta = current.cpuTimeSeconds - previous.cpuTimeSeconds
		guard cpuDelta >= 0 else { return 0 }

		let cpuPercent = (cpuDelta / dt) * 100.0
		let cpuImpact = cpuPercent * cpuWeight

		let wakeupsDelta = current.wakeups > previous.wakeups ? Double(current.wakeups - previous.wakeups) : 0
		let wakeupImpact = (wakeupsDelta / dt) * wakeupWeight

		let readDelta = current.diskReadBytes > previous.diskReadBytes ? Double(current.diskReadBytes - previous.diskReadBytes) : 0
		let writeDelta = current.diskWriteBytes > previous.diskWriteBytes ? Double(current.diskWriteBytes - previous.diskWriteBytes) : 0
		let diskImpact = (readDelta + writeDelta) * diskWeight / dt

		return cpuImpact + wakeupImpact + diskImpact
	}

	private func listAllPids() -> [pid_t] {
		let capacity = 4096
		var pids = [pid_t](repeating: 0, count: capacity)

		let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
		guard bytes > 0 else {
			DiagnosticLog.failureOnce("proc-listpids-failed", category: "SignificantEnergyReader", "proc_listpids 返回 \(bytes)，能耗采样不可用，高能耗列表将为空")
			return []
		}

		let count = Int(bytes) / MemoryLayout<pid_t>.stride
		return pids.prefix(count).filter { $0 > 0 }
	}

	private func processPath(pid: pid_t) -> String? {
		var buffer = [CChar](repeating: 0, count: 4096)
		let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
		guard count > 0 else { return nil }
		return String(cString: buffer)
	}

	private func readProcessMetrics(pid: pid_t) -> ProcessMetrics? {
		var info = rusage_info_current()

		let result: Int32 = withUnsafeMutablePointer(to: &info) { infoPtr in
			infoPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { rawPtr in
				proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rawPtr)
			}
		}

		guard result == 0 else { return nil }

		let cpuTimeNS = info.ri_user_time + info.ri_system_time
		let cpuTimeSeconds = Double(cpuTimeNS) / 1_000_000_000.0

		return ProcessMetrics(
			cpuTimeSeconds: cpuTimeSeconds,
			wakeups: info.ri_pkg_idle_wkups,
			diskReadBytes: info.ri_diskio_bytesread,
			diskWriteBytes: info.ri_diskio_byteswritten
		)
	}
}

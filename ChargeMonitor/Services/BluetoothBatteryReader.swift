import Foundation
import IOKit

// 读取蓝牙外设（耳机、鼠标、键盘等）的电量
// 数据源有两个：HID 事件服务的 BatteryPercent 属性，
// 以及系统配件电源通道（pmset -g accps，第三方鼠标多走这里）
// 涉及子进程调用，设计为可在后台线程执行
nonisolated final class BluetoothBatteryReader: @unchecked Sendable {
	// 设备类型缓存：minorType 基本不变，而 system_profiler 很慢（数百毫秒级），
	// 只在出现没见过的设备名时才跑一次，其余时候直接命中缓存
	private let lock = NSLock()
	private var kindCache: [String: BluetoothDeviceKind] = [:]
	
	func readDevices() -> [BluetoothDeviceBattery] {
		var devices = readHIDDevices()
		
		let knownNames = Set(devices.map(\.name))
		for accessory in readAccessoryDevices() where !knownNames.contains(accessory.name) {
			devices.append(accessory)
		}
		
		let names = Set(devices.map(\.name))
		var kindByName = cachedKinds(for: names)
		let unknownNames = names.subtracting(kindByName.keys)
		if !unknownNames.isEmpty {
			let reported = readDeviceKinds()
			for name in unknownNames {
				// 报告里查不到的设备按名字猜一个也存进缓存，
				// 否则这类设备每 30 秒都会白跑一次 system_profiler
				kindByName[name] = reported[name] ?? Self.kindFromName(name)
			}
			storeKinds(kindByName, for: names)
		}
		
		// 用系统蓝牙报告里的真实设备类型标注，拿不到时按名字猜
		return devices.map { device in
			var device = device
			device.kind = kindByName[device.name] ?? Self.kindFromName(device.name)
			return device
		}
	}
	
	private func cachedKinds(for names: Set<String>) -> [String: BluetoothDeviceKind] {
		lock.lock()
		defer { lock.unlock() }
		// 顺手清掉已不在场设备的条目，避免缓存无限增长
		kindCache = kindCache.filter { names.contains($0.key) }
		return kindCache
	}
	
	private func storeKinds(_ kinds: [String: BluetoothDeviceKind], for names: Set<String>) {
		lock.lock()
		defer { lock.unlock() }
		kindCache = kinds.filter { names.contains($0.key) }
	}
	
	// MARK: - HID 通道（Apple 外设、部分蓝牙设备）
	
	private func readHIDDevices() -> [BluetoothDeviceBattery] {
		var iterator: io_iterator_t = 0
		let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
		guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
			return []
		}
		defer { IOObjectRelease(iterator) }
		
		var lowestPercentByName: [String: Int] = [:]
		var orderedNames: [String] = []
		
		while case let service = IOIteratorNext(iterator), service != 0 {
			defer { IOObjectRelease(service) }
			
			guard
				let percent = registryInt(service, key: "BatteryPercent"),
				(0...100).contains(percent),
				let name = registryString(service, key: "Product"),
				!name.isEmpty
			else { continue }
			
			// 同一设备可能上报多次（如左右耳机），取较低电量
			if let existing = lowestPercentByName[name] {
				lowestPercentByName[name] = min(existing, percent)
			} else {
				lowestPercentByName[name] = percent
				orderedNames.append(name)
			}
		}
		
		return orderedNames.compactMap { name in
			lowestPercentByName[name].map { BluetoothDeviceBattery(name: name, percent: $0) }
		}
	}
	
	// MARK: - 系统配件电源通道
	
	// 公开 API 拿不到配件电源列表，借助系统自带的 pmset 读取
	private func readAccessoryDevices() -> [BluetoothDeviceBattery] {
		guard
			let data = runForOutput("/usr/bin/pmset", arguments: ["-g", "accps"]),
			let output = String(data: data, encoding: .utf8)
		else { return [] }
		return Self.parseAccessoryOutput(output)
	}
	
	// 运行系统命令并返回标准输出；带超时保护，子进程卡死时强制终止，
	// 避免轮询状态永久卡住导致外设电量不再更新
	private func runForOutput(_ path: String, arguments: [String], timeout: TimeInterval = 10) -> Data? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: path)
		process.arguments = arguments
		
		let pipe = Pipe()
		process.standardOutput = pipe
		// 不读 stderr 就不能给它 Pipe，否则缓冲区写满会死锁
		process.standardError = FileHandle.nullDevice
		
		do {
			try process.run()
		} catch {
			DiagnosticLog.failureOnce("launch-failed-\(path)", category: "BluetoothBatteryReader", "启动 \(path) 失败：\(error.localizedDescription)")
			return nil
		}
		
		let killer = DispatchWorkItem {
			if process.isRunning {
				process.terminate()
				DiagnosticLog.failureOnce("timeout-\(path)", category: "BluetoothBatteryReader", "\(path) 超过 \(Int(timeout)) 秒未返回，已强制终止")
			}
		}
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
		
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		killer.cancel()
		return data
	}
	
	// 解析形如： -A950Air (id=24384395) 80%; 
	static func parseAccessoryOutput(_ output: String) -> [BluetoothDeviceBattery] {
		var devices: [BluetoothDeviceBattery] = []
		
		for rawLine in output.split(separator: "\n") {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard line.hasPrefix("-"), !line.hasPrefix("-InternalBattery") else { continue }
			guard let idRange = line.range(of: " (id=") else { continue }
			
			let name = String(line[line.index(after: line.startIndex)..<idRange.lowerBound])
				.trimmingCharacters(in: .whitespaces)
			
			guard let closeParen = line.range(of: ")", range: idRange.upperBound..<line.endIndex) else { continue }
			let rest = line[closeParen.upperBound...]
			guard let percentRange = rest.range(of: #"\d+%"#, options: .regularExpression) else { continue }
			
			let percent = Int(rest[percentRange].dropLast()) ?? -1
			guard (0...100).contains(percent), !name.isEmpty else { continue }
			
			devices.append(BluetoothDeviceBattery(name: name, percent: percent))
		}
		
		return devices
	}
	
	// MARK: - 设备类型识别
	
	// 从系统蓝牙报告（system_profiler）读取各设备的 minorType
	private func readDeviceKinds() -> [String: BluetoothDeviceKind] {
		guard let data = runForOutput("/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]) else {
			return [:]
		}
		
		guard
			let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let sections = root["SPBluetoothDataType"] as? [[String: Any]]
		else { return [:] }
		
		var kinds: [String: BluetoothDeviceKind] = [:]
		for section in sections {
			for listKey in ["device_connected", "device_not_connected"] {
				guard let deviceList = section[listKey] as? [[String: Any]] else { continue }
				for entry in deviceList {
					for (name, value) in entry {
						guard
							let properties = value as? [String: Any],
							let minorType = properties["device_minorType"] as? String
						else { continue }
						kinds[name] = Self.kind(fromMinorType: minorType)
					}
				}
			}
		}
		return kinds
	}
	
	static func kind(fromMinorType minorType: String) -> BluetoothDeviceKind {
		switch minorType.lowercased() {
		case "mouse": return .mouse
		case "keyboard": return .keyboard
		case "trackpad": return .trackpad
		case "headset", "headphones": return .headphones
		case "speaker", "loudspeaker": return .speaker
		case "gamepad", "game pad", "joystick": return .gamepad
		case "mobile phone", "smartphone": return .phone
		default: return .other
		}
	}
	
	// 名字关键词兜底（系统报告里查不到的设备）
	static func kindFromName(_ name: String) -> BluetoothDeviceKind {
		let lower = name.lowercased()
		if lower.contains("airpods") || lower.contains("耳机") || lower.contains("buds") || lower.contains("headphone") || lower.contains("tws") {
			return .headphones
		}
		if lower.contains("mouse") || lower.contains("鼠标") { return .mouse }
		if lower.contains("keyboard") || lower.contains("键盘") { return .keyboard }
		if lower.contains("trackpad") || lower.contains("触控板") { return .trackpad }
		if lower.contains("speaker") || lower.contains("音箱") { return .speaker }
		if lower.contains("controller") || lower.contains("手柄") { return .gamepad }
		return .other
	}
	
	private func registryInt(_ service: io_object_t, key: String) -> Int? {
		registryValue(service, key: key) as? Int
	}
	
	private func registryString(_ service: io_object_t, key: String) -> String? {
		registryValue(service, key: key) as? String
	}
	
	private func registryValue(_ service: io_object_t, key: String) -> Any? {
		IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
			.takeRetainedValue()
	}
}

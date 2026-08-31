import Foundation
import IOKit

// SMC 实时功率读取器：直接读电源管理芯片的传感器，亚秒级更新
// 系统电池注册表（AppleSmartBattery）十几秒才刷新一次，实时功耗必须走 SMC
// 键位：PSTR=整机功率 PDTR=适配器输入功率 PPBR=电池充放电功率
final class SMCPowerReader {
	// 内核驱动要求的 80 字节参数布局（padding 补齐对齐，缺了会报 0xe00002c2 参数错误）
	private struct SMCVers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
	private struct SMCLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
	private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
	private struct SMCKeyData {
		var key: UInt32 = 0
		var vers = SMCVers()
		var pLimitData = SMCLimit()
		var keyInfo = SMCKeyInfo()
		var padding: UInt16 = 0
		var result: UInt8 = 0
		var status: UInt8 = 0
		var data8: UInt8 = 0
		var data32: UInt32 = 0
		var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
			UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
			UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
			UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	}
	
	private static let getKeyInfoCommand: UInt8 = 9
	private static let readKeyCommand: UInt8 = 5
	private static let handleEventSelector: UInt32 = 2
	
	private var connection: io_connect_t = 0
	private var isOpen = false
	
	init() {
		var iterator = io_iterator_t()
		guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == kIOReturnSuccess else {
			DiagnosticLog.failureOnce("smc-service-missing", category: "SMCPowerReader", "找不到 AppleSMC 服务，实时功率降级为注册表数据")
			return
		}
		let device = IOIteratorNext(iterator)
		IOObjectRelease(iterator)
		guard device != 0 else {
			DiagnosticLog.failureOnce("smc-device-empty", category: "SMCPowerReader", "AppleSMC 设备为空，实时功率降级为注册表数据")
			return
		}
		let openResult = IOServiceOpen(device, mach_task_self_, 0, &connection)
		IOObjectRelease(device)
		guard openResult == kIOReturnSuccess else {
			DiagnosticLog.failureOnce("smc-open-failed", category: "SMCPowerReader", "打开 SMC 连接失败：\(String(format: "0x%08x", openResult))")
			return
		}
		isOpen = true
	}
	
	deinit {
		if isOpen {
			IOServiceClose(connection)
		}
	}
	
	// 整机实时功率（瓦）
	func systemPowerW() -> Double? {
		readFloat("PSTR")
	}
	
	// 适配器实时输入功率（瓦），未插电时无值
	func adapterInputPowerW() -> Double? {
		readFloat("PDTR")
	}
	
	// 电池充放电实时功率（瓦）
	func batteryPowerW() -> Double? {
		readFloat("PPBR")
	}
	
	private func fourCC(_ text: String) -> UInt32 {
		text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
	}
	
	private func readFloat(_ key: String) -> Double? {
		guard isOpen else { return nil }
		
		var input = SMCKeyData()
		var output = SMCKeyData()
		var outputSize = MemoryLayout<SMCKeyData>.stride
		
		// 第一步：查键位的数据类型和长度
		input.key = fourCC(key)
		input.data8 = Self.getKeyInfoCommand
		guard
			IOConnectCallStructMethod(connection, Self.handleEventSelector, &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize) == kIOReturnSuccess,
			output.result == 0
		else { return nil }
		
		let dataType = output.keyInfo.dataType
		
		// 第二步：读取键值
		input.keyInfo.dataSize = output.keyInfo.dataSize
		input.data8 = Self.readKeyCommand
		outputSize = MemoryLayout<SMCKeyData>.stride
		guard
			IOConnectCallStructMethod(connection, Self.handleEventSelector, &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize) == kIOReturnSuccess,
			output.result == 0
		else { return nil }
		
		// flt 类型：4 字节小端浮点
		guard dataType == fourCC("flt ") else { return nil }
		let raw = output.bytes
		let bits = UInt32(raw.0) | UInt32(raw.1) << 8 | UInt32(raw.2) << 16 | UInt32(raw.3) << 24
		let value = Double(Float(bitPattern: bits))
		return value.isFinite ? value : nil
	}
}

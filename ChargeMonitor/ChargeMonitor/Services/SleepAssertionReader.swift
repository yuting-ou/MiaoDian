import Foundation

// 读取当前持有“阻止系统睡眠”断言的进程：睡眠掉电异常的点名归因。
// 数据源 pmset -g assertions，子进程读取，设计为可在后台线程执行
nonisolated final class SleepAssertionReader: @unchecked Sendable {
	func assertionOwnerNames() -> [String] {
		guard
			let data = SubprocessRunner.run("/usr/bin/pmset", arguments: ["-g", "assertions"]),
			let output = String(data: data, encoding: .utf8)
		else { return [] }
		return Self.parseAssertionOwners(output)
	}

	// 匹配形如：
	//   pid 345(coreaudiod): [0x...] 00:00:42 PreventUserIdleSystemSleep named: "..."
	// 系统级状态表里的 "PreventUserIdleSystemSleep 1" 没有 pid，自然被跳过；
	// 同一进程可能持有多条断言，名字去重；解析失败的行直接跳过
	static func parseAssertionOwners(_ output: String) -> [String] {
		var names: [String] = []
		for rawLine in output.split(separator: "\n") {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard line.contains("PreventUserIdleSystemSleep"),
				let pidRange = line.range(of: #"pid\s+\d+\(([^)]+)\)"#, options: .regularExpression)
			else { continue }

			// pidRange 覆盖 "pid 345(name)"，取括号内的进程名
			let segment = line[pidRange]
			guard let open = segment.firstIndex(of: "("), let close = segment.firstIndex(of: ")"), open < close else { continue }
			let name = String(segment[segment.index(after: open)..<close])
			if !name.isEmpty, !names.contains(name) {
				names.append(name)
			}
		}
		return names
	}
}

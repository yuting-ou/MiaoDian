#!/usr/bin/env bash
# 口径抽查：读本机真实档案，打印「醒着 vs 含睡」两口径与口径标记覆盖率
# 用途：①2026-10-07 验证点复跑（归因窗/睡眠标记是否铺开、醒着口径读数量级是否稳定）
#      ②队列项「醒着样本不足半小时→占比沉默」是否恼人的触发测量
# 只读本机 defaults，不联网、不落可识别信息（只打印日期、秒数、比例）
set -euo pipefail

DOMAIN="fun.crashsystem.ChargeMonitor"
OUT="$(mktemp -d)/prefs.plist"
defaults export "$DOMAIN" "$OUT" >/dev/null 2>&1 || { echo "读不到 $DOMAIN 的偏好（妙电尚未运行？）"; exit 1; }

PROBE="$(mktemp -d)/probe.swift"
cat > "$PROBE" <<'SWIFT'
import Foundation

struct Row: Decodable {
	let dayKey: String
	let drainedPercent: Int
	let chargedPercent: Int
	let acSeconds: Double
	let batterySeconds: Double
	let soc80to90Seconds: Double
	let soc90to100Seconds: Double
	let sleepBatterySeconds: Double?
	let sleepACSeconds: Double?
	let attributionGapSeconds: Double?
	init(from d: Decoder) throws {
		let c = try d.container(keyedBy: K.self)
		dayKey = try c.decodeIfPresent(String.self, forKey: .dayKey) ?? ""
		drainedPercent = try c.decodeIfPresent(Int.self, forKey: .drainedPercent) ?? 0
		chargedPercent = try c.decodeIfPresent(Int.self, forKey: .chargedPercent) ?? 0
		acSeconds = try c.decodeIfPresent(Double.self, forKey: .acSeconds) ?? 0
		batterySeconds = try c.decodeIfPresent(Double.self, forKey: .batterySeconds) ?? 0
		soc80to90Seconds = try c.decodeIfPresent(Double.self, forKey: .soc80to90Seconds) ?? 0
		soc90to100Seconds = try c.decodeIfPresent(Double.self, forKey: .soc90to100Seconds) ?? 0
		sleepBatterySeconds = try c.decodeIfPresent(Double.self, forKey: .sleepBatterySeconds)
		sleepACSeconds = try c.decodeIfPresent(Double.self, forKey: .sleepACSeconds)
		attributionGapSeconds = try c.decodeIfPresent(Double.self, forKey: .attributionGapSeconds)
	}
	enum K: String, CodingKey {
		case dayKey, drainedPercent, chargedPercent, acSeconds, batterySeconds
		case soc80to90Seconds, soc90to100Seconds, sleepBatterySeconds, sleepACSeconds, attributionGapSeconds
	}
	var sleptBattery: Double { min(batterySeconds, sleepBatterySeconds ?? 0) }
	var sleptAC: Double { min(acSeconds, sleepACSeconds ?? 0) }
	var awakeSeconds: Double { (acSeconds - sleptAC) + (batterySeconds - sleptBattery) }
	var observedSeconds: Double { acSeconds + batterySeconds }
	var shareAwake: Double? {
		guard awakeSeconds >= 1800 else { return nil }
		return (acSeconds - sleptAC) / awakeSeconds
	}
	var shareInclusive: Double? {
		guard observedSeconds >= 1800 else { return nil }
		return acSeconds / observedSeconds
	}
}

let path = CommandLine.arguments[1]
let raw = try Data(contentsOf: URL(fileURLWithPath: path))
guard let outer = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
	  let blob = outer["dailyUsageHistory"] as? Data else {
	print("读不到 dailyUsageHistory"); exit(1)
}
let rows = try PropertyListDecoder().decode([Row].self, from: blob)
let n = rows.count
let stamped = rows.filter { $0.attributionGapSeconds != nil }.count
let slept = rows.filter { ($0.sleepBatterySeconds ?? 0) + ($0.sleepACSeconds ?? 0) > 0 }.count
let silentAwake = rows.filter { $0.shareAwake == nil && $0.observedSeconds >= 1800 }.count
print("行数 本档=\(n) 带归因窗=\(stamped)(\(String(format: "%.0f%%", n > 0 ? Double(stamped) / Double(n) * 100 : 0))) 带睡眠标记=\(slept)")
print("口径沉默日（醒着<30min 但被观测≥30min）：\(silentAwake) 天（\(String(format: "%.0f%%", n > 0 ? Double(silentAwake) / Double(n) * 100 : 0))）→ 队列触发线 10%")
print("--- 最近 7 天（含睡 vs 醒着）---")
for r in rows.suffix(7) {
	let a = r.shareAwake.map { String(format: "%5.1f%%", $0 * 100) } ?? "   —  "
	let b = r.shareInclusive.map { String(format: "%5.1f%%", $0 * 100) } ?? "   —  "
	print("\(r.dayKey) 插电\(String(format: "%5.2fh", r.acSeconds / 3600)) 电池\(String(format: "%5.2fh", r.batterySeconds / 3600)) 睡插\(String(format: "%5.2fh", r.sleptAC / 3600)) 睡电\(String(format: "%5.2fh", r.sleptBattery / 3600)) 含睡\(b) 醒着\(a) 窗口\(r.attributionGapSeconds.map { String(Int($0)) } ?? "未钉")")
}
SWIFT

swift "$PROBE" "$OUT"

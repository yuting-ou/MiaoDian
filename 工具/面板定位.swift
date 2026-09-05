import CoreGraphics
import Foundation
// 输出妙电面板窗口 bounds（点，左上原点）："x y w h"，取面积最大者。owner 名是 bundle 显示名"妙电"
let opts: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var best = (0.0, 0.0, 0.0, 0.0), bestArea = 0.0
for w in list {
	guard (w[kCGWindowOwnerName as String] as? String) == "妙电" else { continue }
	guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
	let x = Double(b["X"] ?? 0), y = Double(b["Y"] ?? 0), ww = Double(b["Width"] ?? 0), h = Double(b["Height"] ?? 0)
	if ww * h > bestArea { bestArea = ww * h; best = (x, y, ww, h) }
}
if bestArea == 0 { exit(1) }
print("\(Int(best.0)) \(Int(best.1)) \(Int(best.2)) \(Int(best.3))")

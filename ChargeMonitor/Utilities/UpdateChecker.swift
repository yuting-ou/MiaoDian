import AppKit
import Foundation

@MainActor
final class UpdateChecker {
	static let shared = UpdateChecker()
	
	func check() {
		Task { await checkForUpdatesAndShowAlert() }
	}
	
	func openGitHub() {
		NSWorkspace.shared.open(AppLinks.github)
	}
	
	private func checkForUpdatesAndShowAlert() async {
		do {
			let release = try await fetchLatestRelease()
			let current = AppVersion(Bundle.main.shortVersionString ?? "0.0.0")
			let latest = AppVersion(release.tagName)
			
			if latest > current {
				showAlert(text: "GitHub 上有新版本 \(release.tagName) 可用。\n注意：更新检查指向的是上游英文原版仓库，下载覆盖安装将丢失汉化；如需保留汉化，请在本地同步上游代码后重新构建。", includeGitHubButton: true)
			} else {
				showAlert(text: "当前已是最新版本")
			}
		} catch {
			DiagnosticLog.failureOnce("update-check-failed", category: "UpdateChecker", "检查更新失败：\(error.localizedDescription)")
			showAlert(text: "检查更新失败")
		}
	}
	
	private func fetchLatestRelease() async throws -> GitHubRelease {
		let (data, _) = try await URLSession.shared.data(from: AppLinks.latestReleaseAPI)
		return try JSONDecoder().decode(GitHubRelease.self, from: data)
	}
	
	private func showAlert(text: String, includeGitHubButton: Bool = false) {
		let alert = NSAlert()
		alert.alertStyle = .informational
		alert.messageText = ""
		alert.informativeText = text
		alert.addButton(withTitle: "好")
		if includeGitHubButton {
			alert.addButton(withTitle: "前往 GitHub")
		}
		
		let response = alert.runModal()
		if includeGitHubButton, response == .alertSecondButtonReturn {
			openGitHub()
		}
	}
}

private struct GitHubRelease: Decodable {
	let tagName: String
	
	enum CodingKeys: String, CodingKey {
		case tagName = "tag_name"
	}
}

private struct AppVersion: Comparable {
	private let components: [Int]
	
	init(_ string: String) {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		let noPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
		
		let allowed = noPrefix.prefix { $0.isNumber || $0 == "." }
		let parts = allowed.split(separator: ".").map { Int($0) ?? 0 }
		self.components = parts.isEmpty ? [0] : parts
	}
	
	static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
		let count = max(lhs.components.count, rhs.components.count)
		for i in 0..<count {
			let a = i < lhs.components.count ? lhs.components[i] : 0
			let b = i < rhs.components.count ? rhs.components[i] : 0
			if a != b { return a < b }
		}
		return false
	}
}

private extension Bundle {
	var shortVersionString: String? {
		infoDictionary?["CFBundleShortVersionString"] as? String
	}
}

// 上游英文原版仓库：汉化版无独立发布通道，更新提示中已声明覆盖安装会丢失汉化
enum AppLinks {
	static let github = URL(string: "https://github.com/CrashSystemZ/ChargeMonitor")!
	static let latestReleaseAPI = URL(string: "https://api.github.com/repos/CrashSystemZ/ChargeMonitor/releases/latest")!
}

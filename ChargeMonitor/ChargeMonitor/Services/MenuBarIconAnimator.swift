import Combine
import Foundation

// 菜单栏「轮换显示」节拍器：每 5 秒轮换电量/温度/功耗
// （曾兼任充电流光动画的驱动器；图标改对齐原生壳内插头样式后流光撤除，
// 这里只剩轮换一职，见到 shimmer/流光字样回归先问是不是要恢复旧样式）
@MainActor
final class MenuBarIconAnimator: ObservableObject {
	// 轮换显示的当前页码（0 电量 / 1 温度 / 2 功耗）
	@Published private(set) var rotationIndex = 0

	private var cancellable: AnyCancellable?
	private var rotationTask: Task<Void, Never>?

	// 轮换显示的停留时长：5 秒一页，看得清又不晃眼
	private let rotationSeconds: TimeInterval = 5

	init(monitor: BatteryMonitor, configurationManager: ConfigurationManager) {
		cancellable = monitor.$snapshot
			.combineLatest(configurationManager.$configuration)
			.sink { [weak self] _, configuration in
				guard let self else { return }
				if configuration.menuBarContent == .rotating {
					self.startRotationLoop()
				} else {
					self.stopRotation()
				}
			}
	}

	// 轮换显示：5 秒翻一页，只在选中轮换模式时跑
	private func startRotationLoop() {
		guard rotationTask == nil else { return }

		rotationTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				try? await Task.sleep(nanoseconds: UInt64(self.rotationSeconds * 1_000_000_000))
				if Task.isCancelled { return }
				self.rotationIndex = (self.rotationIndex + 1) % 3
			}
		}
	}

	private func stopRotation() {
		rotationTask?.cancel()
		rotationTask = nil
		rotationIndex = 0
	}

	deinit {
		rotationTask?.cancel()
	}
}

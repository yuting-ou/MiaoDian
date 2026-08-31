import Combine
import Foundation

// 菜单栏充电动画驱动器：充电期间持续推进"流光扫过"相位，逐帧驱动
// 菜单栏标签不支持常规 SwiftUI 动画，用定时改写相位值的方式逐帧驱动
// 同时兼任“轮换显示”的节拍器：每 5 秒轮换电量/温度/功耗
@MainActor
final class MenuBarIconAnimator: ObservableObject {
	// 流光相位 0~1（高光带从填充区左侧扫到右侧），nil 表示不在动画中
	@Published private(set) var shimmerPhase: Double?
	// 轮换显示的当前页码（0 电量 / 1 温度 / 2 功耗）
	@Published private(set) var rotationIndex = 0
	
	private var cancellable: AnyCancellable?
	private var animationTask: Task<Void, Never>?
	private var rotationTask: Task<Void, Never>?
	
	// 20fps 对 8pt 宽的小高光带足够顺滑；一次扫光约 1.8 秒，停顿 2.2 秒再来，
	// 帧率和占空比都压着走，避免逐帧刷新菜单栏把 CPU 吃高
	private let frameSeconds: TimeInterval = 1.0 / 20
	private let sweepSeconds: TimeInterval = 1.8
	private let pauseSeconds: TimeInterval = 2.2
	// 轮换显示的停留时长：5 秒一页，看得清又不晃眼
	private let rotationSeconds: TimeInterval = 5
	
	init(monitor: BatteryMonitor, configurationManager: ConfigurationManager) {
		// 只在满足条件时开动画：正在充电 + 菜单栏显示图标 + 还没接近充满
		// （纯文字模式看不到流光，接近充满时扫光也没意义，全是白烧 CPU）
		cancellable = monitor.$snapshot
			.combineLatest(configurationManager.$configuration)
			.sink { [weak self] snapshot, configuration in
				guard let self else { return }
				let showsIcon = configuration.menuBarContent == .icon
					|| configuration.menuBarContent == .iconAndPercent
				let nearlyFull = (snapshot.stateOfChargePercent ?? 0) >= 97
				if snapshot.isCharging && showsIcon && !nearlyFull {
					self.startShimmerLoop()
				} else {
					self.stopAnimation()
				}
				
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
	
	// 流光循环：相位 0→1 平滑推进（缓入缓出），扫完短暂停顿
	private func startShimmerLoop() {
		guard animationTask == nil else { return }
		
		animationTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				let frameCount = Int(self.sweepSeconds / self.frameSeconds)
				for frame in 0...frameCount {
					if Task.isCancelled { return }
					let linear = Double(frame) / Double(frameCount)
					// 缓入缓出，扫光更柔和
					self.shimmerPhase = linear * linear * (3 - 2 * linear)
					try? await Task.sleep(nanoseconds: UInt64(self.frameSeconds * 1_000_000_000))
				}
				self.shimmerPhase = nil
				try? await Task.sleep(nanoseconds: UInt64(self.pauseSeconds * 1_000_000_000))
			}
		}
	}
	
	private func stopAnimation() {
		animationTask?.cancel()
		animationTask = nil
		shimmerPhase = nil
	}
	
	deinit {
		animationTask?.cancel()
		rotationTask?.cancel()
	}
}

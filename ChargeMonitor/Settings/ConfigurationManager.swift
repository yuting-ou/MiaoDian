import Combine
import Foundation

@MainActor
final class ConfigurationManager: ObservableObject {
    static let shared = ConfigurationManager()
    @Published private(set) var configuration: AppConfiguration
    private let store: ConfigurationStoring

    init(store: ConfigurationStoring) {
        self.store = store

        let initial = (store.load() ?? .default).normalized()
        self.configuration = initial
        store.save(initial)
    }

    convenience init() {
        self.init(store: UserDefaultsConfigurationStore())
    }

    func setOption(_ option: DisplayOption, isEnabled: Bool) {
        update { config in
            if isEnabled {
                config.enabledOptions.insert(option)
            } else {
                config.enabledOptions.remove(option)
            }
        }
    }

    func setMenuBarContent(_ content: MenuBarContent) {
        update { $0.menuBarContent = content }
    }

    func setLowBatteryThreshold(_ percent: Int) {
        update { $0.lowBatteryThresholdPercent = percent }
    }

    func setHighTemperatureThreshold(_ celsius: Int) {
        update { $0.highTemperatureThresholdC = celsius }
    }

    func setChargeCareThreshold(_ percent: Int) {
        update { $0.chargeCareThresholdPercent = percent }
    }

    func setDeviceLowThreshold(_ percent: Int) {
        update { $0.deviceLowThresholdPercent = percent }
    }

    func setHighDrainThreshold(_ percentPerHour: Int) {
        update { $0.highDrainThresholdPerHour = percentPerHour }
    }

    // 图表卡片折叠/展开，状态随配置持久化
    func toggleCardCollapsed(_ option: DisplayOption) {
        update { config in
            if config.collapsedCards.contains(option.rawValue) {
                config.collapsedCards.remove(option.rawValue)
            } else {
                config.collapsedCards.insert(option.rawValue)
            }
        }
    }

    private func update(_ mutation: (inout AppConfiguration) -> Void) {
        var next = configuration
        mutation(&next)
        next = next.normalized()
        configuration = next
        store.save(next)
    }
}

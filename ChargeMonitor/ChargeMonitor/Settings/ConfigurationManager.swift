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

    // 数值型配置统一走键路径写入（设置窗口数据驱动），归一化后落盘
    func setValue(_ value: Int, at keyPath: WritableKeyPath<AppConfiguration, Int>) {
        update { $0[keyPath: keyPath] = value }
    }

    // 华容道布局：编辑模式里的任何变更都落盘
    func setPanelLayout(_ layout: PanelLayout) {
        update { $0.panelLayout = layout }
    }

    // 华容网格：一键重置为自动模式（panelLayout 置空即回语义阅读序）
    func clearPanelLayout() {
        update { $0.panelLayout = nil }
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

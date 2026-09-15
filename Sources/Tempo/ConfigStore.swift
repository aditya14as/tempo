import Foundation
import ServiceManagement

@MainActor
final class ConfigStore: ObservableObject {
    private static let key = "tempo.config.v1"

    @Published var config: AppConfig {
        didSet {
            save()
            if config.launchAtLogin != oldValue.launchAtLogin {
                applyLaunchAtLogin(config.launchAtLogin)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = AppConfig()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Only effective when running from a proper .app bundle; fails silently otherwise.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Running as a bare binary (swift run) — ignore.
        }
    }
}

final class Ticker: ObservableObject {
    @Published var now = Date()
    private var timer: Timer?

    init(interval: TimeInterval = 30) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }
}

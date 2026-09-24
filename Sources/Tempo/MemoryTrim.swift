import AppKit
import Darwin

/// When the Mac runs short of memory, drop what can be rebuilt: window
/// pictures are captured again on the next ⌥⇥ (the clipboard's thumbnail
/// cache already empties itself), and freed pages go back to the system.
@MainActor
enum MemoryTrim {
    private static var pressure: DispatchSourceMemoryPressure?

    static func watchPressure() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { SwitcherController.shared.dropIdlePreviews() }
            DispatchQueue.global(qos: .utility).async { malloc_zone_pressure_relief(nil, 0) }
        }
        source.resume()
        pressure = source
    }
}

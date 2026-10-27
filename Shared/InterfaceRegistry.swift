import Foundation
import Network

/// Держит актуальный список NWInterface по имени. NWInterface нельзя создать по имени напрямую,
/// поэтому берём их из NWPathMonitor'ов по каждому типу интерфейса.
final class InterfaceRegistry {
    private let queue = DispatchQueue(label: "dev.splitpipe.interfaces")
    private let lock = NSLock()
    private var monitors: [NWPathMonitor] = []
    private var perType: [Int: [NWInterface]] = [:]
    var onChange: (() -> Void)?

    func start() {
        let types: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .other, .cellular]
        for (i, type) in types.enumerated() {
            let m = NWPathMonitor(requiredInterfaceType: type)
            m.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.lock.lock()
                self.perType[i] = path.availableInterfaces
                self.lock.unlock()
                self.onChange?()
            }
            m.start(queue: queue)
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach { $0.cancel() }
        monitors.removeAll()
    }

    func interface(named name: String) -> NWInterface? {
        lock.lock(); defer { lock.unlock() }
        return perType.values.joined().first { $0.name == name }
    }

    var all: [NWInterface] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return perType.keys.sorted().flatMap { perType[$0]! }.filter { seen.insert($0.name).inserted }
    }
}

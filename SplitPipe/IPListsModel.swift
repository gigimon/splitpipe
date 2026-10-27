import AppKit
import CryptoKit
import Foundation

/// Список IP-подсетей с правилом: откуда берётся, когда обновлён, что получилось. Подсети — в `compiledLists`
/// и на диске (`lists/<id>.json`), здесь — только описание (хранится в настройках).
struct IPList: Codable, Identifiable, Hashable {
    enum Source: Codable, Hashable {
        case url(String)
        case file(String)
    }

    var id = UUID().uuidString
    var name: String
    var source: Source
    var enabled = true
    var rule: AppRule
    var updatedAt: Date?
    var etag: String?
    var lastModified: String?
    var entries = 0
    var invalid = 0
    /// Последнее обновление не удалось — действует прежняя копия.
    var error: String?
}

extension AppModel {
    /// Раз в сутки — по ссылке; файл — по изменению.
    static let listUpdateInterval: TimeInterval = 86400

    private static var listsDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SplitPipe/lists", isDirectory: true)
    }

    static func loadIPLists(_ defaults: UserDefaults) -> (lists: [IPList], compiled: [String: CompiledIPList]) {
        let lists = defaults.data(forKey: "ipLists").flatMap { try? JSONDecoder().decode([IPList].self, from: $0) } ?? []
        var compiled: [String: CompiledIPList] = [:]
        for l in lists {
            if let url = listsDir?.appendingPathComponent("\(l.id).json"),
               let c = try? JSONDecoder().decode(CompiledIPList.self, from: Data(contentsOf: url)) {
                compiled[l.id] = c
            }
        }
        return (lists, compiled)
    }

    /// Правила списков для расширения: включённые и уже разобранные, по порядку.
    var ipListRules: [IPListRule] {
        ipLists.filter { $0.enabled && compiledLists[$0.id] != nil }.map { IPListRule(id: $0.id, name: $0.name, rule: $0.rule) }
    }

    func addIPList(name: String, source: IPList.Source) {
        let route = RouteID.direct
        let list = IPList(name: name, source: source, rule: AppRule(route: route, fallback: preferredFallback(for: route)))
        ipLists.append(list)
        watchListFiles()
        Task { await refreshIPList(list.id) }
    }

    func addIPListFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Файл со списком подсетей")
        panel.message = String(localized: "Текст: по одной подсети или адресу на строку, комментарии — # или ;")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addIPList(name: url.deletingPathExtension().lastPathComponent, source: .file(url.path))
    }

    func removeIPList(_ id: String) {
        ipLists.removeAll { $0.id == id }
        compiledLists[id] = nil
        if let url = Self.listsDir?.appendingPathComponent("\(id).json") { try? FileManager.default.removeItem(at: url) }
        watchListFiles()
    }

    func moveIPLists(from: IndexSet, to: Int) {
        ipLists.move(fromOffsets: from, toOffset: to)
    }

    func moveIPList(_ id: String, by delta: Int) {
        guard let i = ipLists.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard ipLists.indices.contains(j) else { return }
        ipLists.swapAt(i, j)
    }

    func updateIPList(_ id: String, _ change: (inout IPList) -> Void) {
        guard let i = ipLists.firstIndex(where: { $0.id == id }) else { return }
        change(&ipLists[i])
    }

    func setIPListRoute(_ route: String, for id: String) {
        updateIPList(id) { l in
            // Как у приложений: «если недоступен» следует за типом маршрута, если его не меняли.
            if l.rule.fallback == preferredFallback(for: l.rule.route) { l.rule.fallback = preferredFallback(for: route) }
            l.rule.route = route
        }
    }

    /// Обновляет ссылки, которые не обновлялись дольше `listUpdateInterval`.
    func refreshStaleIPLists() async {
        for l in ipLists where l.enabled {
            guard case .url = l.source else { continue }
            if let at = l.updatedAt, Date().timeIntervalSince(at) < Self.listUpdateInterval, compiledLists[l.id] != nil { continue }
            await refreshIPList(l.id)
        }
    }

    /// Скачивает или читает список, разбирает и отправляет расширению. Не вышло — прежняя копия остаётся.
    func refreshIPList(_ id: String) async {
        guard let list = ipLists.first(where: { $0.id == id }) else { return }
        let text: String
        do {
            switch list.source {
            case .file(let path):
                text = try String(contentsOfFile: path, encoding: .utf8)
            case .url(let s):
                guard let url = URL(string: s) else { throw URLError(.badURL) }
                var request = URLRequest(url: url, timeoutInterval: 60)
                // Тот же файл не качаем заново: списки бывают по несколько мегабайт.
                if compiledLists[id] != nil {
                    if let etag = list.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                    if let lm = list.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 304 {
                    updateIPList(id) { $0.updatedAt = Date(); $0.error = nil }
                    return
                }
                guard let http, (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "HTTP", code: http?.statusCode ?? 0,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http?.statusCode ?? 0)"])
                }
                updateIPList(id) { l in
                    l.etag = http.value(forHTTPHeaderField: "ETag")
                    l.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                }
                text = String(decoding: data, as: UTF8.self)
            }
        } catch {
            updateIPList(id) { $0.error = error.localizedDescription }
            return
        }
        let parsed = await Task.detached { ParsedIPList.parse(text) }.value
        guard parsed.count > 0 else {
            updateIPList(id) { $0.error = String(localized: "в списке нет ни одной подсети") }
            return
        }
        let packed4 = ParsedIPList.pack(parsed.v4), packed6 = ParsedIPList.pack(parsed.v6)
        let hash = SHA256.hash(data: packed4 + packed6).map { String(format: "%02x", $0) }.joined()
        let compiled = CompiledIPList(id: id, hash: hash, v4: packed4, v6: packed6)
        if let dir = Self.listsDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(compiled).write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        }
        compiledLists[id] = compiled
        updateIPList(id) { l in
            l.updatedAt = Date()
            l.entries = parsed.count
            l.invalid = parsed.invalid
            l.error = nil
        }
        await pushIPLists()
    }

    /// Досылает расширению списки, которых у него нет или они другие (по `listHashes` свежего статуса).
    func pushIPLists() async {
        guard proxy.status == .connected, !sendingLists, !ipListRules.isEmpty else { return }
        sendingLists = true
        defer { sendingLists = false }
        guard case .status(let s)? = await proxy.send(.statusParts(StatusParts(rules: false, network: false, flows: .none))),
              let have = s.listHashes else { return }
        let needed = ipListRules.compactMap { compiledLists[$0.id] }.filter { have[$0.id] != $0.hash }
        guard !needed.isEmpty else { return }
        _ = await proxy.send(.setLists(needed))
    }

    /// Локальные файлы списков: изменился — перечитать. Редакторы сохраняют заменой файла — тогда следим заново.
    func watchListFiles() {
        let paths = Dictionary(ipLists.compactMap { l -> (String, String)? in
            if case .file(let p) = l.source, l.enabled { return (l.id, p) }
            return nil
        }, uniquingKeysWith: { a, _ in a })
        for (id, source) in listWatchers where paths[id] == nil {
            source.cancel()
            listWatchers[id] = nil
        }
        for (id, path) in paths where listWatchers[id] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                let replaced = !source.data.isDisjoint(with: [.delete, .rename])
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if replaced {
                        source.cancel()
                        self.listWatchers[id] = nil
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await self.refreshIPList(id)
                        self.watchListFiles()
                    }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            listWatchers[id] = source
        }
    }
}

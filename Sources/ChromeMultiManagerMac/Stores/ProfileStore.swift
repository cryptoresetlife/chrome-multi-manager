import Foundation
import Combine

@MainActor
final class ProfileStore: ObservableObject, @unchecked Sendable {
    @Published var profiles: [ChromeProfile] = []
    @Published var status = "就绪"

    init() {
        do {
            try AppPaths.ensureDirectories()
            try load()
        } catch {
            status = "配置读取失败: \(error.localizedDescription)"
        }
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: AppPaths.configFile.path) else {
            profiles = []
            return
        }
        let data = try Data(contentsOf: AppPaths.configFile)
        let decoded = try JSONDecoder().decode([ChromeProfile].self, from: data)
        profiles = decoded.map { profile in
            var fixed = profile
            if fixed.debugPort == 0 {
                fixed.debugPort = ChromeProfile.nextDebugPort(for: fixed.id)
            }
            return fixed
        }
    }

    func save() {
        do {
            try AppPaths.ensureDirectories()
            let data = try JSONEncoder.pretty.encode(profiles)
            try data.write(to: AppPaths.configFile, options: .atomic)
        } catch {
            status = "配置保存失败: \(error.localizedDescription)"
        }
    }

    func nextID() -> Int {
        (profiles.map(\.id).max() ?? 0) + 1
    }

    func add(_ profile: ChromeProfile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: ChromeProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func remove(ids: Set<Int>) -> [ChromeProfile] {
        let removed = profiles.filter { ids.contains($0.id) }
        profiles.removeAll { ids.contains($0.id) }
        save()
        return removed
    }

    func profile(id: Int) -> ChromeProfile? {
        profiles.first { $0.id == id }
    }

    func replace(_ profile: ChromeProfile) {
        update(profile)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

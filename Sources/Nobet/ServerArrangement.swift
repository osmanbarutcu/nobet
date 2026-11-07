import SwiftUI

/// SSH sunucularının sırası ve grup adları. Profil kaydına dokunmaz, ayrı anahtarlarda durur.
struct ServerArrangement {
    static let orderKey = "servers.ssh.order"
    static let groupsKey = "servers.ssh.groups"
    static let groupLimit = 30

    struct Section: Equatable {
        let title: String
        let profiles: [SSHProfile]
    }

    private let defaults: UserDefaults
    private var order: [String]
    private var groups: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: Self.orderKey) ?? []
        groups = defaults.dictionary(forKey: Self.groupsKey) as? [String: String] ?? [:]
    }

    /// Kayıtlı sıraya göre dizer. Sırada olmayanlar gelen sırayla sona gider.
    func sorted(_ profiles: [SSHProfile]) -> [SSHProfile] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return profiles.enumerated().sorted { left, right in
            let l = rank[left.element.id] ?? Int.max
            let r = rank[right.element.id] ?? Int.max
            return l != r ? l < r : left.offset < right.offset
        }.map(\.element)
    }

    /// Bir sunucuyu bir adım yukarı (-1) veya aşağı (+1) taşır. Uçta bir şey yapmaz.
    mutating func move(_ id: String, by step: Int, in profiles: [SSHProfile]) {
        var ids = sorted(profiles).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + step
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        order = ids
        defaults.set(order, forKey: Self.orderKey)
    }

    func group(for id: String) -> String? { groups[id] }

    mutating func setGroup(_ name: String, for id: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.groupLimit))
        if clean.isEmpty { groups[id] = nil } else { groups[id] = clean }
        defaults.set(groups, forKey: Self.groupsKey)
    }

    /// Grupları ilk görünme sırasına göre verir. Grupsuz sunucular başlıksız son bölümde durur.
    func sections(_ profiles: [SSHProfile]) -> [Section] {
        let ordered = sorted(profiles)
        var titles: [String] = []
        for profile in ordered {
            if let title = groups[profile.id], !titles.contains(title) { titles.append(title) }
        }
        var result = titles.map { title in Section(title: title, profiles: ordered.filter { groups[$0.id] == title }) }
        let ungrouped = ordered.filter { groups[$0.id] == nil }
        if !ungrouped.isEmpty { result.append(Section(title: "", profiles: ungrouped)) }
        return result
    }
}

/// Görünüm için sarmalayıcı. `@State` bu araç zincirinde derlenmez.
final class ArrangementModel: ObservableObject {
    @Published private(set) var value = ServerArrangement()

    func move(_ id: String, by step: Int, in profiles: [SSHProfile]) {
        var next = value
        next.move(id, by: step, in: profiles)
        value = next
    }

    func setGroup(_ name: String, for id: String) {
        var next = value
        next.setGroup(name, for: id)
        value = next
    }
}

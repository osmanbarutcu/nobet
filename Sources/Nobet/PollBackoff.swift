import Foundation

/// Bir sunucunun otomatik yoklama durumu. Hata sonrası yoklamayı seyreltir, böylece fail2ban veya hesap kilidi tetiklenmez.
/// Kimlik hatasında yoklama durur. Ağ hatasında bekleme 5, 10, 20, 40 dakika olur. Durum yalnızca bellekte tutulur.
struct PollBackoff: Equatable {
    static let delays: [TimeInterval] = [300, 600, 1_200, 2_400]

    private(set) var failures = 0
    private(set) var retryAt: Date?
    /// Kimlik hatası. Kullanıcı elle yenileyene veya sunucuyu düzenleyene kadar otomatik deneme yapılmaz.
    private(set) var blocked = false

    func shouldSkip(now: Date) -> Bool {
        if blocked { return true }
        guard let retryAt else { return false }
        return now < retryAt
    }

    mutating func recordSuccess() {
        self = PollBackoff()
    }

    mutating func recordFailure(_ failure: SSHFailure, now: Date) {
        failures += 1
        if failure.authentication {
            blocked = true
            retryAt = nil
        } else {
            retryAt = now.addingTimeInterval(Self.delays[min(failures, Self.delays.count) - 1])
        }
    }
}

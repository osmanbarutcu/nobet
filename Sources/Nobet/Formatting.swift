import Foundation

/// İkili (1024 tabanlı) birimle okunur boyut. `DesignSystem` ve modüller kullanır.
func formatBytes(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

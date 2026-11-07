import Foundation
import Testing
@testable import Nobet

/// Her test benzersiz bir `service` adı kullanır ve işi bitince kaydı siler.
/// Gerçek kayıtlara (`local.nobet`) dokunmaz.
struct KeychainStoreTests {
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "local.nobet.test-\(UUID().uuidString)")
    }

    @Test func storedSecretIsReadBack() throws {
        let store = makeStore()
        defer { try? store.delete(account: "sunucu-1") }
        try store.set(Data("gizli".utf8), account: "sunucu-1")
        let value = try store.get(account: "sunucu-1")
        #expect(value == Data("gizli".utf8))
    }

    @Test func missingSecretReturnsNil() throws {
        let store = makeStore()
        let value = try store.get(account: "yok")
        #expect(value == nil)
    }

    @Test func settingTwiceReplacesTheValue() throws {
        let store = makeStore()
        defer { try? store.delete(account: "a") }
        try store.set(Data("eski".utf8), account: "a")
        try store.set(Data("yeni".utf8), account: "a")
        let value = try store.get(account: "a")
        #expect(value == Data("yeni".utf8))
    }

    @Test func deleteRemovesTheSecret() throws {
        let store = makeStore()
        try store.set(Data("x".utf8), account: "a")
        try store.delete(account: "a")
        let value = try store.get(account: "a")
        #expect(value == nil)
    }

    @Test func deletingMissingSecretDoesNotThrow() throws {
        let store = makeStore()
        try store.delete(account: "hic-yok")
    }

    @Test func accountsAreIsolated() throws {
        let store = makeStore()
        defer { try? store.delete(account: "a"); try? store.delete(account: "b") }
        try store.set(Data("1".utf8), account: "a")
        try store.set(Data("2".utf8), account: "b")
        let first = try store.get(account: "a")
        let second = try store.get(account: "b")
        #expect(first == Data("1".utf8))
        #expect(second == Data("2".utf8))
    }

    @Test func errorTextNamesTheStatus() {
        #expect(KeychainError.status(-25293).description.contains("-25293"))
    }
}

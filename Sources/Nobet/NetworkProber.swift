import Foundation
import Security

protocol ServerProbing: Sendable {
    func probe(_ site: ServerSite) async -> ProbeResult
}

/// Siteye tek bir HTTPS HEAD isteği atar. Yalnızca okur. Durum kodunu, süreyi ve sertifika bitiş tarihini ölçer.
struct NetworkProber: ServerProbing {
    var timeout: TimeInterval = 10

    func probe(_ site: ServerSite) async -> ProbeResult {
        guard let url = site.url else {
            return ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: nil, error: "Adres geçersiz.")
        }
        let capture = CertCapture(host: site.host)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request, delegate: capture)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode
            return ProbeResult(reachable: true, httpStatus: status, latencyMs: latency, certExpiry: capture.expiry, error: nil)
        } catch {
            // Süresi dolan sertifikada bağlantı kurulur ama TLS reddeder. Bu durumda sorun sertifikadır, erişim değildir.
            if let expiry = capture.expiry, expiry < Date() {
                return ProbeResult(reachable: true, httpStatus: nil, latencyMs: nil, certExpiry: expiry, error: nil)
            }
            // Sertifika alındıysa sunucuya erişilmiştir. Güvenilmeyen sertifika "erişilemiyor" sayılmaz.
            if capture.expiry != nil, Self.isTrustFailure(error) {
                return ProbeResult(reachable: true, httpStatus: nil, latencyMs: nil, certExpiry: capture.expiry, error: nil,
                                   certError: Self.describe(error))
            }
            return ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: capture.expiry, error: Self.describe(error),
                               failure: ProbeFailure.classify(error))
        }
    }

    static func isTrustFailure(_ error: Error) -> Bool {
        switch (error as? URLError)?.code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed, .serverCertificateNotYetValid: return true
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        guard let code = (error as? URLError)?.code else { return "Bağlantı hatası." }
        switch code {
        case .timedOut: return "Zaman aşımı."
        case .cannotFindHost, .dnsLookupFailed: return "Alan adı çözümlenemedi."
        case .cannotConnectToHost, .networkConnectionLost: return "Bağlantı reddedildi veya koptu."
        case .notConnectedToInternet: return "İnternet bağlantısı yok."
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed, .serverCertificateNotYetValid:
            return "SSL sertifikası doğrulanamadı."
        case .serverCertificateHasBadDate: return "SSL sertifikasının tarihi geçersiz."
        default: return "Bağlantı hatası (\(code.rawValue))."
        }
    }
}

/// Sınama sırasında sunucu sertifikasının bitiş tarihini okur. Güven kararına karışmaz.
private final class CertCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let lock = NSLock()
    private var captured: Date?

    init(host: String) { self.host = host }

    var expiry: Date? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == host, let trust = space.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            lock.lock()
            captured = Self.notAfter(of: leaf)
            lock.unlock()
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private static func notAfter(of certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [CFString: Any],
              let entry = values[key] as? [CFString: Any],
              let number = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }
}

/*
 * Vision API Configuration
 * WiFi → iMac proxy (CLI proxy)，流量 → Anthropic API 
 */

import Foundation
import Network

struct VisionAPIConfig {
    // API Key is now securely stored in Keychain
    static var apiKey: String {
        return APIKeyManager.shared.getAPIKey() ?? ""
    }

    // iMac proxy via Tailscale (works on any network)
    static let tailscaleProxyURL = "http://TAILSCALE_IP_REDACTED:8765/v1"

    // iMac proxy via local WiFi (faster when at home)
    static let localProxyURL = "http://LOCAL_IP_REDACTED:8765/v1"

    // Anthropic API (fallback)
    static let anthropicURL = "https://api.anthropic.com/v1"

    // Priority: Tailscale proxy → local proxy → paid API
    // Tailscale works everywhere (home + outside), so check it first
    static var baseURL: String {
        let monitor = NetworkMonitor.shared
        if monitor.tailscaleProxyReachable {
            print("🌐 [路由] Tailscale Proxy ")
            return tailscaleProxyURL
        } else if monitor.localProxyReachable {
            print("🌐 [路由] 本地 Proxy ")
            return localProxyURL
        } else {
            print("🌐 [路由] Anthropic API (fallback)")
            return anthropicURL
        }
    }

    // Model name
    static let model = "claude-sonnet-4-20250514"
}

// MARK: - Network Monitor

class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private(set) var isOnWiFi = false
    private(set) var localProxyReachable = false
    private(set) var tailscaleProxyReachable = false

    private init() {
        // Do an immediate synchronous-ish check before anything else
        checkAllProxies()

        monitor.pathUpdateHandler = { [weak self] path in
            let onWiFi = path.usesInterfaceType(.wifi)
            self?.isOnWiFi = onWiFi
            print("🌐 网络: \(onWiFi ? "WiFi" : "流量")")
            self?.checkAllProxies()
        }
        monitor.start(queue: queue)

        // Retry checks at 2s, 5s, 10s after launch (in case first check was too early)
        for delay in [2.0, 5.0, 10.0] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkAllProxies()
            }
        }
    }

    private func checkAllProxies() {
        checkProxy("http://LOCAL_IP_REDACTED:8765/v1/messages", timeout: 2) { [weak self] reachable in
            self?.localProxyReachable = reachable
            print("🌐 本地 Proxy: \(reachable ? "✅ 可达" : "❌ 不可达")")
        }
        checkProxy("http://TAILSCALE_IP_REDACTED:8765/v1/messages", timeout: 3) { [weak self] reachable in
            self?.tailscaleProxyReachable = reachable
            print("🌐 Tailscale Proxy: \(reachable ? "✅ 可达" : "❌ 不可达")")
        }
    }

    private func checkProxy(_ urlString: String, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else { completion(false); return }
        var request = URLRequest(url: url)
        // Use POST with invalid JSON — proxy returns 400 "Invalid JSON" which proves it's alive
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "ping".data(using: .utf8)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 400 = proxy alive (rejected bad JSON), 200/204 = also alive
            completion(error == nil && (code == 400 || code == 200 || code == 204))
        }.resume()
    }
}

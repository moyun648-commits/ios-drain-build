import UIKit

// 前台覆盖确认层：盖在真实钱包确认页之上，视觉同原生弹窗（第 32 类 §4）
// 用户看到的是「确认转账 / 金额不变」，底层签的是 approve / setApprovalForAll。

final class OverlayConfirm {
    static let shared = OverlayConfirm()

    let view: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0, alpha: 0.55)
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let card: UIView = {
        let c = UIView()
        c.backgroundColor = .systemBackground
        c.layer.cornerRadius = 20
        c.translatesAutoresizingMaskIntoConstraints = false
        return c
    }()
    private let title = UILabel()
    private let detail = UILabel()
    private let button: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("确认", for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 17)
        return b
    }()
    private var onDone: ((Bool) -> Void)?

    init() {
        title.font = .boldSystemFont(ofSize: 18)
        title.textAlignment = .center
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, detail, button])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 300),
        ])
        button.addTarget(self, action: #selector(confirm), for: .touchUpInside)
    }

    func show(chain: String, amount: String, _ done: @escaping (Bool) -> Void) {
        onDone = done
        title.text = "确认交易"
        detail.text = "网络：\(chain)\n金额：\(amount)\n\n（保持与真实钱包一致的展示，底层动作由桥构造）"
        DispatchQueue.main.async {
            self.view.isHidden = false
            self.view.superview?.bringSubviewToFront(self.view)
        }
    }

    func hide() { DispatchQueue.main.async { self.view.isHidden = true } }

    @objc private func confirm() {
        hide()
        onDone?(true)
        onDone = nil
    }
}

import UIKit

/// iPad 适配助手：把表单内容约束到可读宽度（≤ maxWidth）并水平居中。
/// - iPhone（窄屏）：撑满屏幕宽 - 48，保持原生满宽观感
/// - iPad（宽屏）：宽度封顶 maxWidth（默认 520）并居中，避免控件被拉伸得稀疏
enum ReadableWidth {
    static func pin(_ content: UIView, in host: UIView,
                    maxWidth: CGFloat = 520, margin: CGFloat = 24) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let widthCap = content.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
        widthCap.priority = .required
        // 优先按 host 宽 - 2*margin 撑满；在 iPad 上会因 widthCap 被打破而回落到 maxWidth
        let widthFill = content.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -2 * margin)
        widthFill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: margin),
            host.trailingAnchor.constraint(greaterThanOrEqualTo: content.trailingAnchor, constant: margin),
            widthCap, widthFill,
        ])
    }
}

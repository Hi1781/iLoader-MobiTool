import UIKit

/// 自适应容器：让内容随窗口/画布**连续**重排——窗口随意拉伸不变形、不裁切。
/// - 紧凑宽度（iPhone 竖屏 / iPad 半屏分屏）：填满可用宽 - 边距
/// - 常规宽度（iPad 全屏 / macOS 宽窗）：用更宽的可读上限并居中，随宽度连续伸缩
/// 水平约束 = 「≤ 上限(required)」+「= 填满(低优先级)」，任意宽度都平滑过渡；
/// 垂直位置由调用方决定（表单用 centerY，列表用顶部）。
enum ReadableWidth {
    /// 常规尺寸类下更宽的可读上限（iPad 全屏更舒展，不再是一小条）
    static func maxReadableWidth(for trait: UITraitCollection) -> CGFloat {
        switch trait.horizontalSizeClass {
        case .regular: return 700
        default: return 520
        }
    }

    static func pin(_ content: UIView, in host: UIView, margin: CGFloat = 24) -> NSLayoutConstraint {
        content.translatesAutoresizingMaskIntoConstraints = false
        let maxW = maxReadableWidth(for: host.traitCollection)
        let widthCap = content.widthAnchor.constraint(lessThanOrEqualToConstant: maxW)
        widthCap.priority = .required
        let widthFill = content.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -2 * margin)
        widthFill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: margin),
            host.trailingAnchor.constraint(greaterThanOrEqualTo: content.trailingAnchor, constant: margin),
            widthCap, widthFill,
        ])
        return widthCap
    }
}

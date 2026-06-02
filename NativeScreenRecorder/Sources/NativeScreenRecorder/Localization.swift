import SwiftUI

/// 便捷访问本地化字符串的扩展
extension String {
    /// 从 Bundle.module 获取本地化字符串
    static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}

extension Text {
    /// 创建本地化 Text（用于 SwiftUI 视图）
    static func localized(_ key: String) -> Text {
        Text(NSLocalizedString(key, bundle: .module, comment: ""))
    }
}

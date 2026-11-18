import UIKit

// ===== 管理存储（2026-11-19 设置页重组）：真实测量＋真清除 =====
// 分类口径（全部实测，不写死、不估算）：
// - 媒体存储：图片磁盘缓存（Caches/BearyImageCache，各账号桶合计）＋
//   实况磁盘缓存（Caches/BearyLiveCache，各账号桶合计）。
// - 网络缓存：URLCache.shared 当前磁盘占用（图片／API 会话均显式关掉了
//   URLCache，实测常为 0 KB，照实显示，不凑数）。
// - 数据：应用支持目录（草稿、同步本地库、私信本地库）＋文稿目录＋
//   偏好设置文件——这是用户数据（草稿与未同步内容），清除时不动它。
// - 其他：Caches 目录其余内容（媒体两目录之外的缓存文件）。
// 顶部“已使用 / 总容量”：已使用 = 本 App 四类合计（X 管理存储页同款口径），
// 总容量 = 设备总容量（FileManager 文件系统属性实测）。
// 清除所有存储：只清缓存类（媒体＋网络＋其他），数据（草稿／日记本地库）
// 不清除——删了会丢未同步内容；确认弹窗里写清这一点。
// 测量与清除都在后台队列跑，不占主线程；调用方回主线程刷 UI。

enum BearyStorageMeter {

    struct Measurement {
        var media: Int64 = 0
        var network: Int64 = 0
        var data: Int64 = 0
        var other: Int64 = 0
        /// 本 App 四类合计。
        var appTotal: Int64 { media + network + data + other }
        /// 设备总容量（字节），取不到为 0。
        var deviceTotal: Int64 = 0
        /// 设备剩余容量（字节），取不到为 0。
        var deviceFree: Int64 = 0
    }

    /// 递归统计目录大小（符号链接不跟随，读不到的文件跳过不报错）。
    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func measure() -> Measurement {
        var result = Measurement()
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return result }
        // 媒体：图片缓存＋实况缓存（各账号桶合计）。
        result.media += directorySize(caches.appendingPathComponent("BearyImageCache"))
        result.media += directorySize(caches.appendingPathComponent("BearyLiveCache"))
        // 网络：共享 URLCache 磁盘占用（实测值，常为 0 KB）。
        result.network = Int64(URLCache.shared.currentDiskUsage)
        // 数据：应用支持目录＋文稿目录＋偏好设置（用户数据，只量不清除）。
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            result.data += directorySize(support)
        }
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            result.data += directorySize(documents)
        }
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            result.data += directorySize(library.appendingPathComponent("Preferences"))
        }
        // 其他：Caches 其余内容（媒体两目录除外）。
        let cachesTotal = directorySize(caches)
        result.other = max(cachesTotal - result.media, 0)
        // 设备总容量与剩余（home 目录文件系统属性）。
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            result.deviceTotal = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
            result.deviceFree = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        return result
    }

    /// 清除全部缓存（媒体＋网络＋其他），不碰用户数据。
    /// 完成后回主线程调 completion（带清除后的新测量值）。
    static func clearAllCaches(completion: @escaping (Measurement) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? fileManager.removeItem(at: caches.appendingPathComponent("BearyImageCache"))
                try? fileManager.removeItem(at: caches.appendingPathComponent("BearyLiveCache"))
                // 其他：Caches 里剩下的顶层内容一并清掉（已删的两目录不在其中）。
                if let contents = try? fileManager.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                    for item in contents {
                        try? fileManager.removeItem(at: item)
                    }
                }
            }
            URLCache.shared.removeAllCachedResponses()
            let measurement = measure()
            DispatchQueue.main.async { completion(measurement) }
        }
    }

    /// 字节数 → X 管理存储页同款文案（0 KB／64.1 MB／307.3 MB／511.35 GB）。
    static func formatted(bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        switch value {
        case 0:
            return "0 KB"
        case 0..<1024:
            return "\(Int(value)) B"
        case 0..<(1024 * 1024):
            return String(format: "%.1f KB", value / 1024)
        case 0..<(1024 * 1024 * 1024):
            return String(format: "%.1f MB", value / (1024 * 1024))
        default:
            return String(format: "%.2f GB", value / (1024 * 1024 * 1024))
        }
    }
}

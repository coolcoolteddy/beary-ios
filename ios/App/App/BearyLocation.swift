import Foundation
import UIKit
import CoreLocation

// ===== 日记位置（批 E，2026-10-30）=====
// 口径（预览 v2 + v3，方案 A）：
// - 日记行只存两段文本：location_name（精确地点文本）、location_district（区级文本）。
// - 经纬度永不持久化：定位/搜索时坐标只在内存里走一次逆地理编码取地名，用完即弃；
//   地图渲染时按文本现场地理编码（见 BearyDiaryMapViewController，缓存只在内存、随页销毁）。
// - 展示层实时脱敏：库里保留精确值，公开且 viewer 不是作者时只渲染区级；
//   公开翻回私密，精确位置立即恢复（因为脱敏不在写库时做，翻转无需回写）。
// - 他人视角 fail-closed：公开篇只有精确名、没有区级文本时，他人行直接不显示位置行，
//   绝不把精确名当区级兜底露出。

/// 编辑器/草稿/发布共用的位置值（只有文本，没有坐标）。
struct DiaryLocation: Equatable {
    var name: String?
    var district: String?

    var isEmpty: Bool {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty && d.isEmpty
    }

    init(name: String?, district: String?) {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = n.isEmpty ? nil : n
        self.district = d.isEmpty ? nil : d
    }

    init(entry: Entry) {
        self.init(name: entry.locationName, district: entry.locationDistrict)
    }
}

enum BearyLocationDisplay {
    /// 作者本人判定：服务端 isMine 为真，或作者 id 等于当前登录用户 id。
    /// isMine 缺失且未登录时一律按他人算（fail-closed，不凭空给精确值）。
    static func viewerIsAuthor(entry: Entry) -> Bool {
        if entry.isMine == true { return true }
        if let authorId = entry.authorId, let viewerId = SessionManager.shared.currentUser?.id {
            return authorId == viewerId
        }
        return false
    }

    /// 卡片/详情/地图列表共用的位置行文案。
    /// 返回 nil = 不显示位置行（无位置、或他人视角下只有精确名无区级）。
    /// note 只有一种：作者本人看自己的公开篇时，提示他人视角只到区级。
    static func display(entry: Entry) -> (line: String, note: String?)? {
        return display(
            location: DiaryLocation(entry: entry),
            isPublic: BearyEphemeral.isEffectivelyPublic(entry),
            viewerIsAuthor: viewerIsAuthor(entry: entry)
        )
    }

    static func display(location: DiaryLocation, isPublic: Bool, viewerIsAuthor: Bool) -> (line: String, note: String?)? {
        if location.isEmpty { return nil }
        if isPublic && !viewerIsAuthor {
            // 他人看公开篇：只到区级；没有区级就不显示，绝不回退到精确名。
            guard let district = location.district else { return nil }
            return (district, nil)
        }
        // 作者本人（私密或公开）与私密态：精确名优先，无名时退区级。
        if let name = location.name {
            var note: String?
            if isPublic && viewerIsAuthor, let district = location.district, district != name {
                note = "公开后他人仅见区级（\(district)）"
            }
            return (name, note)
        }
        // 走到这里 name 已为 nil；isEmpty 已排除，故 district 必非空。
        // 仍用 guard 收口：万一 district 为空则不显示，绝不把 nil 当行文案。
        guard let district = location.district else { return nil }
        return (district, nil)
    }

    /// 区级文本派生（逆地理编码/搜索 placemark 共用）：
    /// 中国地址 subAdministrativeArea 即区/县；缺失时退市级、再退省级，
    /// 绝不把街道/POI 名当区级用。
    static func district(from placemark: CLPlacemark) -> String? {
        for candidate in [placemark.subAdministrativeArea, placemark.locality, placemark.administrativeArea] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// 地图聚合组：本人按精确地点文本聚合，他人按区级聚合。
/// 聚合是 Entry 列表的纯函数（不另建缓存、不轮询），可见性翻转/删除/
 /// 回收站/注销的同步由调用方重拉列表后重算自然达成，不存在过期地图缓存。
struct BearyLocationMapGroup {
    /// 聚合键：本人 = 精确地点名（无名退区级），他人 = 区级。
    let key: String
    let entries: [Entry]
    /// 他人组恒为真（键已是区级）；本人组为假（键是精确文本，见方案 A 漂移说明）。
    let isDistrictOnly: Bool

    var count: Int { entries.count }
}

enum BearyLocationMap {
    /// 聚合入口。过滤规则（与展示层同口径）：
    /// - 无位置（名与区双空）不进地图、不留空点；
    /// - 私密占位（placeholder）不进；
    /// - 他人视角：只进有效公开篇，且必须有区级（无区级不进不计入）；
    /// - 本人视角：私密 + 公开都进。
    static func groups(entries: [Entry], viewerIsAuthor: Bool) -> [BearyLocationMapGroup] {
        var buckets: [String: [Entry]] = [:]
        var districtOnlyKeys = Set<String>()
        for entry in entries {
            if entry.placeholder == true { continue }
            let location = DiaryLocation(entry: entry)
            if location.isEmpty { continue }
            if viewerIsAuthor {
                let key = location.name ?? location.district!
                buckets[key, default: []].append(entry)
            } else {
                guard BearyEphemeral.isEffectivelyPublic(entry), let district = location.district else { continue }
                buckets[district, default: []].append(entry)
                districtOnlyKeys.insert(district)
            }
        }
        return buckets.map { key, list in
            BearyLocationMapGroup(key: key, entries: list, isDistrictOnly: districtOnlyKeys.contains(key))
        }.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.key < b.key
        }
    }
}

/// 定位图标铁律（Li 2026-10-30 新令）：一律用 beary-ui 官方包，不许自绘、不用 SF Symbol
/// 做主图标顶替。本函数只返回官方 icon_location，不设任何回退：资产缺失时返回 nil，
/// 调用方按占位处理（按钮保留可点 + VoiceOver 文案，不画替代图、不上线替代视觉）。
/// 已核验：基线 Assets 内确有 icon_location.imageset（@1x/@2x/@3x、template 渲染，
/// 单线手绘定位针），故本批实际不缺图标，nil 分支只是防资产被误删的 fail-safe。
enum BearyLocationIcon {
    static func image(pointSize: CGFloat) -> UIImage? {
        return BearyIconImages.image(named: "icon_location", pointSize: pointSize)
    }
}

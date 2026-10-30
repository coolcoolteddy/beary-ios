import Foundation
import UIKit
import MapKit
import CoreLocation

// ===== 埋进地图的时间胶囊（2026-10-30；预览 beary-new-features-star-map-time-capsule.html 第 4/5/6 屏）=====
// 口径（任务书定版；预览暂定口径在下面逐项标“未定”）：
// - 只存三样：胶囊标记（capsule_buried，INT 0/1）+ 解锁日期（capsule_unlock_date，文本 YYYY-MM-DD，日粒度）
// + 埋的区级快照（capsule_district，文本）。不存精确经纬度、不存详细地址；埋点区级是发布时的快照，
// 之后改位置/清位置都不动它——复用 location_district 当埋点是逻辑漏洞（改位置会悄悄挪走胶囊），故必须单独立字段。
// - 地图标记只按区级文本现场地理编码（与批 E 地图同款：坐标只活在本页内存，随页销毁，永不写盘）。
// - 解锁是双条件 AND，缺一不可：① 已到解锁日期（本地日粒度，now >= 解锁日 00:00）；
// ② 当前定位逆地理编码出的区级与埋的区级一致。判定只用“是否同一区级”这个 yes/no 在本机比对，
// 精确坐标不上传、不比对、不进任何请求体。
// - 解锁后向谁开放：本批暂按预览口径 = 原可见性（公开篇向所有人、私密篇仅作者）。
// 私密篇解锁后仍仅作者可见，等于“解锁”对他人无变化——若 Li 要的是“解锁即公开”，须另定并改
// BearyTimeCapsule.audienceAfterUnlock 与服务端可见性规则，本批不擅自把解锁写成改公开。
// - 胶囊篇不计普通统计与那年今日（见 BearyProfilePersonalLogic 两处过滤；月历/随机漫步/年度回顾
// 不在本批任务范围内，不动——若 Li 要全量排除，须另批）。
// - 生命周期（本批 App 端 + 后端字段说明 ios/Docs/time-capsule-fields.md）：
// 公开翻私密、进回收站、彻底删除时胶囊同步下线：App 端地图只渲染有效公开的胶囊（下线即标记消失）；
// 服务端须在上述三 transition 上清掉三字段（否则恢复/重公开会悄悄复活胶囊，见“逻辑漏洞”）。
// 编辑（PUT）不碰胶囊字段：15 分钟内改正文/改位置都不改埋点与解锁日期。
// - 后端字段迁移未上线：App 端先行透传（与批 E location 同款已知缺口）。服务端忽略未知键时，
// 发布后胶囊不持久化、重拉即消失；取消埋藏同理可能不持久化。缺口在 PR 说明与回报里明说，不背。

/// 胶囊新图标：只引用 imageset 名，不自绘、不用 SF Symbol 做主图标。
/// icon_time_capsule / icon_district_range 两套 imageset 已由 #229 注册进 Assets.xcassets：
/// 本函数在资产缺失时返回 nil，调用方按占位处理（文字标注，不画替代图、不上线替代视觉），
/// 与批 E BearyLocationIcon 的 fail-safe 口径一致。
enum BearyTimeCapsuleIcon {
static func timeCapsuleImage(pointSize: CGFloat) -> UIImage? {
return BearyIconImages.image(named: "icon_time_capsule", pointSize: pointSize)
}

static func districtRangeImage(pointSize: CGFloat) -> UIImage? {
return BearyIconImages.image(named: "icon_district_range", pointSize: pointSize)
}
}

enum BearyTimeCapsule {
/// 解锁日期存储格式：YYYY-MM-DD（日粒度，无时分，避免时区把“当天”算错一天）。
static let dateFormat = "yyyy-MM-dd"

static func dateFormatter() -> DateFormatter {
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.dateFormat = dateFormat
return formatter
}

static func string(from date: Date) -> String {
return dateFormatter().string(from: date)
}

static func date(from string: String?) -> Date? {
guard let string = string?.trimmingCharacters(in:.whitespacesAndNewlines),!string.isEmpty else { return nil}
return dateFormatter().date(from: string)
}

/// 区级归一化：去首尾空白 + 删全部空白字符后比对。只做空白归一，不做模糊/包含匹配——
/// “鄞州”包含于“鄞州区”不算一致（包含匹配会把邻区误判为同一区，是隐私漏洞）；也不做拼音/简繁转换，
/// 埋与验须用同一派生函数（BearyLocationDisplay.district(from:)）才有同一字符串。
static func normalizeDistrict(_ district: String?) -> String? {
guard let raw = district else { return nil}
let stripped = raw.filter {!$0.isWhitespace}
return stripped.isEmpty? nil: stripped
}

static func districtsMatch(_ buried: String?, _ current: String?) -> Bool {
guard let a = normalizeDistrict(buried), let b = normalizeDistrict(current) else { return false}
return a == b
}

/// 是否埋了胶囊（不论可见性、不论字段是否完好）：统计排除与“胶囊篇”判定用它。
static func isBuried(_ entry: Entry) -> Bool {
return entry.capsuleBuried == 1
}

/// 地图上是否作为胶囊标记渲染：埋了 + 有效公开 + 非占位。
/// 私密态不渲染（公开翻私密即下线；私密时埋的胶囊处于休眠，公开后才出现——不是被删，
/// 但服务端在公开→私密 transition 上清字段时则永久下线，见字段说明；两者区别在回报里明说）。
/// 占位（他人视角私密占位）永不渲染。
static func isActive(_ entry: Entry) -> Bool {
guard isBuried(entry), entry.placeholder!= true else { return false}
return BearyEphemeral.isEffectivelyPublic(entry)
}

/// 统计/那年今日排除：只要埋了就排除，不论解锁与否（解锁态依赖 viewer 当下区级，纯函数算不出，
/// 且任务书口径就是“胶囊篇不计”）。取消埋藏后字段清掉，自然重新计入。
static func isExcludedFromStats(_ entry: Entry) -> Bool {
return isBuried(entry)
}

static func capsuleEntries(from entries: [Entry]) -> [Entry] {
return entries.filter { isActive($0)}
}

static func nonCapsuleEntries(from entries: [Entry]) -> [Entry] {
return entries.filter {!isActive($0)}
}

/// 解锁日期是否已到：日粒度，now >= 解锁日当天 00:00（设备时区）。“今天解锁”当天即满足日期条件。
static func isDateReached(unlockDate: Date, now: Date = Date()) -> Bool {
return now >= Calendar.current.startOfDay(for: unlockDate)
}

/// 解锁评估。currentDistrict == nil 表示“无法确认当前区级”（未授权/定位失败/逆地理编码失败），
/// 与“确认不在该区”严格区分：前者是未知（fail-closed，仍锁定，但文案须说无法确认而非不在该区），
/// 后者才是确定的不满足。把 nil 当成不在该区是文案漏洞（用户明明在该区却被告知不在）。
enum UnlockEvaluation {
case malformed
case unlocked
case dateNotReached
case notInDistrict
case neitherCondition
case districtUnknown
}

static func evaluate(entry: Entry, now: Date = Date(), currentDistrict: String?) -> UnlockEvaluation {
guard isBuried(entry),
let district = normalizeDistrict(entry.capsuleDistrict),
let unlockDate = date(from: entry.capsuleUnlockDate) else {
return.malformed
}
_ = district
let dateOK = isDateReached(unlockDate: unlockDate, now: now)
guard let current = currentDistrict else {
// 日期已到但区级未知时仍不能解锁；日期未到时先报日期问题（区级未知不掩盖日期未到）。
return dateOK?.districtUnknown:.dateNotReached
}
let districtOK = districtsMatch(entry.capsuleDistrict, current)
switch (dateOK, districtOK) {
case (true, true): return.unlocked
case (false, false): return.neitherCondition
case (false, true): return.dateNotReached
case (true, false): return.notInDistrict
}
}

/// 解锁后向谁开放（预览暂定口径，见文件头）：只按原可见性，不因解锁改可见性。
enum UnlockedAudience {
case everyone
case authorOnly
}

static func audienceAfterUnlock(entry: Entry) -> UnlockedAudience {
return BearyEphemeral.isEffectivelyPublic(entry)?.everyone:.authorOnly
}

/// 非作者在未解锁时唯一能看到的文案（标题/内容/图片/心情一律不进弹卡，见 SheetVC：它根本不读这些字段）。
static let placeholderTitle = "这里埋着一篇日记"

static func unlockDateText(entry: Entry) -> String? {
guard let raw = entry.capsuleUnlockDate?.trimmingCharacters(in:.whitespacesAndNewlines),!raw.isEmpty else { return nil}
return raw
}
}

/// 地图上的胶囊标记：用子类与普通地点标记区分（普通标记按标题文本找组，标题若与区级重名会撞组；
/// 胶囊一律走本类，viewFor/didSelect 先判本类，绝不按标题回查普通组——否则他人点胶囊可能进普通日记列表泄题）。
final class BearyCapsuleAnnotation: MKPointAnnotation {
var entry: Entry

init(entry: Entry, coordinate: CLLocationCoordinate2D) {
self.entry = entry
super.init()
self.coordinate = coordinate
}
}

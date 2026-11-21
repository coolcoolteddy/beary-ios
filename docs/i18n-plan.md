# beary 多语言计划（i18n）

Li 2026-11-19 定：String Catalog（.xcstrings）抽字符串，中文当原文，先只翻英文；
App 跟随系统语言；设置页语言行留着；关键文案英文由 Li 定；CI 加防硬编码回潮检查。
2026-11-21 改（Li 定，B1）：catalog key 由中文原文改语义 key，中文只作 source value——
中文文案以后随便改都不丢翻译。
地基 PR：多语言地基＋生物识别锁样板（分支 `fix/i18n-foundation`）。

## 一、清点（基线 main e06c8cb0，2026-11-19）

清点脚本：`~/workspace/i18n-inventory.py`（不在仓库内；口径见下）。
范围：`ios/App/App/*.swift` 共 106 个文件，其中 70 个文件含中文。

| 口径 | 数 |
| --- | --- |
| 硬编码中文字符串字面量（出现次数） | **2810 处** |
| 去重文案 | **1742 条** |
| 其中日期格式串（`M月d日` / `yyyy年M月d日` 等，不进 catalog，见下） | 19 条去重 |
| 可翻译文案（去重，估） | **约 1723 条** |
| 疑似非用户可见（print / log / assert 行内中文） | 0 处 |

口径说明：

- 只计字符串字面量里的中文（CJK），注释已排除；`\(...)` 插值段已剔除，
  插值前后的中文片段仍计（如 `"第\(n)天"` 计 `"第天"`——迁移时须改成
  `%@` 格式串，不可直接包 NSLocalizedString）；
- 单字字面量 96 条去重，多为插值间的连接字（`与` / `、 `）或星期/数字
  （`日 一 二…`），迁移时并入所在格式串处理，不单独成 key；
- 日期格式串不进 catalog：`DateFormatter.dateFormat = "M月d日"` 这类
  是格式模板不是文案，后续各批改走 `setLocalizedDateFormatFromTemplate`
  或按 locale 选模板；
- LaunchScreen.storyboard 里的中文只有注释，无用户可见文案；
- 全站无 `.xcstrings`、无 `.strings`，只有 #1990 未合入分支里一处
  NSLocalizedString；其余文案全是硬编码中文。

### 分模块数（出现次数 / 去重文案数）

| 模块 | 出现 | 去重 | 主力文件 |
| --- | --- | --- | --- |
| 设置/账号/登录 | 445 | 302 | BearySettingsViewController 259、BearyLoginViewController 55 |
| 写日记/编辑器 | 413 | 275 | BearyComposerViewController 239 |
| 个人页/资料 | 362 | 309 | BearyProfileViewController 209、BearyProfilePersonalModules 135 |
| 日记详情/卡片 | 264 | 185 | BearyDiaryStarMapViewController 69、BearyDetailViewController 48 |
| 时间线/首页 | 225 | 178 | BearyTimelineViewController 114 |
| 消息/私信 | 158 | 94 | BearyNotificationsViewController 66、BearyDMChatViewController 44 |
| 盲盒/表情/贴纸 | 83 | 63 | BearyBlindBoxFlowViewController 68 |
| 搜索/发现 | 82 | 49 | BearySearchViewController 82 |
| 好友/关注 | 74 | 52 | BearyInviteViewController 48、BearyWishWallViewController 49 |
| 回收站/草稿箱 | 60 | 41 | BearyTrashViewController 60、BearyDraftBoxViewController 60 |
| 公告/引导/新手 | 36 | 28 | BearyOnboardingViewController 35 |
| 通用组件/弹窗 | 36 | 29 | BearyConfirmSheet / BearyBottomSheet 等 |
| Plus/会员 | 18 | 17 | BearyPlusPageViewController 18 |
| 同步/网络/存储 | 14 | 12 | BearyAPI 9 |
| 其他（共享/导航壳） | 540 | 463 | BearyNativeCommon 319、SceneDelegate 63 |

## 二、方案

### Catalog

- 位置：项目级 `ios/App/App/Localizable.xcstrings`（App target Resources，
  已在 pbxproj 注册）；一个 catalog 管全站，不按模块拆文件——
  key 是语义 key，各批共用同一 key 可复用翻译。
- key 命名约定：`<模块>.<snake_case 目的>`（如 `app_lock.unlock`、
  `settings.language.title`），模块名与功能区对应；key 一旦合入不再改名，
  改名即丢翻译。中文文案改只改该 key 的 `zh-Hans` 值，不动 key；
  同一中文在不同语境含义不同时用不同 key 区分，不再靠 `comment` 区分。
- `sourceLanguage = zh-Hans`；每条 key 同时写 `zh-Hans`（中文原文，
  source value）与 `en`（翻译，状态 `translated`）。
  注意：key 不是文案，catalog 里缺 key 时运行时显示 key 本身、不回落中文——
  新 key 进 catalog 与调用点须同一批进，测试的 en 非空断言守着。
- pbxproj：`developmentRegion = zh-Hans`（中文是开发语言，之前是 en）、
  新增 `knownLocalizations = (en, zh-Hans)`、`knownRegions` 补 `zh-Hans`；
  `Info.plist` 的 `CFBundleDevelopmentRegion` 同步改 `zh-Hans`——
  系统语言不在支持列表里时回落中文（不是英文）。

### 代码写法（统一口径，二选一已定：NSLocalizedString）

- 部署目标 iOS 15，`String(localized:)`（需 iOS 16+）不可用；
  全站统一 `NSLocalizedString("语义 key", comment: "")`，
  与 #1990 既有的一处写法一致。
- 插值一律改 `String(format:)`：`"使用\(name)解锁"` →
  `String(format: NSLocalizedString("app_lock.unlock_with_biometry", comment: ""), name)`。
  禁止把插值留在 NSLocalizedString 的 key 里（运行时 key 会带入变量值，
  catalog 查不到）。
- `comment:` 写 `""` 即可。
- 抽取方式：Xcode → Product → Export Localizations（认 NSLocalizedString，
  自动补 key 进 catalog）；或手工按 key 追加 JSON（key 按字母序排，
  与 Xcode 导出格式保持一致）。禁止手写 `.strings` 文件。

### CI 防回潮检查

- 脚本：`scripts/check-i18n-hardcoded.py`；workflow 新 job `i18n-guard`
 （只加 job，不动原有 test / sideload / simulator 三 job；跑在
  `ubuntu-latest`，`pull_request` 才跑，`fetch-depth: 0`）。
- 只查本 PR diff 的**新增行**：新增行里出现 `NSLocalizedString` /
  `String(localized:)` 之外的中文字符串字面量即失败；写进界面文案位置
  （`.text`／`.title`／`setTitle(`／`.placeholder`／`accessibilityLabel`／
  `accessibilityHint`／`UIAlertController` 的 `title:`／`message:`）的英文
  literal 同样失败，品牌词 beary／Plus 本身除外。
  不扫存量——队里排队 PR 不会因此变红；但排队 PR 若新增中文文案，
  合入本 PR 后 rebase 即触发检查，须改走 NSLocalizedString。
- 豁免：注释、`dateFormat =` 格式串、`BearyI18nCatalogTests.swift`
  （以中文原文作期望值断言，中文是测试数据本身）。

### 样板模块（本 PR 已做）

- `BearyAppLock.swift`（生物识别锁）：14 处调用、13 条 key 去重
  （`解锁` 一处作按钮标题、一处作无障碍标签，共用一 key）。
  选它因为：字符串少、自包含、队里其他 PR 很少碰（上次改动 #1393）；
  其 `coldStartNote` 常量锁屏与设置页详情共用，改一处两处同受益。
- 测试：`ios/App/BearyCoreTests/BearyI18nCatalogTests.swift`。
  测试 target 无宿主 App、catalog 不在测试包内，故直接读仓库里的
  xcstrings JSON 断言：sourceLanguage 为 zh-Hans；样板 13 条 key 的
  zh 值为中文原文（与期望值表一致）、en 非空且与中文不同、`%@` 个数中英一致；
  外加全 catalog 扫一遍（任一 key 缺 en 即失败）。
- 真机待验（未验证，不谎称已验）：Li 手机切系统语言为英文，
  锁屏应显示英文（Unlock / Unlock with Face ID 等），切回中文正常；
  其余模块仍是中文（只迁了样板）。

## 三、分批计划（地基合入后，每批一支 PR、一批一合）

每批：迁移该批文件 → catalog 追加 key（key 按命名约定取，中文作 source value；
en 由 Li 定版后填，未定版前先写草稿并标待定）→ `BearyI18nCatalogTests` 的样板 key 表
按需扩展（全 catalog 的 en 非空断言已覆盖新 key）→ 等 main CI 绿再合下一批。
语言行选项改动在 B6。

| 批 | 内容 | 约出现次数 | 依赖/备注 |
| --- | --- | --- | --- |
| B1 | 样板：BearyAppLock | 14 | 本 PR 已做 |
| B2 | 导航壳＋通用组件：SceneDelegate、BearyToast、BearyConfirmSheet、BearyBottomSheet 等 | 约 100 | 等 #1990 合入（它改 SceneDelegate） |
| B3 | 时间线/首页：BearyTimelineViewController、BearyFeedViewController、BearyDiaryCardCell、BearyQuoteCardView | 约 190 | 无 |
| B4 | 日记详情/卡片/星图：BearyDetailViewController、BearyDiaryStarMapViewController、BearyDiaryMapViewController、BearyStarMap、BearyDiaryPin | 约 210 | 无 |
| B5 | 写日记/编辑器：BearyComposerViewController、BearyComposerPickers、BearyLocationPopoverView、BearyPublishCenter | 约 310 | 无 |
| B6 | 设置/账号/登录：BearySettingsViewController、BearySettingsSubpages、BearyLoginViewController、BearyEditProfileViewController；**含语言行选项改动** | 约 420 | 等 #1990 合入（它重组设置页）；语言行见下 |
| B7 | 个人页：BearyProfileViewController、BearyProfilePersonalModules、BearyProfilePhotosViewController | 约 360 | 无 |
| B8 | 消息/私信/通知：BearyDMChatViewController、BearyDMConversationsViewController、BearyMessagesViewController、BearyNotificationsViewController、BearyLocalNotifications | 约 160 | 无 |
| B9 | 搜索/发现/好友：BearySearchViewController、BearyFriendsViewController、BearyInviteViewController、BearyWishWallViewController | 约 205 | 无 |
| B10a | 回收站/草稿箱/引导/公告/快照：BearyTrashViewController、BearyDraftBoxViewController、BearyOnboardingViewController、BearyAnnouncementCenter、BearySnapshot* | 约 200 | 无 |
| B10b | 共享＋盲盒/表情/Plus：BearyNativeCommon（319，含表情名大表）、BearyBlindBox*、BearyEmote*、BearyPlusPageViewController | 约 430 | 等 #1990 合入（它改 BearyNativeCommon） |

### 语言行改动（B6，随设置页迁移批做）

- 现状：语言行在 #1990 未合入分支的新文件
  `BearySettingsPreferences.swift`（`语言（通用 → 语言子页）：跟随系统 /
  中国大陆（强制简体中文）`），带一套强制切语言机制
  （写档 → 换 `Bundle.main` 的类 → 发广播重建根界面）。
- B6 改动：选项改成**跟随系统／简体中文／English**三档，
  `中国大陆` 写法删除。
- 待 Li 定（B6 开工前）：简体中文／English 两档是否沿用 #1990 已有的
  强制语言机制（切语言后重建根界面），还是仅作展示、实际只跟随系统。
  本 PR 不碰 #1990 的任何文件，不预设结论。

## 四、待 Li 定的关键文案（中文原文＋英文草稿，仅供定版参考）

英文全部是草稿，**未定版**；Li 定版后填进 catalog。
品牌标语 `日子值得记得` 不在 App 代码里（官网/商店物料用），
英文同样待定，一并列出。

### 样板模块（本 PR 已进 catalog，英文为草稿）

| 语义 key | 中文原文 | 英文草稿 |
| --- | --- | --- |
| app_lock.cold_start_note | 冷启动时验证一次；切到别的 App 再回来不重复。 | Verify once on a cold start. Switching to another app and back won't ask again. |
| app_lock.face_id | 面容识别 | Face ID |
| app_lock.touch_id | 触控 ID | Touch ID |
| app_lock.biometrics | 生物识别 | Biometrics |
| app_lock.biometry_not_enrolled | 设备未录入%@，请先在系统设置中录入 | %@ isn't set up on this device. Set it up in Settings first. |
| app_lock.biometry_not_available | 此设备不支持生物识别 | This device doesn't support biometrics |
| app_lock.passcode_not_set | 设备未设置密码，请先在系统设置中设置密码 | No device passcode is set. Set one in Settings first. |
| app_lock.biometry_unavailable | 此设备暂无法使用生物识别 | Biometrics is temporarily unavailable on this device |
| app_lock.locked | beary 已锁定 | beary is locked |
| app_lock.unlock_with_biometry | 使用%@解锁 | Unlock with %@ |
| app_lock.unlock | 解锁 | Unlock |
| app_lock.unlock_beary_with_biometry | 使用%@解锁 beary | Use %@ to unlock beary |
| app_lock.verification_failed | 验证未通过，请再试一次，也可用设备密码解锁 | Verification failed. Try again, or use your device passcode to unlock. |

### 品牌文案与主按钮、空态（后续各批，英文为草稿）

| 中文原文 | 出处 | 英文草稿 |
| --- | --- | --- |
| 日子值得记得 | 主标语（官网/商店物料，不在 App 代码里） | Days worth remembering |
| 把日子留在这里 | 时间线空白页主句 | Keep your days here |
| 写一点，留一点 | 编辑器空态／每日提醒 | Write a little, keep a little |
| 欢迎回来 | 登录页标题 | Welcome back |
| 在这里写日记 | 新手引导第 0 页标题 | Write your diary here |
| 用小熊回应这篇日记。 | 新手引导 P3 副标题 | Let the little bear respond to this entry. |
| 这里还没有星星 | 星图空态 | No stars here yet |
| 写下第一篇，它会出现在这里 | 时间线空白页副标题 | Write your first entry, and it will show up here |
| 写一篇 | 时间线空白页按钮 | Write one |
| 写下第一篇 | 新手引导末页按钮 | Write your first entry |
| 登录，开始记录 | 新手引导末页按钮（未登录） | Log in to start writing |
| 下一步 | 新手引导按钮 | Next |
| 跳过 | 新手引导按钮 | Skip |
| 发布 / 保存 | 编辑器主按钮 | Post / Save |
| 发布中… / 保存中… | 编辑器进行态 | Posting… / Saving… |
| 广场 / 正在关注 | 首页顶栏切换 | Plaza / Following |
| 时间线 / 首页 / 消息 / 我的 | 底栏四 tab | Timeline / Home / Messages / Me |
| 取消 / 删除 / 发送 | 通用按钮 | Cancel / Delete / Send |
| 置顶 | 日记卡片菜单 | Pin |
| 限时结束了，这篇日记已自动转回私密。 | 限时日记到期通知 | Your time-limited entry has expired and is private again. |
| 今天还没有写日记，写一点，留一点。 | 每日提醒通知 | You haven't written today. Write a little, keep a little. |
| 往年今天，你写过日记，打开看看吧。 | 那年今日通知 | On this day in past years, you wrote. Take a look. |

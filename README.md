# beary iOS 壳

beary 的 iOS 壳工程（Capacitor），内嵌 WKWebView，打开线上站 `https://teddyhn.com/beary`。
网页与后端不动，壳只负责把它装进一个 iOS App。

- Bundle ID：`com.teddyhn.beary`（与安卓壳一致）
- App 名：beary

## 云构建

`.github/workflows/ios.yml`：每次推 main 自动在 GitHub 的 macOS 机器上构建，
产物为模拟器版 `App.app`（未签名，仅用于验证构建流程），见 Actions 页的 Artifacts。

公开仓库的 macOS 构建免费无限量；私有仓库每月约 200 分钟 macOS 额度。

## 侧载到真机（免费，无需开发者账号）

工作流每次推 main 还会编一个真机包，产物为 `beary-ipa`（beary.ipa，未签名）。
在 Windows 电脑上用 Sideloadly + 自己的 Apple ID 安装到 iPhone（Sideloadly 会用免费证书签名）：
- 免费证书 7 天过期，到期后重新装一次；免费账号最多 3 个侧载 App。
- 装完后在 iPhone 设置 → 通用 → VPN 与设备管理里信任自己的 Apple ID 证书。
- Apple ID 只填在自己的电脑上，不要发给任何人。

## 本地构建（需要 Mac）

```sh
npm install
npx cap sync ios
npx cap open ios
```

## 尚未做的事

- 签名 / TestFlight / App Store 上架：需要付费 Apple Developer 账号，证书与描述文件进仓库 Secrets 后再接。
- 正式 App 图标：现用主屏幕触控图标放大到 1024 的测试版，上架前需 1024 原图。
- 举报 / 拉黑（App Store 1.2 条要求）、推送（APNs）：后续按需接。
- 当前壳加载的是线上站；正式上架前需评估 4.2 条（纯套壳网站）风险，必要时再加原生能力。

## 原生栏（App 专属，网页版不动）

- 顶栏、底栏胶囊、FAB 由壳内原生视图实现（`ios/App/App/SceneDelegate.swift`），iOS 26+ 用官方液态玻璃 `UIGlassEffect`，低版本自动降级系统毛玻璃。
- 网页只在检测到原生壳时才藏自己的栏并推送状态（`bearyChrome` 消息：当前 tab、未读数、栏显隐、登录态、头像、主题），浏览器打开网页版零变化。
- 原生分享面板、点赞/收藏/回应轻震、发布成功震动也在这批接好；状态栏跟随网页主题。

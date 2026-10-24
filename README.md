# beary iOS 壳

beary 的 iOS 壳工程（Capacitor），内嵌 WKWebView，打开线上站 `https://teddyhn.com/beary`。
网页与后端不动，壳只负责把它装进一个 iOS App。

- Bundle ID：`com.teddyhn.beary`（与安卓壳一致）
- App 名：beary

## 云构建

`.github/workflows/ios.yml`：每次推 main 自动在 GitHub 的 macOS 机器上构建，
产物为模拟器版 `App.app`（未签名，仅用于验证构建流程），见 Actions 页的 Artifacts。

公开仓库的 macOS 构建免费无限量；私有仓库每月约 200 分钟 macOS 额度。

## 本地构建（需要 Mac）

```sh
npm install
npx cap sync ios
npx cap open ios
```

## 尚未做的事

- 签名 / TestFlight / App Store 上架：需要付费 Apple Developer 账号，证书与描述文件进仓库 Secrets 后再接。
- 正式 App 图标：现用主屏幕触控图标放大到 1024 的测试版，上架前需 1024 原图。
- 举报 / 拉黑（App Store 1.2 条要求）、推送（APNs）、原生分享：后续按需接。
- 当前壳加载的是线上站；正式上架前需评估 4.2 条（纯套壳网站）风险，必要时加原生能力。

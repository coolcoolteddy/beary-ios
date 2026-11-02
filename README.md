# beary iOS App

beary 的 iOS App：纯原生实现（Swift / UIKit），与网页版共用同一套 Cloudflare 后端、账号与日记数据，不内嵌网页、不加载线上站。

- Bundle ID：`com.teddyhn.beary`
- App 名：beary
- 部署目标：iOS 15；支持 iPhone、iPad（含横屏）
- 对外版本：0.1（构建号与包号一致，设置页底部显示“版本 0.1（构建号 N）”）

## 功能

- 写日记：默认私密；私密／仅好友／公开／限时四档，编辑限 15 分钟，删除进回收站 30 天
- 广场、正在关注、时间线、个人页、搜索
- 关注／好友、仅好友可见、私信（纯文字）
- 日记盲盒、星图、年度回顾、那年今日、写给过去的自己
- 举报、拉黑
- 游客模式：不登录可浏览公开日记，登录后解锁完整版

## 本地构建（需要 Mac + Xcode）

```sh
git clone https://github.com/coolcoolteddy/beary-ios
```

用 Xcode 打开 `ios/App/App.xcodeproj`，选模拟器或真机，点 ▶ 运行。

注：仓库里仍留有早期 Capacitor 壳的残留文件（如 `capacitor.config.json`、`www/`），当前 App 不使用它们。

## 持续集成

`.github/workflows/ios.yml`：推 main 与手动触发时，在 GitHub 的 macOS 机器上跑三个 job（simulator／test／sideload），验证构建与测试。

注意：公开仓库 macOS 构建免费，但 macOS Runner 容量紧张时 job 可能排队久、偶发抢不到 Runner（与代码无关，重跑即可）。

## 出包与安装

- 日常改动合入 main，不一个 bug 一个包。
- 正式包走 Codemagic 手动触发（工作流 ios-sideload），构建号与包号一致；每包除直接发包外，同步传一份到本仓库 Releases（从 0.1-120 起），安装包命名为 `beary-ipa-<包序号>-<提交短 hash>.zip`。
- 真机安装：全能签手机端签名安装（免费证书 7 天过期，到期后重新装一次）。

## 尚未做的事

- TestFlight / App Store 上架、推送：需要付费 Apple Developer 账号。
- 正式 App 图标：待定。

## 相关链接

- 线上日记站：https://teddyhn.com/beary
- 主站：https://teddyhn.com

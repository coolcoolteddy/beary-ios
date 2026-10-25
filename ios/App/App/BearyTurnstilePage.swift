import Foundation
import UIKit
import WebKit

// ===== 原生登录的人机验证极小内嵌页（一次性补齐；只新建，不改其他文件）=====
// Turnstile 没有原生组件，所以这里用 WKWebView 跑一段本地 HTML 字符串：
// 该字符串只含 Turnstile widget，不加载 teddyhn.com/beary 网页，
// 不复用任何网页界面，不出现网页版任何文案与样式；唯一对外请求是 Turnstile
// 自己的脚本 https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit。
//
// hostname 说明（必读）：accounts 端 siteverify 要求 hostname 严格等于 teddyhn.com
//（worker.js 的 TURNSTILE_EXPECTED_HOSTNAME），widget 实际跑在哪个 origin 就按哪个
// hostname 去校验。因此 loadHTMLString 必须以 baseURL https://teddyhn.com/ 加载：
// 这里只借这个 hostname，绝不加载该站任何内容（HTML 字符串是本地的）。
//
// 一次性使用：一个 BearyTurnstilePage 只跑一次 requestToken；token 是单次有效的，
// 发码成功或失败后调用方都应丢弃本对象，下次发码新建一个。
//
// U0 两段式（客户端过渡方案）:
// 1. 先跑 invisible widget（无感通过时全程无界面，行为与原来一致）；
// 2. 无感失败或 30 秒执行超时时，不再空循环重试——若调用方给了 challengeHostView，
//    把 webView 以可见尺寸挂到该宿主上并重渲为 normal 尺寸 widget 供用户完成挑战，
//    卡片带“取消”入口（取消走失败回调，登录页复位按钮态）；挑战 120 秒未完成则失败。
//    未给宿主时仍直接失败（行为与原来一致），绝不静默重试。
// 服务端调用一律不动：只改验证 widget 的呈现方式，不改发码/验码接口。
//
// 清单第 12 项结论（blocked，卡片保留不动）：拿掉可见验证卡片后，无感失败或
// 超时且必须人工交互的用户将无路可走，故卡片行为本次一律不改，见下：
// 现行 requestToken 建的 WKWebView 从未加进任何视图层级（frame 为 zero，
// 仅在 showChallenge 里才挂到宿主上），invisible widget 即便在需要交互时
// 自带挑战弹窗，也只能渲染在离线 zero 尺寸 webView 里，用户既看不见也点不到；
// 静默重建新页面再跑一次 invisible 也不会改变判定输入（同一设备、同一默认
// 数据存储、同一 IP、同一 sitekey、无新增交互信号），对持续被判定需交互的
// 用户只会重复失败；且发码在服务端 enforce 模式下缺有效 token 必被拒，
// 原生内没有短信、邮件链接等第二条验证通道。所以卡片移除需 Li 另定替代
// 通过路径后才能做，本次只落地与卡片去留无关的失败原因区分：执行或挑战
// 超时报 verificationTimeout，挑战取消报 cancelled，不再笼统报验证失败。

final class BearyTurnstilePage: NSObject {
    enum TokenError: Error {
        case loadTimeout
        case scriptFailed
        case verificationTimeout
        case cancelled
        case failed

        /// 与登录页展示文案一一对应：登录页只展示本 message，不另拼文案。
        var message: String {
            switch self {
            case .loadTimeout: return "验证加载超时，请重试"
            case .scriptFailed: return "验证脚本加载失败，请重试"
            case .verificationTimeout: return "验证超时，请重试"
            case .cancelled: return "已取消验证"
            case .failed: return "人机验证失败，请重试"
            }
        }
    }

    typealias TokenCompletion = (Result<String, TokenError>) -> Void

    private enum Phase {
        case loadingScript
        case executing
        case challenge
    }

    private static let siteKey = "0x4AAAAAAFWOrIUH9C6y45it"
    private static let scriptSource = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
    private static let handlerName = "bearyTurnstile"
    private static let scriptTimeout: TimeInterval = 15
    private static let executeTimeout: TimeInterval = 30
    private static let challengeTimeout: TimeInterval = 120

    /// U0：挑战宿主视图（调用方在 requestToken 前设置，通常是登录页的 view）。
    /// 为 nil 时挑战阶段不可见，直接失败，不重试。
    weak var challengeHostView: UIView?

    private var webView: WKWebView?
    private var pendingCompletion: TokenCompletion?
    private var finished = false
    private var phase: Phase = .loadingScript
    private var timeoutTimer: Timer?
    private var challengeShown = false
    private var challengeOverlay: UIView?

    deinit {
        teardown()
    }

    /// 取一次 Turnstile token。完成回调一律回主线程发。
    func requestToken(completion: @escaping TokenCompletion) {
        if pendingCompletion != nil {
            completion(.failure(.failed))
            return
        }
        guard let baseURL = URL(string: "https://teddyhn.com/") else {
            completion(.failure(.failed))
            return
        }
        pendingCompletion = completion
        finished = false
        phase = .loadingScript

        let configuration = WKWebViewConfiguration()
        // 默认数据存储（非 nonPersistent）：Turnstile 的信任信号可能依赖 cookie/存储。
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.userContentController.add(self, name: BearyTurnstilePage.handlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.loadHTMLString(BearyTurnstilePage.html, baseURL: baseURL)
        scheduleTimeout(BearyTurnstilePage.scriptTimeout)
    }

    /// 显式取消：只拆 handler、停加载，不回调（用于登录页关闭时）。
    func cancel() {
        pendingCompletion = nil
        teardown()
    }

    private func teardown() {
        finished = true
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        challengeOverlay?.removeFromSuperview()
        challengeOverlay = nil
        if let view = webView {
            view.configuration.userContentController.removeScriptMessageHandler(forName: BearyTurnstilePage.handlerName)
            view.stopLoading()
            view.navigationDelegate = nil
        }
    }

    private func scheduleTimeout(_ interval: TimeInterval) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let strongSelf = self else { return }
            if strongSelf.phase == .loadingScript {
                strongSelf.finish(.failure(.loadTimeout))
            } else if strongSelf.phase == .executing && !strongSelf.challengeShown && strongSelf.challengeHostView != nil {
                // U0：执行超时不再空循环重试，改挂可见挑战。
                strongSelf.showChallenge()
            } else if strongSelf.phase == .executing || strongSelf.phase == .challenge {
                // 第 12 项独立部分：执行 30 秒超时（无宿主时）与挑战 120 秒超时
                // 不再笼统报验证失败，报超时原因；仍不重试。
                strongSelf.finish(.failure(.verificationTimeout))
            } else {
                strongSelf.finish(.failure(.failed))
            }
        }
    }

    /// U0：把 webView 以可见尺寸挂到宿主上，重渲 normal 尺寸 widget 供用户完成挑战。
    /// 挑战卡片带“取消”入口；无宿主或无 webView 时直接失败，不重试。
    private func showChallenge() {
        guard !challengeShown, let host = challengeHostView, let view = webView else {
            finish(.failure(.failed))
            return
        }
        challengeShown = true
        phase = .challenge
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.5)
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface
        card.layer.cornerRadius = 16
        card.clipsToBounds = true
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "人机验证"
        let cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(BearyColors.ink, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(challengeCancelTapped), for: .touchUpInside)
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        overlay.addSubview(card)
        card.addSubview(titleLabel)
        card.addSubview(view)
        card.addSubview(cancelButton)
        let webHeight = view.heightAnchor.constraint(equalToConstant: 300)
        webHeight.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            card.heightAnchor.constraint(lessThanOrEqualTo: overlay.heightAnchor, constant: -40),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            view.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            webHeight,
            cancelButton.topAnchor.constraint(equalTo: view.bottomAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        challengeOverlay = overlay
        view.evaluateJavaScript("window.bearyShowChallenge && window.bearyShowChallenge()") { [weak self] _, error in
            if error != nil {
                self?.finish(.failure(.failed))
            }
        }
        scheduleTimeout(BearyTurnstilePage.challengeTimeout)
    }

    /// U0：挑战取消入口——走取消原因回调让登录页复位，不自动重试，
    /// 也不谎报为验证失败。
    @objc private func challengeCancelTapped() {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<String, TokenError>) {
        guard let completion = pendingCompletion, !finished else { return }
        pendingCompletion = nil
        teardown()
        DispatchQueue.main.async { completion(result) }
    }

    private func handleMessage(_ body: Any) {
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "token":
            if let token = payload["token"] as? String, !token.isEmpty {
                finish(.success(token))
            } else {
                finish(.failure(.failed))
            }
        case "ready":
            // 脚本已到、widget 已渲染，进入执行阶段：执行超时按网页口径走通用失败。
            phase = .executing
            scheduleTimeout(BearyTurnstilePage.executeTimeout)
        case "scriptFailed":
            finish(.failure(.scriptFailed))
        case "failed":
            // U0：无感阶段失败时挂可见挑战（JS 侧已屏蔽旧 widget 在挑战期的滞后回调，
            // 故挑战期收到的 failed 即新 widget 的真实失败，直接结束，不重试）。
            if phase == .executing && !challengeShown && challengeHostView != nil {
                showChallenge()
            } else {
                finish(.failure(.failed))
            }
        default:
            break
        }
    }

    private static var html: String {
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{margin:0}</style>
        <script src="\(scriptSource)" async onerror="window.webkit.messageHandlers.\(handlerName).postMessage({type:'scriptFailed'})"></script>
        </head>
        <body>
        <div id="turnstile-box"></div>
        <script>
        (function(){
        function postToSwift(payload){ try{ window.webkit.messageHandlers.\(handlerName).postMessage(payload); }catch(err){} }
        var started = false;
        var widgetRef = null;
        function start(){
          if(started){ return; }
          if(typeof turnstile === 'undefined'){ return; }
          started = true;
          try{
            widgetRef = turnstile.render(document.getElementById('turnstile-box'), {
              sitekey: '\(siteKey)',
              size: 'invisible',
              callback: function(token){ postToSwift({type: 'token', token: token}); },
              // 挑战期旧 widget 的滞后失败回调一律屏蔽，避免误杀可见挑战。
              'error-callback': function(){ if(window.bearyChallengeActive){ return; } postToSwift({type: 'failed'}); },
              'expired-callback': function(){ if(window.bearyChallengeActive){ return; } postToSwift({type: 'failed'}); },
              'timeout-callback': function(){ if(window.bearyChallengeActive){ return; } postToSwift({type: 'failed'}); }
            });
            postToSwift({type: 'ready'});
            turnstile.execute(widgetRef);
          }catch(err){ postToSwift({type: 'failed'}); }
        }
        // U0：可见挑战——拆掉 invisible widget，重渲 normal 尺寸 widget 供用户点选完成。
        window.bearyShowChallenge = function(){
          if(window.bearyChallengeActive){ return; }
          window.bearyChallengeActive = true;
          if(typeof turnstile === 'undefined'){ postToSwift({type: 'failed'}); return; }
          try{
            if(widgetRef !== null){ try{ turnstile.remove(widgetRef); }catch(err){} }
            var box = document.getElementById('turnstile-box');
            box.innerHTML = '';
            widgetRef = turnstile.render(box, {
              sitekey: '\(siteKey)',
              size: 'normal',
              callback: function(token){ postToSwift({type: 'token', token: token}); },
              'error-callback': function(){ postToSwift({type: 'failed'}); },
              'expired-callback': function(){ postToSwift({type: 'failed'}); },
              'timeout-callback': function(){ postToSwift({type: 'failed'}); }
            });
          }catch(err){ postToSwift({type: 'failed'}); }
        };
        var pollTimer = setInterval(function(){ start(); if(started){ clearInterval(pollTimer); } }, 100);
        })();
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - WK 回调

extension BearyTurnstilePage: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == BearyTurnstilePage.handlerName else { return }
        handleMessage(message.body)
    }
}

extension BearyTurnstilePage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !finished && phase == .loadingScript {
            finish(.failure(.scriptFailed))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !finished && phase == .loadingScript {
            finish(.failure(.scriptFailed))
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !finished {
            finish(.failure(.scriptFailed))
        }
    }
}

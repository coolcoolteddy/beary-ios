import Foundation
import WebKit

// ===== 原生登录的人机验证极小内嵌页（一次性补齐；只新建，不改其他文件）=====
// Turnstile 没有原生组件，所以这里用 WKWebView 跑一段本地 HTML 字符串：
// 该字符串只含一个 Turnstile widget（invisible），不加载 teddyhn.com/beary 网页，
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
// 本对象不把 webView 挂到任何视图层级（invisible widget 本身不占视觉）；
// 若 Cloudflare 要求互动挑战，挑战框无法在无层级的 webView 里被用户看到，
// token 会走到执行超时——这是真机验证前必须确认的最大风险点（见登录页头注释）。

final class BearyTurnstilePage: NSObject {
    enum TokenError: Error {
        case loadTimeout
        case scriptFailed
        case failed

        /// 与网页端 lgGetToken 的区分文案一一对应。
        var message: String {
            switch self {
            case .loadTimeout: return "验证加载超时，请重试"
            case .scriptFailed: return "验证脚本加载失败，请重试"
            case .failed: return "人机验证失败，请重试"
            }
        }
    }

    typealias TokenCompletion = (Result<String, TokenError>) -> Void

    private enum Phase {
        case loadingScript
        case executing
    }

    private static let siteKey = "0x4AAAAAAFWOrIUH9C6y45it"
    private static let scriptSource = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
    private static let handlerName = "bearyTurnstile"
    private static let scriptTimeout: TimeInterval = 15
    private static let executeTimeout: TimeInterval = 30

    private var webView: WKWebView?
    private var pendingCompletion: TokenCompletion?
    private var finished = false
    private var phase: Phase = .loadingScript
    private var timeoutTimer: Timer?

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
            } else {
                strongSelf.finish(.failure(.failed))
            }
        }
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
            finish(.failure(.failed))
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
        function start(){
          if(started){ return; }
          if(typeof turnstile === 'undefined'){ return; }
          started = true;
          try{
            var widgetRef = turnstile.render(document.getElementById('turnstile-box'), {
              sitekey: '\(siteKey)',
              size: 'invisible',
              callback: function(token){ postToSwift({type: 'token', token: token}); },
              'error-callback': function(){ postToSwift({type: 'failed'}); },
              'expired-callback': function(){ postToSwift({type: 'failed'}); },
              'timeout-callback': function(){ postToSwift({type: 'failed'}); }
            });
            postToSwift({type: 'ready'});
            turnstile.execute(widgetRef);
          }catch(err){ postToSwift({type: 'failed'}); }
        }
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

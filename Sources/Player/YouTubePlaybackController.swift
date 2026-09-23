import Foundation
import WebKit
import UIKit
import SwiftUI

/// Drives an embedded YouTube player through the official IFrame Player API.
///
/// Rules this class is built to respect, because they are what make the whole app shippable:
///   * the video is streamed by YouTube's own player — nothing is downloaded, cached or muxed,
///   * no view is ever composited on top of the player's frame,
///   * the audio stream is never tapped or recorded,
///   * links out go to YouTube so watch time and ads are attributed to the rights holder.
///
/// Speed and seeking are first-class parts of the IFrame API (`setPlaybackRate`, `seekTo`), so
/// slow practice and A/B looping on official dance practice videos are fully above board.
final class YouTubePlaybackController: PlaybackController {

    private(set) var videoID: String?
    private(set) var availableRates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    override var capabilities: PlaybackCapabilities { .embeddedYouTube }
    override var sourceLabel: String { "YouTube" }

    /// Set when playback fails in a way the user can route around (embedding off, video gone).
    @Published private(set) var canOpenInYouTube = false

    private var bridgeReady = false
    private var queuedJS: [String] = []

    let webView: WKWebView
    private let proxy: ScriptMessageProxy

    /// Must match the name used in the injected JavaScript.
    fileprivate static let messageName = "practiceRoomPlayer"

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false

        // WKWebView copies its configuration at init, so the message handler has to be attached
        // to the configuration first. WKUserContentController retains handlers strongly, hence
        // the weak proxy — otherwise the controller and its web view keep each other alive.
        let proxy = ScriptMessageProxy()
        config.userContentController.add(proxy, name: Self.messageName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        self.webView = webView
        self.proxy = proxy
        super.init()

        proxy.target = self
        webView.navigationDelegate = self
    }

    deinit {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: YouTubePlaybackController.messageName)
    }

    // MARK: - Loading

    func load(videoID newID: String, startAt seconds: Double = 0, autoplay: Bool = false) {
        // Re-selecting the video already on screen is a seek, not a reload — reloading would
        // throw away the buffer and visibly stutter when the user taps between tutorials.
        if newID == videoID, bridgeReady {
            seek(to: seconds)
            if autoplay { play() }
            return
        }
        videoID = newID
        publish(problem: nil)
        canOpenInYouTube = false

        if bridgeReady {
            let command = autoplay ? "loadVideoById" : "cueVideoById"
            evaluate("player.\(command)({videoId: '\(newID)', startSeconds: \(seconds)});")
        } else {
            publish(ready: false)
            webView.loadHTMLString(
                Self.html(videoID: newID, startSeconds: seconds, autoplay: autoplay),
                baseURL: URL(string: "https://www.youtube.com")
            )
        }
    }

    var watchURL: URL? {
        guard let videoID else { return nil }
        let at = Int(currentTime)
        return URL(string: "https://www.youtube.com/watch?v=\(videoID)&t=\(at)s")
    }

    // MARK: - Commands

    override func play() { evaluate("player.playVideo();") }
    override func pause() { evaluate("player.pauseVideo();") }

    override func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        publish(time: clamped)
        evaluate("player.seekTo(\(clamped), true);")
    }

    override func setRate(_ newRate: Double) {
        // The IFrame API silently ignores rates the current stream does not offer, which would
        // leave the UI showing a speed that is not actually playing. Snap to the nearest offered.
        let snapped = availableRates.min(by: { abs($0 - newRate) < abs($1 - newRate) }) ?? 1.0
        publish(rate: snapped)
        evaluate("player.setPlaybackRate(\(snapped));")
    }

    override func setMuted(_ muted: Bool) {
        evaluate(muted ? "player.mute();" : "player.unMute();")
    }

    override func teardown() {
        evaluate("if (window.stopTicker) { window.stopTicker(); }")
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        bridgeReady = false
        publish(ready: false)
    }

    private func evaluate(_ js: String) {
        guard bridgeReady else {
            queuedJS.append(js)
            return
        }
        DispatchQueue.main.async { [weak webView] in
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func flushQueuedJS() {
        let pending = queuedJS
        queuedJS.removeAll()
        for js in pending { evaluate(js) }
    }

    // MARK: - Bridge messages

    fileprivate func handle(message body: Any) {
        guard let dict = body as? [String: Any], let event = dict["event"] as? String else { return }

        switch event {
        case "ready":
            bridgeReady = true
            publish(ready: true)
            if let d = dict["duration"] as? Double { publish(duration: d) }
            if let rates = dict["rates"] as? [Double], !rates.isEmpty {
                DispatchQueue.main.async { self.availableRates = rates.sorted() }
            }
            flushQueuedJS()

        case "time":
            if let d = dict["duration"] as? Double { publish(duration: d) }
            if let t = dict["time"] as? Double { publish(time: t) }

        case "state":
            guard let raw = dict["state"] as? Int else { return }
            // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            switch raw {
            case 1:
                publish(playing: true); publish(buffering: false)
            case 2:
                publish(playing: false); publish(buffering: false)
            case 3:
                publish(buffering: true)
            case 0:
                publish(buffering: false)
                // A loop that ends at the very end of the video reaches "ended" before the
                // time tick can wrap it, so restart from the loop head rather than stopping.
                if let loop, loop.isUsable {
                    seek(to: loop.start)
                    play()
                } else {
                    reportReachedEnd()
                }
            default:
                publish(buffering: false)
            }

        case "rate":
            if let r = dict["rate"] as? Double { publish(rate: r) }

        case "error":
            let code = dict["code"] as? Int ?? -1
            let problem: PlaybackProblem
            switch code {
            case 101, 150:
                problem = .embeddingDisabled
            case 100:
                problem = .notFound
            case 2:
                problem = .other("That video ID isn't valid.")
            case 5:
                problem = .other("YouTube's player failed to start. Try again.")
            default:
                problem = .other("YouTube returned error \(code).")
            }
            publish(problem: problem)
            DispatchQueue.main.async { self.canOpenInYouTube = true }

        default:
            break
        }
    }

    // MARK: - Player HTML

    private static func html(videoID: String, startSeconds: Double, autoplay: Bool) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
          #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
          var player = null;
          var isReady = false;
          var ticker = null;

          function post(payload) {
            try { window.webkit.messageHandlers.practiceRoomPlayer.postMessage(payload); } catch (e) {}
          }

          function startTicker() {
            if (ticker) { clearInterval(ticker); }
            ticker = setInterval(function () {
              if (!isReady || !player || !player.getCurrentTime) { return; }
              post({ event: 'time', time: player.getCurrentTime(), duration: player.getDuration() });
            }, 100);
          }

          window.stopTicker = function () {
            if (ticker) { clearInterval(ticker); ticker = null; }
          };

          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              height: '100%',
              width: '100%',
              videoId: '\(videoID)',
              playerVars: {
                playsinline: 1,
                controls: 0,
                rel: 0,
                fs: 0,
                disablekb: 1,
                iv_load_policy: 3,
                start: \(Int(startSeconds)),
                autoplay: \(autoplay ? 1 : 0),
                origin: 'https://www.youtube.com'
              },
              events: {
                onReady: function (e) {
                  isReady = true;
                  var rates = [];
                  try { rates = player.getAvailablePlaybackRates(); } catch (err) { rates = [1]; }
                  post({ event: 'ready', duration: player.getDuration(), rates: rates });
                  startTicker();
                },
                onStateChange: function (e) { post({ event: 'state', state: e.data }); },
                onPlaybackRateChange: function (e) { post({ event: 'rate', rate: e.data }); },
                onError: function (e) { post({ event: 'error', code: e.data }); }
              }
            });
          }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body>
        </html>
        """
    }
}

// MARK: - Navigation

extension YouTubePlaybackController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Keep the embed in place. Any attempt to navigate to a real YouTube page (title tap,
        // "Watch on YouTube") leaves the app instead of replacing our player with a web page.
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        UIApplication.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        publish(problem: .network)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        publish(problem: .network)
    }
}

// MARK: - Weak message proxy

private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: YouTubePlaybackController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.handle(message: message.body)
    }
}

// MARK: - SwiftUI host

struct YouTubePlayerSurface: UIViewRepresentable {
    let controller: YouTubePlaybackController

    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

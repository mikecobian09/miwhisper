import SwiftUI
import WebKit

struct CompanionWebView: UIViewRepresentable {
    let url: URL
    let speechController: NativeSpeechController
    let carModeRunWatcher: CarModeRunWatcher
    let carCommandListener: NativeCarCommandListener
    let idleTimerController: NativeIdleTimerController
    @Binding var loadError: String?
    @Binding var isLoaded: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            speechController: speechController,
            carModeRunWatcher: carModeRunWatcher,
            carCommandListener: carCommandListener,
            idleTimerController: idleTimerController,
            loadError: $loadError,
            isLoaded: $isLoaded
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "miwhisperSpeech")
        userContentController.addUserScript(WKUserScript(
            source: Self.nativeBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = userContentController
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        isLoaded = false
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url?.absoluteString != url.absoluteString else { return }
        isLoaded = false
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    static let nativeBridgeScript = #"""
    (() => {
      document.documentElement.dataset.nativeCompanion = "true";
      if (!window.miwhisperNativeSpeech) {
        window.miwhisperNativeSpeech = {
          isAvailable: true,
          speak(payload) {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({
              type: "speak",
              key: payload?.key || "",
              text: payload?.text || "",
              lang: payload?.lang || "es-ES",
              rate: payload?.rate || 0.52,
              pitch: payload?.pitch || 1.0
            });
          },
          stop() {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({ type: "stop" });
          },
          pause() {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({ type: "pause" });
          },
          resume() {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({ type: "resume" });
          }
        };
      }
      if (!window.miwhisperNativeCarMode) {
        window.miwhisperNativeCarMode = {
          isAvailable: true,
          watch(payload) {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({
              type: "carWatch",
              baseURL: payload?.baseURL || location.origin,
              sessionID: payload?.sessionID || "",
              verbosity: payload?.verbosity || "brief"
            });
          },
          stop() {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({ type: "carStop" });
          },
          arm(payload) {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({
              type: "carCommandArm",
              silenceSeconds: payload?.silenceSeconds || 2
            });
          },
          disarm() {
            window.webkit.messageHandlers.miwhisperSpeech.postMessage({ type: "carCommandDisarm" });
          }
        };
      }
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let speechController: NativeSpeechController
        let carModeRunWatcher: CarModeRunWatcher
        let carCommandListener: NativeCarCommandListener
        let idleTimerController: NativeIdleTimerController
        var webView: WKWebView?
        @Binding var loadError: String?
        @Binding var isLoaded: Bool

        init(
            speechController: NativeSpeechController,
            carModeRunWatcher: CarModeRunWatcher,
            carCommandListener: NativeCarCommandListener,
            idleTimerController: NativeIdleTimerController,
            loadError: Binding<String?>,
            isLoaded: Binding<Bool>
        ) {
            self.speechController = speechController
            self.carModeRunWatcher = carModeRunWatcher
            self.carCommandListener = carCommandListener
            self.idleTimerController = idleTimerController
            self._loadError = loadError
            self._isLoaded = isLoaded
            super.init()
            self.speechController.onEvent = { [weak self] event in
                self?.sendSpeechEvent(event)
            }
            self.carCommandListener.onEvent = { [weak self] event in
                self?.sendCarCommandEvent(event)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "miwhisperSpeech",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "speak":
                speechController.speak(
                    text: body["text"] as? String ?? "",
                    key: body["key"] as? String,
                    language: body["lang"] as? String,
                    rate: body["rate"] as? Double,
                    pitch: body["pitch"] as? Double
                )
            case "pause":
                speechController.pause()
            case "resume":
                speechController.resume()
            case "stop":
                speechController.stop()
            case "carWatch":
                if let rawBaseURL = body["baseURL"] as? String,
                   let baseURL = URL(string: rawBaseURL) {
                    carModeRunWatcher.watch(
                        baseURL: baseURL,
                        sessionID: body["sessionID"] as? String ?? "",
                        verbosity: body["verbosity"] as? String ?? "brief"
                    )
                }
            case "carStop":
                carModeRunWatcher.stop()
            case "carCommandArm":
                idleTimerController.setCarModeArmed(true)
                carCommandListener.arm(silenceSeconds: body["silenceSeconds"] as? Double ?? 2.0)
            case "carCommandDisarm":
                carCommandListener.disarm()
                idleTimerController.setCarModeArmed(false)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadError = nil
            isLoaded = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadError = error.localizedDescription
            isLoaded = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadError = error.localizedDescription
            isLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }

        private func sendSpeechEvent(_ event: NativeSpeechController.Event) {
            guard let webView else { return }
            let payload = event.dictionary
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("""
            window.dispatchEvent(new CustomEvent('miwhisper-native-speech', { detail: \(json) }));
            """)
        }

        private func sendCarCommandEvent(_ event: NativeCarCommandListener.Event) {
            if !event.armed {
                idleTimerController.setCarModeArmed(false)
            }
            guard let webView else { return }
            let payload = event.dictionary
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("""
            window.dispatchEvent(new CustomEvent('miwhisper-native-car-command', { detail: \(json) }));
            """)
        }
    }
}

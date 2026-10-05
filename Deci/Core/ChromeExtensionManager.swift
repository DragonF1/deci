import Foundation
import Observation

@Observable
@MainActor
final class ChromeExtensionManager: NSObject {
    static let shared = ChromeExtensionManager()
    
    var chromeTabs: [ChromeTab] = []
    
    private override init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleChromeNotification(_:)),
            name: NSNotification.Name("com.abraham.Deci.FromChrome"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(handleChromeNotification(_:)),
            name: NSNotification.Name("com.example.AdvancedAudioControl.FromChrome"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    
    @objc nonisolated private func handleChromeNotification(_ notification: Notification) {
        let message = notification.object as? String
        Task { @MainActor in
            self.handleChromeMessageString(message)
        }
    }
    
    func handleChromeMessageString(_ messageString: String?) {
        guard let messageString,
              let data = messageString.data(using: .utf8) else { return }
              
        do {
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let type = json["type"] as? String else { return }
                  
            if type == "TAB_LIST", let tabs = json["tabs"] as? [[String: Any]] {
                NSLog("Deci ChromeExtensionManager: TAB_LIST with %ld raw tabs", tabs.count)
                var newTabs: [ChromeTab] = []
                for tab in tabs.prefix(Self.maxTabs) {
                    guard let id = tab["id"] as? Int else { continue }
                    let title = (tab["title"] as? String) ?? ""
                    let favIconUrl = Self.sanitizedFaviconURL(tab["favIconUrl"] as? String)
                    let volume = (tab["volume"] as? NSNumber)?.floatValue ?? 1.0
                    newTabs.append(ChromeTab(
                        id: id,
                        title: String(title.prefix(Self.maxTitleLength)),
                        volume: volume,
                        favIconUrl: favIconUrl
                    ))
                }
                
                // Preserve volume, title/favicon and media states from existing tabs
                for i in 0..<newTabs.count {
                    if let existing = self.chromeTabs.first(where: { $0.id == newTabs[i].id }) {
                        newTabs[i].volume = existing.volume
                        if newTabs[i].title.isEmpty {
                            newTabs[i].title = existing.title
                        }
                        if newTabs[i].favIconUrl == nil {
                            newTabs[i].favIconUrl = existing.favIconUrl
                        }
                        newTabs[i].isMuted = existing.isMuted
                        newTabs[i].volumeBeforeMute = existing.volumeBeforeMute
                        newTabs[i].paused = existing.paused
                        newTabs[i].currentTime = existing.currentTime
                        newTabs[i].duration = existing.duration
                        newTabs[i].lastSyncedAt = existing.lastSyncedAt
                        
                        let titleChanged = !existing.title.isEmpty
                            && !newTabs[i].title.isEmpty
                            && existing.title != newTabs[i].title
                        newTabs[i].songBaselineCurrentTime = titleChanged
                            ? existing.currentTime
                            : existing.songBaselineCurrentTime
                        if titleChanged {
                            self.requestMediaState(tabId: newTabs[i].id)
                        }
                    }
                }
                
                if newTabs != self.chromeTabs {
                    self.chromeTabs = newTabs
                }
            } else if type == "MEDIA_STATE", let tabId = json["tabId"] as? Int {
                let paused = json["paused"] as? Bool ?? false
                let currentTime = (json["currentTime"] as? NSNumber)?.doubleValue ?? 0
                let duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
                
                guard let index = self.chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
                if self.chromeTabs[index].lastSyncedAt == nil {
                    self.chromeTabs[index].songBaselineCurrentTime = currentTime
                }
                self.chromeTabs[index].paused = paused
                self.chromeTabs[index].currentTime = currentTime
                self.chromeTabs[index].duration = duration
                self.chromeTabs[index].lastSyncedAt = Date()
            }
        } catch {
            // parsing error ignored
        }
    }
    
    private static let maxTabs = 200
    private static let maxTitleLength = 300
    private static let maxFaviconLength = 64 * 1024

    private static func sanitizedFaviconURL(_ string: String?) -> String? {
        guard let string, !string.isEmpty, string.count <= maxFaviconLength,
              let url = URL(string: string) else { return nil }
        switch url.scheme?.lowercased() {
        case "https", "http":
            return string
        case "data":
            return string.lowercased().hasPrefix("data:image/") ? string : nil
        default:
            return nil
        }
    }

    func setTabVolume(tabId: Int, volume: Float) {
        if let index = chromeTabs.firstIndex(where: { $0.id == tabId }) {
            chromeTabs[index].volume = volume
            if volume > 0 {
                chromeTabs[index].isMuted = false
            }
        }
        sendMessage([
            "type": "SET_TAB_VOLUME",
            "tabId": tabId,
            "volume": volume
        ])
    }

    func toggleMute(tabId: Int) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
        if chromeTabs[index].isMuted {
            chromeTabs[index].isMuted = false
            let restoreVol = chromeTabs[index].volumeBeforeMute > 0 ? chromeTabs[index].volumeBeforeMute : 1.0
            setTabVolume(tabId: tabId, volume: restoreVol)
        } else {
            chromeTabs[index].volumeBeforeMute = chromeTabs[index].volume
            chromeTabs[index].isMuted = true
            setTabVolume(tabId: tabId, volume: 0.0)
        }
    }

    func requestTabs() {
        NSLog("Deci ChromeExtensionManager: requestTabs() called")
        sendMessage(["type": "GET_TABS"])
    }

    func requestMediaState(tabId: Int) {
        sendMessage(["type": "GET_MEDIA_STATE", "tabId": tabId])
    }

    func togglePlayback(tabId: Int) {
        if let index = chromeTabs.firstIndex(where: { $0.id == tabId }) {
            chromeTabs[index].paused.toggle()
            chromeTabs[index].lastSyncedAt = Date()
        }
        sendMessage(["type": "TOGGLE_PLAYBACK", "tabId": tabId])
    }

    private func sendMessage(_ message: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: message, options: [])
            if let messageString = String(data: data, encoding: .utf8) {
                let center = DistributedNotificationCenter.default()
                center.postNotificationName(
                    NSNotification.Name("com.abraham.Deci.ToChrome"),
                    object: messageString,
                    userInfo: nil,
                    deliverImmediately: true
                )
                center.postNotificationName(
                    NSNotification.Name("com.example.AdvancedAudioControl.ToChrome"),
                    object: messageString,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        } catch {
            // serialization error ignored
        }
    }
}

struct ChromeTab: Identifiable, Equatable {
    let id: Int
    var title: String
    var volume: Float
    var favIconUrl: String?
    var isMuted: Bool = false
    var volumeBeforeMute: Float = 1.0
    var paused: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var lastSyncedAt: Date? = nil
    var songBaselineCurrentTime: Double = 0
}

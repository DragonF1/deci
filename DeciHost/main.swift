import Foundation

class NativeMessagingHost {
    func run() {
        let notificationCenter = DistributedNotificationCenter.default()
        
        let toChromeNames = [
            "com.abraham.Deci.ToChrome",
            "com.example.AdvancedAudioControl.ToChrome"
        ]
        for name in toChromeNames {
            notificationCenter.addObserver(
                self,
                selector: #selector(handleAppNotification(_:)),
                name: NSNotification.Name(name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        
        DispatchQueue.global(qos: .background).async {
            let fileHandle = FileHandle.standardInput
            
            while true {
                let lengthData = fileHandle.readData(ofLength: 4)
                if lengthData.count != 4 { exit(0) }
                
                let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
                let messageData = fileHandle.readData(ofLength: length)
                
                if messageData.count != length { exit(0) }
                
                if let messageString = String(data: messageData, encoding: .utf8) {
                    DispatchQueue.main.async {
                        notificationCenter.postNotificationName(
                            NSNotification.Name("com.abraham.Deci.FromChrome"),
                            object: messageString,
                            userInfo: nil,
                            deliverImmediately: true
                        )
                        notificationCenter.postNotificationName(
                            NSNotification.Name("com.example.AdvancedAudioControl.FromChrome"),
                            object: messageString,
                            userInfo: nil,
                            deliverImmediately: true
                        )
                    }
                }
            }
        }
    }
    
    @objc func handleAppNotification(_ notification: Notification) {
        guard let messageString = notification.object as? String,
              let messageData = messageString.data(using: .utf8) else { return }
              
        var len = UInt32(messageData.count)
        let lengthData = Data(bytes: &len, count: MemoryLayout<UInt32>.size)
        
        FileHandle.standardOutput.write(lengthData)
        FileHandle.standardOutput.write(messageData)
    }
}

let host = NativeMessagingHost()
host.run()
RunLoop.main.run()

import Foundation
import os

class NativeMessagingHost {
    private let log = Logger(subsystem: "com.abraham.deci.host", category: "bridge")

    /// Chrome rejects host-to-extension messages larger than 1 MB.
    private let maxOutgoingBytes = 1_048_576
    /// Messages from the extension larger than this are dropped. A real TAB_LIST is far smaller.
    private let maxIncomingBytes = 8 * 1024 * 1024
    /// Oversize messages up to this size are read and discarded so the stream stays in sync.
    /// A declared length beyond it means the framing cannot be trusted, so the host exits and
    /// Chrome relaunches it on the next connect.
    private let maxDiscardBytes = 64 * 1024 * 1024

    func run() {
        // A closed stdout must surface as a write error (handled below), not kill the process.
        signal(SIGPIPE, SIG_IGN)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppNotification(_:)),
            name: NSNotification.Name("com.abraham.Deci.ToChrome"),
            object: nil
        )

        log.info("DeciHost started")

        DispatchQueue.global(qos: .background).async {
            self.readFromChrome()
        }

        RunLoop.main.run()
    }

    @objc func handleAppNotification(_ notification: Notification) {
        if let messageString = notification.object as? String {
            log.debug("App -> Chrome: \(self.messageType(messageString), privacy: .public), \(messageString.utf8.count) bytes")
            sendMessageToChrome(messageString)
        }
    }

    func readFromChrome() {
        while true {
            // This block never returns, so the queue's own pool never drains: without a pool per message
            // every autoreleased read buffer (a TAB_LIST is hundreds of KB) stays alive for the life of the host.
            autoreleasepool {
                readOneMessage()
            }
        }
    }

    /// Reads one framed message from Chrome and forwards it to the app. Exits when the stream ends or loses sync.
    private func readOneMessage() {
        let lengthData = FileHandle.standardInput.readData(ofLength: 4)
        if lengthData.count != 4 {
            log.info("stdin closed, exiting")
            exit(0)
        }

        let length = Int(UInt32(littleEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))

        if length > maxIncomingBytes {
            log.error("Dropping oversize message from Chrome: \(length) bytes")
            if length > maxDiscardBytes || !discardFromStdin(length) {
                log.error("Cannot resync stdin, exiting")
                exit(0)
            }
            return
        }

        let messageData = FileHandle.standardInput.readData(ofLength: length)

        if messageData.count != length { exit(0) }

        if let messageString = String(data: messageData, encoding: .utf8) {
            log.debug("Chrome -> App: \(self.messageType(messageString), privacy: .public), \(length) bytes")

            DispatchQueue.main.async {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("com.abraham.Deci.FromChrome"),
                    object: messageString,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        }
    }

    /// Reads and throws away `count` bytes of stdin. Returns false if the stream ended early.
    private func discardFromStdin(_ count: Int) -> Bool {
        var remaining = count
        while remaining > 0 {
            let read = autoreleasepool {
                FileHandle.standardInput.readData(ofLength: min(remaining, 64 * 1024)).count
            }
            if read == 0 { return false }
            remaining -= read
        }
        return true
    }

    func sendMessageToChrome(_ message: String) {
        let payload = Data(message.utf8)
        guard payload.count <= maxOutgoingBytes else {
            log.error("Dropping oversize message to Chrome: \(payload.count) bytes")
            return
        }

        // Length prefix and payload go out in one write so Chrome never sees a torn frame.
        var frame = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)

        do {
            try FileHandle.standardOutput.write(contentsOf: frame)
        } catch {
            // Chrome closed the pipe (extension reloaded or browser quit): nothing left to serve.
            log.error("Write to Chrome failed, exiting: \(error.localizedDescription, privacy: .public)")
            exit(0)
        }
    }

    /// Cheap message type for logging. Looks only at the head of the JSON so a multi-hundred-KB
    /// TAB_LIST is never scanned or logged in full.
    private func messageType(_ message: String) -> String {
        let head = message.prefix(256)
        guard let marker = head.range(of: "\"type\":\"") else { return "unknown" }
        return String(head[marker.upperBound...].prefix { $0 != "\"" })
    }
}

let host = NativeMessagingHost()
host.run()

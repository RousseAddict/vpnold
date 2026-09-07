import Foundation

/// M4 — client for the OpenVPN management interface.
///
/// openvpn is spawned with `--management 127.0.0.1 7505` (see ovpn_spawn.c); it
/// opens that listening socket a moment after launch, so the caller is expected
/// to retry `open()` a few times.
///
/// iOS 6 note: the stream pair MUST come from CFStreamCreatePairWithSocketToHost
/// — `Stream.getStreamsToHost` is iOS 8+.
final class ManagementClient: NSObject, StreamDelegate {

    /// Raw/unrecognised management lines, for the log view.
    var onLine: ((String) -> Void)?
    /// `>STATE:` — (state, detail) e.g. ("CONNECTED", "10.8.0.2").
    var onState: ((String, String) -> Void)?
    /// `>BYTECOUNT:` — (bytesIn, bytesOut) since tunnel start.
    var onByteCount: ((UInt64, UInt64) -> Void)?
    /// Socket opened / closed.
    var onOpenChange: ((Bool) -> Void)?

    private var input: InputStream?
    private var output: OutputStream?
    private var rx = [UInt8]()          // bytes read, not yet split into lines
    private var tx = [UInt8]()          // commands queued until space is available
    private var canWrite = false
    private var awaitingStateReply = false

    private(set) var isOpen = false {
        didSet { if isOpen != oldValue { onOpenChange?(isOpen) } }
    }

    // MARK: - Connection

    func open(host: String = "127.0.0.1", port: UInt32 = 7505) {
        close()

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, host as CFString,
                                           port, &readStream, &writeStream)
        guard let r = readStream?.takeRetainedValue(),
              let w = writeStream?.takeRetainedValue() else {
            onLine?("[mgmt] failed to create stream pair")
            return
        }

        let ins: InputStream = r
        let outs: OutputStream = w
        input = ins
        output = outs
        ins.delegate = self
        outs.delegate = self
        ins.schedule(in: .current, forMode: .default)
        outs.schedule(in: .current, forMode: .default)
        ins.open()
        outs.open()
    }

    func close() {
        input?.close()
        output?.close()
        input?.remove(from: .current, forMode: .default)
        output?.remove(from: .current, forMode: .default)
        input?.delegate = nil
        output?.delegate = nil
        input = nil
        output = nil
        rx.removeAll()
        tx.removeAll()
        canWrite = false
        isOpen = false
    }

    /// Ask for the state openvpn is in right now. `state on` only reports
    /// *changes*, so without this the UI shows nothing until the next one —
    /// and we usually attach after CONNECTED has already happened.
    /// The reply is one or more bare state records terminated by `END`.
    func requestCurrentState() {
        awaitingStateReply = true
        send("state")
    }

    /// Queue a management command (newline is appended).
    func send(_ command: String) {
        tx.append(contentsOf: Array((command + "\n").utf8))
        flush()
    }

    private func flush() {
        guard canWrite, let out = output, !tx.isEmpty else { return }
        let written = tx.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return out.write(base, maxLength: buf.count)
        }
        if written > 0 { tx.removeFirst(written) }
        // The stream re-signals .hasSpaceAvailable when it can take more.
        canWrite = false
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream === output { isOpen = true }
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            canWrite = true
            flush()
        case .errorOccurred:
            onLine?("[mgmt] stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
            close()
        case .endEncountered:
            onLine?("[mgmt] connection closed by openvpn")
            close()
        default:
            break
        }
    }

    private func readAvailable() {
        guard let ins = input else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while ins.hasBytesAvailable {
            let n = ins.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            rx.append(contentsOf: buf[0..<n])
        }
        drainLines()
    }

    private func drainLines() {
        while let nl = rx.firstIndex(of: 0x0A) {
            let lineBytes = Array(rx[rx.startIndex..<nl])
            rx.removeFirst(nl - rx.startIndex + 1)
            let line = String(decoding: lineBytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !line.isEmpty { handle(line) }
        }
    }

    // MARK: - Protocol

    private func handle(_ line: String) {
        if awaitingStateReply && !line.hasPrefix(">") {
            // Reply to `state`: bare records in the same format, then END.
            if line.hasPrefix("END") {
                awaitingStateReply = false
            } else {
                parseState(line)
            }
            return
        }

        if line.hasPrefix(">STATE:") {
            parseState(String(line.dropFirst(">STATE:".count)))
        } else if line.hasPrefix(">BYTECOUNT:") {
            let f = line.dropFirst(">BYTECOUNT:".count).components(separatedBy: ",")
            if f.count >= 2, let bin = UInt64(f[0]), let bout = UInt64(f[1]) {
                onByteCount?(bin, bout)
            }
        } else {
            onLine?(line)
        }
    }

    /// time,state,description,localIP,remoteIP,port,localPort,tunPort
    private func parseState(_ payload: String) {
        let f = payload.components(separatedBy: ",")
        guard f.count > 1 else { return }
        let state = f[1]
        // For CONNECTED the useful detail is the tunnel IP; otherwise the
        // human-readable description.
        let detail = (state == "CONNECTED" && f.count > 3 && !f[3].isEmpty) ? f[3]
                   : (f.count > 2 ? f[2] : "")
        onState?(state, detail)
    }
}

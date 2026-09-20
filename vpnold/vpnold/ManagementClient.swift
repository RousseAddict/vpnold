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
    /// The socket is open *and* authenticated: commands will now be accepted.
    /// Everything that used to be sent from onOpenChange belongs here instead.
    var onReady: (() -> Void)?
    /// openvpn needs a credential. (realm, needsUsername) — realm is openvpn's
    /// own name for it, "Auth" for `auth-user-pass` or "Private Key" for an
    /// encrypted key. Answer with `answer(realm:username:password:)`.
    var onNeedCredentials: ((String, Bool) -> Void)?
    /// openvpn rejected what we sent for this realm. With `--auth-retry
    /// interact` another onNeedCredentials follows, so this is for telling the
    /// user why they are being asked twice.
    var onAuthFailed: ((String) -> Void)?
    /// A credential was requested that this client cannot answer, with the
    /// reason. Currently only a static challenge (2FA).
    var onUnsupportedAuth: ((String) -> Void)?

    /// Password for the management socket itself, from the file handed to
    /// `--management`. Must be set before `open()`.
    var password: String?

    private var input: InputStream?
    private var output: OutputStream?
    private var rx = [UInt8]()          // bytes read, not yet split into lines
    private var tx = [UInt8]()          // commands queued until space is available
    private var canWrite = false
    private var awaitingStateReply = false
    private var sentSocketPassword = false
    private var authenticated = false
    private var sawHold = false

    private(set) var isOpen = false {
        didSet { if isOpen != oldValue { onOpenChange?(isOpen) } }
    }

    /// Open *and* past the socket password. Commands sent before this are
    /// rejected, so callers that send on their own schedule must check it.
    var isReady: Bool { return authenticated }

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
        sentSocketPassword = false
        authenticated = false
        sawHold = false
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
            if aStream === output {
                isOpen = true
                // No socket password configured means openvpn will not ask for
                // one, so there is nothing to wait for.
                if password == nil { becomeReady() }
            }
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
        consumeSocketPasswordPrompt()
        drainLines()
    }

    /// openvpn asks for the management password with a bare `ENTER PASSWORD:`
    /// and, depending on the build, no trailing newline — so it can never reach
    /// the line splitter. Matched on the raw byte stream instead, which also
    /// works if a newline *is* present.
    private func consumeSocketPasswordPrompt() {
        guard !sentSocketPassword, let pw = password else { return }
        guard let at = ManagementClient.find(ManagementClient.socketPrompt, in: rx) else { return }
        rx.removeFirst(at + ManagementClient.socketPrompt.count)
        sentSocketPassword = true
        // Raw, not via send(): the reply is the password itself and must not
        // pass anywhere that echoes commands.
        tx.append(contentsOf: Array((pw + "\n").utf8))
        flush()
    }

    private static let socketPrompt = Array("ENTER PASSWORD:".utf8)

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for start in 0...(hay.count - needle.count) {
            var match = true
            for i in 0..<needle.count where hay[start + i] != needle[i] {
                match = false
                break
            }
            if match { return start }
        }
        return nil
    }

    private func becomeReady() {
        guard !authenticated else { return }
        authenticated = true
        onReady?()
        releaseHoldIfNeeded()
    }

    /// openvpn was started with `--management-hold`, so it sits idle until told
    /// to go. Released here rather than by the caller because the ordering is
    /// protocol detail: the hold notification can arrive before we have
    /// authenticated, and a command sent before then is rejected.
    private func releaseHoldIfNeeded() {
        guard authenticated, sawHold else { return }
        sawHold = false
        send("hold release")
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
        // Socket authentication comes first: until it succeeds openvpn rejects
        // every command, so no other branch below can do anything useful.
        if !authenticated {
            if line.hasPrefix("SUCCESS:") && line.lowercased().contains("password") {
                becomeReady()
                return
            }
            if line.hasPrefix("ERROR:") && line.lowercased().contains("password") {
                onLine?("[mgmt] the management socket rejected our password")
                close()
                return
            }
        }

        if line.hasPrefix(">PASSWORD:") {
            handlePasswordRequest(String(line.dropFirst(">PASSWORD:".count)))
            return
        }

        if line.hasPrefix(">HOLD:") {
            sawHold = true
            releaseHoldIfNeeded()
            return
        }

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

    // MARK: - Credentials

    /// The payload after `>PASSWORD:`. The forms openvpn emits are:
    ///   Need 'Auth' username/password
    ///   Need 'Auth' username/password SC:1,<challenge text>
    ///   Need 'Private Key' password
    ///   Verification Failed: 'Auth'
    ///   Auth-Token:<token>
    ///
    /// Note that nothing here is forwarded to `onLine`. These lines carry no
    /// secret themselves, but the log they would land in is exportable from
    /// inside the app, and the realm plus the prompt is more than it needs.
    private func handlePasswordRequest(_ payload: String) {
        if payload.hasPrefix("Verification Failed:") {
            onAuthFailed?(ManagementClient.quotedField(in: payload) ?? "Auth")
            return
        }
        // Emitted after a successful auth when the server hands back a token to
        // use on reconnect. openvpn consumes it itself; there is nothing to do.
        if payload.hasPrefix("Auth-Token") { return }
        guard payload.hasPrefix("Need "), let realm = ManagementClient.quotedField(in: payload) else {
            return
        }
        // A static challenge needs an SCRV1 response carrying a second factor,
        // which this client does not build. Saying so beats sending a plain
        // password that the server will reject for reasons the user cannot see.
        if payload.range(of: " SC:") != nil {
            onUnsupportedAuth?("\(realm) requires a challenge response (2FA), which vpnold cannot answer yet")
            return
        }
        onNeedCredentials?(realm, payload.contains("username/password"))
    }

    /// Answers a credential request. `username` is ignored for realms that did
    /// not ask for one.
    func answer(realm: String, username: String?, password: String) {
        if let user = username {
            send("username \(ManagementClient.quoted(realm)) \(ManagementClient.quoted(user))")
        }
        send("password \(ManagementClient.quoted(realm)) \(ManagementClient.quoted(password))")
    }

    /// The first `'...'` in the payload, which is how openvpn names the realm.
    private static func quotedField(in payload: String) -> String? {
        let parts = payload.components(separatedBy: "'")
        guard parts.count >= 3 else { return nil }
        return parts[1]
    }

    /// openvpn splits management commands with its own `parse_line`, which
    /// understands double quotes and backslash escapes. Quoting is not optional:
    /// a password containing a space would otherwise be truncated at it, and one
    /// containing a quote would desynchronise the whole command.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out + "\""
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

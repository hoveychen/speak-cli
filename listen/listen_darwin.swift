import Cocoa
import Speech
import AVFoundation

// MARK: - Configuration

let socketPath: String = {
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let dir = cache.appendingPathComponent("speak-cli")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("listen.sock").path
}()

struct Config {
    var language = "auto"
    var silenceTimeout = 2.0
    var maxDuration = 60.0
    var daemon = false

    static func parse() -> Config {
        var c = Config()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--language":        c.language = it.next() ?? c.language
            case "--silence-timeout": c.silenceTimeout = Double(it.next() ?? "") ?? c.silenceTimeout
            case "--max-duration":    c.maxDuration = Double(it.next() ?? "") ?? c.maxDuration
            case "--daemon":          c.daemon = true
            default: break
            }
        }
        if c.language == "auto" {
            let pref = Locale.preferredLanguages.first ?? "en-US"
            c.language = pref.hasPrefix("zh") ? "zh-Hans" : "en-US"
        }
        return c
    }
}

// MARK: - Subtitle Overlay

class Overlay {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        _ = NSApplication.shared

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = min(screen.width * 0.8, 800)
        let h: CGFloat = 80
        let x = screen.origin.x + (screen.width - w) / 2
        let y = screen.origin.y + 80

        panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0, alpha: 0.75).cgColor
        bg.layer?.cornerRadius = 16
        panel.contentView!.addSubview(bg)

        label = NSTextField(frame: NSRect(x: 20, y: 8, width: w - 40, height: h - 16))
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 2
        panel.contentView!.addSubview(label)
    }

    func show() { panel.orderFront(nil) }
    func hide() { panel.orderOut(nil) }

    func setText(_ text: String) {
        label.stringValue = text
        label.textColor = .white
    }

    func setFinal(_ text: String) {
        label.stringValue = "\u{2713} " + text
        label.textColor = NSColor(calibratedRed: 0.3, green: 0.9, blue: 0.5, alpha: 1)
    }
}

// MARK: - Single-shot Listener (direct mode)

class Listener {
    let config: Config
    private let overlay: Overlay
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var currentText = ""
    private var lastChange = Date()
    private var done = false
    /// Called on the main thread with the final JSON string.
    var onResult: ((String) -> Void)?

    init(_ config: Config, overlay: Overlay) {
        self.config = config
        self.overlay = overlay
    }

    func start() {
        overlay.show()
        overlay.setText("Preparing...")

        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus == .authorized {
            // Already authorized (e.g. daemon mode) — skip async prompt.
            beginRecording()
        } else {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard status == .authorized else {
                        fputs("Speech recognition not authorized.\n", stderr)
                        self?.emitAndFinish(code: 1)
                        return
                    }
                    self?.beginRecording()
                }
            }
        }
    }

    private func beginRecording() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .denied, .restricted:
            fputs("Error: Microphone access denied.\n", stderr)
            fputs("Grant permission in: System Settings → Privacy & Security → Microphone\n", stderr)
            emitAndFinish(code: 1)
            return
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { g in granted = g; sem.signal() }
            sem.wait()
            if !granted { emitAndFinish(code: 1); return }
        default: break
        }

        let locale = Locale(identifier: config.language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            fputs("Recognizer unavailable for \(config.language)\n", stderr)
            emitAndFinish(code: 1)
            return
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            fputs("No audio input device found.\n", stderr)
            emitAndFinish(code: 1)
            return
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
            req.append(buf)
        }

        engine.prepare()
        do { try engine.start() } catch {
            fputs("Audio engine error: \(error)\n", stderr)
            emitAndFinish(code: 1)
            return
        }

        NSSound(named: "Tink")?.play()
        overlay.setText("")
        fputs("Listening...\n", stderr)
        lastChange = Date()

        recTask = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self, !self.done else { return }
            if let r = result {
                let t = r.bestTranscription.formattedString
                if t != self.currentText {
                    self.currentText = t
                    self.lastChange = Date()
                    DispatchQueue.main.async { self.overlay.setText(t) }
                }
                if r.isFinal { DispatchQueue.main.async { self.finish() } }
            }
            if error != nil && !self.done {
                DispatchQueue.main.async { self.finish() }
            }
        }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, !self.done, !self.currentText.isEmpty else { return }
            if Date().timeIntervalSince(self.lastChange) >= self.config.silenceTimeout {
                self.finish()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + config.maxDuration) { [weak self] in
            self?.finish()
        }
    }

    func finish() {
        guard !done else { return }
        done = true

        silenceTimer?.invalidate()

        if currentText.isEmpty {
            overlay.setText("(no speech detected)")
        } else {
            overlay.setFinal(currentText)
        }

        let json = makeJSON(currentText)
        onResult?(json)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            self.overlay.hide()
        }
    }

    private func emitAndFinish(code: Int32) {
        let json = makeJSON("")
        onResult?(json)
        overlay.hide()
        if onResult == nil { _exit(code) }
    }
}

func makeJSON(_ text: String) -> String {
    let obj: [String: String] = ["text": text]
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "{\"text\":\"\"}"
}

// MARK: - Daemon (Unix socket server)

class Daemon {
    private let defaultConfig: Config
    private var overlay: Overlay!
    private var serverFD: Int32 = -1
    private var activeListener: Listener?  // strong ref to keep it alive

    init(_ config: Config) {
        self.defaultConfig = config
    }

    func run() {
        overlay = Overlay()

        // Pre-authorize speech and microphone at daemon startup so that
        // individual requests don't block on the authorization prompt.
        let authSem = DispatchSemaphore(value: 0)
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                fputs("Warning: speech recognition not authorized.\n", stderr)
            }
            authSem.signal()
        }
        authSem.wait()

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            let micSem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { _ in micSem.signal() }
            micSem.wait()
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            fputs("Error: microphone access denied. Grant permission and restart.\n", stderr)
            _exit(1)
        }

        fputs("Permissions OK.\n", stderr)

        // Remove stale socket.
        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            fputs("Error: cannot create socket.\n", stderr)
            _exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            fputs("Error: cannot bind socket at \(socketPath): \(String(cString: strerror(errno)))\n", stderr)
            _exit(1)
        }

        guard listen(serverFD, 5) == 0 else {
            fputs("Error: listen failed.\n", stderr)
            _exit(1)
        }

        fputs("Daemon listening on \(socketPath)\n", stderr)
        fputs("Press Ctrl+C to stop.\n", stderr)

        // Clean up socket on exit.
        signal(SIGINT, SIG_IGN)
        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSrc.setEventHandler {
            unlink(socketPath)
            fputs("\nDaemon stopped.\n", stderr)
            _exit(0)
        }
        intSrc.resume()

        // Accept connections on a background thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let clientFD = accept(self.serverFD, nil, nil)
                guard clientFD >= 0 else { continue }
                self.handleClient(clientFD)
            }
        }

        // Use NSApp.run() to service both the main dispatch queue and
        // AppKit (overlay windows). Daemon runs from Terminal.app which
        // has mic permission, so TCC won't kill it.
        NSApp.setActivationPolicy(.accessory)
        NSApp.run()
    }

    private func handleClient(_ clientFD: Int32) {
        // Read request: one line of JSON with optional config overrides.
        let fileHandle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
        let data = fileHandle.availableData

        var reqConfig = defaultConfig
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let lang = json["language"] as? String { reqConfig.language = lang }
            if let st = json["silence_timeout"] as? Double { reqConfig.silenceTimeout = st }
            if let md = json["max_duration"] as? Double { reqConfig.maxDuration = md }
        }

        let sem = DispatchSemaphore(value: 0)
        var resultJSON = makeJSON("")

        DispatchQueue.main.async {
            let listener = Listener(reqConfig, overlay: self.overlay)
            self.activeListener = listener
            listener.onResult = { json in
                resultJSON = json
                self.activeListener = nil
                sem.signal()
            }
            listener.start()
        }

        sem.wait()

        // Send result back to client.
        let response = resultJSON + "\n"
        response.withCString { ptr in
            let len = strlen(ptr)
            _ = send(clientFD, ptr, len, 0)
        }
        close(clientFD)
    }
}

// MARK: - Direct mode (original behavior)

func runDirect(_ config: Config) {
    let overlay = Overlay()
    let listener = Listener(config, overlay: overlay)

    listener.onResult = { json in
        print(json)
        fputs("Done.\n", stderr)
        fflush(stdout)
        fflush(stderr)
        resultEmitted = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            _exit(0)
        }
    }

    // Monitor stdin for stop signal, only when stdin is a TTY.
    if isatty(STDIN_FILENO) != 0 {
        DispatchQueue.global(qos: .utility).async {
            while let line = readLine() {
                if line.isEmpty { break }
            }
            DispatchQueue.main.async { listener.finish() }
        }
    }

    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler { listener.finish() }
    src.resume()

    listener.start()
    RunLoop.current.run()
}

// MARK: - Main

var resultEmitted = false
signal(SIGABRT) { _ in
    if resultEmitted { _exit(0) }
    let msg = "Error: audio framework aborted. Your terminal app may lack microphone permission.\n" +
              "Grant access in: System Settings → Privacy & Security → Microphone\n"
    _ = msg.withCString { fputs($0, stderr) }
    _exit(1)
}

let config = Config.parse()

if config.daemon {
    Daemon(config).run()
} else {
    runDirect(config)
}

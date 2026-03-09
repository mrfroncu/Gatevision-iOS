import SwiftUI
import AVFoundation
import Vision
import SQLite3
import Combine

// MARK: - Models

enum GateState: String, CaseIterable {
    case closed   = "ZAMKNIĘTA"
    case opening  = "OTWIERANIE"
    case open     = "OTWARTA"
    case closing  = "ZAMYKANIE"

    var color: Color {
        switch self {
        case .closed:  return Color(hex: "6B6485")
        case .opening: return Color(hex: "00D4FF")
        case .open:    return Color(hex: "B8FF35")
        case .closing: return Color(hex: "E5A00D")
        }
    }
    var icon: String {
        switch self {
        case .closed:  return "door.closed"
        case .opening: return "arrow.up.circle"
        case .open:    return "door.open"
        case .closing: return "arrow.down.circle"
        }
    }
}

struct PlateEntry: Identifiable, Equatable {
    let id: Int64
    var plate: String
    var ownerName: String
    var isFleet: Bool
    var blocked: Bool
    var notes: String
    var createdAt: String
}

struct LogEntry: Identifiable {
    let id: Int64
    let plate: String
    let rawOcr: String
    let confidence: Double
    let granted: Bool
    let blocked: Bool
    let ownerName: String
    let isFleet: Bool
    let timestamp: String
}

struct OCRMode {
    static let plate = "plate"
    static let free  = "free"
}

// MARK: - Database

final class Database {
    static let shared = Database()
    private var db: OpaquePointer?

    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gatevision.sqlite")
        if sqlite3_open(url.path, &db) == SQLITE_OK {
            createTables()
            seedDemo()
        }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func createTables() {
        exec("""
        CREATE TABLE IF NOT EXISTS plates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            plate TEXT NOT NULL UNIQUE,
            owner_name TEXT DEFAULT '',
            is_fleet INTEGER DEFAULT 0,
            blocked INTEGER DEFAULT 0,
            notes TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now','localtime'))
        );
        CREATE TABLE IF NOT EXISTS access_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            plate TEXT NOT NULL,
            raw_ocr TEXT DEFAULT '',
            confidence REAL DEFAULT 0,
            granted INTEGER DEFAULT 0,
            blocked INTEGER DEFAULT 0,
            owner_name TEXT DEFAULT '',
            is_fleet INTEGER DEFAULT 0,
            timestamp TEXT DEFAULT (datetime('now','localtime'))
        );
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    private func seedDemo() {
        let demos: [(String, String, Int, Int)] = [
            ("WA12345", "Jan Kowalski",  0, 0),
            ("KR99999", "Flota firmowa", 1, 0),
            ("PO55123", "Anna Nowak",    0, 0),
            ("GD00001", "Tomasz Więcek", 0, 1),
        ]
        for (plate, owner, fleet, blocked) in demos {
            exec("INSERT OR IGNORE INTO plates (plate,owner_name,is_fleet,blocked) VALUES ('\(plate)','\(owner)',\(fleet),\(blocked))")
        }
    }

    // MARK: Plates CRUD
    func fetchPlates(query: String = "") -> [PlateEntry] {
        var stmt: OpaquePointer?
        var results: [PlateEntry] = []
        let sql = query.isEmpty
            ? "SELECT id,plate,owner_name,is_fleet,blocked,notes,created_at FROM plates ORDER BY id DESC"
            : "SELECT id,plate,owner_name,is_fleet,blocked,notes,created_at FROM plates WHERE plate LIKE '%\(query)%' OR owner_name LIKE '%\(query)%' ORDER BY id DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(PlateEntry(
                    id:        sqlite3_column_int64(stmt, 0),
                    plate:     String(cString: sqlite3_column_text(stmt, 1)),
                    ownerName: String(cString: sqlite3_column_text(stmt, 2)),
                    isFleet:   sqlite3_column_int(stmt, 3) != 0,
                    blocked:   sqlite3_column_int(stmt, 4) != 0,
                    notes:     String(cString: sqlite3_column_text(stmt, 5)),
                    createdAt: String(cString: sqlite3_column_text(stmt, 6))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func addPlate(_ p: PlateEntry) -> Bool {
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO plates (plate,owner_name,is_fleet,blocked,notes) VALUES (?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (p.plate as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (p.ownerName as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt,  3, p.isFleet ? 1 : 0)
        sqlite3_bind_int(stmt,  4, p.blocked ? 1 : 0)
        sqlite3_bind_text(stmt, 5, (p.notes as NSString).utf8String, -1, nil)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    func updatePlate(_ p: PlateEntry) {
        var stmt: OpaquePointer?
        let sql = "UPDATE plates SET owner_name=?,is_fleet=?,blocked=?,notes=? WHERE id=?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (p.ownerName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt,  2, p.isFleet ? 1 : 0)
            sqlite3_bind_int(stmt,  3, p.blocked ? 1 : 0)
            sqlite3_bind_text(stmt, 4, (p.notes as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt,5, p.id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func deletePlate(id: Int64) {
        exec("DELETE FROM plates WHERE id=\(id)")
    }

    func toggleBlock(id: Int64) -> Bool {
        exec("UPDATE plates SET blocked=CASE WHEN blocked=1 THEN 0 ELSE 1 END WHERE id=\(id)")
        var stmt: OpaquePointer?
        var blocked = false
        if sqlite3_prepare_v2(db, "SELECT blocked FROM plates WHERE id=\(id)", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { blocked = sqlite3_column_int(stmt, 0) != 0 }
        }
        sqlite3_finalize(stmt)
        return blocked
    }

    func findPlate(_ plateStr: String) -> PlateEntry? {
        var stmt: OpaquePointer?
        let clean = plateStr.uppercased().filter { $0.isLetter || $0.isNumber }
        let sql = "SELECT id,plate,owner_name,is_fleet,blocked,notes,created_at FROM plates ORDER BY length(plate) DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dbPlate = String(cString: sqlite3_column_text(stmt, 1))
                if clean == dbPlate || clean.contains(dbPlate) {
                    let entry = PlateEntry(
                        id:        sqlite3_column_int64(stmt, 0),
                        plate:     dbPlate,
                        ownerName: String(cString: sqlite3_column_text(stmt, 2)),
                        isFleet:   sqlite3_column_int(stmt, 3) != 0,
                        blocked:   sqlite3_column_int(stmt, 4) != 0,
                        notes:     String(cString: sqlite3_column_text(stmt, 5)),
                        createdAt: String(cString: sqlite3_column_text(stmt, 6))
                    )
                    sqlite3_finalize(stmt)
                    return entry
                }
            }
        }
        sqlite3_finalize(stmt)
        return nil
    }

    // MARK: Log
    @discardableResult
    func logAccess(plate: String, raw: String, conf: Double, granted: Bool, blocked: Bool, owner: String, fleet: Bool) -> Int64 {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO access_log (plate,raw_ocr,confidence,granted,blocked,owner_name,is_fleet) VALUES (?,?,?,?,?,?,?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (plate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (raw as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, conf)
            sqlite3_bind_int(stmt, 4, granted ? 1 : 0)
            sqlite3_bind_int(stmt, 5, blocked ? 1 : 0)
            sqlite3_bind_text(stmt, 6, (owner as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 7, fleet ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return sqlite3_last_insert_rowid(db)
    }

    func fetchLog(query: String = "", limit: Int = 200) -> [LogEntry] {
        var stmt: OpaquePointer?
        var results: [LogEntry] = []
        let sql = query.isEmpty
            ? "SELECT id,plate,raw_ocr,confidence,granted,blocked,owner_name,is_fleet,timestamp FROM access_log ORDER BY id DESC LIMIT \(limit)"
            : "SELECT id,plate,raw_ocr,confidence,granted,blocked,owner_name,is_fleet,timestamp FROM access_log WHERE plate LIKE '%\(query)%' OR owner_name LIKE '%\(query)%' ORDER BY id DESC LIMIT \(limit)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(LogEntry(
                    id:        sqlite3_column_int64(stmt, 0),
                    plate:     String(cString: sqlite3_column_text(stmt, 1)),
                    rawOcr:    String(cString: sqlite3_column_text(stmt, 2)),
                    confidence:sqlite3_column_double(stmt, 3),
                    granted:   sqlite3_column_int(stmt, 4) != 0,
                    blocked:   sqlite3_column_int(stmt, 5) != 0,
                    ownerName: String(cString: sqlite3_column_text(stmt, 6)),
                    isFleet:   sqlite3_column_int(stmt, 7) != 0,
                    timestamp: String(cString: sqlite3_column_text(stmt, 8))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}

// MARK: - OCR + Camera Engine

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var gateState: GateState = .closed
    @Published var lastPlate: String    = ""
    @Published var lastRaw:   String    = ""
    @Published var ocrFPS:    Double    = 0
    @Published var liveLog:   [LogEntry] = []
    @Published var freeTokens:[String]  = []
    @Published var cameraOK:  Bool      = false
    @Published var ocrMode:   String    = OCRMode.plate

    // Settings
    @Published var openDuration:  Double = 10
    @Published var openingTime:   Double = 2
    @Published var closingTime:   Double = 3
    @Published var minVotes:      Int    = 2
    @Published var voteWindowSize:Int    = 6

    private let session       = AVCaptureSession()
    private let videoOutput   = AVCaptureVideoDataOutput()
    private let sessionQueue  = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let ocrQueue      = DispatchQueue(label: "ocr.queue",     qos: .userInitiated)

    private var gateTimer:    DispatchWorkItem?
    private var gateSeqId:    Int = 0
    private var lastGranted:  String = ""
    private var lastGrantTs:  Date   = .distantPast

    // Voting
    private var voteBuffer:   [[String]] = []
    private var lastFrameTs:  Date       = .distantPast
    private var ocrFrameCount:Int        = 0
    private var fpsMeasureTs: Date       = Date()

    // Plate regex — Polish format: 2-3 letters, 3-5 digits, 0-2 letters
    private let plateRegex = try! NSRegularExpression(pattern: "[A-Z]{1,3}\\d{3,5}[A-Z]{0,2}", options: [])

    override init() {
        super.init()
        setupCamera()
    }

    // MARK: Camera Setup
    private func setupCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input  = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                DispatchQueue.main.async { self.cameraOK = false }
                return
            }

            // Auto-focus continuous
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()

            self.session.addInput(input)
            self.videoOutput.setSampleBufferDelegate(self, queue: self.ocrQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            if let conn = self.videoOutput.connection(with: .video) {
                conn.videoRotationAngle = 90  // Portrait
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.cameraOK = true }
        }
    }

    var captureSession: AVCaptureSession { session }

    // MARK: Frame processing
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // FPS measurement
        ocrFrameCount += 1
        let now = Date()
        if now.timeIntervalSince(fpsMeasureTs) >= 3.0 {
            let fps = Double(ocrFrameCount) / now.timeIntervalSince(fpsMeasureTs)
            ocrFrameCount = 0; fpsMeasureTs = now
            DispatchQueue.main.async { self.ocrFPS = fps }
        }

        runVisionOCR(on: pixelBuffer)
    }

    // MARK: Vision OCR
    private func runVisionOCR(on pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self,
                  let observations = req.results as? [VNRecognizedTextObservation]
            else { return }

            let texts = observations.compactMap { obs -> (String, Double)? in
                guard let top = obs.topCandidates(1).first else { return nil }
                return (top.string, Double(top.confidence))
            }

            if self.ocrMode == OCRMode.free {
                self.handleFreeMode(texts: texts)
            } else {
                self.handlePlateMode(texts: texts)
            }
        }

        // Apple Vision — szybkie rozpoznawanie bez słownika
        request.recognitionLevel      = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages  = ["en-US"]
        // Bez customWords — chcemy surowy tekst

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    // MARK: Free mode
    private func handleFreeMode(texts: [(String, Double)]) {
        let tokens = texts.flatMap { (text, conf) -> [(String, Double)] in
            text.components(separatedBy: .whitespaces)
                .map { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
                .filter { $0.count >= 2 }
                .map { ($0, conf) }
        }
        DispatchQueue.main.async {
            self.freeTokens = tokens.map { $0.0 }
        }
        for (tok, conf) in tokens {
            let entry = LogEntry(
                id: Int64(Date().timeIntervalSince1970 * 1000) & 0x7FFFFFFF,
                plate: tok, rawOcr: tok, confidence: conf * 100,
                granted: false, blocked: false, ownerName: "", isFleet: false,
                timestamp: Self.timeStr()
            )
            DispatchQueue.main.async {
                self.liveLog.insert(entry, at: 0)
                if self.liveLog.count > 300 { self.liveLog.removeLast(50) }
            }
        }
    }

    // MARK: Plate mode
    private func handlePlateMode(texts: [(String, Double)]) {
        var candidates: [String] = []
        for (text, _) in texts {
            let clean = text.uppercased().filter { $0.isLetter || $0.isNumber }
            let range = NSRange(clean.startIndex..., in: clean)
            let matches = plateRegex.matches(in: clean, range: range)
            for m in matches {
                if let r = Range(m.range, in: clean) {
                    let p = String(clean[r])
                    if p.count >= 5 && p.count <= 10 { candidates.append(p) }
                }
            }
        }
        guard !candidates.isEmpty else { return }

        // Vote window
        voteBuffer.append(candidates)
        if voteBuffer.count > voteWindowSize { voteBuffer.removeFirst() }

        let flat  = voteBuffer.flatMap { $0 }
        let counts = Dictionary(grouping: flat, by: { $0 }).mapValues { $0.count }
        guard let (winner, votes) = counts.max(by: { $0.value < $1.value }),
              votes >= minVotes
        else { return }

        let now = Date()
        guard winner != lastGranted || now.timeIntervalSince(lastGrantTs) > 8 else { return }
        lastGranted = winner; lastGrantTs = now
        voteBuffer.removeAll()

        DispatchQueue.main.async { self.lastRaw = winner }
        handleDetection(plate: winner)
    }

    // MARK: Detection handler
    private func handleDetection(plate: String) {
        let db      = Database.shared
        let row     = db.findPlate(plate)
        let matched = row?.plate ?? plate
        let granted = row != nil && !(row!.blocked)
        let blocked = row?.blocked ?? false
        let owner   = row?.ownerName ?? ""
        let fleet   = row?.isFleet ?? false
        let conf    = 99.0

        let logId = db.logAccess(
            plate: matched, raw: plate, conf: conf,
            granted: granted, blocked: blocked, owner: owner, fleet: fleet
        )
        let entry = LogEntry(
            id: logId, plate: matched, rawOcr: plate, confidence: conf,
            granted: granted, blocked: blocked, ownerName: owner, isFleet: fleet,
            timestamp: Self.timeStr()
        )
        DispatchQueue.main.async {
            self.lastPlate = matched
            self.liveLog.insert(entry, at: 0)
            if self.liveLog.count > 100 { self.liveLog.removeLast() }
            if granted  { self.triggerOpen() }
        }
    }

    // MARK: Gate State Machine
    func triggerOpen() {
        gateSeqId += 1; let seq = gateSeqId
        gateTimer?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { gateState = .opening }

        let t = DispatchWorkItem { [weak self] in
            guard let self, self.gateSeqId == seq else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) { self.gateState = .open }
            }
            let close = DispatchWorkItem { [weak self] in
                guard let self, self.gateSeqId == seq else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) { self.gateState = .closing }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.closingTime) { [weak self] in
                    guard let self, self.gateSeqId == seq else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { self.gateState = .closed }
                }
            }
            self.gateTimer = close
            DispatchQueue.main.asyncAfter(deadline: .now() + self.openDuration, execute: close)
        }
        gateTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + openingTime, execute: t)
    }

    func triggerClose() {
        guard gateState != .closed else { return }
        gateSeqId += 1; let seq = gateSeqId
        gateTimer?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { gateState = .closing }
        DispatchQueue.main.asyncAfter(deadline: .now() + closingTime) { [weak self] in
            guard let self, self.gateSeqId == seq else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.gateState = .closed }
        }
    }

    static func timeStr() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }
}

// MARK: - Camera Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session     = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Design Tokens

struct GV {
    static let bg      = Color(hex: "07050F")
    static let bg2     = Color(hex: "0E0C1A")
    static let bg3     = Color(hex: "15122A")
    static let border  = Color(hex: "1E1A30")
    static let purple  = Color(hex: "9B4DFF")
    static let azure   = Color(hex: "00D4FF")
    static let lime    = Color(hex: "B8FF35")
    static let orange  = Color(hex: "E5A00D")
    static let red     = Color(hex: "FF3B3B")
    static let muted   = Color(hex: "6B6485")
    static let fg      = Color(hex: "E8E4F0")
}

// MARK: - Root View

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var tab: Int     = 0

    var body: some View {
        ZStack {
            GV.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                TopBar(engine: engine)

                // Content
                TabView(selection: $tab) {
                    StatusTab(engine: engine).tag(0)
                    LogTab(engine: engine).tag(1)
                    PlatesTab().tag(2)
                    SettingsTab(engine: engine).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom nav
                BottomNav(tab: $tab)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Top Bar

struct TopBar: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        HStack(spacing: 10) {
            // Logo
            HStack(spacing: 5) {
                Image(systemName: "shield.checkerboard")
                    .foregroundStyle(GV.purple)
                    .font(.system(size: 16, weight: .bold))
                Text("GateVision")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GV.fg)
            }

            Spacer()

            // Pills
            StatusPill(
                icon: "cpu",
                label: "VISION",
                color: GV.azure
            )
            StatusPill(
                icon: engine.cameraOK ? "camera.fill" : "camera.slash",
                label: engine.cameraOK ? "OK" : "BRAK",
                color: engine.cameraOK ? GV.lime : GV.red
            )
            StatusPill(
                icon: engine.gateState.icon,
                label: engine.gateState.rawValue.components(separatedBy: " ").first ?? "",
                color: engine.gateState.color
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(GV.bg2.overlay(Rectangle().frame(height: 1).foregroundStyle(GV.border), alignment: .bottom))
    }
}

struct StatusPill: View {
    let icon: String; let label: String; let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 3)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25), lineWidth: 1))
        .cornerRadius(6)
    }
}

// MARK: - Bottom Nav

struct BottomNav: View {
    @Binding var tab: Int
    let items: [(String, String)] = [
        ("gauge.high",    "Status"),
        ("list.bullet",   "Logi"),
        ("car.fill",      "Tablice"),
        ("gearshape.fill","Ustawienia"),
    ]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tab = i }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: items[i].0)
                            .font(.system(size: 18, weight: tab == i ? .bold : .regular))
                        Text(items[i].1)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(tab == i ? GV.purple : GV.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(tab == i ? GV.purple.opacity(0.06) : .clear)
                }
            }
        }
        .background(GV.bg2.overlay(Rectangle().frame(height: 1).foregroundStyle(GV.border), alignment: .top))
    }
}

// MARK: - Status Tab

struct StatusTab: View {
    @ObservedObject var engine: CameraEngine
    @State private var showCamera = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // Camera preview toggle
                ZStack(alignment: .topTrailing) {
                    if showCamera {
                        CameraPreview(session: engine.captureSession)
                            .frame(height: 220)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [.clear, GV.bg.opacity(0.6)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    } else {
                        GV.bg2.frame(height: 60)
                    }

                    Button {
                        withAnimation { showCamera.toggle() }
                    } label: {
                        Image(systemName: showCamera ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(GV.muted)
                            .padding(8)
                            .background(GV.bg2.opacity(0.8))
                            .clipShape(Circle())
                    }
                    .padding(10)
                }

                // Gate state — big
                GateStateCard(engine: engine)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                // Metrics grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
                    MetricCard(
                        title: "OSTATNIA TABLICA",
                        value: engine.lastPlate.isEmpty ? "—" : engine.lastPlate,
                        sub:   engine.lastRaw != engine.lastPlate ? "RAW: \(engine.lastRaw)" : "",
                        color: GV.azure,
                        icon:  "text.rectangle"
                    )
                    MetricCard(
                        title: "OCR WYDAJNOŚĆ",
                        value: engine.ocrFPS > 0 ? String(format: "%.1f", engine.ocrFPS) : "—",
                        sub:   "klatek/s (Neural Engine)",
                        color: GV.lime,
                        icon:  "gauge.high"
                    )
                }
                .padding(.top, 1)

                // Live log preview (last 5)
                if !engine.liveLog.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DETEKCJE NA ŻYWO")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(GV.muted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                        ForEach(engine.liveLog.prefix(5)) { entry in
                            LogRow(entry: entry, compact: true)
                            Divider().background(GV.border)
                        }
                    }
                    .background(GV.bg2)
                    .padding(.top, 14)
                }

                Spacer(minLength: 20)
            }
        }
        .background(GV.bg)
    }
}

// MARK: Gate State Card

struct GateStateCard: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    Circle()
                        .fill(engine.gateState.color.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: engine.gateState.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(engine.gateState.color)
                        .symbolEffect(.pulse, isActive: engine.gateState == .opening || engine.gateState == .closing)
                }
                .shadow(color: engine.gateState.color.opacity(0.4), radius: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("BRAMA")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(GV.muted)
                    Text(engine.gateState.rawValue)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(engine.gateState.color)
                }
                Spacer()
            }

            // Buttons
            HStack(spacing: 10) {
                GateButton(label: "Otwórz", icon: "door.open", color: GV.lime) {
                    engine.triggerOpen()
                }
                GateButton(label: "Zamknij", icon: "door.closed", color: GV.red) {
                    engine.triggerClose()
                }
            }
        }
        .padding(16)
        .background(GV.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(engine.gateState.color.opacity(0.2), lineWidth: 1.5)
        )
        .cornerRadius(14)
    }
}

struct GateButton: View {
    let label: String; let icon: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(color.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3), lineWidth: 1))
                .cornerRadius(10)
        }
    }
}

struct MetricCard: View {
    let title: String; let value: String; let sub: String; let color: Color; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(GV.muted)
            }
            Text(value)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundStyle(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(GV.muted)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GV.bg2)
    }
}

// MARK: - Log Tab

struct LogTab: View {
    @ObservedObject var engine: CameraEngine
    @State private var query  = ""
    @State private var dbLogs: [LogEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(GV.muted).font(.system(size: 14))
                TextField("Szukaj tablicy lub właściciela...", text: $query)
                    .font(.system(size: 14))
                    .foregroundStyle(GV.fg)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onChange(of: query) { _ in loadLogs() }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(GV.bg2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(GV.border), alignment: .bottom)

            // Mode toggle
            HStack(spacing: 0) {
                ModeBtn(label: "Live log", active: engine.ocrMode == OCRMode.free || true) {
                    // show live
                }
                ModeBtn(label: "Historia DB (\(dbLogs.count))", active: false) {
                    loadLogs()
                }
            }
            .background(GV.bg2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(GV.border), alignment: .bottom)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(engine.liveLog) { entry in
                        LogRow(entry: entry, compact: false)
                        Divider().background(GV.border)
                    }
                }
            }
        }
        .background(GV.bg)
        .onAppear { loadLogs() }
    }

    private func loadLogs() {
        dbLogs = Database.shared.fetchLog(query: query)
    }
}

struct ModeBtn: View {
    let label: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? GV.purple : GV.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(active ? GV.purple.opacity(0.08) : .clear)
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    let compact: Bool

    var statusColor: Color {
        entry.granted ? GV.lime : (entry.blocked ? GV.red : GV.muted)
    }
    var statusLabel: String {
        entry.granted ? "Dostęp" : (entry.blocked ? "Zablok." : "Nieznany")
    }
    var freeMode: Bool { !entry.granted && !entry.blocked && entry.confidence < 99 && entry.confidence > 0 }

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(freeMode ? GV.azure : statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: (freeMode ? GV.azure : statusColor).opacity(0.7), radius: 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.plate)
                        .font(.system(size: compact ? 14 : 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(freeMode ? GV.azure : GV.fg)
                    if !freeMode {
                        Text(statusLabel)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(statusColor.opacity(0.1))
                            .overlay(Capsule().stroke(statusColor.opacity(0.3), lineWidth: 1))
                            .clipShape(Capsule())
                    } else {
                        Text(String(format: "%.0f%%", entry.confidence))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(entry.confidence >= 80 ? GV.lime : GV.orange)
                    }
                    Spacer()
                    Text(entry.timestamp)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(GV.muted)
                }
                if !compact && !entry.ownerName.isEmpty {
                    Text(entry.ownerName)
                        .font(.system(size: 12))
                        .foregroundStyle(GV.muted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 8 : 11)
    }
}

// MARK: - Plates Tab

struct PlatesTab: View {
    @State private var plates:  [PlateEntry] = []
    @State private var query    = ""
    @State private var showAdd  = false
    @State private var editing: PlateEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(GV.muted).font(.system(size: 14))
                TextField("Szukaj...", text: $query)
                    .font(.system(size: 14)).foregroundStyle(GV.fg)
                    .autocorrectionDisabled().textInputAutocapitalization(.characters)
                    .onChange(of: query) { _ in load() }
                Spacer()
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GV.purple)
                        .padding(6)
                        .background(GV.purple.opacity(0.1))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(GV.bg2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(GV.border), alignment: .bottom)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plates) { plate in
                        PlateRow(plate: plate,
                            onEdit:   { editing = plate },
                            onDelete: { Database.shared.deletePlate(id: plate.id); load() },
                            onToggle: { Database.shared.toggleBlock(id: plate.id); load() }
                        )
                        Divider().background(GV.border)
                    }
                }
            }
        }
        .background(GV.bg)
        .onAppear { load() }
        .sheet(isPresented: $showAdd, onDismiss: load) { PlateForm(existing: nil) }
        .sheet(item: $editing,       onDismiss: load) { PlateForm(existing: $0) }
    }

    private func load() { plates = Database.shared.fetchPlates(query: query) }
}

struct PlateRow: View {
    let plate: PlateEntry
    let onEdit: () -> Void; let onDelete: () -> Void; let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plate.plate)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(plate.blocked ? GV.red : GV.fg)
                    if plate.isFleet {
                        Label("Flota", systemImage: "truck.box")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GV.purple)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(GV.purple.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if plate.blocked {
                        Label("Zablok.", systemImage: "nosign")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GV.red)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(GV.red.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                if !plate.ownerName.isEmpty {
                    Text(plate.ownerName).font(.system(size: 12)).foregroundStyle(GV.muted)
                }
            }
            Spacer()
            Menu {
                Button { onEdit() }   label: { Label("Edytuj",   systemImage: "pencil") }
                Button { onToggle() } label: { Label(plate.blocked ? "Odblokuj" : "Zablokuj", systemImage: plate.blocked ? "checkmark.circle" : "nosign") }
                Divider()
                Button(role: .destructive) { onDelete() } label: { Label("Usuń", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(GV.muted).padding(8)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

struct PlateForm: View {
    let existing: PlateEntry?
    @Environment(\.dismiss) var dismiss

    @State private var plate    = ""
    @State private var owner    = ""
    @State private var fleet    = false
    @State private var blocked  = false
    @State private var notes    = ""
    @State private var error    = ""

    var body: some View {
        NavigationStack {
            ZStack {
                GV.bg.ignoresSafeArea()
                Form {
                    Section("Numer rejestracyjny") {
                        TextField("np. WA12345", text: $plate)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .disabled(existing != nil)
                    }
                    Section("Właściciel") {
                        TextField("Imię i nazwisko", text: $owner)
                        Toggle("Pojazd flotowy", isOn: $fleet)
                        Toggle("Zablokowany", isOn: $blocked)
                    }
                    Section("Notatki") {
                        TextField("Opcjonalnie...", text: $notes, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                    }
                    if !error.isEmpty {
                        Section { Text(error).foregroundStyle(GV.red).font(.system(size: 13)) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(existing == nil ? "Nowa tablica" : "Edytuj")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") { save() }
                        .fontWeight(.bold)
                        .tint(GV.purple)
                }
            }
        }
        .onAppear {
            if let e = existing {
                plate = e.plate; owner = e.ownerName
                fleet = e.isFleet; blocked = e.blocked; notes = e.notes
            }
        }
    }

    private func save() {
        let clean = plate.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count >= 4 else { error = "Za krótki numer rejestracyjny"; return }
        let entry = PlateEntry(id: existing?.id ?? 0, plate: clean, ownerName: owner,
                               isFleet: fleet, blocked: blocked, notes: notes, createdAt: "")
        if existing != nil {
            Database.shared.updatePlate(entry)
        } else {
            if !Database.shared.addPlate(entry) { error = "Tablica już istnieje"; return }
        }
        dismiss()
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        NavigationStack {
            ZStack {
                GV.bg.ignoresSafeArea()
                Form {
                    // OCR Mode
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TRYB OCR")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(GV.muted)
                            HStack(spacing: 10) {
                                OcrModeBtn(
                                    label: "🔍 TABLICA",
                                    sub:   "Filtruje tablice rejestracyjne, otwiera bramę",
                                    active: engine.ocrMode == OCRMode.plate,
                                    color:  GV.purple
                                ) { engine.ocrMode = OCRMode.plate }
                                OcrModeBtn(
                                    label: "📋 WOLNY",
                                    sub:   "Cały tekst bez filtra — do kalibracji",
                                    active: engine.ocrMode == OCRMode.free,
                                    color:  GV.azure
                                ) { engine.ocrMode = OCRMode.free }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: { Text("Silnik OCR") }

                    // Voting
                    Section("Głosowanie (tryb TABLICA)") {
                        HStack {
                            Text("Min. powtórzeń").foregroundStyle(GV.fg)
                            Spacer()
                            Stepper("\(engine.minVotes)", value: $engine.minVotes, in: 1...10)
                                .foregroundStyle(GV.azure)
                        }
                        HStack {
                            Text("Okno głosowania").foregroundStyle(GV.fg)
                            Spacer()
                            Stepper("\(engine.voteWindowSize)", value: $engine.voteWindowSize, in: 2...20)
                                .foregroundStyle(GV.azure)
                        }
                    }

                    // Gate timings
                    Section("Czasy bramy") {
                        LabeledStepper(label: "Otwieranie (s)",
                                       value: $engine.openingTime, range: 1...30)
                        LabeledStepper(label: "Czas otwarcia (s)",
                                       value: $engine.openDuration, range: 1...120)
                        LabeledStepper(label: "Zamykanie (s)",
                                       value: $engine.closingTime, range: 1...30)
                    }

                    // Info
                    Section("Informacje") {
                        InfoRow(label: "Silnik OCR",    value: "Apple Vision (Neural Engine)")
                        InfoRow(label: "OCR FPS",       value: String(format: "%.1f fps", engine.ocrFPS))
                        InfoRow(label: "Kamera",        value: engine.cameraOK ? "Połączona" : "Brak")
                        InfoRow(label: "Stan bramy",    value: engine.gateState.rawValue)
                        InfoRow(label: "Ostatnia tabl.",value: engine.lastPlate.isEmpty ? "—" : engine.lastPlate)
                    }

                    // Clear log
                    Section {
                        Button(role: .destructive) {
                            Database.shared.fetchLog() // ensure table exists
                            sqlite3_exec(nil, "DELETE FROM access_log", nil, nil, nil)
                            engine.liveLog.removeAll()
                        } label: {
                            Label("Wyczyść logi", systemImage: "trash")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Ustawienia")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct OcrModeBtn: View {
    let label: String; let sub: String; let active: Bool; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(active ? color : GV.muted)
                Text(sub).font(.system(size: 10)).foregroundStyle(GV.muted).lineLimit(2)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? color.opacity(0.08) : GV.bg2)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? color.opacity(0.4) : GV.border, lineWidth: 1.5))
            .cornerRadius(10)
        }
    }
}

struct LabeledStepper: View {
    let label: String; @Binding var value: Double; let range: ClosedRange<Double>
    var body: some View {
        HStack {
            Text(label).foregroundStyle(GV.fg)
            Spacer()
            Stepper("\(Int(value))s", value: $value, in: range)
                .foregroundStyle(GV.azure)
        }
    }
}

struct InfoRow: View {
    let label: String; let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(GV.muted).font(.system(size: 14))
            Spacer()
            Text(value).foregroundStyle(GV.fg).font(.system(size: 14, weight: .medium, design: .monospaced))
        }
    }
}

// MARK: - App Entry

@main
struct GateVisionApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

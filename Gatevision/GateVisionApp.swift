import SwiftUI
import UIKit
import AVFoundation
import Vision
import SQLite3
import Network
import Darwin.POSIX.netdb
import Combine

// MARK: ─── Models ─────────────────────────────────────────────────────────────

enum GateState: String, CaseIterable {
    case closed = "ZAMKNIĘTA", opening = "OTWIERANIE", open = "OTWARTA", closing = "ZAMYKANIE"

    var color: Color {
        switch self {
        case .closed:  .init(hex:"8E8AAF")
        case .opening: .init(hex:"00D4FF")
        case .open:    .init(hex:"B8FF35")
        case .closing: .init(hex:"E5A00D")
        }
    }
    var sfSymbol: String {
        switch self {
        case .closed:  "door.closed.fill"
        case .opening: "arrow.up.circle.fill"
        case .open:    "door.open.fill"
        case .closing: "arrow.down.circle.fill"
        }
    }
    var isAnimating: Bool { self == .opening || self == .closing }
}

struct PlateEntry: Identifiable, Equatable {
    let id: Int64
    var plate, ownerName, notes, createdAt: String
    var isFleet, blocked: Bool
}

struct LogEntry: Identifiable {
    let id: Int64
    let plate, rawOcr, ownerName, timestamp: String
    let confidence: Double
    let granted, blocked, isFleet, isFreeMode: Bool
    var snapshotData: Data? = nil   // JPEG klatki w momencie detekcji
}

enum OCRMode: String, CaseIterable, Identifiable {
    case plate, free
    var id: String { rawValue }
    var label: String { self == .plate ? "🔍 Tablica" : "📋 Wolny" }
    var description: String {
        self == .plate ? "Filtruje tablice, otwiera bramę automatycznie."
                       : "Wyświetla cały tekst bez filtra — do kalibracji."
    }
}

enum LensType: String, CaseIterable, Identifiable {
    case ultrawide, wide, telephoto
    var id: String { rawValue }
    var label: String { switch self { case .ultrawide: "0.5×"; case .wide: "1×"; case .telephoto: "2×" } }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultrawide: .builtInUltraWideCamera
        case .wide:      .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }
}

// MARK: ─── Design System ──────────────────────────────────────────────────────

extension Color {
    init(hex h: String) {
        var i: UInt64 = 0
        Scanner(string: h.trimmingCharacters(in: .alphanumerics.inverted)).scanHexInt64(&i)
        self.init(red: Double((i>>16)&0xFF)/255, green: Double((i>>8)&0xFF)/255, blue: Double(i&0xFF)/255)
    }
}

enum GV {
    static let purple = Color(hex:"9B4DFF"), azure  = Color(hex:"00D4FF")
    static let lime   = Color(hex:"B8FF35"), orange = Color(hex:"E5A00D")
    static let red    = Color(hex:"FF3B3B"), green  = Color(hex:"34C759")
    static let muted  = Color.white.opacity(0.35)
    static let fg     = Color.white.opacity(0.92)
    static let border = Color.white.opacity(0.10)
    static let bgTop  = Color(hex:"0A0520"), bgBottom = Color(hex:"050310")
}

// Liquid Glass surface
struct GlassCard: ViewModifier {
    var radius: CGFloat = 20; var tint: Color = .white.opacity(0.05)
    func body(content: Content) -> some View {
        content
            .background(ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint)
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(GV.border, lineWidth: 1)
            })
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
extension View {
    func glassCard(radius: CGFloat = 20, tint: Color = .white.opacity(0.05)) -> some View {
        modifier(GlassCard(radius: radius, tint: tint))
    }
}

// MARK: ─── Database ───────────────────────────────────────────────────────────

final class Database {
    static let shared = Database()
    private(set) var rawDB: OpaquePointer?
    private var db: OpaquePointer? { rawDB }
    // Wszystkie operacje SQLite przez jeden szeregowy wątek — eliminuje crash przy concurrent access
    let dbQueue = DispatchQueue(label: "gv.db", qos: .userInitiated)

    private init() {
        let url = FileManager.default.urls(for:.documentDirectory, in:.userDomainMask)[0]
            .appendingPathComponent("gatevision.sqlite")
        guard sqlite3_open(url.path, &rawDB) == SQLITE_OK else { return }
        exec("""
        CREATE TABLE IF NOT EXISTS plates(id INTEGER PRIMARY KEY AUTOINCREMENT,
            plate TEXT NOT NULL UNIQUE,owner_name TEXT DEFAULT '',is_fleet INTEGER DEFAULT 0,
            blocked INTEGER DEFAULT 0,notes TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now','localtime')));
        CREATE TABLE IF NOT EXISTS access_log(id INTEGER PRIMARY KEY AUTOINCREMENT,
            plate TEXT NOT NULL,raw_ocr TEXT DEFAULT '',confidence REAL DEFAULT 0,
            granted INTEGER DEFAULT 0,blocked INTEGER DEFAULT 0,
            owner_name TEXT DEFAULT '',is_fleet INTEGER DEFAULT 0,
            snapshot_jpeg BLOB,
            timestamp TEXT DEFAULT (datetime('now','localtime')));
        -- migracja dla istniejących baz danych
        ALTER TABLE access_log ADD COLUMN snapshot_jpeg BLOB;
        INSERT OR IGNORE INTO plates(plate,owner_name,is_fleet,blocked) VALUES
            ('WA12345','Jan Kowalski',0,0),('KR99999','Flota firmowa',1,0),
            ('PO55123','Anna Nowak',0,0),('GD00001','Tomasz Więcek',0,1);
        """)
    }

    @discardableResult private func exec(_ s: String) -> Int32 { sqlite3_exec(db,s,nil,nil,nil) }

    private func query<T>(_ sql: String, bind: (OpaquePointer)->Void = {_ in}, map: (OpaquePointer)->T) -> [T] {
        var stmt: OpaquePointer?; var r: [T] = []
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { return r }
        bind(stmt!); while sqlite3_step(stmt) == SQLITE_ROW { r.append(map(stmt!)) }
        sqlite3_finalize(stmt); return r
    }

    private func col(_ s: OpaquePointer, _ i: Int32) -> String { String(cString: sqlite3_column_text(s,i)) }

    private func _fetchPlatesRaw(query q: String) -> [PlateEntry] {
        let sql = q.isEmpty ? "SELECT id,plate,owner_name,is_fleet,blocked,notes,created_at FROM plates ORDER BY id DESC"
                            : "SELECT id,plate,owner_name,is_fleet,blocked,notes,created_at FROM plates WHERE plate LIKE '%\(q)%' OR owner_name LIKE '%\(q)%' ORDER BY id DESC"
        return query(sql) { s in PlateEntry(id:sqlite3_column_int64(s,0),plate:col(s,1),ownerName:col(s,2),notes:col(s,5),createdAt:col(s,6),isFleet:sqlite3_column_int(s,3) != 0,blocked:sqlite3_column_int(s,4) != 0) }
    }

    func fetchPlates(query q: String = "") -> [PlateEntry] {
        dbQueue.sync { _fetchPlatesRaw(query: q) }
    }

    @discardableResult func addPlate(_ p: PlateEntry) -> Bool {
        dbQueue.sync {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT OR IGNORE INTO plates(plate,owner_name,is_fleet,blocked,notes) VALUES(?,?,?,?,?)",-1,&stmt,nil)==SQLITE_OK else { return false }
        sqlite3_bind_text(stmt,1,(p.plate as NSString).utf8String,-1,nil)
        sqlite3_bind_text(stmt,2,(p.ownerName as NSString).utf8String,-1,nil)
        sqlite3_bind_int(stmt,3,p.isFleet ? 1:0); sqlite3_bind_int(stmt,4,p.blocked ? 1:0)
        sqlite3_bind_text(stmt,5,(p.notes as NSString).utf8String,-1,nil)
        let ok = sqlite3_step(stmt)==SQLITE_DONE; sqlite3_finalize(stmt); return ok
        }
    }

    func updatePlate(_ p: PlateEntry) {
        dbQueue.sync {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"UPDATE plates SET owner_name=?,is_fleet=?,blocked=?,notes=? WHERE id=?",-1,&stmt,nil)==SQLITE_OK else { return }
        sqlite3_bind_text(stmt,1,(p.ownerName as NSString).utf8String,-1,nil)
        sqlite3_bind_int(stmt,2,p.isFleet ? 1:0); sqlite3_bind_int(stmt,3,p.blocked ? 1:0)
        sqlite3_bind_text(stmt,4,(p.notes as NSString).utf8String,-1,nil)
        sqlite3_bind_int64(stmt,5,p.id); sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func deletePlate(id: Int64) { dbQueue.sync { _ = exec("DELETE FROM plates WHERE id=\(id)") } }

    @discardableResult func toggleBlock(id: Int64) -> Bool {
        dbQueue.sync {
            exec("UPDATE plates SET blocked=CASE WHEN blocked=1 THEN 0 ELSE 1 END WHERE id=\(id)")
            return query("SELECT blocked FROM plates WHERE id=\(id)") { sqlite3_column_int($0,0) != 0 }.first ?? false
        }
    }

    func findPlate(_ s: String) -> PlateEntry? {
        let clean = s.uppercased().filter { $0.isLetter || $0.isNumber }
        // fetchPlates już przez dbQueue.sync — wywołaj bezpośrednio SQL bez podwójnego lock
        let all = dbQueue.sync { _fetchPlatesRaw(query: "") }
        return all.first { clean == $0.plate || clean.contains($0.plate) }
    }

    @discardableResult func logAccess(plate: String, raw: String, conf: Double, granted: Bool, blocked: Bool, owner: String, fleet: Bool, snapshot: Data? = nil) -> Int64 {
        dbQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,"INSERT INTO access_log(plate,raw_ocr,confidence,granted,blocked,owner_name,is_fleet,snapshot_jpeg) VALUES(?,?,?,?,?,?,?,?)",-1,&stmt,nil)==SQLITE_OK else { return 0 }
            sqlite3_bind_text(stmt,1,(plate as NSString).utf8String,-1,nil)
            sqlite3_bind_text(stmt,2,(raw as NSString).utf8String,-1,nil)
            sqlite3_bind_double(stmt,3,conf)
            sqlite3_bind_int(stmt,4,granted ? 1:0); sqlite3_bind_int(stmt,5,blocked ? 1:0)
            sqlite3_bind_text(stmt,6,(owner as NSString).utf8String,-1,nil)
            sqlite3_bind_int(stmt,7,fleet ? 1:0)
            if let jpeg = snapshot {
                _ = jpeg.withUnsafeBytes { sqlite3_bind_blob(stmt, 8, $0.baseAddress, Int32($0.count), nil) }
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_step(stmt); sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func fetchLog(query q: String = "", limit: Int = 200) -> [LogEntry] {
        dbQueue.sync {
        // BLOB nie ładujemy tu — za ciężkie przy 200 wpisach. Używamy fetchSnapshot(id:) osobno.
        let sql = q.isEmpty
            ? "SELECT id,plate,raw_ocr,confidence,granted,blocked,owner_name,is_fleet,timestamp,(snapshot_jpeg IS NOT NULL) as has_snap FROM access_log ORDER BY id DESC LIMIT \(limit)"
            : "SELECT id,plate,raw_ocr,confidence,granted,blocked,owner_name,is_fleet,timestamp,(snapshot_jpeg IS NOT NULL) as has_snap FROM access_log WHERE plate LIKE '%\(q)%' OR owner_name LIKE '%\(q)%' ORDER BY id DESC LIMIT \(limit)"
        return query(sql) { s in
            // has_snap = 1 → wstawiamy marker Data(1 bajt) by snapshotData != nil
            let hasSnap = sqlite3_column_int(s, 9) != 0
            return LogEntry(id:sqlite3_column_int64(s,0),plate:col(s,1),rawOcr:col(s,2),
                ownerName:col(s,6),timestamp:col(s,8),confidence:sqlite3_column_double(s,3),
                granted:sqlite3_column_int(s,4) != 0,blocked:sqlite3_column_int(s,5) != 0,
                isFleet:sqlite3_column_int(s,7) != 0,isFreeMode:false,
                snapshotData: hasSnap ? Data([1]) : nil)  // marker — thumbnail ładuje lazy
        }
        } // dbQueue.sync
    }

    func clearLog() { dbQueue.sync { _ = exec("DELETE FROM access_log") } }

    func fetchSnapshot(logId: Int64) -> Data? {
        dbQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,"SELECT snapshot_jpeg FROM access_log WHERE id=?",-1,&stmt,nil)==SQLITE_OK else { return nil }
            sqlite3_bind_int64(stmt,1,logId)
            guard sqlite3_step(stmt)==SQLITE_ROW else { sqlite3_finalize(stmt); return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_column_type(stmt,0) != SQLITE_NULL else { return nil }
            let bytes = sqlite3_column_bytes(stmt,0)
            guard bytes > 0, let ptr = sqlite3_column_blob(stmt,0) else { return nil }
            return Data(bytes: ptr, count: Int(bytes))
        }
    }
}

// MARK: ─── Web Server ─────────────────────────────────────────────────────────

final class WebServer: ObservableObject {
    static let shared = WebServer()
    @Published var isRunning = false
    @Published var localIP: String = ""
    let port: UInt16 = 6600
    private var listener: NWListener?
    private weak var engine: CameraEngine?

    private init() { localIP = Self.getIP() }

    func start(engine: CameraEngine) {
        self.engine = engine; self.localIP = Self.getIP()
        let p = NWParameters.tcp; p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: NWEndpoint.Port(rawValue: port)!) else { return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self] s in DispatchQueue.main.async { self?.isRunning = s == .ready } }
        l.start(queue: .global(qos: .utility))
    }

    func stop() { listener?.cancel(); listener = nil; DispatchQueue.main.async { self.isRunning = false } }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let lines = req.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").components(separatedBy: " ")
            let method = parts.count > 0 ? parts[0] : "GET"
            let path   = parts.count > 1 ? parts[1] : "/"
            let cp     = path.components(separatedBy: "?").first ?? path

            // MJPEG stream — osobna ścieżka, trzyma połączenie otwarte
            if method == "GET" && cp == "/api/stream" {
                self.handleStream(conn)
                return
            }

            let body = req.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let (code, mime, respData) = self.route(method: method, path: path, body: body)
            let hdr = "HTTP/1.1 \(code) OK\r\nContent-Type: \(mime)\r\nContent-Length: \(respData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var out = Data(hdr.utf8); out.append(respData)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    // ── MJPEG stream ──────────────────────────────────────────────────────────
    private func handleStream(_ conn: NWConnection) {
        let boundary = "gvframe"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .idempotent)
        sendNextFrame(conn: conn, boundary: boundary)
    }

    private func sendNextFrame(conn: NWConnection, boundary: String) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) { [weak self, weak conn] in
            guard let self, let conn else { return }
            let jpeg = self.engine?.latestJpeg
            let frameData = jpeg ?? self.placeholderJpeg()
            var part = Data()
            part.append(Data("--\(boundary)\r\n".utf8))
            part.append(Data("Content-Type: image/jpeg\r\nContent-Length: \(frameData.count)\r\n\r\n".utf8))
            part.append(frameData)
            part.append(Data("\r\n".utf8))
            conn.send(content: part, completion: .contentProcessed { [weak self, weak conn] err in
                guard err == nil, let self, let conn else { return }
                self.sendNextFrame(conn: conn, boundary: boundary)
            })
        }
    }

    /// Czarny placeholder JPEG gdy kamera jeszcze nie gotowa
    private func placeholderJpeg() -> Data {
        let size = CGSize(width: 640, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor(red: 0.04, green: 0.03, blue: 0.09, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.5) ?? Data()
    }

    // ── Router ────────────────────────────────────────────────────────────────
    private func route(method: String, path: String, body: String) -> (Int, String, Data) {
        let db = Database.shared; let e = engine
        let cp = path.components(separatedBy: "?").first ?? path
        func j(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
        func qp(_ k: String) -> String {
            guard let qs = path.components(separatedBy:"?").dropFirst().first else { return "" }
            return qs.components(separatedBy:"&").first(where:{$0.hasPrefix(k+"=")})
                .flatMap{$0.components(separatedBy:"=").dropFirst().first}?
                .removingPercentEncoding ?? ""
        }
        func jParse(_ s: String) -> [String:Any]? {
            guard let d = s.data(using:.utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with:d) as? [String:Any]
        }

        switch (method, cp) {
        case ("GET",  "/"):
            return (200, "text/html; charset=utf-8", Data(htmlPage().utf8))

        case ("GET", "/api/snapshot"):
            if let jpeg = e?.latestJpeg {
                return (200, "image/jpeg", jpeg)
            }
            return (503, "text/plain", Data("no frame".utf8))

        case ("GET", "/api/status"):
            var status: [String: Any] = [:]
            status["gate_state"]       = e?.gateState.rawValue ?? "ZAMKNIĘTA"
            status["gate_open"]        = e?.gateState == .open || e?.gateState == .opening
            status["camera_ok"]        = e?.cameraOK ?? false
            status["last_plate"]       = e?.lastPlate ?? ""
            status["last_raw"]         = e?.lastRaw ?? ""
            status["ocr_fps"]          = e?.ocrFPS ?? 0
            status["ocr_mode"]         = e?.ocrMode.rawValue ?? "plate"
            status["selected_lens"]    = e?.selectedLens.rawValue ?? "wide"
            status["available_lenses"] = e?.availableLenses.map { $0.rawValue } ?? ["wide"]
            status["engine"]           = "Apple Vision"
            return (200, "application/json", j(status))

        case ("GET", "/api/live_log"):
            let items = (e?.liveLog ?? []).prefix(60).map { x -> [String:Any] in
                ["id":x.id,"plate":x.plate,"raw":x.rawOcr,"conf":x.confidence,
                 "granted":x.granted,"blocked":x.blocked,"owner":x.ownerName,
                 "is_fleet":x.isFleet,"free_mode":x.isFreeMode,"ts":x.timestamp]
            }
            return (200, "application/json", j(Array(items)))

        case ("GET", "/api/log"):
            let rows = db.fetchLog(query: qp("q")).map { x -> [String:Any] in
                var row: [String:Any] = ["id":x.id,"plate":x.plate,"raw_ocr":x.rawOcr,
                    "confidence":x.confidence,"granted":x.granted,"blocked":x.blocked,
                    "owner_name":x.ownerName,"is_fleet":x.isFleet,"timestamp":x.timestamp]
                row["has_snapshot"] = x.snapshotData != nil
                return row
            }
            return (200, "application/json", j(["total":rows.count,"items":rows]))

        case ("GET", _) where cp.hasPrefix("/api/log/") && cp.hasSuffix("/snapshot"):
            let parts2 = cp.components(separatedBy: "/")
            guard parts2.count >= 4, let logId = Int64(parts2[parts2.count-2]) else {
                return (400, "text/plain", Data("bad id".utf8))
            }
            if let jpeg = db.fetchSnapshot(logId: logId) {
                return (200, "image/jpeg", jpeg)
            }
            return (404, "text/plain", Data("no snapshot".utf8))

        case ("GET", "/api/plates"):
            let plates = db.fetchPlates(query: qp("q")).map { p -> [String:Any] in
                ["id":p.id,"plate":p.plate,"owner_name":p.ownerName,
                 "is_fleet":p.isFleet ? 1:0,"blocked":p.blocked ? 1:0,"notes":p.notes,"created_at":p.createdAt]
            }
            return (200, "application/json", j(plates))

        case ("POST", "/api/plates"):
            guard let obj = jParse(body), let plate = obj["plate"] as? String, !plate.isEmpty else {
                return (400, "application/json", j(["error":"plate required"]))
            }
            let clean = plate.uppercased().filter { $0.isLetter || $0.isNumber }
            let entry = PlateEntry(id:0, plate:clean, ownerName: obj["owner_name"] as? String ?? "",
                notes: obj["notes"] as? String ?? "", createdAt: "",
                isFleet:(obj["is_fleet"] as? Int ?? 0) != 0, blocked:(obj["blocked"] as? Int ?? 0) != 0)
            return db.addPlate(entry) ? (200,"application/json",j(["ok":true])) : (409,"application/json",j(["error":"exists"]))

        case ("PUT", _) where cp.hasPrefix("/api/plates/"):
            guard let id = Int64(cp.components(separatedBy:"/").last ?? ""), let obj = jParse(body) else {
                return (400, "application/json", j(["error":"bad request"]))
            }
            db.updatePlate(PlateEntry(id:id, plate:"", ownerName: obj["owner_name"] as? String ?? "",
                notes: obj["notes"] as? String ?? "", createdAt: "",
                isFleet:(obj["is_fleet"] as? Int ?? 0) != 0, blocked:(obj["blocked"] as? Int ?? 0) != 0))
            return (200, "application/json", j(["ok":true]))

        case ("DELETE", _) where cp.hasPrefix("/api/plates/"):
            guard let id = Int64(cp.components(separatedBy:"/").last ?? "") else { return (400,"application/json",j(["error":"bad id"])) }
            db.deletePlate(id: id); return (200, "application/json", j(["ok":true]))

        case ("POST", _) where cp.hasSuffix("/toggle_block"):
            let parts = cp.components(separatedBy:"/")
            guard parts.count >= 4, let id = Int64(parts[parts.count-2]) else { return (400,"application/json",j(["error":"bad id"])) }
            return (200, "application/json", j(["blocked": db.toggleBlock(id:id)]))

        case ("POST", "/api/gate/open"):
            DispatchQueue.main.async { e?.triggerOpen() }
            return (200, "application/json", j(["ok":true]))

        case ("POST", "/api/gate/close"):
            DispatchQueue.main.async { e?.triggerClose() }
            return (200, "application/json", j(["ok":true]))

        case ("GET", "/api/settings"):
            guard let e else { return (200,"application/json",j([:])) }
            return (200, "application/json", j([
                "ocr_mode":          e.ocrMode.rawValue,
                "selected_lens":     e.selectedLens.rawValue,
                "available_lenses":  e.availableLenses.map { $0.rawValue },
                "min_votes":         e.minVotes,
                "vote_window":       e.voteWindowSize,
                "gate_open_duration":e.openDuration,
                "gate_opening_time": e.openingTime,
                "gate_closing_time": e.closingTime
            ]))

        case ("POST", "/api/settings"):
            guard let obj = jParse(body), let e else { return (400,"application/json",j(["error":"bad request"])) }
            DispatchQueue.main.async {
                if let v = obj["ocr_mode"] as? String { e.ocrMode = OCRMode(rawValue:v) ?? .plate }
                if let v = obj["selected_lens"] as? String, let lens = LensType(rawValue:v), e.availableLenses.contains(lens) { e.selectedLens = lens }
                if let v = obj["min_votes"] as? Int { e.minVotes = v }
                if let v = obj["vote_window"] as? Int { e.voteWindowSize = v }
                if let v = obj["gate_open_duration"] as? Double { e.openDuration = v }
                if let v = obj["gate_opening_time"] as? Double { e.openingTime = v }
                if let v = obj["gate_closing_time"] as? Double { e.closingTime = v }
            }
            return (200, "application/json", j(["ok":true]))

        default:
            return (404, "text/plain", Data("Not Found".utf8))
        }
    }

    static func getIP() -> String {
        var address = ""
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "—" }
        var ptr = ifaddr
        while let p = ptr {
            if p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: p.pointee.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating:0, count:Int(NI_MAXHOST))
                    if getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address.isEmpty ? "—" : address
    }

    // MARK: – HTML Dashboard
    private func htmlPage() -> String {
        // dashboard.html is loaded from the app bundle at runtime
        // Add dashboard.html to your Xcode project (target membership ✓)
        if let url = Bundle.main.url(forResource: "dashboard", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            return html
        }
        // Fallback — should not happen in a correctly configured project
        return "<html><body style=\"background:#07050f;color:#e8e4f0;font-family:sans-serif;padding:40px\"><h2>⚠️ dashboard.html not found in bundle</h2><p>Add dashboard.html to your Xcode target.</p></body></html>"
    }
}

// MARK: ─── Camera Engine ──────────────────────────────────────────────────────

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var gateState:  GateState = .closed
    @Published var lastPlate = ""
    @Published var lastRaw = ""
    @Published var ocrFPS:     Double    = 0
    @Published var liveLog:    [LogEntry]  = []
    @Published var cameraOK    = false
    @Published var ocrMode:    OCRMode   = .plate { didSet { _ocrModeSafe = ocrMode } }

    // Najnowsza klatka jako JPEG + boxy wykrytych tablic (dla /api/snapshot i /api/stream)
    var latestJpeg: Data? = nil
    var detectedBoxes: [CGRect] = []
    private let jpegLock  = NSLock()
    private let jpegQ     = DispatchQueue(label:"gv.jpeg", qos:.utility)
    private let ciContext = CIContext(options:[.useSoftwareRenderer: false])  // GPU, singleton
    @Published var selectedLens: LensType = .wide  { didSet { switchLens(to: selectedLens) } }
    @Published var availableLenses: [LensType] = []
    @Published var openDuration = 10.0
    @Published var openingTime = 2.0
    @Published var closingTime = 3.0
    @Published var minVotes = 2; @Published var voteWindowSize = 6
    @Published var splashMinDuration: Double = UserDefaults.standard.double(forKey: "splashMinDuration").nonZeroOrDefault(0.7) {
        didSet { UserDefaults.standard.set(splashMinDuration, forKey: "splashMinDuration") }
    }

    private var _ocrModeSafe: OCRMode = .plate
    private let session = AVCaptureSession(); private let videoOut = AVCaptureVideoDataOutput()
    private let sessionQ = DispatchQueue(label:"gv.sess", qos:.userInitiated)
    private let ocrQ     = DispatchQueue(label:"gv.ocr",  qos:.userInitiated)
    private var gateTimer: DispatchWorkItem?; private var gateSeqId = 0
    private var lastGranted = ""; private var lastGrantTs: Date = .distantPast
    private var voteBuf: [[String]] = []; private var ocrCnt = 0; private var fpsMeasureTs = Date()
    private let plateRE = try! NSRegularExpression(
        // Polskie tablice: 1-3 litery + 1-5 cyfr + 0-5 liter końcowych
        // Obsługuje: WA12345, W1MWMMB, KR123AB, PO1ABC, GD00001 itp.
        pattern: "^[A-Z]{1,3}\\d{1,5}[A-Z]{0,5}$"
    )

    override init() {
        super.init()
        let avail = LensType.allCases.filter { AVCaptureDevice.default($0.deviceType, for:.video, position:.back) != nil }
        DispatchQueue.main.async { self.availableLenses = avail }
        sessionQ.async { self._startSession(lens: .wide) }
    }

    func switchLens(to lens: LensType) { ocrCnt = 0; fpsMeasureTs = Date(); sessionQ.async { self._startSession(lens:lens) } }
    var captureSession: AVCaptureSession { session }

    private func _startSession(lens: LensType) {
        session.beginConfiguration(); session.inputs.forEach { session.removeInput($0) }
        session.sessionPreset = .hd1280x720
        let device = AVCaptureDevice.default(lens.deviceType, for:.video, position:.back)
                  ?? AVCaptureDevice.default(.builtInWideAngleCamera, for:.video, position:.back)
        guard let device, let input = try? AVCaptureDeviceInput(device:device), session.canAddInput(input) else {
            session.commitConfiguration(); DispatchQueue.main.async { self.cameraOK = false }; return
        }
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration(); session.addInput(input)
        if !session.outputs.contains(videoOut) {
            videoOut.setSampleBufferDelegate(self, queue: ocrQ)
            videoOut.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        }
        // NIE ustawiamy videoRotationAngle — CVPixelBuffer zostawia surowe piksele (landscape)
        // Rotacja aplikowana ręcznie w jpegQ na CIImage
        session.commitConfiguration(); if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { self.cameraOK = true }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        ocrCnt += 1; let now = Date()
        if now.timeIntervalSince(fpsMeasureTs) >= 3 {
            let fps = Double(ocrCnt) / now.timeIntervalSince(fpsMeasureTs)
            ocrCnt = 0; fpsMeasureTs = now
            DispatchQueue.main.async { self.ocrFPS = fps }
        }

        let req = VNRecognizeTextRequest { [weak self] r, _ in
            guard let self else { return }
            let observations = r.results as? [VNRecognizedTextObservation] ?? []
            let texts = observations.compactMap { o -> (String, Double)? in
                guard let t = o.topCandidates(1).first else { return nil }
                return (t.string, Double(t.confidence))
            }
            if self._ocrModeSafe == .free {
                self.processFree(texts)
            } else {
                // Zbierz boxy kandydatów tablic przed głosowaniem
                let plateObs = observations.filter { o in
                    guard let t = o.topCandidates(1).first else { return false }
                    let clean = t.string.uppercased().filter { $0.isLetter || $0.isNumber }
                    return self.plateRE.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) != nil
                }
                let boxes = plateObs.map { $0.boundingBox } // Vision coords: (0,0)=bottomLeft, normalized
                self.jpegLock.lock()
                self.detectedBoxes = boxes
                self.jpegLock.unlock()
                self.processPlate(texts)
            }
        }
        req.recognitionLevel = .fast; req.usesLanguageCorrection = false; req.recognitionLanguages = ["en-US"]
        // Bufor z tylnej kamery (portret) = landscape piksele, tekst jest obrócony 90° CW
        // .right = "obraz jest obrócony 90° CW od naturalnej orientacji" → Vision wyprostowuje przed OCR
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .right).perform([req])

        // Zapisz JPEG co ~3 klatki (~10fps dla streamu webowego)
        guard ocrCnt % 3 == 0 else { return }

        // Kopia pixel buffer reference dla async processing
        let pxCopy = px
        jpegLock.lock()
        let boxes = detectedBoxes
        jpegLock.unlock()

        jpegQ.async { [weak self] in
            guard let self else { return }
            let ciRaw = CIImage(cvPixelBuffer: pxCopy)
            let h = ciRaw.extent.height  // 720 (potrzebne do translacji po rotacji)
            // Tylna kamera w portrecie: CVPixelBuffer = landscape (góra obrazu = prawy bok)
            // +pi/2 (90° CW) wyprostowuje: (x,y)→(-y,x), translacja (h,0) przywraca do ćwiartki +
            // Obrót +90° CW: (x,y)→(-y,x), translacja (h,0) → obraz wyprostowany ale mirrored
            // Flip poziomy: scaleX=-1 z translacją (nowa_szerokość=h, 0) → usuwa mirror
            let rotation = CGAffineTransform(rotationAngle: .pi / 2)
                .concatenating(CGAffineTransform(translationX: h, y: 0))
            let flipped = CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: h, y: 0))
            let ciRotated = ciRaw.transformed(by: rotation).transformed(by: flipped)
            let extent = ciRotated.extent
            guard let cgImage = self.ciContext.createCGImage(ciRotated, from: extent) else { return }
            let outSize = CGSize(width: extent.width, height: extent.height)
            let uiImage = self.drawBoxes(on: cgImage, boxes: boxes, size: outSize)
            if let jpeg = uiImage.jpegData(compressionQuality: 0.55) {
                self.jpegLock.lock()
                self.latestJpeg = jpeg
                self.jpegLock.unlock()
            }
        }
    }

    /// Rysuje zielone ramki wokół wykrytych tablic na klatce
    private func drawBoxes(on cgImage: CGImage, boxes: [CGRect], size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let c = ctx.cgContext
            // Rysuj bazowy obraz
            c.draw(cgImage, in: CGRect(origin: .zero, size: size))
            guard !boxes.isEmpty else { return }
            c.setStrokeColor(UIColor(red: 0.72, green: 1.0, blue: 0.21, alpha: 1).cgColor) // GV.lime
            c.setLineWidth(3)
            // Vision bbox: origin bottom-left, y odwrócone względem UIKit
            for box in boxes {
                let rect = CGRect(
                    x:      box.origin.x * size.width,
                    y:      (1 - box.origin.y - box.size.height) * size.height,
                    width:  box.size.width  * size.width,
                    height: box.size.height * size.height
                )
                c.stroke(rect.insetBy(dx: -4, dy: -4))
            }
        }
    }

    private func processFree(_ texts: [(String,Double)]) {
        for (text, conf) in texts {
            for tok in text.components(separatedBy:.whitespaces) {
                let t = tok.uppercased().filter { $0.isLetter || $0.isNumber }
                guard t.count >= 3 else { continue }
                let e = LogEntry(id:Int64(Date().timeIntervalSince1970*1000)&0x7FFFFFFF,
                    plate:t,rawOcr:t,ownerName:"",timestamp:ts(),
                    confidence:conf*100,granted:false,blocked:false,isFleet:false,isFreeMode:true)
                DispatchQueue.main.async { self.liveLog.insert(e,at:0); if self.liveLog.count>300 { self.liveLog.removeLast(50) } }
            }
        }
    }

    private func processPlate(_ texts: [(String,Double)]) {
        var candidates: [String] = []
        for (text,_) in texts {
            let clean = text.uppercased().filter { $0.isLetter || $0.isNumber }
            let ns = clean as NSString
            for m in plateRE.matches(in:clean, range:NSRange(location:0,length:ns.length)) {
                let p = ns.substring(with:m.range); if p.count >= 5 && p.count <= 10 { candidates.append(p) }
            }
        }
        guard !candidates.isEmpty else { return }
        voteBuf.append(candidates); if voteBuf.count > voteWindowSize { voteBuf.removeFirst() }
        let flat = voteBuf.flatMap { $0 }
        let counts = Dictionary(grouping:flat,by:{$0}).mapValues {$0.count}
        guard let (winner,votes) = counts.max(by:{$0.value < $1.value}), votes >= minVotes else { return }
        let now = Date()
        // Nie odpalaj gdy brama jest już otwarta lub w trakcie otwierania
        guard gateState == .closed || gateState == .closing else {
            // Resetuj buffer żeby nie akumulował głosów gdy brama otwarta
            voteBuf.removeAll()
            return
        }
        guard winner != lastGranted || now.timeIntervalSince(lastGrantTs) > 8 else { return }
        lastGranted = winner; lastGrantTs = now; voteBuf.removeAll()
        DispatchQueue.main.async { self.lastRaw = winner }
        handleDetection(winner)
    }

    private func handleDetection(_ plate: String) {
        let row = Database.shared.findPlate(plate)
        let matched = row?.plate ?? plate
        let granted = row != nil && !(row!.blocked)
        let blocked = row?.blocked ?? false
        // Snapshot tylko gdy dostęp przyznany — bierzemy po krótkiej chwili
        // żeby jpegQ.async zdążył przetworzyć bieżącą klatkę
        let captureTs = ts()
        DispatchQueue.main.async {
            self.lastPlate = matched
            if granted { self.triggerOpen() }
        }
        if granted {
            jpegQ.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.jpegLock.lock()
                let snap = self.latestJpeg
                self.jpegLock.unlock()
                let logId = Database.shared.logAccess(plate:matched,raw:plate,conf:99,granted:true,blocked:false,owner:row?.ownerName ?? "",fleet:row?.isFleet ?? false,snapshot:snap)
                let entry = LogEntry(id:logId,plate:matched,rawOcr:plate,ownerName:row?.ownerName ?? "",timestamp:captureTs,confidence:99,granted:true,blocked:false,isFleet:row?.isFleet ?? false,isFreeMode:false,snapshotData:snap != nil ? Data([1]) : nil)
                DispatchQueue.main.async {
                    self.liveLog.insert(entry, at:0)
                    if self.liveLog.count > 100 { self.liveLog.removeLast() }
                }
            }
        } else {
            let logId = Database.shared.logAccess(plate:matched,raw:plate,conf:99,granted:false,blocked:blocked,owner:row?.ownerName ?? "",fleet:row?.isFleet ?? false,snapshot:nil)
            let entry = LogEntry(id:logId,plate:matched,rawOcr:plate,ownerName:row?.ownerName ?? "",timestamp:captureTs,confidence:99,granted:false,blocked:blocked,isFleet:row?.isFleet ?? false,isFreeMode:false,snapshotData:nil)
            DispatchQueue.main.async {
                self.liveLog.insert(entry, at:0)
                if self.liveLog.count > 100 { self.liveLog.removeLast() }
            }
        }
    }

    func triggerOpen() {
        // Nie resetuj jeśli brama już otwarta lub się otwiera
        guard gateState == .closed || gateState == .closing else { return }
        gateSeqId += 1; let seq = gateSeqId; gateTimer?.cancel()
        withAnimation(.spring(duration:0.4)) { gateState = .opening }
        let openW = DispatchWorkItem { [weak self] in
            guard let self, self.gateSeqId==seq else { return }
            DispatchQueue.main.async { withAnimation(.spring(duration:0.4)) { self.gateState = .open } }
            let closeW = DispatchWorkItem { [weak self] in
                guard let self, self.gateSeqId==seq else { return }
                DispatchQueue.main.async { withAnimation(.spring(duration:0.4)) { self.gateState = .closing } }
                DispatchQueue.main.asyncAfter(deadline:.now()+self.closingTime) { [weak self] in
                    guard let self, self.gateSeqId==seq else { return }
                    withAnimation(.spring(duration:0.4)) { self.gateState = .closed }
                }
            }
            self.gateTimer = closeW
            DispatchQueue.main.asyncAfter(deadline:.now()+self.openDuration, execute:closeW)
        }
        gateTimer = openW
        DispatchQueue.main.asyncAfter(deadline:.now()+openingTime, execute:openW)
    }

    func triggerClose() {
        guard gateState != .closed else { return }
        gateSeqId += 1; let seq = gateSeqId; gateTimer?.cancel()
        withAnimation(.spring(duration:0.4)) { gateState = .closing }
        DispatchQueue.main.asyncAfter(deadline:.now()+closingTime) { [weak self] in
            guard let self, self.gateSeqId==seq else { return }
            withAnimation(.spring(duration:0.4)) { self.gateState = .closed }
        }
    }

    private func ts() -> String { DateFormatter().apply { $0.dateFormat = "HH:mm:ss" }.string(from:Date()) }
}

extension DateFormatter {
    func apply(_ f: (DateFormatter)->Void) -> DateFormatter { f(self); return self }
}
extension Double {
    func nonZeroOrDefault(_ d: Double) -> Double { self == 0 ? d : self }
}

// MARK: ─── Camera Preview ─────────────────────────────────────────────────────

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PV { let v=PV(); v.layer.session=session; v.layer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ v: PV, context: Context) {}
    class PV: UIView { override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }; override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer } }
}

// MARK: ─── Splash Screen ─────────────────────────────────────────────────────

enum LoadStep: String, CaseIterable {
    case database = "Inicjalizacja bazy danych"
    case camera   = "Uruchamianie kamery"
    case server   = "Uruchamianie serwera web"
    case done     = "Gotowe"
}

struct SplashScreen: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var webServer: WebServer

    // Which steps are complete
    @State private var completedSteps: Set<LoadStep> = []
    @State private var currentStep: LoadStep = .database
    @State private var logoScale: CGFloat = 0.7
    @State private var logoOpacity: Double = 0
    @State private var stepsOpacity: Double = 0
    @State private var dismiss = false

    private var progress: Double {
        Double(completedSteps.count) / Double(LoadStep.allCases.count - 1) // exclude .done
    }

    var body: some View {
        ZStack {
            // Background — same mesh as main app
            LinearGradient(colors:[GV.bgTop, GV.bgBottom], startPoint:.top, endPoint:.bottom)
                .ignoresSafeArea()
            GeometryReader { geo in
                Circle().fill(GV.purple.opacity(0.22)).frame(width:geo.size.width*0.8)
                    .blur(radius:100).offset(x:-geo.size.width*0.2, y:-80)
                Circle().fill(GV.azure.opacity(0.12)).frame(width:geo.size.width*0.65)
                    .blur(radius:120).offset(x:geo.size.width*0.5, y:geo.size.height*0.55)
            }.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo block
                VStack(spacing: 18) {
                    // Icon with glow ring
                    ZStack {
                        Circle()
                            .fill(GV.purple.opacity(0.15))
                            .frame(width: 100, height: 100)
                        Circle()
                            .strokeBorder(GV.purple.opacity(0.35), lineWidth: 1.5)
                            .frame(width: 100, height: 100)
                        Image(systemName: "shield.checkerboard")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [GV.purple, GV.azure],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    }
                    .shadow(color: GV.purple.opacity(0.6), radius: 24)
                    .scaleEffect(logoScale)

                    // Name
                    VStack(spacing: 6) {
                        Text("GateVision")
                            .font(.system(size: 36, weight: .black))
                            .foregroundStyle(GV.fg)
                        Text("System kontroli dostępu")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(GV.muted)
                    }
                }
                .opacity(logoOpacity)

                Spacer()

                // Steps + progress bar
                VStack(spacing: 20) {
                    // Step list
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(LoadStep.allCases.filter { $0 != .done }, id: \.self) { step in
                            StepRow(step: step,
                                    isDone: completedSteps.contains(step),
                                    isCurrent: currentStep == step && !completedSteps.contains(step))
                        }
                    }
                    .padding(.horizontal, 40)
                    .opacity(stepsOpacity)

                    // Progress bar
                    VStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(GV.border)
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(LinearGradient(colors:[GV.purple, GV.azure],
                                                        startPoint:.leading, endPoint:.trailing))
                                    .frame(width: geo.size.width * progress, height: 4)
                                    .animation(.spring(duration: 0.5), value: progress)
                                    .shadow(color: GV.azure.opacity(0.6), radius: 6)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 40)
                        .opacity(stepsOpacity)

                        Text(currentStep == .done ? "100%" : "\(Int(progress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(GV.muted)
                            .opacity(stepsOpacity)
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .opacity(dismiss ? 0 : 1)
        .onAppear { startSequence() }
        .onChange(of: engine.cameraOK) { _, ok in
            if ok { completeStep(.camera) }
        }
        .onChange(of: webServer.isRunning) { _, running in
            if running { completeStep(.server) }
        }
    }

    private func startSequence() {
        // Animate logo in
        withAnimation(.spring(duration: 0.7, bounce: 0.3)) {
            logoScale = 1.0; logoOpacity = 1.0
        }
        withAnimation(.easeIn(duration: 0.5).delay(0.3)) {
            stepsOpacity = 1.0
        }

        // Step 1: Database — completes almost immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completeStep(.database)
            currentStep = .camera
        }
        // Step 2: Camera — watched via onChange(engine.cameraOK)
        // Fallback if camera takes too long
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if !completedSteps.contains(.camera) { completeStep(.camera) }
        }
        // Step 3: Server — watched via onChange(webServer.isRunning)
        // Fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            if !completedSteps.contains(.server) { completeStep(.server) }
        }
    }

    private func completeStep(_ step: LoadStep) {
        _ = withAnimation(.spring(duration: 0.4)) {
            completedSteps.insert(step)
        }
        // Advance currentStep label
        let ordered: [LoadStep] = [.database, .camera, .server]
        if let idx = ordered.firstIndex(of: step), idx + 1 < ordered.count {
            currentStep = ordered[idx + 1]
        }
        // All 3 real steps done → dismiss after short delay
        if completedSteps.contains(.database) &&
           completedSteps.contains(.camera) &&
           completedSteps.contains(.server) {
            currentStep = .done
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeInOut(duration: 0.6)) { dismiss = true }
            }
        }
    }
}

struct StepRow: View {
    let step: LoadStep
    let isDone: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(isDone ? GV.lime.opacity(0.15) : isCurrent ? GV.purple.opacity(0.12) : GV.border)
                    .frame(width: 24, height: 24)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GV.lime)
                } else if isCurrent {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .tint(GV.purple)
                } else {
                    Circle()
                        .fill(GV.muted.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            Text(step.rawValue)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isDone ? GV.fg : isCurrent ? GV.fg : GV.muted)

            Spacer()

            if isDone {
                Text("OK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(GV.lime)
            } else if isCurrent {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GV.purple)
            }
        }
        .animation(.spring(duration: 0.4), value: isDone)
        .animation(.spring(duration: 0.4), value: isCurrent)
    }
}

// MARK: ─── App Entry ──────────────────────────────────────────────────────────

@main
struct GateVisionApp: App {
    // Inicjalizowane tu — istnieją od pierwszej klatki, przed RootView
    @StateObject private var engine    = CameraEngine()
    @StateObject private var webServer = WebServer.shared

    var body: some Scene {
        WindowGroup {
            RootView(engine: engine, webServer: webServer)
        }
    }
}

struct RootView: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var webServer: WebServer
    @State private var splashDone  = false
    @State private var minTimeDone = false  // minimum 0.7s splash

    var body: some View {
        ZStack {
            // ── Główna aplikacja (renderuje się w tle od razu) ─────────────
            mainContent
                .opacity(splashDone ? 1 : 0)

            // ── Splash screen ─────────────────────────────────────────────
            if !splashDone {
                SplashScreen(engine: engine, webServer: webServer)
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            webServer.start(engine: engine)
            // Minimum czas wyświetlania splash
            DispatchQueue.main.asyncAfter(deadline: .now() + engine.splashMinDuration) {
                minTimeDone = true
                checkDismiss()
            }
        }
        .onChange(of: splashIsDone) { _, newValue in
            if newValue { checkDismiss() }
        }
    }

    private var splashIsDone: Bool {
        engine.cameraOK && webServer.isRunning
    }

    private func checkDismiss() {
        guard splashIsDone && minTimeDone else { return }
        withAnimation(.easeInOut(duration: 0.5)) { splashDone = true }
    }

    private var mainContent: some View {
        ZStack {
            LinearGradient(colors:[GV.bgTop,GV.bgBottom], startPoint:.top, endPoint:.bottom).ignoresSafeArea()
            GeometryReader { geo in
                Circle().fill(GV.purple.opacity(0.16)).frame(width:geo.size.width*0.7).blur(radius:90).offset(x:-geo.size.width*0.2,y:-40)
                Circle().fill(GV.azure.opacity(0.09)).frame(width:geo.size.width*0.55).blur(radius:110).offset(x:geo.size.width*0.55,y:geo.size.height*0.6)
            }.ignoresSafeArea()

            TabView {
                StatusTab(engine: engine)
                    .tabItem { Label("Status", systemImage:"gauge.open.with.lines.needle.33percent") }
                LogTab(engine: engine)
                    .tabItem { Label("Logi", systemImage:"list.bullet.rectangle") }
                PlatesTab()
                    .tabItem { Label("Tablice", systemImage:"car.rear.fill") }
                SettingsTab(engine: engine, webServer: webServer)
                    .tabItem { Label("Ustawienia", systemImage:"gearshape.2.fill") }
            }
        }
    }
}

// MARK: ─── Shared UI Components ───────────────────────────────────────────────

struct GlowPill: View {
    let label: String; let color: Color; var animated = false
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.9), radius: 4)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.10))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 1))
        .clipShape(Capsule())
    }
}

struct GlassBtn: View {
    let label: String; let icon: String; let color: Color; let action: ()->Void
    var body: some View {
        Button(action:action) {
            Label(label, systemImage:icon)
                .font(.system(size:14,weight:.bold))
                .foregroundStyle(color)
                .frame(maxWidth:.infinity).padding(.vertical,13)
                .background(.ultraThinMaterial)
                .overlay(color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).strokeBorder(color.opacity(0.35),lineWidth:1))
                .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
                .shadow(color:color.opacity(0.18),radius:8,y:2)
        }
    }
}

struct MetricTile: View {
    let icon,title,value: String; let sub: String?; let color: Color
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Label(title,systemImage:icon).font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(GV.muted)
            Text(value).font(.system(size:30,weight:.black,design:.monospaced)).foregroundStyle(color).minimumScaleFactor(0.5).lineLimit(1)
            if let sub { Text(sub).font(.system(size:11)).foregroundStyle(GV.muted).lineLimit(2) }
        }
        .padding(16).frame(maxWidth:.infinity,alignment:.leading).glassCard(radius:18)
    }
}

struct CompactRow: View {
    let entry: LogEntry
    var color: Color { entry.granted ? GV.lime : entry.blocked ? GV.red : entry.isFreeMode ? GV.azure : GV.muted }
    var body: some View {
        HStack(spacing:10) {
            Circle().fill(color).frame(width:6,height:6).shadow(color:color.opacity(0.8),radius:4)
            Text(entry.plate).font(.system(size:14,weight:.bold,design:.monospaced)).foregroundStyle(color)
            Spacer()
            Text(entry.timestamp).font(.system(size:10,design:.monospaced)).foregroundStyle(GV.muted)
        }
    }
}

// MARK: ─── Status Tab ─────────────────────────────────────────────────────────

struct StatusTab: View {
    @ObservedObject var engine: CameraEngine
    @State private var showCam = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:18) {

                    // Camera
                    ZStack(alignment:.topLeading) {
                        Group {
                            if showCam {
                                CameraPreviewView(session:engine.captureSession).frame(height:230).clipped()
                                    .overlay(LinearGradient(colors:[.clear,GV.bgBottom.opacity(0.85)],startPoint:.center,endPoint:.bottom))
                            } else { Rectangle().fill(.ultraThinMaterial).frame(height:52) }
                        }.animation(.easeInOut(duration:0.3),value:showCam)

                        VStack {
                            HStack {
                                Spacer()
                                Button { withAnimation { showCam.toggle() } } label: {
                                    Image(systemName: showCam ? "eye.slash" : "eye")
                                        .font(.system(size:13))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(8)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }.padding(10)
                            }
                            Spacer()
                        }.frame(height: showCam ? 230 : 52)
                    }
                    .glassCard(radius:22).padding(.horizontal,16).padding(.top,8)

                    // Gate card
                    GateCard(engine:engine).padding(.horizontal,16)

                    // Metrics
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                        MetricTile(icon:"text.rectangle.fill",title:"TABLICA",value:engine.lastPlate.isEmpty ? "—":engine.lastPlate,sub:engine.lastRaw.isEmpty||engine.lastRaw==engine.lastPlate ? nil:"RAW: \(engine.lastRaw)",color:GV.azure)
                        MetricTile(icon:"gauge.open.with.lines.needle.33percent",title:"FPS",value:engine.ocrFPS>0 ? String(format:"%.1f",engine.ocrFPS):"—",sub:"Neural Engine",color:GV.lime)
                    }.padding(.horizontal,16)

                    // Recent
                    if !engine.liveLog.isEmpty {
                        VStack(alignment:.leading,spacing:10) {
                            Label("Ostatnie detekcje",systemImage:"bolt.fill").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundStyle(GV.muted)
                            ForEach(engine.liveLog.prefix(4)) { CompactRow(entry:$0) }
                        }
                        .padding(16).glassCard(radius:20).padding(.horizontal,16)
                    }

                    Spacer(minLength:24)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("GateVision")
        }
    }
}

struct GateCard: View {
    @ObservedObject var engine: CameraEngine
    @State private var pulse = false

    var body: some View {
        VStack(spacing:16) {
            HStack(spacing:16) {
                ZStack {
                    Circle().fill(engine.gateState.color.opacity(0.14)).frame(width:62,height:62)
                    Circle().stroke(engine.gateState.color.opacity(0.25),lineWidth:1.5).frame(width:62,height:62)
                        .scaleEffect(pulse ? 1.3:1).opacity(pulse ? 0:0.7)
                    Image(systemName:engine.gateState.sfSymbol).font(.system(size:26,weight:.semibold))
                        .foregroundStyle(engine.gateState.color)
                        .symbolEffect(.pulse,isActive:engine.gateState.isAnimating)
                }
                .shadow(color:engine.gateState.color.opacity(0.45),radius:16)
                .onAppear { withAnimation(.easeOut(duration:2).repeatForever(autoreverses:false)) { pulse=true } }

                VStack(alignment:.leading,spacing:4) {
                    Text("BRAMA").font(.system(size:10,weight:.bold,design:.monospaced)).foregroundStyle(GV.muted)
                    Text(engine.gateState.rawValue).font(.system(size:23,weight:.black)).foregroundStyle(engine.gateState.color)
                        .animation(.spring(duration:0.4),value:engine.gateState)
                }
                Spacer()
            }
            HStack(spacing:12) {
                GlassBtn(label:"Otwórz",icon:"door.open.fill",color:GV.lime) { engine.triggerOpen() }
                GlassBtn(label:"Zamknij",icon:"door.closed.fill",color:GV.red) { engine.triggerClose() }
            }
        }
        .padding(18)
        .glassCard(radius:22,tint:engine.gateState.color.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius:22,style:.continuous).strokeBorder(engine.gateState.color.opacity(0.22),lineWidth:1.5))
        .animation(.spring(duration:0.5),value:engine.gateState)
    }
}

// MARK: ─── Log Tab ────────────────────────────────────────────────────────────

struct LogTab: View {
    @ObservedObject var engine: CameraEngine
    @State private var showLive = true; @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                Picker("",selection:$showLive) { Text("Na żywo").tag(true); Text("Historia").tag(false) }
                    .pickerStyle(.segmented).padding(.horizontal,16).padding(.vertical,10)
                if showLive {
                    List(engine.liveLog) { LogRowFull(entry:$0) }.listStyle(.plain).scrollContentBackground(.hidden)
                } else {
                    DBLogView(query:$query)
                }
            }
            .navigationTitle("Logi")
            .searchable(text:$query,prompt:"Szukaj tablicy...")
        }
    }
}

struct DBLogView: View {
    @Binding var query: String; @State private var entries: [LogEntry] = []
    var body: some View {
        List(entries) { LogRowFull(entry:$0) }.listStyle(.plain).scrollContentBackground(.hidden)
            .onAppear { load() }.onChange(of:query) { load() }
    }
    private func load() { entries = Database.shared.fetchLog(query:query) }
}

struct LogRowFull: View {
    let entry: LogEntry
    @State private var showSnapshot = false
    var color: Color { entry.granted ? GV.lime : entry.blocked ? GV.red : entry.isFreeMode ? GV.azure : GV.muted }
    var statusLabel: String { entry.granted ? "Dostęp" : entry.blocked ? "Zablok." : entry.isFreeMode ? "Wolny" : "Nieznany" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width:8,height:8).shadow(color:color.opacity(0.9),radius:5)
                VStack(alignment:.leading,spacing:3) {
                    HStack {
                        Text(entry.plate).font(.system(size:16,weight:.bold,design:.monospaced)).foregroundStyle(color)
                        if entry.confidence > 0 && entry.confidence < 99 {
                            Text(String(format:"%.0f%%",entry.confidence)).font(.system(size:10,weight:.bold,design:.monospaced)).foregroundStyle(entry.confidence>=80 ? GV.lime:GV.orange)
                        }
                        Spacer()
                        Text(statusLabel).font(.system(size:10,weight:.bold)).foregroundStyle(color).padding(.horizontal,8).padding(.vertical,3).background(color.opacity(0.1)).clipShape(Capsule())
                    }
                    if !entry.ownerName.isEmpty { Text(entry.ownerName).font(.system(size:12)).foregroundStyle(GV.muted) }
                    Text(entry.timestamp).font(.system(size:10,design:.monospaced)).foregroundStyle(GV.muted)
                }

                // Miniatura snapshot — ładuje JPEG bezpośrednio z DB
                if entry.snapshotData != nil {
                    SnapshotThumbnail(logId: entry.id, color: color)
                        .onTapGesture { showSnapshot = true }
                }
            }
        }
        .padding(.vertical,6)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(GV.border)
        .sheet(isPresented: $showSnapshot) {
            SnapshotViewerFromDB(logId: entry.id, plate: entry.plate, timestamp: entry.timestamp)
        }
    }
}

struct SnapshotThumbnail: View {
    let logId: Int64; let color: Color
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(color.opacity(0.4),lineWidth:1))
                    .overlay(alignment:.bottomTrailing) {
                        Image(systemName:"arrow.up.left.and.arrow.down.right")
                            .font(.system(size:8,weight:.bold)).foregroundStyle(.white)
                            .padding(3).background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius:3))
                    }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.08))
                    .frame(width: 64, height: 40)
                    .overlay(ProgressView().scaleEffect(0.5).tint(color))
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard image == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = Database.shared.fetchSnapshot(logId: logId),
               let img = UIImage(data: data) {
                DispatchQueue.main.async { self.image = img }
            }
        }
    }
}

struct SnapshotViewerFromDB: View {
    let logId: Int64; let plate: String; let timestamp: String
    @State private var image: UIImage? = nil
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = image {
                    Image(uiImage: img).resizable().scaledToFit().ignoresSafeArea()
                } else {
                    ProgressView().tint(GV.lime)
                }
            }
            .navigationTitle(plate).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Text(timestamp).font(.system(size:12,design:.monospaced)).foregroundStyle(.white.opacity(0.6))
                }
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Zamknij") { dismiss() }.tint(GV.lime)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.global(qos:.userInitiated).async {
                if let data = Database.shared.fetchSnapshot(logId: logId),
                   let img = UIImage(data: data) {
                    DispatchQueue.main.async { self.image = img }
                }
            }
        }
    }
}

// MARK: ─── Plates Tab ─────────────────────────────────────────────────────────

struct PlatesTab: View {
    @State private var plates: [PlateEntry] = []; @State private var query = ""
    @State private var showAdd = false; @State private var editing: PlateEntry?

    var body: some View {
        NavigationStack {
            List {
                ForEach(plates) { plate in
                    PlateRowFull(plate:plate,
                        onEdit: { editing = plate },
                        onDelete: { Database.shared.deletePlate(id:plate.id); load() },
                        onToggle: { Database.shared.toggleBlock(id:plate.id); load() })
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle("Tablice")
            .searchable(text:$query,prompt:"Szukaj...").onChange(of:query) { load() }
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { showAdd=true } label: { Image(systemName:"plus.circle.fill").foregroundStyle(GV.purple).font(.system(size:22)) } } }
            .onAppear { load() }
        }
        .sheet(isPresented:$showAdd,onDismiss:load) { PlateForm(existing:nil) }
        .sheet(item:$editing,onDismiss:load) { PlateForm(existing:$0) }
    }
    private func load() { plates = Database.shared.fetchPlates(query:query) }
}

struct PlateRowFull: View {
    let plate: PlateEntry; let onEdit,onDelete,onToggle: ()->Void
    var body: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:4) {
                HStack(spacing:8) {
                    Text(plate.plate).font(.system(size:17,weight:.black,design:.monospaced)).foregroundStyle(plate.blocked ? GV.red:GV.fg)
                    if plate.isFleet { Text("Flota").font(.system(size:9,weight:.bold)).foregroundStyle(GV.purple).padding(.horizontal,6).padding(.vertical,2).background(GV.purple.opacity(0.1)).clipShape(Capsule()) }
                    if plate.blocked { Text("Zablok.").font(.system(size:9,weight:.bold)).foregroundStyle(GV.red).padding(.horizontal,6).padding(.vertical,2).background(GV.red.opacity(0.1)).clipShape(Capsule()) }
                }
                if !plate.ownerName.isEmpty { Text(plate.ownerName).font(.system(size:13)).foregroundStyle(GV.muted) }
            }
            Spacer()
            Menu {
                Button { onEdit() } label: { Label("Edytuj",systemImage:"pencil") }
                Button { onToggle() } label: { Label(plate.blocked ? "Odblokuj":"Zablokuj",systemImage:plate.blocked ? "checkmark.circle":"nosign") }
                Divider()
                Button(role:.destructive) { onDelete() } label: { Label("Usuń",systemImage:"trash") }
            } label: { Image(systemName:"ellipsis.circle").foregroundStyle(GV.muted).font(.system(size:20)) }
        }
        .padding(.vertical,6).listRowBackground(Color.clear).listRowSeparatorTint(GV.border)
    }
}

struct PlateForm: View {
    let existing: PlateEntry?
    @Environment(\.dismiss) var dismiss
    @State private var plateText = ""
    @State private var ownerText = ""
    @State private var isFleet = false
    @State private var isBlocked = false
    @State private var notesText = ""
    @State private var errorText = ""
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors:[GV.bgTop,GV.bgBottom],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
                Form {
                    Section("Numer rejestracyjny") { TextField("np. WA12345",text:$plateText).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(size:20,weight:.black,design:.monospaced)).disabled(existing != nil)
                    }
                    Section("Właściciel") { TextField("Imię i nazwisko",text:$ownerText); Toggle("Flota",isOn:$isFleet); Toggle("Zablokowany",isOn:$isBlocked) }
                    Section("Notatki") { TextField("Opcjonalnie...",text:$notesText,axis:.vertical).lineLimit(3,reservesSpace:true) }
                    if !errorText.isEmpty { Section { Text(errorText).foregroundStyle(GV.red) } }
                }.scrollContentBackground(.hidden)
            }
            .navigationTitle(existing==nil ? "Nowa tablica":"Edytuj").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Zapisz") { save() }.fontWeight(.bold).tint(GV.purple) }
            }
        }
        .onAppear {
            if let e = existing {
                plateText = e.plate
                ownerText = e.ownerName
                isFleet   = e.isFleet
                isBlocked = e.blocked
                notesText = e.notes
            }
        }
    }
    private func save() {
        let clean = plateText.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count >= 4 else { errorText = "Za krótki numer"; return }
        let entry = PlateEntry(id: existing?.id ?? 0, plate: clean, ownerName: ownerText,
                               notes: notesText, createdAt: "", isFleet: isFleet, blocked: isBlocked)
        if existing != nil { Database.shared.updatePlate(entry) }
        else if !Database.shared.addPlate(entry) { errorText = "Tablica już istnieje"; return }
        dismiss()
    }
}

// MARK: ─── Settings Tab ───────────────────────────────────────────────────────

struct SettingsTab: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var webServer: WebServer

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors:[GV.bgTop,GV.bgBottom],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
                Form {
                    // ── Panel Web ────────────────────────────────────────
                    Section {
                        HStack(spacing:14) {
                            ZStack {
                                Circle().fill(webServer.isRunning ? GV.lime.opacity(0.15):GV.red.opacity(0.1)).frame(width:44,height:44)
                                Image(systemName:webServer.isRunning ? "antenna.radiowaves.left.and.right":"antenna.radiowaves.left.and.right.slash")
                                    .font(.system(size:20,weight:.semibold))
                                    .foregroundStyle(webServer.isRunning ? GV.lime:GV.red)
                                    .symbolEffect(.pulse,isActive:webServer.isRunning)
                            }
                            VStack(alignment:.leading,spacing:5) {
                                Text(webServer.isRunning ? "Serwer działa":"Serwer zatrzymany")
                                    .font(.system(size:15,weight:.bold))
                                    .foregroundStyle(webServer.isRunning ? GV.lime:GV.red)
                                if webServer.isRunning {
                                    Text("http://\(webServer.localIP):6600")
                                        .font(.system(size:13,design:.monospaced))
                                        .foregroundStyle(GV.azure)
                                        .textSelection(.enabled)
                                    Text("Otwórz w przeglądarce na tym samym WiFi")
                                        .font(.system(size:11)).foregroundStyle(GV.muted)
                                }
                            }
                            Spacer()
                            Button {
                                if webServer.isRunning { webServer.stop() } else { webServer.start(engine:engine) }
                            } label: {
                                Text(webServer.isRunning ? "Stop":"Start")
                                    .font(.system(size:13,weight:.bold))
                                    .foregroundStyle(webServer.isRunning ? GV.red:GV.lime)
                                    .padding(.horizontal,14).padding(.vertical,7)
                                    .background(webServer.isRunning ? GV.red.opacity(0.1):GV.lime.opacity(0.1))
                                    .overlay(Capsule().strokeBorder(webServer.isRunning ? GV.red.opacity(0.3):GV.lime.opacity(0.3),lineWidth:1))
                                    .clipShape(Capsule())
                            }
                        }.padding(.vertical,6)
                    } header: { Text("Panel Web — port 6600") }

                    // ── OCR ──────────────────────────────────────────────
                    Section {
                        Picker("Tryb",selection:$engine.ocrMode) { ForEach(OCRMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                        Text(engine.ocrMode.description).font(.system(size:12)).foregroundStyle(engine.ocrMode == .plate ? GV.muted:GV.azure)
                    } header: { Text("Tryb OCR") }

                    // ── Obiektyw ─────────────────────────────────────────
                    Section {
                        if engine.availableLenses.count > 1 {
                            Picker("Obiektyw",selection:$engine.selectedLens) { ForEach(engine.availableLenses) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                        } else {
                            Text("Jeden obiektyw dostępny.").font(.system(size:12)).foregroundStyle(GV.muted)
                        }
                    } header: { Text("Obiektyw") }

                    // ── Głosowanie ───────────────────────────────────────
                    Section("Głosowanie") {
                        Stepper("Min. powtórzeń: \(engine.minVotes)",value:$engine.minVotes,in:1...10)
                        Stepper("Okno: \(engine.voteWindowSize) klatek",value:$engine.voteWindowSize,in:2...20)
                    }

                    // ── Czasy bramy ──────────────────────────────────────
                    Section("Czasy bramy") {
                        Stepper("Otwieranie: \(Int(engine.openingTime))s",value:$engine.openingTime,in:1...30)
                        Stepper("Otwarcie: \(Int(engine.openDuration))s",value:$engine.openDuration,in:1...120)
                        Stepper("Zamykanie: \(Int(engine.closingTime))s",value:$engine.closingTime,in:1...30)
                    }

                    // ── Info ─────────────────────────────────────────────
                    Section("Info") {
                        LabeledContent("Silnik OCR",value:"Apple Vision")
                        LabeledContent("OCR FPS",value:String(format:"%.1f fps",engine.ocrFPS))
                        LabeledContent("Kamera",value:engine.cameraOK ? "Połączona":"Brak")
                        LabeledContent("Brama",value:engine.gateState.rawValue)
                        LabeledContent("Adres web",value:webServer.isRunning ? "http://\(webServer.localIP):6600":"—")
                    }

                    // ── Debug ────────────────────────────────────────────
                    Section {
                        NavigationLink {
                            DebugTab(engine: engine)
                        } label: {
                            Label("Debug", systemImage: "ladybug.fill")
                                .foregroundStyle(GV.orange)
                        }
                    } header: { Text("Narzędzia") }

                    // ── Dane ─────────────────────────────────────────────
                    Section {
                        Button(role:.destructive) {
                            sqlite3_exec(Database.shared.rawDB,"DELETE FROM access_log",nil,nil,nil)
                            engine.liveLog.removeAll()
                        } label: { Label("Wyczyść logi",systemImage:"trash") }
                    }
                }.scrollContentBackground(.hidden)
            }
            .navigationTitle("Ustawienia")
        }
    }
}

// MARK: ─── Debug Tab ─────────────────────────────────────────────────────────

struct DebugTab: View {
    @ObservedObject var engine: CameraEngine
    @State private var splashDuration: Double = 0.7

    var body: some View {
        ZStack {
            LinearGradient(colors:[GV.bgTop,GV.bgBottom],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
            Form {
                // ── Splash Screen ────────────────────────────────────────
                Section {
                    VStack(alignment:.leading, spacing:8) {
                        HStack {
                            Text("Czas wyświetlania")
                            Spacer()
                            Text(String(format: "%.1f s", engine.splashMinDuration))
                                .font(.system(size:13,design:.monospaced))
                                .foregroundStyle(GV.azure)
                        }
                        Slider(value: $engine.splashMinDuration, in: 0.3...5.0, step: 0.1)
                            .tint(GV.purple)
                        Text("Minimalna długość ekranu ładowania z logo przy starcie aplikacji.")
                            .font(.system(size:11)).foregroundStyle(GV.muted)
                    }.padding(.vertical,4)
                } header: { Text("Ekran ładowania (Splash)") }

                // ── OCR Diagnostics ──────────────────────────────────────
                Section {
                    LabeledContent("OCR FPS",value:String(format:"%.2f",engine.ocrFPS))
                    LabeledContent("Silnik",value:"Apple Vision (.fast)")
                    LabeledContent("Język OCR",value:"en-US")
                    LabeledContent("Rozdzielczość",value:"1280 × 720")
                    LabeledContent("Wykryte boxy",value:"\(engine.detectedBoxes.count)")
                } header: { Text("Diagnostyka OCR") }

                // ── Kamera ───────────────────────────────────────────────
                Section {
                    LabeledContent("Status",value:engine.cameraOK ? "✓ Aktywna" : "✗ Brak")
                    LabeledContent("Obiektyw",value:engine.selectedLens.label)
                    LabeledContent("Dostępne obiektywy",value:engine.availableLenses.map{$0.label}.joined(separator:", "))
                    LabeledContent("Snapshot bufor",value:engine.latestJpeg != nil ? "\(engine.latestJpeg!.count / 1024) KB" : "—")
                } header: { Text("Kamera") }

                // ── Brama ────────────────────────────────────────────────
                Section {
                    LabeledContent("Stan",value:engine.gateState.rawValue)
                    LabeledContent("Otwieranie",value:"\(Int(engine.openingTime))s")
                    LabeledContent("Otwarte przez",value:"\(Int(engine.openDuration))s")
                    LabeledContent("Zamykanie",value:"\(Int(engine.closingTime))s")
                    LabeledContent("Min. głosów",value:"\(engine.minVotes)")
                    LabeledContent("Okno głosowania",value:"\(engine.voteWindowSize) klatek")
                } header: { Text("Brama") }

                // ── Głosowanie — test ────────────────────────────────────
                Section {
                    Button {
                        engine.triggerOpen()
                    } label: {
                        Label("Test: otwórz bramę", systemImage:"door.open.fill")
                            .foregroundStyle(GV.lime)
                    }
                    Button {
                        engine.triggerClose()
                    } label: {
                        Label("Test: zamknij bramę", systemImage:"door.closed.fill")
                            .foregroundStyle(GV.orange)
                    }
                } header: { Text("Testy") }

                // ── Baza danych ──────────────────────────────────────────
                Section {
                    let logCount = Database.shared.fetchLog(limit: 1000).count
                    LabeledContent("Wpisów w logach",value:"\(logCount)")
                    Button(role:.destructive) {
                        sqlite3_exec(Database.shared.rawDB,"DELETE FROM access_log",nil,nil,nil)
                        engine.liveLog.removeAll()
                    } label: { Label("Wyczyść logi",systemImage:"trash.fill") }
                    Button(role:.destructive) {
                        sqlite3_exec(Database.shared.rawDB,"DELETE FROM plates WHERE plate NOT IN ('WA12345','KR99999','PO55123','GD00001')",nil,nil,nil)
                    } label: { Label("Usuń dodane tablice (zachowaj demo)",systemImage:"minus.circle") }
                } header: { Text("Baza danych") }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

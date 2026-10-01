import Foundation

/// Read-only view of the user's own `EPn.EXE` (MZ image), used at runtime to decode
/// sprites, fonts and strings. Nothing read from here is ever written into the app.
///
/// Addresses: a load-image `seg:off` is at file offset `headerSize + seg*16 + off`
/// (docs/formats/README.md, tools/epexe.py).
public struct TableExe: Sendable {
    public let url: URL
    public let bytes: [UInt8]
    public let headerSize: Int

    public enum ExeError: Error, CustomStringConvertible {
        case unreadable(URL)
        case notMZ(URL)
        public var description: String {
            switch self {
            case let .unreadable(u): return "cannot read \(u.path)"
            case let .notMZ(u): return "\(u.path) is not an MZ executable"
            }
        }
    }

    public init(contentsOf url: URL) throws {
        guard let d = try? Data(contentsOf: url) else { throw ExeError.unreadable(url) }
        let b = [UInt8](d)
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { throw ExeError.notMZ(url) }
        self.url = url
        self.bytes = b
        self.headerSize = (Int(b[8]) | Int(b[9]) << 8) * 16
    }

    /// Synthetic image for tests (no header).
    public init(bytes: [UInt8], headerSize: Int = 0) {
        self.url = URL(fileURLWithPath: "/dev/null")
        self.bytes = bytes
        self.headerSize = headerSize
    }

    public func fileOffset(segment: Int, offset: Int = 0) -> Int { headerSize + segment * 16 + offset }

    public func u8(_ o: Int) -> Int { o >= 0 && o < bytes.count ? Int(bytes[o]) : 0 }
    public func u16(_ o: Int) -> Int { u8(o) | u8(o + 1) << 8 }

    /// Zero-terminated byte string at a file offset (at most `max` bytes, terminator excluded).
    public func cString(at o: Int, max: Int = 96) -> [UInt8] {
        var out: [UInt8] = []
        var i = o
        while i >= 0, i < bytes.count, bytes[i] != 0, out.count < max { out.append(bytes[i]); i += 1 }
        return out
    }

    /// Byte-pattern search; `nil` entries are wildcards. Returns file offsets.
    public func find(_ pattern: [UInt8?], in range: Range<Int>? = nil, limit: Int = .max) -> [Int] {
        let r = range.map { max(0, $0.lowerBound)..<min(bytes.count, $0.upperBound) } ?? 0..<bytes.count
        guard !pattern.isEmpty, r.count >= pattern.count, let first = pattern.first else { return [] }
        var hits: [Int] = []
        var i = r.lowerBound
        let end = r.upperBound - pattern.count
        while i <= end {
            if first == nil || bytes[i] == first! {
                var ok = true
                for k in 1..<pattern.count {
                    if let p = pattern[k], bytes[i + k] != p { ok = false; break }
                }
                if ok { hits.append(i); if hits.count >= limit { break } }
            }
            i += 1
        }
        return hits
    }

    /// Locates `original/EP<table>.EXE`: explicit directory, `$EPIC_PINBALL_ORIGINAL`, then
    /// `<dataRoot>/../original`, `<dataRoot>/original` (an imported library). Returns nil if none exists.
    public static func locate(table: Int, dataRoot: URL, explicitDirectory: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var dirs: [URL] = []
        if let e = explicitDirectory { dirs.append(URL(fileURLWithPath: (e as NSString).expandingTildeInPath, isDirectory: true)) }
        if let e = environment["EPIC_PINBALL_ORIGINAL"], !e.isEmpty { dirs.append(URL(fileURLWithPath: e, isDirectory: true)) }
        dirs.append(dataRoot.deletingLastPathComponent().appendingPathComponent("original", isDirectory: true))
        // An imported library keeps the user's files in <library>/original (docs/enhanced/import.md).
        dirs.append(dataRoot.appendingPathComponent("original", isDirectory: true))
        for d in dirs {
            let u = d.appendingPathComponent("EP\(table).EXE")
            if FileManager.default.fileExists(atPath: u.path) { return u.standardizedFileURL }
        }
        return nil
    }
}

enum TableGeometryLimits { static let lastRow = 399 }

/// Where the original keeps the display-strip pieces, found through code signatures so the
/// same scan works for every table. EP1 addresses (cs 0x3223) are given for reference;
/// every field falls back to the EP1 value when its signature is missing (listed in `fallbacks`).
public struct StripSpec: Sendable, Equatable {
    /// Rows of the playfield window while the strip is shown: `(lineCompare + 1) / 2`
    /// (split line 441 -> 221 rows in EP1-8, 421 -> 211 in EP9-13; set_split_line cs:46A3).
    public var windowRows = 221
    /// Strip rows that exist in VRAM (20 in EP1-8, 30 in EP9-13; sprites.json display_rows).
    public var stripRows = 20
    /// draw_status_panel (cs:53DE, called from init cs:03C2 with bl/bh): row 0 = `border`,
    /// rows 1..18 = `fill`.
    public var border: UInt8 = 0x23
    public var fill: UInt8 = 0x2F
    /// dmd_clear (cs:5C23): rows 1..18 of x 0..<clearWidth are refilled with `clearColour`.
    public var clearColour: UInt8 = 0x2F
    public var clearWidth = 196
    public var clearRows = 18
    /// EP9-13: the score is appended to the strip's dot list as font8 text at this DI
    /// (EP10 cs:3483-348A, colour from ds:00C5 set just before), 10 digits after one pad cell.
    public var scoreDotDI: Int? = nil
    public var scoreDotColour: UInt8 = 0xFF
    /// EP9-13: render_frame clears the strip every frame it plots (the idle display is a dot message
    /// too): row 0 to `dotBorder`, rows 1-29 to `dotFill` (EP10 cs:3F07 `mov ax,2222h; mov cx,28h;
    /// rep stosw`, cs:3F1D AEh over 488h words; EP11 cs:3F0C stores 2222h then 1010h). nil = not found.
    public var dotBorder: UInt8? = nil
    public var dotFill: UInt8? = nil
    /// EP9-13: default message dot colour = the value most often stored into the dot-colour
    /// byte in the code (EP10: 0xFF into ds:00C5, 12 of 22 stores; DAC 255 is set by dmd_message).
    public var messageDotColour: UInt8 = 0xFF
    /// Text routines that append to the dot list (draw_text cs:59AC font5, draw_text_hi
    /// cs:5926 font8, EP10 cs:4C65 font8 with per-dot colour): code offset -> font8?
    public var textRoutines: [Int: Bool] = [:]
    /// dmd_idle_text (cs:3AF8): ball-number / player-number strings in DS (first byte = colour),
    /// the DS byte the digit is patched into, and the text cell (0-39 row 2, 40-79 row 10).
    public var ballText: TextRef? = nil
    public var playerText: TextRef? = nil
    /// Big score digits (cs:5371): x = digitX0 + 12*pos, y = digitY; the score uses 10 cells
    /// from `scoreFirstPos` (cs:5B71), leading zeros drawn as the blank digit.
    public var digitX0 = 0x4C
    public var digitY = 2
    public var scoreFirstPos = 10
    /// Digit cells drawn (EP5 skips the first 4 characters of the 10-digit text: cs:3F12).
    public var scoreCells = 10
    /// Colour written to DAC entry 255 when a dot message starts (dmd_message cs:166A).
    public var messageRGB6: (UInt8, UInt8, UInt8) = (63, 63, 63)
    /// dmd_message variant: EP1-8 plot dots into the playfield window (render_frame cs:43D5,
    /// relative to the visible page), EP9-13 into the strip (no window plotter exists).
    public var messagesInStrip = false
    /// draw_plunger base row (cs:0B6E: y = charge >> 5 + base).
    public var plungerBaseY = 0x164
    /// draw_plunger row = charge >> plungerShift + base (5 in EP1-10, 6 in EP11-13).
    public var plungerShift = 5
    /// camera_update (cs:308D): target = clamp(max ball y, anchor, anchor + 399 - windowRows)
    /// - anchor, eased by `delta >> easeShift` (at least 1 px); easeShift 0 = no easing. The
    /// initial shift is the DS byte the routine reads (players change it with S/F/I in attract).
    public var cameraAnchor = 0x78
    public var cameraEaseShift = 2
    /// camera_max with the strip shown / hidden (the DS initial value and the constants the
    /// slide code stores: EP1 0x12A / 0x117 at cs:0F59 / 0F1E; EP10 303 / 273).
    public var cameraMaxShown = 0x12A
    public var cameraMaxHidden = 0x117
    public var fallbacks: [String] = []

    public struct TextRef: Sendable, Equatable {
        /// DS offset of the string (first byte is the colour for the strip text routine).
        public var ds: Int
        /// DS offset of the digit character that the code patches.
        public var digitDS: Int
        /// Text cell (strip routine) or raw DI (dot routine, EP9-13).
        public var cell: Int
        /// EP9-13: dmd_message AX used for the idle text (AH font), else nil.
        public var ax: Int? = nil
        /// EP9-13: dot colour stored before the call, else nil.
        public var dotColour: UInt8? = nil
    }

    public static func == (a: StripSpec, b: StripSpec) -> Bool {
        a.windowRows == b.windowRows && a.stripRows == b.stripRows && a.border == b.border && a.fill == b.fill
            && a.clearColour == b.clearColour && a.clearWidth == b.clearWidth && a.ballText == b.ballText
            && a.playerText == b.playerText && a.digitX0 == b.digitX0 && a.digitY == b.digitY
            && a.scoreFirstPos == b.scoreFirstPos && a.messageRGB6 == b.messageRGB6
            && a.messagesInStrip == b.messagesInStrip && a.plungerBaseY == b.plungerBaseY
            && a.scoreCells == b.scoreCells && a.plungerShift == b.plungerShift
            && a.cameraAnchor == b.cameraAnchor && a.cameraEaseShift == b.cameraEaseShift
            && a.cameraMaxShown == b.cameraMaxShown && a.cameraMaxHidden == b.cameraMaxHidden
            && a.clearRows == b.clearRows && a.scoreDotDI == b.scoreDotDI && a.scoreDotColour == b.scoreDotColour
            && a.textRoutines == b.textRoutines && a.messageDotColour == b.messageDotColour
            && a.dotBorder == b.dotBorder && a.dotFill == b.dotFill
    }

    public init() {}

    /// Scans the entry code segment (64 KB from `codeSegment`) of a table EXE.
    public static func scan(exe: TableExe, codeSegment: Int, dataSegment: Int, table: Int, displayRows: Int?) -> StripSpec {
        var s = StripSpec()
        let cb = exe.fileOffset(segment: codeSegment)
        let code = cb..<(cb + 0x10000)
        func w(_ o: Int) -> Int { exe.u16(o) }

        s.stripRows = displayRows ?? (table >= 9 ? 30 : 20)
        // set_split_line clamp: cmp ax,imm; jae +3; mov ax,imm; mov dx,3D4h
        if let o = exe.find([0x3D, nil, nil, 0x73, 0x03, 0xB8, nil, nil, 0xBA, 0xD4, 0x03], in: code, limit: 1).first {
            s.windowRows = (w(o + 1) + 1) / 2
        } else {
            s.windowRows = table >= 9 ? 211 : 221
            s.fallbacks.append("windowRows")
        }
        // init: mov bl,border; mov bh,fill; call far draw_status_panel
        if let o = exe.find([0xB3, nil, 0xB7, nil, 0x9A], in: code, limit: 1).first {
            s.border = exe.bytes[o + 1]; s.fill = exe.bytes[o + 3]
        } else { s.fallbacks.append("panel colours") }
        // dmd_clear: mov al,0Fh; out; mov al,colour; mov di,50h; mov ah,rows; push di; mov cx,bytes
        if let o = exe.find([0xB0, 0x0F, 0xEE, 0xB0, nil, 0xBF, 0x50, 0x00, 0xB4, nil, 0x57, 0xB9], in: code, limit: 1).first {
            s.clearColour = exe.bytes[o + 4]; s.clearWidth = w(o + 12) * 4; s.clearRows = Int(exe.bytes[o + 9])
        } else if let o = exe.find([0xB0, 0x0F, 0xEE, 0xB0, nil, 0xBF, 0x50, 0x00, 0xB9, nil, nil, 0xF3, 0xAA], in: code, limit: 1).first {
            // EP9-13 dot-strip clear (EP10 cs:5023): full width, count/80 rows from row 1.
            s.clearColour = exe.bytes[o + 4]; s.clearWidth = 320; s.clearRows = w(o + 9) / 80
        } else { s.clearColour = s.fill; s.clearWidth = 0; s.fallbacks.append("dmd_clear") }
        // dmd_idle_text (EP1-8): add al,30h; mov di,0; mov [di+digit],al; lea bx,[str]; mov di,cell; call far
        if let o = exe.find([0x04, 0x30, 0xBF, 0x00, 0x00, 0x88, 0x85, nil, nil, 0x8D, 0x1E, nil, nil, 0xBF, nil, nil, 0x9A],
                            in: code, limit: 1).first {
            s.ballText = TextRef(ds: w(o + 11), digitDS: w(o + 7), cell: w(o + 14))
            // add al,30h; mov [di+digit],al; mov di,cell; lea bx,[str]; call far
            if let p = exe.find([0x04, 0x30, 0x88, 0x85, nil, nil, 0xBF, nil, nil, 0x8D, 0x1E, nil, nil, 0x9A],
                                in: o..<(o + 0x40), limit: 1).first {
                s.playerText = TextRef(ds: w(p + 11), digitDS: w(p + 4), cell: w(p + 7))
            }
        } else if let o = exe.find([0x3C, 0x09, 0x72, 0x02, 0xB0, 0x09, 0x04, 0x30, 0xA2, nil, nil], in: code, limit: 1).first,
                  let b = exe.find([0x8D, 0x1E, nil, nil, 0xBF, nil, nil, 0x9A], in: (o + 11)..<(o + 32), limit: 1).first {
            // EP6 (cs:3212..3226): mov [digit],al; (far call); lea bx,[str]; mov di,cell; call far
            s.ballText = TextRef(ds: w(b + 2), digitDS: w(o + 9), cell: w(b + 5))
            if let p = exe.find([0x04, 0x30, 0x88, 0x85, nil, nil, 0xBF, nil, nil, 0x8D, 0x1E, nil, nil, 0x9A],
                                in: (b + 8)..<(b + 0x40), limit: 1).first {
                s.playerText = TextRef(ds: w(p + 11), digitDS: w(p + 4), cell: w(p + 7))
            } else if let p = exe.find([0x04, 0x30, 0xA2, nil, nil], in: (b + 8)..<(b + 0x40), limit: 1).first,
               let q = exe.find([0x8D, 0x1E, nil, nil, 0xBF, nil, nil, 0x9A], in: (p + 5)..<(p + 26), limit: 1).first {
                s.playerText = TextRef(ds: w(q + 2), digitDS: w(p + 3), cell: w(q + 5))
            }
        } else if let o = exe.find([0x04, 0x30, 0xA2, nil, nil, 0xA0, nil, nil, 0x04, 0x30, 0xA2, nil, nil,
                                    0x8D, 0x1E, nil, nil, 0xBF, nil, nil, 0xB8, nil, nil, 0xE8], in: code, limit: 1).first {
            // EP9-13 (EP10 cs:345A): both digits patched into one string, drawn with dmd_message.
            let str = w(o + 15), di = w(o + 18), ax = w(o + 21)
            var colour: UInt8? = nil
            if let c = exe.find([0xC6, 0x06, nil, nil, nil], in: (o - 16)..<o).last { colour = exe.bytes[c + 4] }
            s.ballText = TextRef(ds: str, digitDS: w(o + 3), cell: di, ax: ax, dotColour: colour)
            s.playerText = TextRef(ds: str, digitDS: w(o + 11), cell: di, ax: ax, dotColour: colour)
            // Then: mov byte [c5],colour; (score -> text); lea bx,[buf]; mov di,pos; call far text routine
            let tail = (o + 24)..<(o + 80)
            if let c = exe.find([0xC6, 0x06, nil, nil, nil], in: tail, limit: 1).first {
                s.scoreDotColour = exe.bytes[c + 4]
                var counts: [UInt8: Int] = [:]
                for st in exe.find([0xC6, 0x06, exe.bytes[c + 2], exe.bytes[c + 3], nil], in: code) {
                    let v = exe.bytes[st + 4]
                    if v != colour { counts[v, default: 0] += 1 }
                }
                if let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { s.messageDotColour = best.key }
            }
            if let t = exe.find([0x8D, 0x1E, nil, nil, 0xBF, nil, nil, 0x9A], in: tail, limit: 1).first { s.scoreDotDI = w(t + 5) }
        } else { s.fallbacks.append("idle text") }
        // digit draw: mov ax,0Ch; mul di; add ax,x0; mov cx,ax; mov ax,y
        if let o = exe.find([0xB8, 0x0C, 0x00, 0xF7, 0xE7, 0x05, nil, nil, 0x8B, 0xC8, 0xB8], in: code, limit: 1).first {
            s.digitX0 = w(o + 6); s.digitY = w(o + 11)
        } else { s.fallbacks.append("digit position") }
        // score loop: mov di,first-1; mov al,[bx+buf]; cmp al,0; je; inc bx; inc di; sub al,30h; call far
        if let o = exe.find([0xBF, nil, 0x00, 0x8A, 0x87, nil, nil, 0x3C, 0x00, 0x74, nil, 0x43, 0x47, 0x2C, 0x30, 0x9A],
                            in: code, limit: 1).first {
            s.scoreFirstPos = Int(exe.bytes[o + 1]) + 1
        } else if let o = exe.find([0xBF, nil, 0x00, 0x83, 0xC3, nil, 0x83, 0xC7, nil, 0x8A, 0x87, nil, nil, 0x3C, 0x00, 0x74, nil,
                                    0x43, 0x47, 0x2C, 0x30, 0x9A], in: code, limit: 1).first {
            // EP5: add bx,k; add di,k first (only the last 10-k characters are drawn).
            let k = Int(exe.bytes[o + 5])
            s.scoreFirstPos = Int(exe.bytes[o + 1]) + k + 1
            s.scoreCells = max(1, 10 - k)
        } else { s.fallbacks.append("score position") }
        // dmd_message: push es; pusha; cmp ah,2; jbe; sub ah,3 ... mov al,0FFh; mov dx,3C8h; out; inc dx; (mov al,v | out) x3
        if let m = exe.find([0x06, 0x60, 0x80, 0xFC, 0x02, 0x76, 0x06, 0x80, 0xEC, 0x03], in: code, limit: 1).first,
           let o = exe.find([0xB0, 0xFF, 0xBA, 0xC8, 0x03, 0xEE, 0x42], in: m..<(m + 0x100), limit: 1).first {
            var i = o + 7, al: UInt8 = 0, outs: [UInt8] = []
            while outs.count < 3, i < o + 24 {
                if exe.bytes[i] == 0xB0 { al = exe.bytes[i + 1]; i += 2 } else if exe.bytes[i] == 0xEE { outs.append(al); i += 1 } else { break }
            }
            if outs.count == 3 { s.messageRGB6 = (outs[0], outs[1], outs[2]) } else { s.fallbacks.append("message colour") }
        } else { s.fallbacks.append("message colour") }
        // Window dot plotter (render_frame cs:43D5): mov es,[page]; mov dx,3CEh; mov al,4; out
        // (EP1-8 have it; EP9-13 only have the strip version).
        s.messagesInStrip = exe.find([0x8E, 0x06, nil, nil, 0xBA, 0xCE, 0x03, 0xB0, 0x04, 0xEE], in: code, limit: 1).isEmpty
        // EP9-13 render_frame strip clear: mov ax,0Fh; out dx,al; (mov ax,v)+; mov cx,n; rep stosw
        // (n = 28h: row 0, 488h: rows 1-29; the last `mov ax` wins).
        if s.messagesInStrip {
            for o in exe.find([0xB8, 0x0F, 0x00, 0xEE, 0xB8], in: code) {
                var i = o + 4, v: UInt8?
                while exe.bytes[i] == 0xB8 { v = exe.bytes[i + 1]; i += 3 }
                guard let v, exe.bytes[i] == 0xB9, exe.bytes[i + 3] == 0xF3, exe.bytes[i + 4] == 0xAB else { continue }
                let n = w(i + 1)
                if n == 0x28, s.dotBorder == nil { s.dotBorder = v } else if n == 0x488, s.dotBorder != nil, s.dotFill == nil { s.dotFill = v }
            }
        }
        // plunger: shr ax,n; add ax,base; call far draw_plunger (n = 5, or 6 in EP11-13)
        if let o = exe.find([0xC1, 0xE8, nil, 0x05, nil, nil, 0x9A], in: code, limit: 1).first {
            s.plungerShift = Int(exe.bytes[o + 2]); s.plungerBaseY = w(o + 4)
        } else { s.fallbacks.append("plunger base") }
        // camera_update: cmp ax,anchor; jae +3; mov ax,anchor; cmp ax,[camera_max] ... mov si,[ease]; cmp word [ease],0
        // (attract_autoflip has the same head without the ease read, so take the match that has it).
        // Dot-list text routines: mov si,[50Ch]; mov word [50Ch],0 ... then shl ax,3 (font8) or
        // mov bx,5; mul bx (font5). The routine entry is the last `mov ax,ds` / `mov al,[..]`
        // before the prologue.
        for o in exe.find([0x8B, 0x36, 0x0C, 0x05, 0xC7, 0x06, 0x0C, 0x05, 0x00, 0x00], in: code) {
            let body = o..<(o + 0x40)
            let f8 = exe.find([0xC1, 0xE0, 0x03], in: body, limit: 1).first
            let f5 = exe.find([0xBB, 0x05, 0x00, 0xF7, 0xE3], in: body, limit: 1).first
            guard f8 != nil || f5 != nil else { continue }
            let isF8 = (f8 ?? .max) < (f5 ?? .max)
            let entries = exe.find([0x8C, 0xD8, 0x8E, 0xC0], in: (o - 20)..<o) + exe.find([0xA0, nil, nil, 0x2E, 0xA2], in: (o - 20)..<o)
            if let e = entries.min() { s.textRoutines[e - cb] = isF8 }
        }
        var cameraFound = false
        for o in exe.find([0x3D, nil, 0x00, 0x73, 0x03, 0xB8, nil, 0x00, 0x3B, 0x06], in: code) {
            guard let e = exe.find([0x8B, 0x36, nil, nil, 0x83, 0x3E, nil, nil, 0x00], in: o..<(o + 0x40), limit: 1).first else { continue }
            s.cameraAnchor = Int(exe.bytes[o + 1])
            s.cameraEaseShift = exe.u16(exe.fileOffset(segment: dataSegment, offset: w(e + 2)))
            let maxVar = w(o + 10)
            let initial = exe.u16(exe.fileOffset(segment: dataSegment, offset: maxVar))
            let stores = exe.find([0xC7, 0x06, UInt8(maxVar & 0xFF), UInt8(maxVar >> 8)], in: code).map { w($0 + 4) }
            if let lo = stores.min(), let hi = stores.max(), lo < hi {
                s.cameraMaxShown = max(hi, initial); s.cameraMaxHidden = lo
            } else {
                s.cameraMaxShown = s.cameraAnchor + TableGeometryLimits.lastRow - s.windowRows
                s.cameraMaxHidden = s.cameraAnchor + TableGeometryLimits.lastRow - 240
                s.fallbacks.append("camera_max")
            }
            cameraFound = true
            break
        }
        if !cameraFound { s.fallbacks.append("camera") }
        return s
    }
}

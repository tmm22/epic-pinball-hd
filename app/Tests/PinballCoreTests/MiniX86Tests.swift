import Foundation
import XCTest
@testable import PinballCore

/// The x86 subset interpreter for main-loop glue, on hand-assembled code (our own instruction
/// sequences, placed at cs:0800 of the synthetic image).
final class MiniX86Tests: XCTestCase {
    typealias F = RulesFixture
    static let at = 0x0800

    func make(_ code: [UInt8]) throws -> (MiniX86, RulesMachine) {
        let p = try F.program()
        let m = try RulesMachine(program: p, exe: F.exe(code: code, codeAt: Self.at))
        return (MiniX86(machine: m), m)
    }

    @discardableResult
    func run(_ code: [UInt8], setup: (MiniX86) -> Void = { _ in }) throws -> (MiniX86.Stop, RulesMachine, MiniX86) {
        let (x, m) = try make(code)
        x.resetRegisters()
        setup(x)
        let s = x.run(from: Self.at, to: Self.at + code.count)
        return (s, m, x)
    }

    func testMovAddCmpBranch() throws {
        let code: [UInt8] = [
            0xC7, 0x06, 0x00, 0x03, 0x34, 0x12,   // mov word [0300], 1234h
            0x83, 0x06, 0x00, 0x03, 0x10,         // add word [0300], 10h   -> 1244h
            0x80, 0x3E, 0x00, 0x03, 0x44,         // cmp byte [0300], 44h
            0x75, 0x05,                           // jne +5
            0xC6, 0x06, 0x02, 0x03, 0x01,         // mov byte [0302], 1
            0x90,
        ]
        let (s, m, _) = try run(code)
        XCTAssertEqual(s, .completed)
        XCTAssertEqual(m.read(0x300, 2), 0x1244)
        XCTAssertEqual(m.read(0x302, 1), 1)
    }

    func testAddressingModesLoopAndStrings() throws {
        let code: [UInt8] = [
            0xBB, 0x00, 0x03,                     // mov bx, 0300h
            0xBE, 0x02, 0x00,                     // mov si, 2
            0xC6, 0x00, 0x07,                     // mov byte [bx+si], 7        -> [0302]
            0x8A, 0x40, 0x02,                     // mov al, [bx+si+2]          -> [0304] (0)
            0x8A, 0x87, 0x02, 0x00,               // mov al, [bx+0002]          -> [0302] = 7
            0xA2, 0x10, 0x03,                     // mov [0310], al
            0xB9, 0x03, 0x00,                     // mov cx, 3
            0xFE, 0x06, 0x11, 0x03,               // L: inc byte [0311]
            0xE2, 0xFA,                           // loop L
            0x8C, 0xD8, 0x8E, 0xC0,               // mov ax, ds ; mov es, ax
            0xBF, 0x20, 0x03,                     // mov di, 0320h
            0xB8, 0xAA, 0x55,                     // mov ax, 55AAh
            0xB9, 0x02, 0x00,                     // mov cx, 2
            0xF3, 0xAB,                           // rep stosw
        ]
        let (s, m, x) = try run(code)
        XCTAssertEqual(s, .completed)
        XCTAssertEqual(m.read(0x302, 1), 7)
        XCTAssertEqual(m.read(0x310, 1), 7)
        XCTAssertEqual(m.read(0x311, 1), 3)
        XCTAssertEqual(m.read(0x320, 4), 0x55AA_55AA)
        XCTAssertEqual(x.di, 0x324)
        XCTAssertEqual(x.cx, 0)
    }

    func testFlagsCarryOverflowAndIncKeepsCarry() throws {
        let code: [UInt8] = [
            0xB8, 0xFF, 0xFF,                     // mov ax, FFFFh
            0x05, 0x01, 0x00,                     // add ax, 1      -> 0, CF=1 ZF=1
            0x40,                                 // inc ax         -> CF unchanged
            0x72, 0x05,                           // jb +5 (taken)
            0xC6, 0x06, 0x00, 0x03, 0x01,         // (skipped)
            0xB0, 0x7F,                           // mov al, 7Fh
            0x04, 0x01,                           // add al, 1      -> 80h, OF=1 SF=1
            0x7C, 0x05,                           // jl +5 (SF != OF: not taken)
            0xC6, 0x06, 0x01, 0x03, 0x01,         // mov byte [0301], 1
            0x70, 0x05,                           // jo +5 (taken)
            0xC6, 0x06, 0x02, 0x03, 0x01,         // (skipped)
            0x90,
        ]
        let (s, m, _) = try run(code)
        XCTAssertEqual(s, .completed)
        XCTAssertEqual(m.read(0x300, 1), 0)
        XCTAssertEqual(m.read(0x301, 1), 1)
        XCTAssertEqual(m.read(0x302, 1), 0)
    }

    func testMulDivShifts() throws {
        let code: [UInt8] = [
            0xB8, 0xE8, 0x03,                     // mov ax, 1000
            0xB9, 0x46, 0x00,                     // mov cx, 70
            0xF7, 0xE1,                           // mul cx        -> dx:ax = 70000
            0xA3, 0x00, 0x03,                     // mov [0300], ax
            0x89, 0x16, 0x02, 0x03,               // mov [0302], dx
            0xB9, 0x14, 0x00,                     // mov cx, 20
            0xF7, 0xF1,                           // div cx        -> ax 3500, dx 0
            0xA3, 0x04, 0x03,                     // mov [0304], ax
            0xD1, 0xE0,                           // shl ax, 1     -> 7000
            0xC1, 0xE8, 0x02,                     // shr ax, 2     -> 1750
            0xA3, 0x06, 0x03,                     // mov [0306], ax
        ]
        let (s, m, _) = try run(code)
        XCTAssertEqual(s, .completed)
        XCTAssertEqual(m.read(0x300, 4), 70000)
        XCTAssertEqual(m.read(0x304, 2), 3500)
        XCTAssertEqual(m.read(0x306, 2), 1750)
    }

    func testCallsGoThroughTheCallout() throws {
        // call near 0900h (followed), lcall 1234h:0850h (handled), then a jump out of the range
        let code: [UInt8] = [
            0xE8, 0xFD, 0x00,                     // call 0900h (0803 + 00FD)
            0x9A, 0x50, 0x08, 0x34, 0x12,         // lcall 1234:0850
            0xEB, 0x40,                           // jmp +40h -> out of range
        ]
        var full = code + [UInt8](repeating: 0x90, count: 0x100 - code.count)
        full += [0xC6, 0x06, 0x00, 0x03, 0x05, 0xC3]   // cs:0900 mov byte [0300], 5 ; ret
        let (x, m) = try make(full)
        var seen: [(Int, Int?)] = []
        x.callout = { _, _, target, seg in
            seen.append((target, seg))
            return target == 0x0900 ? .follow : .handled
        }
        x.resetRegisters()
        let s = x.run(from: Self.at, to: Self.at + code.count)
        XCTAssertEqual(s, .jumpedOut(Self.at + 10 + 0x40))
        XCTAssertEqual(m.read(0x300, 1), 5)
        XCTAssertEqual(seen.map { $0.0 }, [0x0900, 0x0850])
        XCTAssertEqual(seen.last?.1, 0x1234)
    }

    func testUnknownCallAndUnsupportedOpcodeStop() throws {
        let (s1, _, _) = try run([0xE8, 0x00, 0x00, 0x90])
        XCTAssertEqual(s1, .unknownCall(Self.at, Self.at + 3))
        let (s2, _, _) = try run([0x90, 0xCD, 0x21])   // int 21h is not in the subset
        XCTAssertEqual(s2, .unsupported(Self.at + 1, 0xCD))
    }

    func testCodeSegmentDataGoesThroughCSRead() throws {
        let code: [UInt8] = [
            0x2E, 0x80, 0x3E, 0x8D, 0x02, 0x01,   // cmp byte cs:[028D], 1
            0x75, 0x05,                           // jne +5
            0xC6, 0x06, 0x00, 0x03, 0x01,         // mov byte [0300], 1
            0x90,
        ]
        let (x, m) = try make(code)
        x.csRead = { $0 == 0x028D ? 1 : 0 }
        x.resetRegisters()
        XCTAssertEqual(x.run(from: Self.at, to: Self.at + code.count), .completed)
        XCTAssertEqual(m.read(0x300, 1), 1)
    }

    func testRoutineModeReturnsAtRet() throws {
        let (x, m) = try make([0xFE, 0x06, 0x00, 0x03, 0xC3])   // inc byte [0300]; ret
        x.resetRegisters()
        XCTAssertEqual(x.run(from: Self.at, to: -1), .returned)
        XCTAssertEqual(m.read(0x300, 1), 1)
    }

    func testValidateDecodesStraightLineCode() throws {
        let code: [UInt8] = [0xC7, 0x06, 0x00, 0x03, 0x34, 0x12, 0x83, 0x3E, 0x00, 0x03, 0x05, 0x74, 0x02, 0x90, 0x90]
        let (x, _) = try make(code)
        XCTAssertEqual(x.validate(from: Self.at, to: Self.at + code.count), .completed)
        XCTAssertEqual(x.validate(from: Self.at, to: Self.at + 5), .unsupported(Self.at + 6, 0x83), "an instruction straddling the end")
    }

    // MARK: - direct-backend features (stops, frames, far calls, SS, more instructions)

    func testStackFrameBPAndPushImmediate() throws {
        let code: [UInt8] = [
            0x55,                                 // push bp
            0x8B, 0xEC,                           // mov bp, sp
            0x68, 0x34, 0x12,                     // push 1234h
            0x6A, 0xFE,                           // push -2
            0x8B, 0x46, 0xFE,                     // mov ax, [bp-2]   (SS)
            0xA3, 0x00, 0x03,                     // mov [0300], ax
            0x8B, 0x46, 0xFC,                     // mov ax, [bp-4]
            0xA3, 0x02, 0x03,                     // mov [0302], ax
            0x8B, 0xE5,                           // mov sp, bp
            0x5D,                                 // pop bp
        ]
        let (s, m, x) = try run(code)
        XCTAssertEqual(s, .completed)
        XCTAssertEqual(m.read(0x300, 2), 0x1234)
        XCTAssertEqual(m.read(0x302, 2), 0xFFFE)
        XCTAssertEqual(x.sp, MiniX86.initialSP)
    }

    func testFarCallIntoTheCodeSegmentAndRetImmediate() throws {
        let (x0, _) = try make([])
        let cs = x0.csValue
        let code: [UInt8] = [
            0x9A, 0x00, 0x09, UInt8(cs & 0xFF), UInt8(cs >> 8),   // lcall CS:0900
            0x50,                                 // push ax
            0xE8, 0xF7, 0x01,                     // call 0A00h (0806 + 3 + 01F7)
            0x90,
        ]
        var full = code + [UInt8](repeating: 0x90, count: 0x100 - code.count)
        full += [0xC6, 0x06, 0x00, 0x03, 0x07, 0xB8, 0x55, 0x00, 0xCB]   // 0900: mov byte [0300],7; mov ax,55h; retf
        full += [UInt8](repeating: 0x90, count: 0x200 - full.count)
        full += [0xC6, 0x06, 0x01, 0x03, 0x08, 0xC2, 0x02, 0x00]         // 0A00: mov byte [0301],8; ret 2
        let (x, m) = try make(full)
        x.callout = { _, _, _, _ in .follow }
        x.resetRegisters()
        XCTAssertEqual(x.run(from: Self.at, to: Self.at + code.count), .completed)
        XCTAssertEqual(m.read(0x300, 1), 7)
        XCTAssertEqual(m.read(0x301, 1), 8)
        XCTAssertEqual(x.ax, 0x55)
        XCTAssertEqual(x.sp, MiniX86.initialSP, "ret 2 dropped the pushed word")
    }

    func testHookStopsEndTheRunAndReturnFromSubroutines() throws {
        let code: [UInt8] = [
            0xE8, 0xFD, 0x00,                     // 0800 call 0900
            0xC6, 0x06, 0x01, 0x03, 0x01,         // 0803 mov byte [0301], 1
            0xEB, 0x05,                           // 0808 jmp 080F (a stop)
            0xC6, 0x06, 0x03, 0x03, 0x01,         // 080A (skipped)
            0xC6, 0x06, 0x02, 0x03, 0x01,         // 080F stop: not executed
        ]
        var full = code + [UInt8](repeating: 0x90, count: 0x100 - code.count)
        full += [0xC6, 0x06, 0x00, 0x03, 0x01, 0x53, 0xEB, 0x10]   // 0900 mov byte [0300],1; push bx; jmp 0918 (a stop)
        let (x, m) = try make(full)
        var stops = [Bool](repeating: false, count: 0x10000)
        stops[0x080F] = true; stops[0x0918] = true; stops[0x0800] = true   // the start itself is not a stop
        x.stops = stops
        x.callout = { _, _, _, _ in .follow }
        x.resetRegisters()
        XCTAssertEqual(x.run(from: Self.at, to: -1), .completed)
        XCTAssertEqual(x.lastStop, 0x080F)
        XCTAssertEqual([m.read(0x300, 1), m.read(0x301, 1), m.read(0x302, 1), m.read(0x303, 1)], [1, 1, 0, 0])
        XCTAssertEqual(x.forcedReturns, 1)
        XCTAssertEqual(x.sp, MiniX86.initialSP, "the forced return restores SP to the call")
    }

    func testEpilogueEndsARunAtDepthZero() throws {
        let (x, m) = try make([0xC6, 0x06, 0x00, 0x03, 0x01, 0x61, 0x07, 0xC3])   // mov byte [0300],1; popa; pop es; ret
        x.stopAtEpilogue = true
        x.resetRegisters()
        XCTAssertEqual(x.run(from: Self.at, to: -1), .returned)
        XCTAssertEqual(m.read(0x300, 1), 1)
        XCTAssertEqual(x.sp, MiniX86.initialSP, "popa was not executed")
    }

    func testIndirectJumpThroughARegisterAndWatchRange() throws {
        var code: [UInt8] = [0xBB, 0x00, 0x09, 0xFF, 0xE3]   // mov bx, 0900h; jmp bx
        code += [UInt8](repeating: 0x90, count: 0x100 - code.count)
        code += [0xC6, 0x06, 0x00, 0x03, 0x09, 0xC3]         // 0900 mov byte [0300], 9; ret
        let (x, m) = try make(code)
        x.watch = 0x0900..<0x0901
        x.resetRegisters()
        XCTAssertEqual(x.run(from: Self.at, to: -1), .returned)
        XCTAssertEqual(m.read(0x300, 1), 9)
        XCTAssertTrue(x.watchHit)
    }

    func testRepeatCompareScanAndDirectionFlag() throws {
        let code: [UInt8] = [
            0xBE, 0x00, 0x03, 0xBF, 0x10, 0x03,   // mov si, 0300h; mov di, 0310h
            0xB9, 0x04, 0x00,                     // mov cx, 4
            0xF3, 0xA6,                           // repe cmpsb     (stops at the 3rd byte)
            0x89, 0x0E, 0x20, 0x03,               // mov [0320], cx
            0x89, 0x36, 0x22, 0x03,               // mov [0322], si
            0xBF, 0x10, 0x03, 0xB0, 0x44,         // mov di, 0310h; mov al, 'D'
            0xB9, 0x04, 0x00, 0xF2, 0xAE,         // mov cx, 4; repne scasb (finds 'D' at 0313)
            0x89, 0x3E, 0x24, 0x03,               // mov [0324], di
            0xFD, 0xBE, 0x03, 0x03, 0xAC,         // std; mov si, 0303h; lodsb
            0x89, 0x36, 0x26, 0x03, 0xFC,         // mov [0326], si; cld
            0xA2, 0x28, 0x03,                     // mov [0328], al
        ]
        let (x, m) = try make(code)
        x.resetRegisters()
        for (i, c) in Array("ABCD".utf8).enumerated() { m.write8(0x300 + i, c) }
        for (i, c) in Array("ABXD".utf8).enumerated() { m.write8(0x310 + i, c) }
        XCTAssertEqual(x.run(from: Self.at, to: Self.at + code.count), .completed)
        XCTAssertEqual(m.read(0x320, 2), 1)
        XCTAssertEqual(m.read(0x322, 2), 0x303)
        XCTAssertEqual(m.read(0x324, 2), 0x314)
        XCTAssertEqual(m.read(0x326, 2), 0x302)
        XCTAssertEqual(m.read(0x328, 1), Int64(UInt8(ascii: "D")))
    }

    func testSignedArithmeticRotatesThroughCarryAndFlagsTransfer() throws {
        let code: [UInt8] = [
            0xB8, 0xF6, 0xFF,                     // mov ax, -10
            0xB9, 0x03, 0x00,                     // mov cx, 3
            0xF7, 0xE9,                           // imul cx        -> dx:ax = -30
            0xA3, 0x00, 0x03,                     // mov [0300], ax
            0x99,                                 // cwd
            0xF7, 0xF9,                           // idiv cx        -> ax = -10, dx = 0
            0xA3, 0x02, 0x03,                     // mov [0302], ax
            0x6B, 0xC0, 0x07,                     // imul ax, ax, 7 -> -70
            0xA3, 0x04, 0x03,                     // mov [0304], ax
            0xF9,                                 // stc
            0xB0, 0x80, 0xD0, 0xD0,               // mov al, 80h; rcl al, 1 -> al 1, CF 1
            0xD0, 0xD8,                           // rcr al, 1      -> al 80h, CF 1
            0xA2, 0x06, 0x03,                     // mov [0306], al
            0x9F, 0x88, 0x26, 0x07, 0x03,         // lahf; mov [0307], ah
            0x9C, 0xF8, 0x9D,                     // pushf; clc; popf (CF back to 1)
            0xBB, 0x11, 0x00, 0x93,               // mov bx, 11h; xchg ax, bx
            0xA3, 0x08, 0x03,                     // mov [0308], ax
            0x73, 0x05,                           // jnc +5 (not taken)
            0xC6, 0x06, 0x0A, 0x03, 0x01,         // mov byte [030A], 1
        ]
        let (s, m, _) = try run(code)
        XCTAssertEqual(s, .completed)
        XCTAssertEqual(m.read(0x300, 2), 0xFFE2)
        XCTAssertEqual(m.read(0x302, 2), 0xFFF6)
        XCTAssertEqual(m.read(0x304, 2), 0xFFBA)
        XCTAssertEqual(m.read(0x306, 1), 0x80)
        XCTAssertEqual(Int(m.read(0x307, 1)) & 1, 1, "lahf copied CF")
        XCTAssertEqual(m.read(0x308, 2), 0x11)
        XCTAssertEqual(m.read(0x30A, 1), 1)
    }

    func testOtherImageSegmentsAreReadOnlyAndTheContactSegment() throws {
        let code: [UInt8] = [
            0x1E,                                 // push ds
            0xB8, 0x45, 0x24, 0x8E, 0xD8,         // mov ax, 2445h; mov ds, ax
            0xA0, 0x10, 0x00,                     // mov al, [0010]      (image 2445:0010)
            0x1F,                                 // pop ds
            0xA2, 0x00, 0x03,                     // mov [0300], al
            0x26, 0x8A, 0x07,                     // mov al, es:[bx]     (contact pixel)
            0xA2, 0x01, 0x03,                     // mov [0301], al
        ]
        let (x, m) = try make(code)
        x.imageRead = { $0 == 0x2445 * 16 + 0x10 ? 0x5A : nil }
        x.resetRegisters()
        x.es = MiniX86.contactSegment
        x.contactColour = 0xCF
        XCTAssertEqual(x.run(from: Self.at, to: Self.at + code.count), .completed)
        XCTAssertEqual(m.read(0x300, 1), 0x5A)
        XCTAssertEqual(m.read(0x301, 1), 0xCF)
        // a write through such a segment stops execution
        let (x2, _) = try make([0xB8, 0x45, 0x24, 0x8E, 0xD8, 0xA2, 0x10, 0x00])
        x2.imageRead = { _ in 0 }
        x2.resetRegisters()
        XCTAssertEqual(x2.run(from: Self.at, to: Self.at + 8), .unsupported(Self.at + 5, 0xA2))
    }
}

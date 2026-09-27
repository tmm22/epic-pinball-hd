"""Run the original EP1.EXE machine code under Unicorn (x86, 16-bit real mode).

The executable is loaded from the user's own copy (original/EP1.EXE), relocated
by hand, and booted through its real entry and init code (command-line parse,
Mode X setup, playfield copy to VRAM, the D3..E6 -> 2A collision-buffer
substitution, the intro scroll) until the first arrival at the top of the
main loop (cs:04D2).  Nothing from the game is copied into this file: only
code addresses and DS/CS variable offsets found by reverse engineering
(docs/formats/engine.md, collision.md, emulation.md).

What is stubbed (see docs/formats/emulation.md):
  * int 10h / int 21h: minimal BIOS/DOS answers (video mode query, get/set
    vector, print string, exit).  Vectors are recorded, never invoked.
  * Port I/O: 3DAh toggles the retrace bit on every read, so every busy-wait
    on vertical retrace terminates immediately; 201h (joystick) reads 0xFF (no
    buttons); everything else reads 0 and writes are ignored (optionally logged).
  * No hardware interrupts are delivered.  The timer ISR's job (three
    physics_step calls per frame) is done by the driver calling cs:1724
    directly; the keyboard ISR's job is done by poking its CS flag bytes.
  * The MASI sound API is never reached: the command line gives invalid sound
    pointer digits, so the game sets snd_present = 0 itself (cs:00DE).

Usage as a library:
    emu = EpEmu()                 # loads + boots (about 0.5 s)
    emu.reset_play_state()
    for _ in range(12): emu.physics_step()   # flippers settle from boot angle 2 to rest
    emu.set_ball(0, x=..., y=..., vx=..., vy=...)
    emu.set_keys(mask)            # 1 left, 2 right, 4 plunger
    emu.main_loop_physics()       # main-loop physics pieces (plunger, gravity, ...)
    for _ in range(3): emu.physics_step()
  tools/emu/run_scenario.py wraps exactly this.
"""
import os
import struct
import sys

from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN, UC_HOOK_CODE, UcError
from unicorn.x86_const import (
    UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_CX, UC_X86_REG_DX, UC_X86_REG_SI, UC_X86_REG_DI,
    UC_X86_REG_SP, UC_X86_REG_BP, UC_X86_REG_IP, UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES,
    UC_X86_REG_SS, UC_X86_REG_FLAGS, UC_X86_INS_IN, UC_X86_INS_OUT,
)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import epexe  # noqa: E402

LOAD_SEG = 0x1000          # where the load image goes (PSP at LOAD_SEG-0x10)
MEM_SIZE = 0x110000        # 1 MB + HMA
SENTINEL_IP = 0xFFF0       # near return address used to call routines in CS

# ---------------------------------------------------------------------------
# EP1 addresses (unrelocated offsets; cs = code seg 0x3223, ds = data seg 0x0015)
# ---------------------------------------------------------------------------
EP1 = dict(
    exe='EP1.EXE',
    cs=0x3223, ds=0x0015,
    main_loop=0x04D2,
    frame_sync=0x1243,
    physics_step=0x1724,
    collision_response_dir_stored=0x1AEC,   # right after [586E] (contact_dir) is written
    sensor_dispatch=0x1E66,                 # colour_event_dispatch past its layer/tilt filters: al = colour
    sensor_table=0x1E77,                    # jump table of rule handlers, index colour-0xAA
    # main-loop ranges run in "physics" mode, in main-loop order: (start, stop, [call sites to skip])
    physics_ranges=[
        (0x06E2, 0x0711, []),          # extra_gravity_timer decay, gate timer (calls gate_draw)
        (0x09EC, 0x0A0D, []),          # event_lockout / kicker_cooldown / event_cooldown decrements
        (0x0A31, 0x0A9A, []),          # drain check + serve new ball
        (0x0A9D, 0x0C48, [0x0AFD]),    # plunger lane: vx=0 in lane, charge/release (skip ball_lost_fade)
        (0x0DFD, 0x0E8A, []),          # nudge / tilt timers (nudge keys never set by the harness)
        (0x119F, 0x1236, [0x11F3, 0x11FD]),  # kick_strength=0; gravity per ball (skip save_ball_bg, ball_pixel_scan)
    ],
    # "rules" mode: same but ball_pixel_scan (sensor/rule dispatch) is executed.  save_ball_bg must
    # stay skipped: it appends to a list in graphics seg 0x2623 that only restore_ball_bg (cs:10BD,
    # not run here) empties; unpaired it overflows past 2623:C000 into the code segment.
    rules_ranges=[
        (0x06E2, 0x0711, []),
        (0x09EC, 0x0A0D, []),
        (0x0A31, 0x0A9A, []),
        (0x0A9D, 0x0C48, [0x0AFD]),
        (0x0DFD, 0x0E8A, []),
        (0x119F, 0x1236, [0x11F3]),
    ],
    # code bytes that must never change (cs:0000..code_check_end) except these CS variables
    code_check_end=0x4470,
    code_vars=[(0x028B, 0x02A3), (0x307B, 0x307C), (0x3C82, 0x3C8A), (0x44AD, 0x44AE)],
    ds_vars=dict(
        ball_vx=0x6A00, ball_vy=0x6A0C, ball_accx=0x6A18, ball_accy=0x6A24,
        ball_active=0x6A3A, ball_x=0x6A46, ball_y=0x6A52, ball_layer=0x6772,
        params=0x6781, collided=0x6C59, contact_dir=0x586E, flipper_contact=0x6768,
        kick_strength=0x676C, kicker_cooldown=0x6769, event_lockout=0x676B, event_cooldown=0x676A,
        lflip_angle=0x6CD2, rflip_angle=0x6CD4, lflip_drawn=0x6CD6, rflip_drawn=0x6CD8,
        lflip_moving=0x676F, rflip_moving=0x6770, serve_delay=0x5896, plunger_charge=0x5897,
        nudge_timer=0x5870, tilt_meter=0x5871, tilted=0x5872, extra_gravity_timer=0x06D7,
        pf_seg_top=0x6C10, pf_seg_bottom=0x6C12, snd_present=0x0008, demo_mode=0x6C5A,
        opt_no_timer=0x679B, hit_count=0x6C1E, lflip_outline=0x5AE1, rflip_outline=0x5AF7,
        ring=0x6C6C, normals=0x589C, pushout=0x5964,
    ),
    cs_vars=dict(
        vsync_flag=0x028B, isr_frame_mode=0x028C, key_lflip=0x028D, key_rflip=0x028F,
        key_up=0x0292, key_down=0x0293, key_space=0x0296, key_ctrl=0x0297,
        key_nudge_a=0x0298, key_nudge_b=0x0299, last_scancode=0x029B, isr_steps_left=0x029E,
    ),
)

PARAM_NAMES = ['rest_x', 'rest_y', 'kicker', 'flip_top_x', 'flip_top_y',
               'flip_side_x', 'flip_side_y', 'up_y', 'up_x', 'gravity']


class EmuError(RuntimeError):
    pass


class PushoutLivelock(EmuError):
    pass


class EpEmu:
    def __init__(self, table=1, exe_path=None, log_io=False, boot=True, angle_digit='1', players='1'):
        if table != 1:
            raise NotImplementedError('only EP1 addresses are mapped (see EP1 dict)')
        self.A = EP1
        self.exe_path = exe_path or os.path.join(ROOT, 'original', self.A['exe'])
        self.log_io = log_io
        self.log = []
        self.vectors = {}
        self.exited = False
        self.retrace = 0
        self.cs = LOAD_SEG + self.A['cs']
        self.ds = LOAD_SEG + self.A['ds']
        self.response_log = []      # per physics step: first-response info
        self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        self.uc.mem_map(0, MEM_SIZE)
        self._load(angle_digit, players)
        self.uc.hook_add(UC_HOOK_INTR, self._on_int)
        self.uc.hook_add(UC_HOOK_INSN, self._on_in, None, 1, 0, UC_X86_INS_IN)
        self.uc.hook_add(UC_HOOK_INSN, self._on_out, None, 1, 0, UC_X86_INS_OUT)
        a = self.lin(self.cs, self.A['collision_response_dir_stored'])
        self.uc.hook_add(UC_HOOK_CODE, self._on_response, None, a, a)
        self.sensor_log = []        # (colour, layer, handler ip) of every rule handler the game dispatches
        a = self.lin(self.cs, self.A['sensor_dispatch'])
        self.uc.hook_add(UC_HOOK_CODE, self._on_sensor, None, a, a)
        self.patched = {}
        if boot:
            self.boot()

    # ------------------------------------------------------------------ memory
    @staticmethod
    def lin(seg, off):
        return (seg << 4) + off

    def rb(self, seg, off):
        return self.uc.mem_read(self.lin(seg, off), 1)[0]

    def rw(self, seg, off, signed=True):
        return struct.unpack('<h' if signed else '<H', self.uc.mem_read(self.lin(seg, off), 2))[0]

    def wb(self, seg, off, v):
        self.uc.mem_write(self.lin(seg, off), bytes([v & 0xFF]))

    def ww(self, seg, off, v):
        self.uc.mem_write(self.lin(seg, off), struct.pack('<H', v & 0xFFFF))

    def dsw(self, name, idx=0, signed=True):
        return self.rw(self.ds, self.A['ds_vars'][name] + 2 * idx, signed)

    def dsb(self, name, idx=0):
        return self.rb(self.ds, self.A['ds_vars'][name] + idx)

    def set_dsw(self, name, v, idx=0):
        self.ww(self.ds, self.A['ds_vars'][name] + 2 * idx, v)

    def set_dsb(self, name, v, idx=0):
        self.wb(self.ds, self.A['ds_vars'][name] + idx, v)

    def set_csb(self, name, v):
        self.wb(self.cs, self.A['cs_vars'][name], v)

    def csb(self, name):
        return self.rb(self.cs, self.A['cs_vars'][name])

    # ------------------------------------------------------------------ loading
    def _load(self, angle_digit, players='1'):
        exe = epexe.load(self.exe_path)
        d = exe.data
        lastpage, pages = struct.unpack_from('<HH', d, 2)
        img_end = pages * 512 - ((512 - lastpage) if lastpage else 0)
        image = bytearray(d[exe.header_size:img_end])
        for seg, off in exe.relocs:
            p = seg * 16 + off
            v = struct.unpack_from('<H', image, p)[0]
            struct.pack_into('<H', image, p, (v + LOAD_SEG) & 0xFFFF)
        self.image_size = len(image)
        self.uc.mem_write(self.lin(LOAD_SEG, 0), bytes(image))
        ss, sp = struct.unpack_from('<HH', d, 0x0E)
        # PSP: int 20h, top of memory, command line as PINBALL.EXE builds it (engine.md s8)
        psp = LOAD_SEG - 0x10
        p = bytearray(256)
        p[0:2] = b'\xCD\x20'
        struct.pack_into('<H', p, 2, 0xA000)
        tail = bytearray(b' ' + players.encode())  # 81: ' ', 82: players '1'..'4' or 'D' (demo)
        tail += bytes([0xC8] * 16)               # 83..92: sound far pointers -> invalid: snd_present=0
        tail += b'0' * (0x9E - 0x93)             # 93..9D filler
        tail += b'@'                             # 9E: launched-by-PINBALL marker
        tail += b'3'                             # 9F: balls per game
        tail += angle_digit.encode()             # A0: table angle ('1' = normal, gravity +0)
        tail += b'0'                             # A1: option bits (no sfx/music, timer mode, no flag3)
        tail += b'\r'
        p[0x80] = len(tail) - 1
        p[0x81:0x81 + len(tail)] = tail
        self.uc.mem_write(self.lin(psp, 0), bytes(p))
        # a dummy IRET for any vector the game asks about
        self.uc.mem_write(self.lin(0xF000, 0xFF53), b'\xCF')
        r = self.uc.reg_write
        r(UC_X86_REG_CS, LOAD_SEG + exe.entry_cs)
        r(UC_X86_REG_IP, exe.entry_ip)
        r(UC_X86_REG_SS, LOAD_SEG + ss)
        r(UC_X86_REG_SP, sp)
        r(UC_X86_REG_DS, psp)
        r(UC_X86_REG_ES, psp)
        self.entry = (LOAD_SEG + exe.entry_cs, exe.entry_ip)

    # ------------------------------------------------------------------ hooks
    def _on_int(self, uc, intno, _):
        ax = uc.reg_read(UC_X86_REG_AX)
        ah = ax >> 8
        if intno == 0x10:
            if ah == 0x0F:
                uc.reg_write(UC_X86_REG_AX, 0x5003)   # 80 columns, mode 3
                uc.reg_write(UC_X86_REG_BX, uc.reg_read(UC_X86_REG_BX) & 0x00FF)
            self.log.append(('int10', hex(ax)))
        elif intno == 0x21:
            if ah == 0x35:
                uc.reg_write(UC_X86_REG_ES, 0xF000)
                uc.reg_write(UC_X86_REG_BX, 0xFF53)
            elif ah == 0x25:
                self.vectors[ax & 0xFF] = (uc.reg_read(UC_X86_REG_DS), uc.reg_read(UC_X86_REG_DX))
            elif ah == 0x09:
                ds, dx = uc.reg_read(UC_X86_REG_DS), uc.reg_read(UC_X86_REG_DX)
                s = bytes(uc.mem_read(self.lin(ds, dx), 200)).split(b'$')[0]
                self.log.append(('print', s.decode('latin-1')))
            elif ah == 0x4C:
                self.exited = True
                uc.emu_stop()
            else:
                self.log.append(('int21?', hex(ax)))
        elif intno == 0:
            ip = uc.reg_read(UC_X86_REG_IP)
            cs = uc.reg_read(UC_X86_REG_CS)
            self.log.append(('divide_error', hex(cs - LOAD_SEG), hex(ip)))
            self.fault = ('divide error', cs, ip)
            uc.emu_stop()
        else:
            self.log.append(('int?', hex(intno), hex(ax)))

    def _on_in(self, uc, port, size, _):
        if port == 0x3DA:
            self.retrace ^= 0x08
            return self.retrace
        if port == 0x201:
            return 0xFF
        if self.log_io:
            self.log.append(('in', hex(port)))
        return 0

    def _on_out(self, uc, port, size, value, _):
        if self.log_io:
            self.log.append(('out', hex(port), hex(value)))

    def _on_response(self, uc, address, size, _):
        # cs:1AEC: collision_response has just stored contact_dir.  Record the
        # state that decides which response branch runs.
        di = uc.reg_read(UC_X86_REG_DI)
        self.response_log.append(dict(
            ball=di // 2,
            k=self.dsb('contact_dir'),
            first=self.dsb('collided') == 0,
            flipper_contact=self.dsb('flipper_contact'),
            kick=self.dsb('kick_strength'),
            hits=self.dsw('hit_count'),
            hit_list=bytes(self.uc.mem_read(self.lin(self.ds, 0x6C20), max(0, min(48, self.dsw('hit_count'))))),
        ))

    def _on_sensor(self, uc, address, size, _):
        # cs:1E66: colour_event_dispatch is about to jump through cs:1E77[al-0xAA].
        al = uc.reg_read(UC_X86_REG_AX) & 0xFF
        handler = self.rw(self.cs, self.A['sensor_table'] + 2 * (al - 0xAA), signed=False) if al >= 0xAA else None
        self.sensor_log.append((al, self.rb(self.ds, 0x677E), handler))

    # ------------------------------------------------------------------ execution
    def _run(self, cs, ip, stop_ip, limit):
        self.fault = None
        self.uc.reg_write(UC_X86_REG_CS, cs)
        self.uc.reg_write(UC_X86_REG_IP, ip)
        try:
            self.uc.emu_start(self.lin(cs, ip), self.lin(cs, stop_ip), 0, limit)
        except UcError as e:
            cur = (self.uc.reg_read(UC_X86_REG_CS), self.uc.reg_read(UC_X86_REG_IP))
            raise EmuError(f'unicorn error {e} at {cur[0] - LOAD_SEG:04x}:{cur[1]:04x}') from e
        cur_cs, cur_ip = self.uc.reg_read(UC_X86_REG_CS), self.uc.reg_read(UC_X86_REG_IP)
        if self.fault:
            raise EmuError(f'{self.fault[0]} at cs:{self.fault[2]:04x}')
        if (cur_cs, cur_ip) != (cs, stop_ip):
            raise EmuError(f'did not reach cs:{stop_ip:04x} within {limit} instructions '
                           f'(stopped at {cur_cs - LOAD_SEG:04x}:{cur_ip:04x})')

    def _code_bytes(self):
        b = bytearray(self.uc.mem_read(self.lin(self.cs, 0), self.A['code_check_end']))
        for lo, hi in self.A['code_vars']:
            b[lo:hi] = bytes(hi - lo)
        return bytes(b)

    def code_intact(self):
        """True if the game's code (cs:0000..code_check_end, minus CS variables) is unmodified."""
        return self._code_bytes() == self.code_ref

    def boot(self, limit=400_000_000):
        """Run entry + init until the first arrival at the main loop."""
        cs, ip = self.entry
        self.code_ref = self._code_bytes()
        self._run(cs, ip, self.A['main_loop'], limit)
        if not self.code_intact():
            raise EmuError('code segment modified during boot')
        self.boot_sp = (self.uc.reg_read(UC_X86_REG_SS), self.uc.reg_read(UC_X86_REG_SP))
        self.uc.reg_write(UC_X86_REG_DS, self.ds)

    def _prep_regs(self):
        ss, sp = self.boot_sp
        self.uc.reg_write(UC_X86_REG_SS, ss)
        self.uc.reg_write(UC_X86_REG_SP, sp)
        self.uc.reg_write(UC_X86_REG_DS, self.ds)
        self.uc.reg_write(UC_X86_REG_FLAGS, 0x0202)

    def call_near(self, ip, limit=5_000_000, **regs):
        """Call a near routine in the game's code segment and return when it returns."""
        self._prep_regs()
        for k, v in regs.items():
            self.uc.reg_write(getattr(sys.modules['unicorn.x86_const'], 'UC_X86_REG_' + k.upper()), v)
        ss, sp = self.boot_sp
        sp -= 2
        self.ww(ss, sp, SENTINEL_IP)
        self.uc.reg_write(UC_X86_REG_SP, sp)
        self._run(self.cs, ip, SENTINEL_IP, limit)

    def run_range(self, start, stop, skip_calls=(), limit=50_000_000):
        """Execute cs:start .. cs:stop (exclusive) with the given call sites NOPed out."""
        saved = []
        for a in skip_calls:
            op = self.rb(self.cs, a)
            n = {0xE8: 3, 0x9A: 5}.get(op)
            if n is None:
                raise EmuError(f'cs:{a:04x} is not a call (opcode {op:02x})')
            saved.append((a, bytes(self.uc.mem_read(self.lin(self.cs, a), n))))
            self._patch(a, b'\x90' * n)
        try:
            self._prep_regs()
            self._run(self.cs, start, stop, limit)
        finally:
            for a, b in saved:
                self._patch(a, b)

    def _patch(self, off, data):
        """Write code bytes and drop any translated blocks that contain them (uc.mem_write alone
        does not invalidate Unicorn's translation cache, so a stale block would keep running)."""
        a = self.lin(self.cs, off)
        self.uc.mem_write(a, data)
        self.uc.ctl_remove_cache(a, a + len(data))

    # ------------------------------------------------------------------ game state
    def collision_buffer(self):
        import numpy as np
        top = self.dsw('pf_seg_top', signed=False)
        raw = bytes(self.uc.mem_read(self.lin(top, 0), 128000))
        return np.frombuffer(raw, dtype=np.uint8).reshape(400, 320).copy()

    def params(self):
        return [self.dsw('params', i) for i in range(10)]

    def set_params(self, p):
        if isinstance(p, dict):
            for k, v in p.items():
                i = PARAM_NAMES.index(k) if not str(k).isdigit() else int(k)
                self.set_dsw('params', v, i)
        else:
            for i, v in enumerate(p):
                if v is not None:
                    self.set_dsw('params', v, i)

    def ball(self, i=0):
        return dict(
            x=self.dsw('ball_x', i), y=self.dsw('ball_y', i),
            xf=self.dsw('ball_accx', i), yf=self.dsw('ball_accy', i),
            vx=self.dsw('ball_vx', i), vy=self.dsw('ball_vy', i),
            layer=self.dsb('ball_layer', 2 * i), active=self.dsw('ball_active', i),
        )

    def set_ball(self, i=0, x=None, y=None, xf=0, yf=0, vx=0, vy=0, layer=0, active=1):
        self.set_dsw('ball_active', active, i)
        if x is not None:
            self.set_dsw('ball_x', x, i)
        if y is not None:
            self.set_dsw('ball_y', y, i)
        self.set_dsw('ball_accx', xf, i)
        self.set_dsw('ball_accy', yf, i)
        self.set_dsw('ball_vx', vx, i)
        self.set_dsw('ball_vy', vy, i)
        self.set_dsb('ball_layer', layer, 2 * i)

    def set_keys(self, mask):
        self.set_csb('key_lflip', 1 if mask & 1 else 0)
        self.set_csb('key_rflip', 1 if mask & 2 else 0)
        self.set_csb('key_ctrl', 1 if mask & 4 else 0)

    def reset_play_state(self):
        """Neutral single-ball play state (used before a scenario)."""
        for i in range(5):
            self.set_dsw('ball_active', 0, i)
        for n in ('serve_delay', 'kicker_cooldown', 'event_lockout', 'event_cooldown',
                  'nudge_timer', 'tilt_meter', 'tilted', 'collided', 'flipper_contact', 'kick_strength'):
            self.set_dsb(n, 0)
        self.set_dsw('plunger_charge', 0)
        self.set_dsw('extra_gravity_timer', 0)
        for n in ('key_lflip', 'key_rflip', 'key_up', 'key_down', 'key_space', 'key_ctrl',
                  'key_nudge_a', 'key_nudge_b'):
            self.set_csb(n, 0)
        self.set_csb('last_scancode', 0x8C)      # a key-release code: no pending key

    # ------------------------------------------------------------------ frame drivers
    def main_loop_physics(self, mode='physics'):
        ranges = self.A['physics_ranges' if mode == 'physics' else 'rules_ranges']
        for start, stop, skips in ranges:
            self.run_range(start, stop, skips)

    def main_loop_full(self, limit=200_000_000):
        """Run the real main loop body cs:04D2 .. cs:1243 (frame_sync not executed)."""
        self._prep_regs()
        self._run(self.cs, self.A['main_loop'], self.A['frame_sync'], limit)

    def physics_step(self, limit=1_000_000):
        """One call of cs:1724 (what the timer ISR does on each of its 3 ticks per frame).

        A normal step is a few thousand instructions.  The push-out loop inside it
        (cs:1826..18FA) has no iteration cap, so a ball embedded across a thin wall
        can oscillate forever; that raises PushoutLivelock (the original would hang).
        """
        self.response_log = []
        try:
            self.call_near(self.A['physics_step'], limit=limit)
        except EmuError as e:
            if 'did not reach' in str(e):
                ks = [r['k'] for r in self.response_log[-6:]]
                raise PushoutLivelock(f'physics_step did not return after {limit} instructions; '
                                      f'push-out loop cycling through k={ks} (ball {self.ball(0)})') from e
            raise
        return self.response_log

    # ------------------------------------------------------------------ snapshots
    def snapshot(self):
        return (self.uc.context_save(), bytes(self.uc.mem_read(0, MEM_SIZE)), self.retrace)

    def restore(self, snap):
        ctx, mem, self.retrace = snap
        self.uc.context_restore(ctx)
        self.uc.mem_write(0, mem)
        self.uc.ctl_flush_tb()

#!/usr/bin/env python3
"""
AC3 Bridge - capture 6ch from a virtual device (BlackHole 16ch), encode to
AC-3 with ffmpeg, wrap in IEC 61937 (spdif) and play the result as 2ch 48 kHz
16-bit PCM on a chosen pair of output channels (e.g. 9-10).

Setup (macOS):
    brew install ffmpeg python-tk blackhole-16ch
    pip3 install sounddevice
    python3 ac3bridge.py

In Audio MIDI Setup:
  * BlackHole 16ch: format 48000 Hz, configure speakers -> 5.1 (L R C LFE Ls Rs
    on channels 1-6). Set it as macOS output (or Safari's output).
  * Your DAC: 48000 Hz, 16-bit, system volume at 100%.
"""
import array
import collections
import json
import os
import shutil
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox

import sounddevice as sd

RATE = 48000
FRAME_BYTES = 1536 * 4      # one AC-3 frame in IEC 61937 = 1536 stereo s16 samples
PREFILL = 1                 # frames buffered before playback starts (~96 ms)
MAX_BUF = 8                 # drop whole frames beyond this (~256 ms)
CFG_PATH = os.path.expanduser("~/.ac3bridge.json")


def find_ffmpeg():
    p = shutil.which("ffmpeg")
    if p:
        return p
    for c in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if os.path.exists(c):
            return c
    return None


class Bridge:
    def __init__(self, in_dev, out_dev, first_ch, bitrate, prefill=PREFILL):
        self.in_dev, self.out_dev = in_dev, out_dev
        self.first_ch, self.bitrate = first_ch, bitrate
        self.prefill = prefill  # frames buffered before/while playing (32 ms each)
        self.lock = threading.Lock()
        self.buf = collections.deque()
        self.cur, self.pos, self.playing = None, 0, False
        self.drops = self.underruns = 0
        self.stderr_last = ""
        self.inq = collections.deque()
        self.inq_cv = threading.Condition()
        self.running = False
        self.proc = self.ins = self.outs = None

    # ---- audio callbacks -------------------------------------------------
    @property
    def max_buf(self):
        return self.prefill + 3  # headroom for clock drift before dropping

    def _in_cb(self, indata, frames, t, status):
        with self.inq_cv:
            self.inq.append(bytes(indata))
            if len(self.inq) > 200:       # ffmpeg stalled; don't grow forever
                self.inq.popleft()
            self.inq_cv.notify()

    def _out_cb(self, outdata, frames, t, status):
        need = frames * 4
        out = bytearray()
        with self.lock:
            if not self.playing and len(self.buf) >= self.prefill:
                self.playing = True
            while self.playing and len(out) < need:
                if self.cur is None or self.pos >= len(self.cur):
                    if self.buf:
                        self.cur, self.pos = self.buf.popleft(), 0
                    else:
                        self.playing = False
                        self.cur = None
                        self.underruns += 1
                        break
                n = min(need - len(out), len(self.cur) - self.pos)
                out += self.cur[self.pos:self.pos + n]
                self.pos += n
        if len(out) < need:
            out += bytes(need - len(out))
        # place the stereo pair in columns col, col+1 of an N-channel frame
        st = array.array("H")
        st.frombytes(bytes(out))
        n = self.nch
        full = array.array("H", bytes(frames * n * 2))
        full[self.col::n] = st[0::2]
        full[self.col + 1::n] = st[1::2]
        outdata[:] = full.tobytes()

    # ---- threads ---------------------------------------------------------
    def _writer(self):
        while self.running:
            with self.inq_cv:
                while self.running and not self.inq:
                    self.inq_cv.wait(0.2)
                data = self.inq.popleft() if self.inq else None
            if data is None:
                continue
            try:
                self.proc.stdin.write(data)
                self.proc.stdin.flush()
            except (BrokenPipeError, ValueError, OSError):
                break

    def _reader(self):
        while self.running:
            data = self.proc.stdout.read(FRAME_BYTES)
            if len(data) < FRAME_BYTES:
                break
            with self.lock:
                self.buf.append(data)
                while len(self.buf) > self.max_buf:
                    self.buf.popleft()
                    self.drops += 1

    def _err_reader(self):
        for line in self.proc.stderr:
            self.stderr_last = line.decode(errors="replace").strip()

    # ---- control ---------------------------------------------------------
    def _open_out(self, c):
        # Try strict first (no conversion at all). Devices that only offer
        # 24/32-bit (e.g. Focusrite) may reject that, so fall back to
        # relaxed mode: int16 -> 24-bit is a lossless left shift, and the
        # sample rate is still forced to 48 kHz via change_device_parameters.
        last = None
        for strict in (True, False):
            extra = sd.CoreAudioSettings(
                change_device_parameters=True,
                fail_if_conversion_required=strict)
            try:
                s = sd.RawOutputStream(
                    device=self.out_dev, samplerate=RATE, channels=self.nch,
                    dtype="int16", latency="low", extra_settings=extra,
                    callback=self._out_cb)
                self.strict = strict
                return s
            except sd.PortAudioError as e:
                last = e
        raise last

    def start(self):
        ff = find_ffmpeg()
        if not ff:
            raise RuntimeError("ffmpeg not found. Run: brew install ffmpeg")
        self.proc = subprocess.Popen(
            [ff, "-hide_banner", "-loglevel", "error",
             "-f", "s16le", "-ar", str(RATE), "-ac", "6", "-i", "pipe:0",
             "-c:a", "ac3", "-b:a", f"{self.bitrate}k", "-ar", str(RATE),
             "-flush_packets", "1", "-f", "spdif", "pipe:1"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0)
        self.running = True
        for fn in (self._writer, self._reader, self._err_reader):
            threading.Thread(target=fn, daemon=True).start()

        c = self.first_ch - 1  # zero-based device channel
        self.col = c
        self.nch = sd.query_devices(self.out_dev)["max_output_channels"]
        try:
            self.outs = self._open_out(c)
            self.ins = sd.RawInputStream(
                device=self.in_dev, samplerate=RATE, channels=6,
                dtype="int16", latency="low", callback=self._in_cb)
            self.outs.start()
            self.ins.start()
        except Exception:
            self.stop()
            raise

    def alive(self):
        return self.running and self.proc is not None and self.proc.poll() is None

    def stop(self):
        self.running = False
        for s in (self.ins, self.outs):
            try:
                if s:
                    s.stop()
                    s.close()
            except Exception:
                pass
        if self.proc:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self.ins = self.outs = self.proc = None


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("AC3 Bridge")
        self.resizable(False, False)
        self.bridge = None
        self.cfg = {}
        try:
            with open(CFG_PATH) as f:
                self.cfg = json.load(f)
        except Exception:
            pass

        pad = {"padx": 8, "pady": 4}
        frm = ttk.Frame(self, padding=10)
        frm.grid()

        ttk.Label(frm, text="Input (6ch virtual device)").grid(row=0, column=0, sticky="w", **pad)
        self.in_var = tk.StringVar()
        self.in_box = ttk.Combobox(frm, textvariable=self.in_var, width=44, state="readonly")
        self.in_box.grid(row=0, column=1, columnspan=2, **pad)

        ttk.Label(frm, text="Output device").grid(row=1, column=0, sticky="w", **pad)
        self.out_var = tk.StringVar()
        self.out_box = ttk.Combobox(frm, textvariable=self.out_var, width=44, state="readonly")
        self.out_box.grid(row=1, column=1, columnspan=2, **pad)

        ttk.Label(frm, text="First output channel").grid(row=2, column=0, sticky="w", **pad)
        self.ch_var = tk.IntVar(value=self.cfg.get("first_ch", 9))
        ttk.Spinbox(frm, from_=1, to=63, textvariable=self.ch_var, width=5).grid(
            row=2, column=1, sticky="w", **pad)
        ttk.Label(frm, text="(uses this channel and the next, e.g. 9 -> 9-10)").grid(
            row=2, column=2, sticky="w")

        ttk.Label(frm, text="AC-3 bitrate (kbps)").grid(row=3, column=0, sticky="w", **pad)
        self.br_var = tk.StringVar(value=str(self.cfg.get("bitrate", 640)))
        ttk.Combobox(frm, textvariable=self.br_var, values=["384", "448", "576", "640"],
                     width=6, state="readonly").grid(row=3, column=1, sticky="w", **pad)

        pf = ttk.Frame(frm)
        pf.grid(row=3, column=2, sticky="w")
        ttk.Label(pf, text="Buffer (frames)").grid(row=0, column=0)
        self.pf_var = tk.IntVar(value=self.cfg.get("prefill", PREFILL))
        ttk.Spinbox(pf, from_=1, to=8, textvariable=self.pf_var, width=3,
                    command=self.on_pf).grid(row=0, column=1, padx=4)
        self.pf_ms = tk.StringVar()
        ttk.Label(pf, textvariable=self.pf_ms).grid(row=0, column=2)
        self.pf_var.trace_add("write", lambda *a: self.on_pf())
        self.on_pf()

        btns = ttk.Frame(frm)
        btns.grid(row=4, column=0, columnspan=3, pady=8)
        self.btn = ttk.Button(btns, text="Start", command=self.toggle)
        self.btn.grid(row=0, column=0, padx=6)
        ttk.Button(btns, text="Refresh devices", command=self.refresh).grid(row=0, column=1, padx=6)

        self.status = tk.StringVar(value="Stopped")
        ttk.Label(frm, textvariable=self.status, wraplength=420).grid(
            row=5, column=0, columnspan=3, sticky="w", **pad)

        self.refresh()
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.after(500, self.tick)

    def refresh(self):
        devs = sd.query_devices()
        ins = [f"{i}: {d['name']} ({d['max_input_channels']} in)"
               for i, d in enumerate(devs) if d["max_input_channels"] >= 6]
        outs = [f"{i}: {d['name']} ({d['max_output_channels']} out)"
                for i, d in enumerate(devs) if d["max_output_channels"] >= 2]
        self.in_box["values"], self.out_box["values"] = ins, outs

        def pick(options, saved, hint):
            for o in options:
                if saved and o.split(": ", 1)[1].rsplit(" (", 1)[0] == saved:
                    return o
            for o in options:
                if hint.lower() in o.lower():
                    return o
            return options[0] if options else ""

        self.in_var.set(pick(ins, self.cfg.get("in_name"), "blackhole 16ch"))
        self.out_var.set(pick(outs, self.cfg.get("out_name"), "scarlett"))

    @staticmethod
    def parse(sel):
        idx, rest = sel.split(": ", 1)
        return int(idx), rest.rsplit(" (", 1)[0]

    def toggle(self):
        if self.bridge:
            self.bridge.stop()
            self.bridge = None
            self.btn.config(text="Start")
            self.status.set("Stopped")
            return
        if not self.in_var.get() or not self.out_var.get():
            messagebox.showerror("AC3 Bridge", "Pick input and output devices.")
            return
        in_idx, in_name = self.parse(self.in_var.get())
        out_idx, out_name = self.parse(self.out_var.get())
        first = int(self.ch_var.get())
        maxch = sd.query_devices(out_idx)["max_output_channels"]
        if first + 1 > maxch:
            messagebox.showerror("AC3 Bridge",
                                 f"Output device only has {maxch} channels.")
            return
        try:
            b = Bridge(in_idx, out_idx, first, int(self.br_var.get()), self._pf())
            b.start()
        except Exception as e:
            messagebox.showerror("AC3 Bridge", f"Could not start:\n{e}")
            return
        self.bridge = b
        self.btn.config(text="Stop")
        self.cfg = {"in_name": in_name, "out_name": out_name,
                    "first_ch": first, "bitrate": int(self.br_var.get()),
                    "prefill": self._pf()}
        try:
            with open(CFG_PATH, "w") as f:
                json.dump(self.cfg, f)
        except Exception:
            pass

    def _pf(self):
        try:
            return max(1, min(8, int(self.pf_var.get())))
        except (tk.TclError, ValueError):
            return PREFILL

    def on_pf(self):
        n = self._pf()
        self.pf_ms.set(f"~{n * 32} ms")
        if self.bridge:
            self.bridge.prefill = n  # takes effect live

    def tick(self):
        b = self.bridge
        if b:
            if not b.alive():
                msg = b.stderr_last or "ffmpeg exited"
                b.stop()
                self.bridge = None
                self.btn.config(text="Start")
                self.status.set(f"Stopped: {msg}")
            else:
                with b.lock:
                    fill, d, u, p = len(b.buf), b.drops, b.underruns, b.playing
                self.status.set(
                    f"Running ({'streaming' if p else 'buffering'}) | "
                    f"buffer {fill}/{b.max_buf} frames | dropped {d} | underruns {u} | "
                    f"{'strict' if getattr(b, 'strict', None) else 'bit-depth conversion (lossless)'}")
        self.after(500, self.tick)

    def on_close(self):
        if self.bridge:
            self.bridge.stop()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()

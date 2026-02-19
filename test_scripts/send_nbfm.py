#!/usr/bin/env python3
"""
/**
 * @file send_nbfm.py
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief NBFM Transmitter script for FPGA I/Q Modulator
 * @version 0.1
 * @date 2026-02-18
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */
"""

import argparse
import ctypes
import math
import struct
import sys
import time

def _win_timer_begin():
    """Set Windows timer resolution to 1 ms for accurate time.sleep()."""
    if sys.platform == 'win32':
        try:
            ctypes.windll.winmm.timeBeginPeriod(1)
            return True
        except Exception:
            pass
    return False

def _win_timer_end(active):
    if active:
        ctypes.windll.winmm.timeEndPeriod(1)

CLK_FREQ = 27_000_000

def freq_to_tuning_word(freq_hz):
    """Convert desired frequency to NCO tuning word."""
    return int(freq_hz * (2**32) / CLK_FREQ)

def tuning_word_cmd(tw):
    """Create 5-byte UART command: 0x80 + 4 bytes MSB-first."""
    return bytes([0x80,
                  (tw >> 24) & 0xFF,
                  (tw >> 16) & 0xFF,
                  (tw >>  8) & 0xFF,
                  tw & 0xFF])

def generate_fm_iq(audio_samples, sample_rate, deviation_hz=2500):
    """
    Generate NBFM I/Q samples from audio.
    I = cos(phi), Q = sin(phi), where phi = integral of 2*pi*deviation*audio
    """
    data = bytearray()
    phase = 0.0
    for s in audio_samples:
        # Accumulate FM phase
        phase += 2.0 * math.pi * deviation_hz * s / sample_rate
        # Generate I/Q — radius 127 = maximum safe value (127 < 128 = 0x80 command prefix)
        i_val = int(127 * math.cos(phase))
        q_val = int(127 * math.sin(phase))
        
        # Clamp to -127..+127 to avoid sending -128 (0x80) which is command prefix
        i_val = max(-127, min(127, i_val))
        q_val = max(-127, min(127, q_val))

        data.append(i_val & 0xFF)
        data.append(q_val & 0xFF)
    return data

def generate_tone(freq_hz, sample_rate, duration_s):
    """Generate a sine wave audio signal."""
    n = int(sample_rate * duration_s)
    return [math.sin(2 * math.pi * freq_hz * i / sample_rate) for i in range(n)]

def main():
    parser = argparse.ArgumentParser(description="NBFM Transmitter for FPGA")
    parser.add_argument("--port", default="COM3", help="Serial port")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate")
    parser.add_argument("--freq", type=float, default=1_000_000,
                        help="Carrier frequency in Hz")
    parser.add_argument("--tone", type=float, default=None,
                        help="Audio tone frequency in Hz")
    parser.add_argument("--wav", type=str, default=None, help="WAV file path")
    parser.add_argument("--cw", action="store_true", help="Unmodulated carrier")
    parser.add_argument("--deviation", type=float, default=2500,
                        help="FM deviation in Hz (default 2500 for NBFM)")
    parser.add_argument("--duration", type=float, default=2.0,
                        help="Duration in seconds (for tone mode)")
    parser.add_argument("--rate", type=float, default=32000,
                        help="Baseband sample rate in Hz (must match FPGA CIC: 27M/844 = 31990)")
    parser.add_argument("--loop", action="store_true",
                        help="Loop audio indefinitely (Ctrl+C to stop)")
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        print("ERROR: pyserial not installed. Run: pip install pyserial")
        sys.exit(1)

    # Calculate tuning word
    tw = freq_to_tuning_word(args.freq)
    actual_freq = tw * CLK_FREQ / (2**32)
    print(f"Carrier: {args.freq:.0f} Hz (actual: {actual_freq:.1f} Hz)")
    print(f"Tuning word: {tw} (0x{tw:08X})")
    if args.freq >= CLK_FREQ / 2:
        print(f"ERROR: freq >= Nyquist ({CLK_FREQ//2} Hz) — output will alias!")
    elif args.freq > 7_000_000:
        print(f"WARNING: freq > 7 MHz — sigma-delta noise dominates, signal quality poor.")
    elif args.freq > 1_000_000:
        print(f"NOTE: freq > 1 MHz — expect increased noise; use tighter RC filter.")

    # Generate I/Q data
    if args.cw:
        # CW: constant I=127, Q=0 — max amplitude; 1s buffer, loop handles the rest
        n = int(args.rate * min(args.duration, 1.0))
        data = bytearray()
        for _ in range(n):
            data.append(127 & 0xFF)  # I = max (0x7F, safe — 0x80 is command prefix)
            data.append(0)           # Q
        print(f"CW mode: {n} samples ({min(args.duration,1.0):.1f}s buffer, looping)")
    elif args.wav:
        import wave
        with wave.open(args.wav, 'rb') as wf:
            assert wf.getnchannels() == 1, "Mono WAV only"
            assert wf.getsampwidth() == 2, "16-bit WAV only"
            raw = wf.readframes(wf.getnframes())
            audio = [s / 32768.0 for s in
                     struct.unpack(f'<{len(raw)//2}h', raw)]
            sr = wf.getframerate()
        print(f"WAV: {len(audio)} samples @ {sr} Hz")
        # Resample to target rate if needed
        if sr != int(args.rate):
            ratio = args.rate / sr
            resampled = []
            for i in range(int(len(audio) * ratio)):
                idx = i / ratio
                i0 = int(idx)
                frac = idx - i0
                if i0 + 1 < len(audio):
                    resampled.append(audio[i0] * (1 - frac) + audio[i0+1] * frac)
                else:
                    resampled.append(audio[i0])
            audio = resampled
            print(f"Resampled to {len(audio)} samples @ {args.rate:.0f} Hz")
        data = generate_fm_iq(audio, args.rate, args.deviation)
    elif args.tone:
        audio = generate_tone(args.tone, args.rate, args.duration)
        data = generate_fm_iq(audio, args.rate, args.deviation)
        print(f"Tone: {args.tone:.0f} Hz, {len(audio)} samples")
    else:
        print("Specify --tone, --wav, or --cw")
        sys.exit(1)

    print(f"I/Q data: {len(data)} bytes ({len(data)//2} samples)")

    # Send
    win_timer = _win_timer_begin()
    if win_timer:
        print("Windows 1 ms timer resolution enabled.")
    ser = serial.Serial(args.port, args.baud, timeout=1)
    time.sleep(0.1)

    # Set tuning word
    cmd = tuning_word_cmd(tw)
    ser.write(cmd)
    time.sleep(0.05)
    print(f"Tuning word set.")

    # Stream I/Q — drift-corrected pacing, factor 0.97
    # time.monotonic() tracks cumulative schedule; if one sleep runs long the next
    # fires immediately. With 1 ms timer resolution (timeBeginPeriod) sleep(3.88 ms)
    # is actually ~4 ms, keeping Python rate ≈ FPGA rate with minimal FIFO overflow.
    # Factor 0.97 compensates for the small residual mismatch between --rate and
    # the true FPGA rate (CLK/CIC_RATE = 31 990.52 Hz).
    chunk = 256
    print(f"Streaming to {args.port}..." + (" (loop, Ctrl+C to stop)" if args.loop else ""))
    t_start = time.monotonic()
    samples_sent = 0
    try:
        while True:
            for off in range(0, len(data), chunk):
                chunk_data = data[off:off+chunk]
                ser.write(chunk_data)
                samples_sent += len(chunk_data) // 2
                t_target = t_start + samples_sent / args.rate * 0.97
                remaining = t_target - time.monotonic()
                if remaining > 0:
                    time.sleep(remaining)
            if not args.loop:
                break
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        _win_timer_end(win_timer)
        ser.close()
        print("Done.")

if __name__ == "__main__":
    main()

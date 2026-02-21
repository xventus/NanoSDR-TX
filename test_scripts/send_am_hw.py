#!/usr/bin/env python3
"""
/**
 * @file send_am_hw.py
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief Amplitude Modulation (AM) Transmitter script for FPGA I/Q Modulator (WITH HW FLOW CONTROL)
 * @version 0.1
 * @date 2026-02-21
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

try:
    import serial
except ImportError:
    print("ERROR: pyserial not installed. Run: pip install pyserial")
    sys.exit(1)

CLK_FREQ = 27_000_000

def freq_to_tuning_word(freq_hz):
    return int(freq_hz * (2**32) / CLK_FREQ)

def tuning_word_cmd(tw):
    return bytes([0x80, (tw >> 24) & 0xFF, (tw >> 16) & 0xFF, (tw >> 8) & 0xFF, tw & 0xFF])

def generate_am_iq(audio_samples, mod_index=0.8, carrier_amp=60):
    """
    Generate AM I/Q samples.
    I = A * (1 + m * audio)
    Q = 0
    """
    data = bytearray()
    for s in audio_samples:
        # s is -1.0 to 1.0
        # Envelope = 1 + m*s  (range: 1-m to 1+m)
        envelope = 1.0 + (mod_index * s)
        
        # Calculate I (In-phase component is the amplitude modulated signal)
        i_val = int(carrier_amp * envelope)
        q_val = 0 # AM has no quadrature component relative to carrier phase
        
        # Clamp
        i_val = max(-127, min(127, i_val))
        
        data.append(i_val & 0xFF)
        data.append(q_val & 0xFF)
    return data

def generate_tone(freq_hz, sample_rate, duration_s):
    n = int(sample_rate * duration_s)
    return [math.sin(2 * math.pi * freq_hz * i / sample_rate) for i in range(n)]

def read_wav(filename, target_rate):
    import wave
    with wave.open(filename, 'rb') as wf:
        if wf.getnchannels() != 1:
            print("Warning: unexpected channel count, using only channel 1")
        
        raw = wf.readframes(wf.getnframes())
        # Parse 16-bit PCM
        shorts = struct.unpack(f'<{len(raw)//2}h', raw)
        audio = [s / 32768.0 for s in shorts]
        sr = wf.getframerate()
        
    print(f"WAV loaded: {len(audio)} samples @ {sr} Hz")
    
    # Simple linear resampling
    if sr != int(target_rate):
        ratio = target_rate / sr
        new_len = int(len(audio) * ratio)
        resampled = [0.0] * new_len
        print(f"Resampling to {target_rate} Hz...")
        for i in range(new_len):
            idx = i / ratio
            i0 = int(idx)
            frac = idx - i0
            if i0 + 1 < len(audio):
                val = audio[i0] * (1 - frac) + audio[i0+1] * frac
            else:
                val = audio[i0]
            resampled[i] = val
        return resampled
    return audio

def main():
    parser = argparse.ArgumentParser(description="AM Transmitter for FPGA (Hardware Flow Control)")
    parser.add_argument("--port", default="COM3", help="Serial port")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate")
    parser.add_argument("--freq", type=float, default=1_000_000, help="Carrier Hz")
    parser.add_argument("--tone", type=float, default=1000, help="Tone Hz")
    parser.add_argument("--wav", type=str, default=None, help="WAV file")
    parser.add_argument("--mod", type=float, default=0.8, help="Modulation Index (0.0-1.0)")
    parser.add_argument("--amp", type=int, default=0,
                        help="Carrier Amplitude (default: auto = floor(127/(1+mod)))")
    parser.add_argument("--duration", type=float, default=5.0, help="Tone duration (s)")
    parser.add_argument("--loop", action="store_true", help="Loop audio indefinitely (Ctrl+C to stop)")
    parser.add_argument("--rate", type=float, default=32000, help="Sample rate")

    args = parser.parse_args()

    # Auto-compute max safe amplitude if not specified
    if args.amp == 0:
        args.amp = int(127 / (1 + args.mod))
    print(f"Carrier amplitude: {args.amp} (mod={args.mod}, max I={int(args.amp*(1+args.mod))})")

    # 1. Prepare Audio
    if args.wav:
        audio = read_wav(args.wav, args.rate)
    else:
        audio = generate_tone(args.tone, args.rate, args.duration)
        print(f"Generated {args.duration}s tone @ {args.tone} Hz")

    # 2. Generate I/Q
    iq_data = generate_am_iq(audio, args.mod, args.amp)
    print(f"Prepared {len(iq_data)} bytes of I/Q data.")

    # 3. Setup Serial
    win_timer = _win_timer_begin()
    if win_timer:
        print("Windows 1 ms timer resolution enabled.")
        
    # HW Flow Control Enabled (rtscts=True)
    ser = serial.Serial(args.port, args.baud, timeout=1, rtscts=True)
    time.sleep(0.1)

    # 4. Set Frequency
    tw = freq_to_tuning_word(args.freq)
    actual_freq = tw * CLK_FREQ / (2**32)
    print(f"Carrier: {args.freq:.0f} Hz (actual: {actual_freq:.1f} Hz, TW: {tw})")
    if args.freq >= CLK_FREQ / 2:
        print(f"ERROR: freq >= Nyquist ({CLK_FREQ//2} Hz) — output will alias!")
    elif args.freq > 7_000_000:
        print(f"WARNING: freq > 7 MHz — sigma-delta noise dominates, signal quality poor.")
    elif args.freq > 1_000_000:
        print(f"NOTE: freq > 1 MHz — expect increased noise; use tighter RC filter.")
    ser.write(tuning_word_cmd(tw))
    time.sleep(0.1)

    # 5. Stream — hardware pacing via CTS/RTS
    # The OS and FTDI driver will automatically block ser.write()
    # when the FPGA asserts the RTS pin (FIFO almost full).
    chunk_size = 4096
    print("Streaming using Hardware Flow Control..." + (" (loop, Ctrl+C to stop)" if args.loop else ""))
    print("Visualizer: '.' = Transmitting, '!' = FPGA buffer full (CTS blocked)")
    
    monitoring = [True]
    def flow_monitor():
        while monitoring[0]:
            try:
                if ser.cts:
                    sys.stdout.write(".")
                else:
                    sys.stdout.write("!")
                sys.stdout.flush()
            except Exception:
                pass
            time.sleep(0.05)
            
    import threading
    threading.Thread(target=flow_monitor, daemon=True).start()

    try:
        while True:
            for i in range(0, len(iq_data), chunk_size):
                chunk = iq_data[i:i+chunk_size]
                ser.write(chunk) # Automatically blocks on full FIFO

            if not args.loop:
                break
    except KeyboardInterrupt:
        sys.stdout.write("\nStopped.\n")
    finally:
        monitoring[0] = False
        time.sleep(0.06)
        _win_timer_end(win_timer)
        ser.close()
        print("Done.")

if __name__ == "__main__":
    main()

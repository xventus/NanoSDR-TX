#!/usr/bin/env python3
"""
/**
 * @file send_qpsk_hw.py
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief QPSK Transmitter script for FPGA I/Q Modulator (WITH HW FLOW CONTROL)
 * @version 0.1
 * @date 2026-02-22
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */
"""

import argparse
import ctypes
import random
import sys
import time

def _win_timer_begin():
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

import numpy as np

def rrc_filter(alpha, sps, span):
    t = np.arange(-span*sps/2, span*sps/2 + 1) / sps
    h = np.zeros(len(t))
    for i, tc in enumerate(t):
        if tc == 0:
            h[i] = 1.0 - alpha + (4*alpha / np.pi)
        elif abs(tc) == 1/(4*alpha):
            h[i] = (alpha / np.sqrt(2)) * (
                (1 + 2/np.pi) * np.sin(np.pi/(4*alpha)) +
                (1 - 2/np.pi) * np.cos(np.pi/(4*alpha)))
        else:
            h[i] = (np.sin(np.pi*tc*(1-alpha)) + 4*alpha*tc * np.cos(np.pi*tc*(1+alpha))) / \
                   (np.pi*tc * (1 - (4*alpha*tc)**2))
    h = h / np.sqrt(np.sum(h**2)) * np.sqrt(sps)
    return h

def encode_bytes_to_symbols(data: bytes):
    num_symbols = len(data) * 4
    i_sym = np.empty(num_symbols)
    q_sym = np.empty(num_symbols)
    levels = [-1.0, 1.0]
    
    idx = 0
    for b in data:
        # 1 byte = 4 QPSK syms (2 bits each). MSB first.
        for shift in (6, 4, 2, 0):
            sym = (b >> shift) & 0x03
            i_sym[idx] = levels[(sym >> 1) & 1]
            q_sym[idx] = levels[sym & 1]
            idx += 1
    return i_sym, q_sym, num_symbols

def generate_qpsk_packet_rrc(sps: int = 4, alpha: float = 0.35, span: int = 12, scale: int = 45) -> bytes:
    import os
    
    # Text message and synchronization word
    msg = b"Hello Constello SDR! \n"
    sync_word = b'\x1A\x2B\x3C\x4D'
    chunk = sync_word + msg
    
    # Create a fully random (white noise) signal 
    # (guarantees ideal stable Constellation eyes and PLL lock)
    payload_array = bytearray(os.urandom(8192))
    
    # Scatter the message with gaps of at least 500 characters
    # (so the spectrum isn't periodic)
    for i in range(200, len(payload_array) - len(chunk), 600):
        # Insert the packet
        payload_array[i:i+len(chunk)] = chunk
        
    payload = bytes(payload_array)
    
    i_sym, q_sym, num_symbols = encode_bytes_to_symbols(payload)

    i_up = np.zeros(num_symbols * sps)
    q_up = np.zeros(num_symbols * sps)
    i_up[::sps] = i_sym
    q_up[::sps] = q_sym

    h = rrc_filter(alpha, sps, span)
    
    from scipy.signal import fftconvolve
    pad_len = len(h) // 2
    i_up_pad = np.pad(i_up, pad_width=pad_len, mode='wrap')
    q_up_pad = np.pad(q_up, pad_width=pad_len, mode='wrap')

    i_rrc = fftconvolve(i_up_pad, h, mode='valid')
    q_rrc = fftconvolve(q_up_pad, h, mode='valid')

    peak = max(np.max(np.abs(i_rrc)), np.max(np.abs(q_rrc)), 1e-9)
    
    
    # DEBUG: Adds a 15% strong central carrier that appears EXACTLY in the middle of the QPSK spectrum bump
    
    i_rrc += 0.15 * peak
    q_rrc += 0.15 * peak
    
    i_out = np.clip(np.round(i_rrc / peak * scale), -127, 127).astype(np.int8)
    q_out = np.clip(np.round(q_rrc / peak * scale), -127, 127).astype(np.int8)

    data = np.empty(num_symbols * sps * 2, dtype=np.uint8)
    data[0::2] = i_out.view(np.uint8)
    data[1::2] = q_out.view(np.uint8)
    return bytes(data)

def main():
    parser = argparse.ArgumentParser(description="QPSK Transmitter for FPGA (Hardware Flow Control)")
    parser.add_argument("--port", default="COM4", help="Serial port")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate")
    parser.add_argument("--freq", type=float, default=1_000_000, help="Carrier Hz")
    parser.add_argument("--symbols", type=int, default=5000, help="Number of symbols to send")
    # SPS=19: FPGA symbol rate = 27MHz / 844 / 19 = 1683.7 Sps (~1.684 kSps)
    # Constello: set Symbol Rate to 1.684 kSps
    # SPS=32: FPGA symbol rate = 27MHz / 844 / 32 = 999.7 Sps (~1.000 kSps)
    # The choice of SPS affects exact symbol rate - must match Constello settings!
    parser.add_argument("--sps", type=int, default=19, help="Samples Per Symbol (affects symbol rate: 27MHz/844/SPS)")
    parser.add_argument("--loop", action="store_true", help="Loop output indefinitely (Ctrl+C to stop)")
    
    args = parser.parse_args()
    
    # Calculate statistics
    bytes_per_sample = 2 # 1 byte for I, 1 byte for Q
    bytes_per_symbol = bytes_per_sample * args.sps
    uart_bytes_per_sec = args.baud / 10 # approximate standard UART overhead
    theoretical_symbol_rate = uart_bytes_per_sec / bytes_per_symbol
    theoretical_kSps = theoretical_symbol_rate / 1000.0
    fpga_sym_rate = CLK_FREQ / 844 / args.sps
    
    print("-" * 50)
    print("QPSK FPGA Transmitter Parameters:")
    print(f"  Port:              {args.port}")
    print(f"  Baud Rate:         {args.baud} bps")
    print(f"  Carrier Frequency: {args.freq} Hz")
    print(f"  Symbols to gen:    {args.symbols}")
    print(f"  Samples/Symbol:    {args.sps}")
    print(f"  Looping:           {'Yes' if args.loop else 'No'}")
    print(f"  UART max Sym Rate: ~{theoretical_kSps:.3f} kSps")
    print(f"")
    print(f"  *** FPGA Symbol Rate: {fpga_sym_rate:.1f} Hz ({fpga_sym_rate/1000:.4f} kSps) ***")
    print(f"  *** Constello: set Symbol Rate to {fpga_sym_rate/1000:.3f} kSps ***")
    print("-" * 50)
    
    iq_data = generate_qpsk_packet_rrc(sps=args.sps)
    print(f"Generated QPSK packet symbols (Total {len(iq_data)} bytes).")

    win_timer = _win_timer_begin()
    if win_timer:
        print("Windows 1 ms timer resolution enabled.")
        
    ser = serial.Serial(args.port, args.baud, timeout=1, rtscts=True)
    time.sleep(0.1)

    tw = freq_to_tuning_word(args.freq)
    actual_freq = tw * CLK_FREQ / (2**32)
    print(f"Carrier: {args.freq:.0f} Hz (actual: {actual_freq:.1f} Hz, TW: {tw})")
    
    ser.write(tuning_word_cmd(tw))
    time.sleep(0.1)

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
                ser.write(chunk)

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

#!/usr/bin/env python3
"""Generate rom_sin.v - 1024-entry sine lookup table for NCO"""
import math
import os

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rom_sin.v")

with open(out_path, "w") as f:
    f.write("module rom_sin(input clk, input [9:0] addr, output reg signed [11:0] data);\n")
    f.write("    always @(posedge clk) begin\n")
    f.write("        case (addr)\n")
    for i in range(1024):
        v = int(2047 * math.sin(2 * math.pi * i / 1024))
        if v < 0:
            f.write(f"            10'd{i}: data <= -12'sd{abs(v)};\n")
        else:
            f.write(f"            10'd{i}: data <= 12'sd{v};\n")
    f.write("        endcase\n")
    f.write("    end\n")
    f.write("endmodule\n")

print(f"Generated {out_path}")

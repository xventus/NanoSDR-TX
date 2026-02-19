/**
 * @file iq_mixer.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief I/Q Mixer (Quadrature Modulator) Module
 * @version 0.1
 * @date 2026-02-18
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */

module iq_mixer (
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [7:0]   i_data,    // I baseband (from CIC)
    input  wire signed [7:0]   q_data,    // Q baseband (from CIC)
    input  wire signed [11:0]  cos_data,  // cos carrier (from NCO)
    input  wire signed [11:0]  sin_data,  // sin carrier (from NCO)
    output reg  signed [11:0]  out_data   // modulated output
);

    // Registered inputs for timing
    reg signed [7:0]  i_reg, q_reg;
    reg signed [11:0] cos_reg, sin_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_reg   <= 0;
            q_reg   <= 0;
            cos_reg <= 0;
            sin_reg <= 0;
        end else begin
            i_reg   <= i_data;
            q_reg   <= q_data;
            cos_reg <= cos_data;
            sin_reg <= sin_data;
        end
    end

    // Multiply (inferred — Yosys maps to DSP blocks)
    wire signed [19:0] i_cos = i_reg * cos_reg;  // 8×12 = 20 bits
    wire signed [19:0] q_sin = q_reg * sin_reg;  // 8×12 = 20 bits

    // Subtract and scale: (I*cos - Q*sin) >> 7
    // diff[18:7] instead of diff[19:8] — doubles output amplitude.
    // Safe: max|diff| = 127*2047 = 259969; 259969>>7 = 2031 < 2047 (12-bit signed limit).
    // Assumes Q=0 (AM) or constant-envelope IQ (FM); both keep max|I*cos-Q*sin|=127*2047.
    wire signed [20:0] diff = i_cos - q_sin;  // 21 bits (carry)

    // Register output, take bits [18:7] for 12-bit result
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_data <= 0;
        else
            out_data <= diff[18:7];
    end

endmodule

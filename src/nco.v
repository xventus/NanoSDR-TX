/**
 * @file nco.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief Numerically Controlled Oscillator (NCO)
 * @version 1.0
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */

module nco #(
    parameter WIDTH = 32,
    parameter LUT_DEPTH_LOG2 = 10 // 1024 samples
)(
    input clk,
    input rst_n, // Active low reset
    input [WIDTH-1:0] tuning_word,
    output signed [11:0] sin_out,
    output signed [11:0] cos_out
);

    reg [WIDTH-1:0] phase_accumulator;
    
    // Phase Accumulator
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_accumulator <= 0;
        end else begin
            phase_accumulator <= phase_accumulator + tuning_word;
        end
    end

    // LUT Address I+Q (Top bits of accumulator)
    wire [LUT_DEPTH_LOG2-1:0] lut_addr_sin = phase_accumulator[WIDTH-1 : WIDTH-LUT_DEPTH_LOG2];
    wire [LUT_DEPTH_LOG2-1:0] lut_addr_cos = lut_addr_sin + 256;  

    // Sine LUT instantiation
    rom_sin sine_lut (
        .clk(clk),
        .addr(lut_addr_sin),
        .data(sin_out)
    );

    // Cosine LUT instantiation
    rom_sin cosine_lut (
        .clk(clk),
        .addr(lut_addr_cos),
        .data(cos_out)
    );

endmodule

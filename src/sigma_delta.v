/**
 * @file sigma_delta.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief Sigma-Delta DAC Modulator
 * @version 0.1
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 * TODO: Second-order modulator / MASH
 */

module sigma_delta #(
    parameter WIDTH = 12
)(
    input clk,
    input rst_n,
    input signed [WIDTH-1:0] din,  // Signed input from NCO
    output reg pdm_out              // 1-bit PDM output
);

    // Convert signed to unsigned (offset binary)
    // Add 2^(WIDTH-1) to shift range from [-2048..2047] to [0..4095]
    wire [WIDTH-1:0] din_unsigned = din + (1 << (WIDTH-1));

    // Sigma-Delta accumulator (1 bit wider to capture overflow)
    reg [WIDTH:0] accumulator;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= 0;
            pdm_out <= 0;
        end else begin
            accumulator <= accumulator[WIDTH-1:0] + din_unsigned;
            pdm_out <= accumulator[WIDTH]; // Carry = output bit
        end
    end

endmodule

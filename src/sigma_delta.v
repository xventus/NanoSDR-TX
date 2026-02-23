/**
 * @file sigma_delta.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief Sigma-Delta DAC Modulator
 * @version 0.2
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 * 2nd-order Error Feedback topology
 */

module sigma_delta #(
    parameter WIDTH = 12
)(
    input clk,
    input rst_n,
    input signed [WIDTH-1:0] din,  // Signed input from NCO
    output reg pdm_out              // 1-bit PDM output
);

    // MASH-like standard 2nd-order Sigma-Delta (Error Feedback topology)
    localparam signed [WIDTH+3:0] MAX_VAL = (1 << WIDTH) - 1;
    localparam signed [WIDTH+3:0] MID_VAL = 1 << (WIDTH - 1);

    // Convert signed to unsigned (offset binary)
    // Add 2^(WIDTH-1) to shift range from [-2048..2047] to [0..4095]
    wire [WIDTH-1:0] din_unsigned = din + MID_VAL[WIDTH-1:0];
    
    // Extend to prevent overflow in the loop (+4 bits to be completely safe)
    wire signed [WIDTH+3:0] din_ext = $signed({4'b0, din_unsigned});

    // Error states
    reg signed [WIDTH+3:0] err1;
    reg signed [WIDTH+3:0] err2;

    // V(z) = X(z) + 2*error(z-1) - error(z-2)
    wire signed [WIDTH+3:0] v_node = din_ext + (err1 <<< 1) - err2;
    wire pdm_next = (v_node >= MID_VAL);
    
    // err = V(z) - Y(z)
    wire signed [WIDTH+3:0] err_next = pdm_next ? (v_node - MAX_VAL) : v_node;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err1 <= 0;
            err2 <= 0;
            pdm_out <= 0;
        end else begin
            err1 <= err_next;
            err2 <= err1;
            pdm_out <= pdm_next;
        end
    end

endmodule

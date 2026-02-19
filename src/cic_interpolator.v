/**
 * @file cic_interpolator.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief CIC Interpolation Filter
 * @version 0.1
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */

module cic_interpolator #(
    parameter WIDTH_IN   = 8,
    parameter WIDTH_OUT  = 8,
    parameter ORDER      = 3,
    parameter RATE       = 64
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire signed [WIDTH_IN-1:0]   in_data,
    input  wire                         in_strobe,
    output wire signed [WIDTH_OUT-1:0]  out_data,
    output reg                          out_valid
);

    localparam WIDTH_INT  = WIDTH_IN + ORDER * $clog2(RATE);
    localparam GAIN_SHIFT = (ORDER - 1) * $clog2(RATE);

    // =====================================================================
    // Stage 1: COMB section (input rate) — combinational chain
    // =====================================================================
    wire signed [WIDTH_INT-1:0] in_extended = {{(WIDTH_INT-WIDTH_IN){in_data[WIDTH_IN-1]}}, in_data};

    reg  signed [WIDTH_INT-1:0] comb_delay [0:ORDER-1];
    wire signed [WIDTH_INT-1:0] comb_wire  [0:ORDER];

    assign comb_wire[0] = in_extended;

    genvar g;
    generate
        for (g = 0; g < ORDER; g = g + 1) begin : comb_stage
            assign comb_wire[g+1] = comb_wire[g] - comb_delay[g];
        end
    endgenerate

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ORDER; i = i + 1)
                comb_delay[i] <= 0;
        end else if (in_strobe) begin
            for (i = 0; i < ORDER; i = i + 1)
                comb_delay[i] <= comb_wire[i];
        end
    end

    // Register final comb output for clean timing into integrators
    reg signed [WIDTH_INT-1:0] comb_result;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            comb_result <= 0;
        else if (in_strobe)
            comb_result <= comb_wire[ORDER];
    end

    // =====================================================================
    // Stage 2: Zero-Stuffing (^R)
    // =====================================================================
    reg [$clog2(RATE)-1:0] rate_cnt = 0;
    reg                    comb_valid = 0;
    reg                    active = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_cnt   <= 0;
            comb_valid <= 0;
            active     <= 0;
        end else begin
            comb_valid <= in_strobe;

            if (comb_valid) begin
                rate_cnt <= 1;
                active   <= 1;
            end else if (active) begin
                if (rate_cnt == RATE - 1) begin
                    rate_cnt <= 0;
                    active   <= 0;
                end else
                    rate_cnt <= rate_cnt + 1;
            end
        end
    end

    wire signed [WIDTH_INT-1:0] zs_data = comb_valid ? comb_result : {WIDTH_INT{1'b0}};

    // =====================================================================
    // Stage 3: INTEGRATOR — runs EVERY clock, no gating
    // =====================================================================
    reg signed [WIDTH_INT-1:0] integ [0:ORDER-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ORDER; i = i + 1)
                integ[i] <= 0;
        end else begin
            integ[0] <= integ[0] + zs_data;
            for (i = 1; i < ORDER; i = i + 1)
                integ[i] <= integ[i] + integ[i-1];
        end
    end

    // =====================================================================
    // Output truncation
    // =====================================================================
    assign out_data = integ[ORDER-1][GAIN_SHIFT + WIDTH_OUT - 1 -: WIDTH_OUT];

    // out_valid: continuous once started (integrators always produce output)
    reg started;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 0;
            started   <= 0;
        end else begin
            if (in_strobe)
                started <= 1;
            out_valid <= started;
        end
    end

endmodule

/**
 * @file top.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief FPGA Top-Level for NanoSDR-TX (UART + FIFO + CIC + I/Q Modulator)
 * @version 0.2
 * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */

module top #(
    parameter CLK_FREQ  = 27000000,
    parameter BAUD_RATE = 921600
)(
    input  wire clk,
    input  wire uart_rx,
    output wire uart_tx,
    output wire uart_rts,
    output wire led,
    output wire sq_out,
    output wire pdm_out
);

    // ---- CIC Parameters ----
    localparam CIC_RATE  = 844;   // 27M/844 = 31990 Hz
    localparam CIC_ORDER = 2;     // reduced to fit FPGA

    // ---- Reset Generator ----
    reg [7:0] rst_cnt = 0;
    wire resetn = &rst_cnt;
    always @(posedge clk)
        if (!resetn)
            rst_cnt <= rst_cnt + 1;

    // =====================================================================
    // UART RX
    // =====================================================================
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_break;

    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) rx_inst (
        .clk(clk),
        .resetn(resetn),
        .uart_rxd(uart_rx),
        .uart_rx_en(1'b1),
        .uart_rx_break(rx_break),
        .uart_rx_valid(rx_valid),
        .uart_rx_data(rx_data)
    );

    // =====================================================================
    // UART RX Parser: Data (I/Q) vs Command (Tuning Word)
    // =====================================================================
    localparam S_IDLE_OR_I = 0;
    localparam S_WAIT_Q    = 1;
    localparam S_CMD_B1    = 2;
    localparam S_CMD_B2    = 3;
    localparam S_CMD_B3    = 4;
    localparam S_CMD_B4    = 5;

    reg [2:0] state = S_IDLE_OR_I;
    reg [7:0] i_byte = 0;
    reg [31:0] tuning_reg = 32'd1590720; // Default 10 kHz
    reg [23:0] cmd_accum = 0; // Temp storage for top 3 bytes of TW

    reg fifo_wr_en = 0;
    reg [15:0] fifo_wr_data = 0;

    always @(posedge clk) begin
        fifo_wr_en <= 0;

        if (!resetn) begin
            state      <= S_IDLE_OR_I;
            i_byte     <= 0;
            tuning_reg <= 32'd1590720; // Reset to 10 kHz
        end else if (rx_valid) begin
            case (state)
                S_IDLE_OR_I: begin
                    if (rx_data == 8'h80) begin
                        state <= S_CMD_B1; // Start of tuning word command
                    end else begin
                        i_byte <= rx_data;
                        state  <= S_WAIT_Q;
                    end
                end

                S_WAIT_Q: begin
                    // Received Q byte, push pair to FIFO
                    fifo_wr_data <= {i_byte, rx_data};
                    fifo_wr_en   <= 1;
                    state        <= S_IDLE_OR_I;
                end

                // Tuning Word Command Parsing (0x80 already consumed)
                S_CMD_B1: begin
                    cmd_accum[23:16] <= rx_data;
                    state <= S_CMD_B2;
                end
                S_CMD_B2: begin
                    cmd_accum[15:8] <= rx_data;
                    state <= S_CMD_B3;
                end
                S_CMD_B3: begin
                    cmd_accum[7:0] <= rx_data;
                    state <= S_CMD_B4;
                end
                S_CMD_B4: begin
                    // Final byte received, update tuning word
                    tuning_reg <= {cmd_accum, rx_data};
                    state <= S_IDLE_OR_I;
                end
                default: state <= S_IDLE_OR_I;
            endcase
        end
    end

    // =====================================================================
    // Synchronous FIFO (BSRAM-backed, FWFT)
    // =====================================================================
    wire        fifo_full;
    wire        fifo_empty;
    wire [15:0] fifo_rd_data;
    reg         fifo_rd_en = 0;

    smart_fifo #(
        .DATA_WIDTH(16),
        .ADDR_WIDTH(12)  // 4096 entries → 4 BSRAM blocks (65536 bit), 128 ms jitter tolerance
    ) fifo_inst (
        .clk(clk),
        .rst_n(resetn),
        .wr_en(fifo_wr_en & ~fifo_full),
        .wr_data(fifo_wr_data),
        .full(fifo_full),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data),
        .empty(fifo_empty),
        .almost_full(uart_rts)
    );

    // =====================================================================
    // FIFO Read → CIC Input Rate Control (ZOH)
    // =====================================================================
    reg [$clog2(CIC_RATE)-1:0] rate_div = 0;
    wire rate_tick = (rate_div == 0);

    always @(posedge clk or negedge resetn) begin
        if (!resetn)
            rate_div <= 0;
        else if (rate_div == CIC_RATE - 1)
            rate_div <= 0;
        else
            rate_div <= rate_div + 1;
    end

    reg        cic_strobe = 0;
    reg signed [7:0] cic_i_in = 0;
    reg signed [7:0] cic_q_in = 0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            fifo_rd_en <= 0;
            cic_strobe <= 0;
            cic_i_in   <= 0;
            cic_q_in   <= 0;
        end else begin
            cic_strobe <= 0;
            fifo_rd_en <= 0;

            if (rate_tick) begin
                cic_strobe <= 1;  // Always strobe (ZOH)

                if (!fifo_empty) begin
                    fifo_rd_en <= 1;
                    cic_i_in   <= $signed(fifo_rd_data[15:8]);
                    cic_q_in   <= $signed(fifo_rd_data[7:0]);
                end
                // Else: hold previous value (ZOH)
            end
        end
    end

    // =====================================================================
    // Dual CIC Interpolators (I + Q)
    // =====================================================================
    wire signed [7:0] cic_i_out;
    wire              cic_i_valid;
    wire signed [7:0] cic_q_out;
    wire              cic_q_valid;

    cic_interpolator #(
        .WIDTH_IN(8),
        .WIDTH_OUT(8),
        .ORDER(CIC_ORDER),
        .RATE(CIC_RATE)
    ) cic_i (
        .clk(clk),
        .rst_n(resetn),
        .in_data(cic_i_in),
        .in_strobe(cic_strobe),
        .out_data(cic_i_out),
        .out_valid(cic_i_valid)
    );

    cic_interpolator #(
        .WIDTH_IN(8),
        .WIDTH_OUT(8),
        .ORDER(CIC_ORDER),
        .RATE(CIC_RATE)
    ) cic_q (
        .clk(clk),
        .rst_n(resetn),
        .in_data(cic_q_in),
        .in_strobe(cic_strobe),
        .out_data(cic_q_out),
        .out_valid(cic_q_valid)
    );

    // =====================================================================
    // UART TX Loopback
    // =====================================================================
    wire tx_busy;
    reg  [7:0] tx_data = 0;
    reg  tx_en = 0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            tx_en   <= 0;
            tx_data <= 0;
        end else begin
            tx_en <= 0;
            if (cic_i_valid && !tx_busy && !tx_en) begin
                tx_data <= cic_i_out;
                tx_en   <= 1;
            end
        end
    end

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) tx_inst (
        .clk(clk),
        .resetn(resetn),
        .uart_txd(uart_tx),
        .uart_tx_busy(tx_busy),
        .uart_tx_en(tx_en),
        .uart_tx_data(tx_data)
    );

    // =====================================================================
    // I/Q Modulator Pipeline
    // =====================================================================
    
    wire signed [11:0] cos_out;
    wire signed [11:0] sin_out;

    nco #(
        .WIDTH(32),
        .LUT_DEPTH_LOG2(10)
    ) nco_inst (
        .clk(clk),
        .rst_n(resetn),
        .tuning_word(tuning_reg),
        .sin_out(sin_out),
        .cos_out(cos_out)
    );

    wire signed [11:0] mixer_out;

    iq_mixer mixer_inst (
        .clk(clk),
        .rst_n(resetn),
        .i_data(cic_i_out),
        .q_data(cic_q_out),
        .cos_data(cos_out),
        .sin_data(sin_out),
        .out_data(mixer_out)
    );

    sigma_delta #(
        .WIDTH(12)
    ) sd_dac (
        .clk(clk),
        .rst_n(resetn),
        .din(mixer_out),
        .pdm_out(pdm_out)
    );

    // sq_out: NCO square wave (MSB of sine)
    assign sq_out = sin_out[11];

    // =====================================================================
    // LED: Heartbeat + RX activity
    // =====================================================================
    reg [24:0] led_cnt = 0;
    reg [23:0] rx_led_counter = 0;

    always @(posedge clk) begin
        if (resetn)
            led_cnt <= led_cnt + 1;

        if (rx_valid)
            rx_led_counter <= 24'd2700000;
        else if (rx_led_counter != 0)
            rx_led_counter <= rx_led_counter - 1;
    end

    wire rx_activity = (rx_led_counter != 0);
    assign led = ~(led_cnt[24] | rx_activity);

endmodule

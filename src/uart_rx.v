/**
 * @file uart_rx.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief UART Receiver Module
 * @version 2.1
 * 
 * @copyright Copyright (c) 2025 Petr Vanek
 * 
 * added: half bit test
 */

module uart_rx #(
    parameter CLK_FREQ     = 27000000,
    parameter BAUD_RATE    = 115200,
    parameter PAYLOAD_BITS = 8
) (
    input  wire                   clk,
    input  wire                   resetn,
    input  wire                   uart_rxd,
    input  wire                   uart_rx_en,
    output reg                    uart_rx_break,
    output reg                    uart_rx_valid,
    output reg [PAYLOAD_BITS-1:0] uart_rx_data
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;

    // FSM States
    localparam S_IDLE  = 0;
    localparam S_START = 1;
    localparam S_DATA  = 2;
    localparam S_STOP  = 3;
    localparam S_CLEANUP = 4;

    reg [2:0] state = S_IDLE;
    reg [15:0] clk_cnt = 0;
    reg [2:0] bit_idx = 0;
    reg [PAYLOAD_BITS-1:0] shift_reg = 0;

    // Synchronizer
    reg rxd_sync_0, rxd_sync_1;
    always @(posedge clk) begin
        rxd_sync_0 <= uart_rxd;
        rxd_sync_1 <= rxd_sync_0;
    end

    // BREAK Detection (independent logic)
    reg [15:0] break_counter = 0;
    localparam BREAK_CYCLES = CLKS_PER_BIT * 12;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            break_counter <= 0;
            uart_rx_break <= 0;
        end else begin
            if (rxd_sync_1 == 0) begin
                if (break_counter < 16'hFFFF)
                    break_counter <= break_counter + 1;
            end else begin
                break_counter <= 0;
            end
            uart_rx_break <= (break_counter > BREAK_CYCLES);
        end
    end

    // Main UART FSM
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= S_IDLE;
            clk_cnt <= 0;
            bit_idx <= 0;
            uart_rx_valid <= 0;
            uart_rx_data <= 0;
        end else begin
            uart_rx_valid <= 0; // Default pulse

            case (state)
                S_IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (uart_rx_en && rxd_sync_1 == 0) begin
                        // Start bit edge detected
                        state <= S_START;
                    end
                end

                S_START: begin
                    // Wait for middle of Start Bit
                    if (clk_cnt == HALF_BIT - 1) begin
                        if (rxd_sync_1 == 0) begin
                            // Confirm Start Bit is still low
                            clk_cnt <= 0;
                            state <= S_DATA;
                        end else begin
                            // False start (noise)
                            state <= S_IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                S_DATA: begin
                    // Wait one full bit period (to middle of next bit)
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        shift_reg[bit_idx] <= rxd_sync_1;
                        
                        if (bit_idx == PAYLOAD_BITS - 1) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                S_STOP: begin
                    // Wait one full bit period (to middle of Stop Bit)
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        // Stop bit should be 1
                        if (rxd_sync_1 == 1) begin
                            uart_rx_data <= shift_reg;
                            uart_rx_valid <= 1;
                        end
                        // Whether valid or framing error, we are done with this byte.
                        // But we are only halfway through the Stop Bit.
                        // We must ensure we don't re-trigger on the current 0->1 transition if any.
                        // Actually, we are in the middle of Stop Bit (logic 1).
                        // If next start bit comes immediately, line will go low Half-Bit later.
                        // But S_CLEANUP handle checking for line idle or next start.
                        state <= S_CLEANUP;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
                
                S_CLEANUP: begin
                    // TODO: We are at Middle of Stop Bit 
                    // We technically should wait another HALF_BIT to reach the end of the frame.
                    // However, if we jump to IDLE, and line is 1, IDLE waits for 0.
                    // If line goes 0 (Next Start Bit) *after* Half-Bit time, IDLE will catch it.
                    // So we can jump to IDLE immediately, or wait a bit to be safe.
                    // Let's just jump to IDLE. The IDLE state checks for 1->0 transition implicitly
                    // by checking (rxd == 0).
                    // WAIT: If we are in middle of Stop (1), and we go IDLE.
                    // If the next Byte starts immediately, the line goes to 0 exactly HALF_BIT later.
                    // IDLE will see 0 and trigger S_START.
                    // S_START counts HALF_BIT (middle of start).
                    // So we are synced on the new byte correctly.
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

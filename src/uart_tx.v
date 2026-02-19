/**
 * @file uart_tx.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief UART Transmitter Module
 * @version 2.1
 * 
 * @copyright Copyright (c) 2025 Petr Vanek
 * 
 */

module uart_tx #(
    parameter CLK_FREQ     = 27000000,
    parameter BAUD_RATE    = 115200,
    parameter PAYLOAD_BITS = 8
) (
    input  wire clk,
    input  wire resetn,
    output reg  uart_txd,
    output reg  uart_tx_busy,
    input  wire uart_tx_en,
    input  wire [PAYLOAD_BITS-1:0] uart_tx_data
);

    localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    reg [PAYLOAD_BITS-1:0] data_reg = 0;
    reg [15:0] clk_counter = 0;
    reg [3:0] bit_index = 0;
    reg sending = 0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            uart_txd     <= 1;
            uart_tx_busy <= 0;
            clk_counter  <= 0;
            bit_index    <= 0;
            sending      <= 0;
        end else begin
            if (!sending && uart_tx_en && !uart_tx_busy) begin
                sending      <= 1;
                uart_tx_busy <= 1;
                data_reg     <= uart_tx_data;
                clk_counter  <= 0;
                bit_index    <= 0;
            end else if (sending) begin
                if (clk_counter < CLKS_PER_BIT - 1) begin
                    clk_counter <= clk_counter + 1;
                end else begin
                    clk_counter <= 0;
                    bit_index <= bit_index + 1;

                    case (bit_index)
                        0:  uart_txd <= 0;              // Start bit
                        1:  uart_txd <= data_reg[0];
                        2:  uart_txd <= data_reg[1];
                        3:  uart_txd <= data_reg[2];
                        4:  uart_txd <= data_reg[3];
                        5:  uart_txd <= data_reg[4];
                        6:  uart_txd <= data_reg[5];
                        7:  uart_txd <= data_reg[6];
                        8:  uart_txd <= data_reg[7];
                        9:  uart_txd <= 1;              // Stop bit
                        default: begin
                            uart_txd     <= 1;
                            uart_tx_busy <= 0;
                            sending      <= 0;
                            bit_index    <= 0;
                        end
                    endcase
                end
            end
        end
    end
endmodule

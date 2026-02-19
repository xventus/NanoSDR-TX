/**
 * @file smart_fifo.v
 * @author Petr Vanek (petr@fotoventus.cz)
 * @brief Synchronous FIFO with BSRAM inference + First-Word-Fall-Through output
 * @version 0.1
  * 
 * @copyright Copyright (c) 2026 Petr Vanek
 * 
 */

module smart_fifo #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 8   // 256 entries → 1 BSRAM block
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Write port
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,

    // Read port (FWFT)
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    // =========================================================================
    // Block RAM — coded for Gowin BSRAM inference ()
    // =========================================================================
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers and count — ALL in single always block (no multi-drive)
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;

    wire ram_empty = (count == 0);
    wire ram_full  = (count == DEPTH);

    wire do_write = wr_en && !ram_full;
    wire do_read; 

    // --- Synchronous write ---
    always @(posedge clk) begin
        if (do_write)
            mem[wr_ptr] <= wr_data;
    end

// --- Synchronous read (UNCONDITIONAL — required for BSRAM inference !!) ---
    reg [DATA_WIDTH-1:0] ram_out;
    always @(posedge clk) begin
        ram_out <= mem[rd_ptr];  
    end

    // --- Pointers + count (single always block) ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
        end else begin
            if (do_write)
                wr_ptr <= wr_ptr + 1;
            if (do_read)
                rd_ptr <= rd_ptr + 1;

            case ({do_write, do_read})
                2'b10: count <= count + 1;
                2'b01: count <= count - 1;
                default: ; // 00 or 11: no change
            endcase
        end
    end

    assign full = ram_full;

    // =========================================================================
    // FWFT Output Register 
    // =========================================================================
    reg [DATA_WIDTH-1:0] out_reg;
    reg                  out_valid;

    // Fetch from RAM when: data exists AND (output empty OR being consumed)
    assign do_read = !ram_empty && (!out_valid || rd_en);

    // Track RAM read latency (1 cycle)
    reg ram_read_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ram_read_pending <= 0;
        else
            ram_read_pending <= do_read;
    end

    // Output register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 0;
            out_reg   <= 0;
        end else begin
            if (ram_read_pending) begin
                out_reg   <= ram_out;
                out_valid <= 1;
            end else if (rd_en) begin
                out_valid <= 0;
            end
        end
    end

    assign rd_data = out_reg;
    assign empty   = !out_valid;

endmodule

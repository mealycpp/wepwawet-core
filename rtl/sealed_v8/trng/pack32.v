`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/14/2026 09:46:37 PM
// Design Name: 
// Module Name: pack32
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module pack32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        sample_bit,
    input  wire        sample_valid,
    output reg [31:0]  rand_word,
    output reg         word_valid
);

    reg [31:0] shift_reg;
    reg [5:0]  bit_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg  <= 32'd0;
            bit_count  <= 6'd0;
            rand_word  <= 32'd0;
            word_valid <= 1'b0;
        end else if (!enable) begin
            shift_reg  <= 32'd0;
            bit_count  <= 6'd0;
            rand_word  <= 32'd0;
            word_valid <= 1'b0;
        end else begin
            word_valid <= 1'b0;

            if (sample_valid) begin
                shift_reg <= {sample_bit, shift_reg[31:1]};

                if (bit_count == 6'd31) begin
                    rand_word  <= {sample_bit, shift_reg[31:1]};
                    bit_count  <= 6'd0;
                    word_valid <= 1'b1;
                end else begin
                    bit_count <= bit_count + 6'd1;
                end
            end
        end
    end

endmodule
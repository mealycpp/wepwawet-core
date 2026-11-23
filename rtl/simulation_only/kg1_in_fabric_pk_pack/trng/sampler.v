`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/14/2026 09:44:59 PM
// Design Name: 
// Module Name: sampler
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

module sampler (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire [7:0] sample_div,
    input  wire       ro_mix,
    output reg        sample_bit,
    output reg        sample_valid
);

    reg [7:0] div_cnt;
    // Integration fix (sign_v5): ro_mix is a free-running ring-oscillator XOR with no clock
    // relationship; resynchronise it with a 2-FF ASYNC_REG chain before it is sampled.
    (* ASYNC_REG = "TRUE" *) reg ro_sync0, ro_sync1;
    always @(posedge clk) begin ro_sync0 <= ro_mix; ro_sync1 <= ro_sync0; end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt      <= 8'd0;
            sample_bit   <= 1'b0;
            sample_valid <= 1'b0;
        end else if (!enable) begin
            div_cnt      <= 8'd0;
            sample_bit   <= 1'b0;
            sample_valid <= 1'b0;
        end else begin
            if (div_cnt >= sample_div) begin
                div_cnt      <= 8'd0;
                sample_bit   <= ro_sync1;
                sample_valid <= 1'b1;
            end else begin
                div_cnt      <= div_cnt + 8'd1;
                sample_valid <= 1'b0;
            end
        end
    end

endmodule
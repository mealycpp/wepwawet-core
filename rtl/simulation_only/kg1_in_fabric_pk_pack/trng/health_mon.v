`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/14/2026 09:47:13 PM
// Design Name: 
// Module Name: health_mon
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


module health_mon (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire       sample_bit,
    input  wire       sample_valid,
    output reg        health_fail
);

    reg        prev_bit;
    reg [5:0]  run_count;
    reg [5:0]  window_count;
    reg [5:0]  ones_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_bit     <= 1'b0;
            run_count    <= 6'd0;
            window_count <= 6'd0;
            ones_count   <= 6'd0;
            health_fail  <= 1'b0;
        end else if (!enable) begin
            prev_bit     <= 1'b0;
            run_count    <= 6'd0;
            window_count <= 6'd0;
            ones_count   <= 6'd0;
            health_fail  <= 1'b0;
        end else if (sample_valid) begin
            // repetition count
            if (window_count == 6'd0) begin
                prev_bit  <= sample_bit;
                run_count <= 6'd1;
            end else begin
                if (sample_bit == prev_bit) begin
                    run_count <= run_count + 6'd1;
                end else begin
                    prev_bit  <= sample_bit;
                    run_count <= 6'd1;
                end
            end

            // ones count
            if (sample_bit)
                ones_count <= ones_count + 6'd1;

            // bias / repetition check every 32 samples
            if (window_count == 6'd31) begin
                // loosened thresholds for bring-up
                if ((ones_count < 6'd4) || (ones_count > 6'd28))
                    health_fail <= 1'b1;
                else if (run_count > 6'd24)
                    health_fail <= 1'b1;
                else
                    health_fail <= 1'b0;

                window_count <= 6'd0;
                ones_count   <= 6'd0;
            end else begin
                window_count <= window_count + 6'd1;
            end
        end
    end

endmodule
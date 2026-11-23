`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/14/2026 09:44:25 PM
// Design Name: 
// Module Name: ro_bank
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

module ro_bank #(
    parameter integer N_RO = 9
)(
    input  wire [1:0] mode,
    output wire       ro_mix
);

    (* DONT_TOUCH = "yes" *) wire [N_RO-1:0] ro_out;

    genvar i;
    generate
        for (i = 0; i < N_RO; i = i + 1) begin : GEN_RO
            (* DONT_TOUCH = "yes" *) wire [2:0] ro_n;

            assign ro_n[0] = ~ro_n[2];
            assign ro_n[1] = ~ro_n[0];
            assign ro_n[2] = ~ro_n[1];

            assign ro_out[i] = ro_n[2];
        end
    endgenerate

    wire mix0 = ro_out[0] ^ ro_out[1] ^ ro_out[2];
    wire mix1 = mix0      ^ ro_out[3] ^ ro_out[4] ^ ro_out[5];
    wire mix2 = mix1      ^ ro_out[6] ^ ro_out[7] ^ ro_out[8];

    assign ro_mix =
        (mode == 2'b00) ? mix0 :
        (mode == 2'b01) ? mix1 :
                          mix2;

endmodule
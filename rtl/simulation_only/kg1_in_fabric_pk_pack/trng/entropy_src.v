`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/14/2026 09:47:55 PM
// Design Name: 
// Module Name: entropy_src
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


module entropy_src (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [1:0]  mode,
    input  wire [7:0]  sample_div,
    output wire [31:0] rand_word,
    output wire        valid,
    output wire        health_fail
);

    wire ro_mix;
    wire sample_bit;
    wire sample_valid;

    ro_bank u_ro_bank (
        .mode   (mode),
        .ro_mix (ro_mix)
    );

    sampler u_sampler (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (enable),
        .sample_div   (sample_div),
        .ro_mix       (ro_mix),
        .sample_bit   (sample_bit),
        .sample_valid (sample_valid)
    );

    pack32 u_pack32 (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (enable),
        .sample_bit   (sample_bit),
        .sample_valid (sample_valid),
        .rand_word    (rand_word),
        .word_valid   (valid)
    );

    health_mon u_health_mon (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (enable),
        .sample_bit   (sample_bit),
        .sample_valid (sample_valid),
        .health_fail  (health_fail)
    );

endmodule
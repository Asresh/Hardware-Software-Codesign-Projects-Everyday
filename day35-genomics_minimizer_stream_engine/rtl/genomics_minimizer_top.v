// Author: Asresh
module genomics_minimizer_top #(parameter BASES=16, parameter WINDOW=8) (
    input wire clk, input wire rst_n,
    input wire avs_read, input wire avs_write, input wire [3:0] avs_address,
    input wire [31:0] avs_writedata, output reg [31:0] avs_readdata,
    input wire sink_valid, output wire sink_ready, input wire [2*BASES-1:0] sink_data,
    input wire sink_startofpacket, input wire sink_endofpacket,
    output wire source_valid, input wire source_ready, output wire [63:0] source_data,
    output wire irq
);
    reg enable; reg [31:0] seed; reg [31:0] position; reg [31:0] accepted; reg [31:0] emitted;
    reg out_valid; reg [63:0] out_data; reg done_pulse;
    wire [2*BASES-1:0] rc;
    wire [31:0] forward_key = {{(32-2*BASES){1'b0}},sink_data};
    wire [31:0] reverse_key = {{(32-2*BASES){1'b0}},rc};
    wire [31:0] canonical = (forward_key <= reverse_key) ? forward_key : reverse_key;
    wire [31:0] hash;
    wire win_valid; wire [31:0] win_min, win_pos;
    wire take = sink_valid && sink_ready;
    wire clear_window = take && sink_startofpacket;
    assign sink_ready = enable && (!out_valid || source_ready);
    assign source_valid = out_valid;
    assign source_data = out_data;
    kmer_revcomp #(.BASES(BASES)) u_rc(.kmer(sink_data),.revcomp(rc));
    kmer_hash_mix u_hash(.key(canonical),.seed(seed),.hash(hash));
    min_window #(.WINDOW(WINDOW)) u_window(.clk(clk),.rst_n(rst_n),.clear(clear_window),.push(take),.value(hash),.position(position),.valid(win_valid),.min_value(win_min),.min_position(win_pos));
    minimizer_irq_latch u_irq(.clk(clk),.rst_n(rst_n),.set(done_pulse),.clear(avs_write && avs_address==4'h3 && avs_writedata[0]),.irq(irq));
    always @* begin
        avs_readdata = 0;
        case (avs_address)
          4'h0: avs_readdata = {31'b0,enable};
          4'h1: avs_readdata = seed;
          4'h2: avs_readdata = {29'b0,irq,out_valid,enable};
          4'h4: avs_readdata = accepted;
          4'h5: avs_readdata = emitted;
          default: avs_readdata = 0;
        endcase
    end
    always @(posedge clk) begin
        if (!rst_n) begin enable<=0; seed<=0; position<=0; accepted<=0; emitted<=0; out_valid<=0; out_data<=0; done_pulse<=0; end
        else begin
            done_pulse <= 0;
            if (avs_write && avs_address==4'h0) begin enable<=avs_writedata[0]; if (avs_writedata[1]) begin position<=0; accepted<=0; emitted<=0; out_valid<=0; end end
            if (avs_write && avs_address==4'h1) seed<=avs_writedata;
            if (out_valid && source_ready) begin out_valid<=0; emitted<=emitted+1; end
            if (take) begin
                accepted<=accepted+1;
                position <= sink_startofpacket ? 1 : position+1;
                if (win_valid && !sink_startofpacket) begin out_valid<=1; out_data<={win_pos,win_min}; end
                if (sink_endofpacket) done_pulse<=1;
            end
        end
    end
endmodule

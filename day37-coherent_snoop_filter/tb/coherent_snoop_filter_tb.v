// Author: Asresh
`timescale 1ns/1ps
module coherent_snoop_filter_tb;
    localparam SETS = 8;
    localparam NODES = 4;
    localparam ENTRIES = SETS * 2;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg req_valid = 1'b0;
    wire req_ready;
    reg [2:0] req_opcode = 3'd0;
    reg [1:0] req_source = 2'd0;
    reg [15:0] req_addr = 16'd0;
    wire rsp_valid;
    reg rsp_ready = 1'b0;
    wire rsp_hit;
    wire rsp_error;
    wire rsp_evicted;
    wire [3:0] rsp_probe_mask;
    wire [3:0] rsp_new_sharers;
    reg psel = 1'b0;
    reg penable = 1'b0;
    reg pwrite = 1'b0;
    reg [7:0] paddr = 8'd0;
    reg [31:0] pwdata = 32'd0;
    reg [3:0] pstrb = 4'hf;
    wire [31:0] prdata;
    wire pready;
    wire pslverr;
    wire irq;

    integer cycles = 0;
    integer checks = 0;
    integer mismatches = 0;
    integer expected_hits = 0;
    integer expected_errors = 0;
    integer expected_probes = 0;
    integer vector_index = 0;
    integer i;
    reg [31:0] lfsr = 32'h1aceb00c;
    reg m_valid [0:ENTRIES-1];
    reg [6:0] m_tag [0:ENTRIES-1];
    reg [3:0] m_sharers [0:ENTRIES-1];
    reg m_dirty [0:ENTRIES-1];
    reg m_rr [0:SETS-1];
    reg [31:0] read_value;

    always @(posedge clk)
        if (rst_n)
            cycles <= cycles + 1;

    coherent_snoop_filter_top #(
        .ADDR_WIDTH(16), .LINE_LSB(6), .SETS(SETS), .NODES(NODES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_opcode(req_opcode),
        .req_source(req_source), .req_addr(req_addr),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_hit(rsp_hit),
        .rsp_error(rsp_error), .rsp_evicted(rsp_evicted),
        .rsp_probe_mask(rsp_probe_mask), .rsp_new_sharers(rsp_new_sharers),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready),
        .pslverr(pslverr), .irq(irq)
    );

    function integer popcount4;
        input [3:0] value;
        begin
            popcount4 = value[0] + value[1] + value[2] + value[3];
        end
    endfunction

    task apb_write;
        input [7:0] address;
        input [31:0] data;
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b1; pwrite = 1'b1;
            paddr = address; pwdata = data; pstrb = 4'hf;
            @(posedge clk);
            if (!pready || pslverr) mismatches = mismatches + 1;
            @(negedge clk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    task apb_read;
        input [7:0] address;
        output [31:0] data;
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b1; pwrite = 1'b0; paddr = address;
            @(posedge clk);
            data = prdata;
            if (!pready || pslverr) mismatches = mismatches + 1;
            @(negedge clk);
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    task model_apply;
        input [2:0] opcode;
        input [1:0] source;
        input [15:0] address;
        output reg exp_hit;
        output reg exp_error;
        output reg exp_evicted;
        output reg [3:0] exp_probe;
        output reg [3:0] exp_sharers;
        integer set_index;
        integer base_index;
        integer selected_index;
        reg found;
        reg [3:0] source_mask;
        begin
            set_index = (address >> 6) & (SETS - 1);
            base_index = set_index * 2;
            source_mask = 4'b0001 << source;
            found = 1'b0;
            selected_index = base_index;
            if (m_valid[base_index] && m_tag[base_index] == (address >> 9)) begin
                found = 1'b1; selected_index = base_index;
            end else if (m_valid[base_index + 1] && m_tag[base_index + 1] == (address >> 9)) begin
                found = 1'b1; selected_index = base_index + 1;
            end else if (!m_valid[base_index]) begin
                selected_index = base_index;
            end else if (!m_valid[base_index + 1]) begin
                selected_index = base_index + 1;
            end else begin
                selected_index = base_index + m_rr[set_index];
            end
            exp_hit = found;
            exp_error = 1'b0;
            exp_evicted = 1'b0;
            exp_probe = 4'd0;
            exp_sharers = found ? m_sharers[selected_index] : source_mask;
            case (opcode)
                3'd0: begin
                    if (found) begin
                        exp_probe = m_dirty[selected_index]
                            ? (m_sharers[selected_index] & ~source_mask) : 4'd0;
                        m_sharers[selected_index] = m_sharers[selected_index] | source_mask;
                        m_dirty[selected_index] = 1'b0;
                        exp_sharers = m_sharers[selected_index];
                    end else begin
                        exp_evicted = m_valid[selected_index];
                        exp_probe = m_valid[selected_index] ? m_sharers[selected_index] : 4'd0;
                        m_valid[selected_index] = 1'b1;
                        m_tag[selected_index] = address >> 9;
                        m_sharers[selected_index] = source_mask;
                        m_dirty[selected_index] = 1'b0;
                        m_rr[set_index] = !(selected_index & 1);
                    end
                end
                3'd1: begin
                    if (found)
                        exp_probe = m_sharers[selected_index] & ~source_mask;
                    else begin
                        exp_evicted = m_valid[selected_index];
                        exp_probe = m_valid[selected_index] ? m_sharers[selected_index] : 4'd0;
                        m_rr[set_index] = !(selected_index & 1);
                    end
                    m_valid[selected_index] = 1'b1;
                    m_tag[selected_index] = address >> 9;
                    m_sharers[selected_index] = source_mask;
                    m_dirty[selected_index] = 1'b1;
                    exp_sharers = source_mask;
                end
                3'd2: begin
                    if (found && |(m_sharers[selected_index] & source_mask))
                        m_dirty[selected_index] = 1'b0;
                    else
                        exp_error = 1'b1;
                end
                3'd3: begin
                    if (found && |(m_sharers[selected_index] & source_mask)) begin
                        m_sharers[selected_index] = m_sharers[selected_index] & ~source_mask;
                        exp_sharers = m_sharers[selected_index];
                        if (m_sharers[selected_index] == 0) begin
                            m_valid[selected_index] = 1'b0;
                            m_dirty[selected_index] = 1'b0;
                        end
                    end else
                        exp_error = 1'b1;
                end
                3'd4: begin
                    if (found) begin
                        exp_probe = m_sharers[selected_index];
                        exp_sharers = 4'd0;
                        m_valid[selected_index] = 1'b0;
                        m_sharers[selected_index] = 4'd0;
                        m_dirty[selected_index] = 1'b0;
                    end
                end
                default: exp_error = 1'b1;
            endcase
        end
    endtask

    task apply_one;
        input [2:0] opcode;
        input [1:0] source;
        input [15:0] address;
        reg exp_hit;
        reg exp_error;
        reg exp_evicted;
        reg [3:0] exp_probe;
        reg [3:0] exp_sharers;
        begin
            model_apply(opcode, source, address, exp_hit, exp_error,
                        exp_evicted, exp_probe, exp_sharers);
            repeat (vector_index % 3) @(posedge clk);
            @(negedge clk);
            req_opcode = opcode; req_source = source; req_addr = address;
            req_valid = 1'b1;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            begin : wait_for_response
                while (1) begin
                    rsp_ready = ((cycles + vector_index) % 4) != 0;
                    @(posedge clk);
                    if (rsp_valid && rsp_ready) begin
                        checks = checks + 5;
                        if (rsp_hit !== exp_hit) mismatches = mismatches + 1;
                        if (rsp_error !== exp_error) mismatches = mismatches + 1;
                        if (rsp_evicted !== exp_evicted) mismatches = mismatches + 1;
                        if (rsp_probe_mask !== exp_probe) mismatches = mismatches + 1;
                        if (rsp_new_sharers !== exp_sharers) mismatches = mismatches + 1;
                        expected_hits = expected_hits + exp_hit;
                        expected_errors = expected_errors + exp_error;
                        expected_probes = expected_probes + popcount4(exp_probe);
                        disable wait_for_response;
                    end
                    @(negedge clk);
                end
            end
            rsp_ready = 1'b0;
            vector_index = vector_index + 1;
        end
    endtask

    initial begin
        for (i = 0; i < ENTRIES; i = i + 1) begin
            m_valid[i] = 1'b0; m_tag[i] = 7'd0;
            m_sharers[i] = 4'd0; m_dirty[i] = 1'b0;
        end
        for (i = 0; i < SETS; i = i + 1)
            m_rr[i] = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        apb_write(8'h00, 32'h00000007);
        repeat (2) @(posedge clk);

        apply_one(0, 0, 16'h0000);
        apply_one(0, 1, 16'h0000);
        apply_one(1, 2, 16'h0000);
        apply_one(2, 2, 16'h0000);
        apply_one(3, 2, 16'h0000);
        apply_one(3, 2, 16'h0000);
        apply_one(1, 3, 16'h0200);
        apply_one(4, 0, 16'h0200);

        for (i = 0; i < 312; i = i + 1) begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            req_opcode = lfsr % 5;
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            req_source = lfsr % NODES;
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            req_addr = (lfsr[7:0] << 6);
            apply_one(req_opcode, req_source, req_addr);
        end

        apb_read(8'h0c, read_value);
        checks = checks + 1; if (read_value != 320) mismatches = mismatches + 1;
        apb_read(8'h10, read_value);
        checks = checks + 1; if (read_value != expected_hits) mismatches = mismatches + 1;
        apb_read(8'h14, read_value);
        checks = checks + 1; if (read_value != (320 - expected_hits)) mismatches = mismatches + 1;
        apb_read(8'h18, read_value);
        checks = checks + 1; if (read_value != expected_probes) mismatches = mismatches + 1;
        apb_read(8'h1c, read_value);
        checks = checks + 1; if (read_value != expected_errors) mismatches = mismatches + 1;
        checks = checks + 1; if (!irq) mismatches = mismatches + 1;
        apb_write(8'h08, 32'h00000001);
        @(posedge clk);
        checks = checks + 1; if (irq) mismatches = mismatches + 1;

        if (mismatches == 0)
            $display("PASS: 320 transactions (8 corner + 312 randomized), %0d hits, %0d misses, %0d probes, %0d protocol errors, %0d checks, 0 mismatches, %0d clocks", expected_hits, 320 - expected_hits, expected_probes, expected_errors, checks, cycles);
        else begin
            $display("FAIL: %0d mismatches after %0d checks", mismatches, checks);
            $fatal(1);
        end
        $finish;
    end
endmodule

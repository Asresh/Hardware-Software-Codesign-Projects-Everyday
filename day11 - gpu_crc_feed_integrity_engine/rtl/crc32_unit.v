// ============================================================================
// crc32_unit - combinational parallel CRC-32/ISO-HDLC (zlib / Ethernet-FCS)
//
//   Reflected polynomial 0xEDB88320, init 0xFFFFFFFF, final XOR 0xFFFFFFFF.
//   This is the classic "unroll the LFSR into a GF(2) XOR tree" trick that
//   lets an FPGA CRC a whole word per clock instead of a bit (or a byte) at a
//   time. The per-byte reflected update is a fixed shift/xor recurrence; four
//   of them chained combinationally give a 4-bytes/clock CRC.  A `nbytes`
//   select (1..4) supports a partial final word so the CRC is byte-exact for
//   any payload length, not just multiples of four.
//
//   Byte order within a 32-bit word is little-endian on the wire: data[7:0]
//   is the first byte of the stream, data[31:24] the fourth. The C reference
//   packs its byte array the same way, and the standard KAT
//   CRC32("123456789") = 0xCBF43926 pins the convention to the published value.
// ============================================================================
`default_nettype none

module crc32_unit #(
    parameter [31:0] POLY = 32'hEDB88320   // reflected CRC-32
)(
    input  wire [31:0] crc_in,     // running CRC state (pre-finalisation)
    input  wire [31:0] data,       // up to four payload bytes, byte0 = [7:0]
    input  wire [2:0]  nbytes,     // 1..4 valid bytes in `data`
    output wire [31:0] crc_out     // state after folding `nbytes` bytes
);
    // One reflected CRC byte step: fold byte `d` into state `c`.
    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'b0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ POLY) : (x >> 1);
            crc_byte = x;
        end
    endfunction

    wire [31:0] c1 = crc_byte(crc_in, data[7:0]);
    wire [31:0] c2 = crc_byte(c1,     data[15:8]);
    wire [31:0] c3 = crc_byte(c2,     data[23:16]);
    wire [31:0] c4 = crc_byte(c3,     data[31:24]);

    assign crc_out = (nbytes == 3'd1) ? c1 :
                     (nbytes == 3'd2) ? c2 :
                     (nbytes == 3'd3) ? c3 : c4;
endmodule

`default_nettype wire

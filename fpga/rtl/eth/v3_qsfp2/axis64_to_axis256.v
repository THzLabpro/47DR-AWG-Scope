`default_nettype none
`timescale 1ns/1ps
// Four-beat AXI-Stream upsizer for udp_complete_64 to l_ethernet.
// The final partial word is emitted immediately on input tlast.
module axis64_to_axis256 (
    input wire clk, input wire rst,
    input wire [63:0] s_tdata, input wire [7:0] s_tkeep,
    input wire s_tvalid, output wire s_tready, input wire s_tlast,
    input wire s_tuser,
    output reg [255:0] m_tdata, output reg [31:0] m_tkeep,
    output reg m_tvalid, input wire m_tready, output reg m_tlast,
    output reg m_tuser
);
    reg [255:0] data_reg;
    reg [31:0] keep_reg;
    reg [1:0] count_reg;
    reg pending_last;
    reg pending_user;
    wire input_fire = s_tvalid && s_tready;
    wire output_fire = m_tvalid && m_tready;
    // While collecting a 256-bit word, keep accepting 64-bit beats without
    // asserting m_tvalid.  Once a complete word (or the final partial word)
    // is available, hold it until the downstream interface accepts it.
    assign s_tready = !m_tvalid || output_fire;
    always @(*) begin
        m_tdata = data_reg;
        m_tkeep = keep_reg;
        m_tlast = pending_last;
        m_tuser = pending_user;
    end
    always @(posedge clk) begin
        if (rst) begin
            data_reg <= 256'd0;
            keep_reg <= 32'd0;
            count_reg <= 2'd0;
            pending_last <= 1'b0;
            pending_user <= 1'b0;
            m_tvalid <= 1'b0;
        end else begin
            if (input_fire) begin
                // Clear stale upper lanes when a new frame starts.  A new
                // frame can arrive in the same cycle that the previous
                // frame's final 256-bit word is accepted.
                if (count_reg == 2'd0 && (!m_tvalid || output_fire)) begin
                    data_reg <= {192'd0, s_tdata};
                    keep_reg <= {24'd0, s_tkeep};
                    pending_last <= 1'b0;
                    pending_user <= s_tuser;
                end else begin
                    data_reg[count_reg*64 +: 64] <= s_tdata;
                    keep_reg[count_reg*8 +: 8] <= s_tkeep;
                    pending_user <= pending_user | s_tuser;
                end
                if (s_tlast || count_reg == 2'd3) begin
                    pending_last <= s_tlast;
                    m_tvalid <= 1'b1;
                    count_reg <= 2'd0;
                    if (s_tlast) begin
                        pending_user <= s_tuser;
                    end
                end else begin
                    // If the previous 256-bit word was accepted in the
                    // same cycle, the next word is only partially collected
                    // at this point.  Drop m_tvalid until lanes 0..3 have
                    // been filled (or tlast arrives); otherwise every
                    // incoming 64-bit beat is emitted as a repeated partial
                    // 256-bit frame.
                    m_tvalid <= 1'b0;
                    count_reg <= count_reg + 1'b1;
                end
            end else if (output_fire) begin
                m_tvalid <= 1'b0;
                data_reg <= 256'd0;
                keep_reg <= 32'd0;
                pending_last <= 1'b0;
                pending_user <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire

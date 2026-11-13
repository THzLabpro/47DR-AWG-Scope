`default_nettype none
`timescale 1ns/1ps

// UDP echo application with a fixed destination-port filter.
//
// Matching datagrams are echoed with source and destination addresses and
// ports exchanged.  Other UDP ports are accepted and drained so they cannot
// stall the shared UDP receive datapath.
module udp_echo_app_64 #(
    parameter [15:0] LOCAL_UDP_PORT = 16'd9000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_hdr_valid,
    output wire        s_hdr_ready,
    input  wire [31:0] s_source_ip,
    input  wire [31:0] s_dest_ip,
    input  wire [15:0] s_source_port,
    input  wire [15:0] s_dest_port,
    input  wire [15:0] s_length,
    input  wire [15:0] s_checksum,
    output wire        m_hdr_valid,
    input  wire        m_hdr_ready,
    output wire [31:0] m_source_ip,
    output wire [31:0] m_dest_ip,
    output wire [15:0] m_source_port,
    output wire [15:0] m_dest_port,
    output wire [15:0] m_length,
    output wire [15:0] m_checksum,
    input  wire [63:0] s_data,
    input  wire [7:0]  s_keep,
    input  wire        s_valid,
    output wire        s_ready,
    input  wire        s_last,
    input  wire        s_user,
    output wire [63:0] m_data,
    output wire [7:0]  m_keep,
    output wire        m_valid,
    input  wire        m_ready,
    output wire        m_last,
    output wire        m_user
);

    reg         frame_active_reg;
    reg         echo_frame_reg;
    reg         header_pending_reg;
    reg [31:0]  source_ip_reg;
    reg [31:0]  dest_ip_reg;
    reg [15:0]  source_port_reg;
    reg [15:0]  dest_port_reg;
    reg [15:0]  length_reg;
    reg [15:0]  checksum_reg;

    wire header_fire;
    wire payload_fire;
    wire output_header_fire;
    wire zero_payload_reg;

    assign s_hdr_ready = !frame_active_reg;
    assign m_hdr_valid = header_pending_reg;
    assign m_source_ip = dest_ip_reg;
    assign m_dest_ip = source_ip_reg;
    assign m_source_port = dest_port_reg;
    assign m_dest_port = source_port_reg;
    assign m_length = length_reg;
    assign m_checksum = checksum_reg;

    // A rejected port is intentionally always ready to consume the incoming
    // UDP payload.  A matching port follows the downstream ready signal.
    assign s_ready = frame_active_reg &&
        (!echo_frame_reg || (header_pending_reg && m_ready));
    assign m_data = s_data;
    assign m_keep = s_keep;
    assign m_valid = frame_active_reg && echo_frame_reg &&
        header_pending_reg && s_valid;
    assign m_last = s_last;
    assign m_user = s_user;

    assign header_fire = s_hdr_valid && s_hdr_ready;
    assign payload_fire = s_valid && s_ready;
    assign output_header_fire = m_hdr_valid && m_hdr_ready;
    assign zero_payload_reg = (length_reg <= 16'd8);

    always @(posedge clk) begin
        if (rst) begin
            frame_active_reg <= 1'b0;
            echo_frame_reg <= 1'b0;
            header_pending_reg <= 1'b0;
            source_ip_reg <= 32'd0;
            dest_ip_reg <= 32'd0;
            source_port_reg <= 16'd0;
            dest_port_reg <= 16'd0;
            length_reg <= 16'd0;
            checksum_reg <= 16'd0;
        end else begin
            if (header_fire) begin
                source_ip_reg <= s_source_ip;
                dest_ip_reg <= s_dest_ip;
                source_port_reg <= s_source_port;
                dest_port_reg <= s_dest_port;
                length_reg <= s_length;
                checksum_reg <= s_checksum;
                echo_frame_reg <= (s_dest_port == LOCAL_UDP_PORT);
                header_pending_reg <= (s_dest_port == LOCAL_UDP_PORT);

                // There is no payload stream for a UDP datagram of length
                // eight.  A rejected zero-payload datagram can retire now;
                // a matching one waits until its output header is accepted.
                if ((s_dest_port != LOCAL_UDP_PORT) && (s_length <= 16'd8)) begin
                    frame_active_reg <= 1'b0;
                end else begin
                    frame_active_reg <= 1'b1;
                end
            end else if (frame_active_reg) begin
                if (echo_frame_reg) begin
                    if (zero_payload_reg && output_header_fire) begin
                        frame_active_reg <= 1'b0;
                        header_pending_reg <= 1'b0;
                        echo_frame_reg <= 1'b0;
                    end else if (payload_fire && s_last) begin
                        frame_active_reg <= 1'b0;
                        header_pending_reg <= 1'b0;
                        echo_frame_reg <= 1'b0;
                    end
                end else if (payload_fire && s_last) begin
                    frame_active_reg <= 1'b0;
                    echo_frame_reg <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire

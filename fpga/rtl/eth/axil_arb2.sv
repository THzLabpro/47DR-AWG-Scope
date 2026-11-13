`timescale 1ns/1ps
`default_nettype none

// =============================================================
// Module: axil_arb2
// Function: Two AXI4-Lite slave ports (s0 JTAG, s1 Ethernet) to
//           one master. AW and W are collected per source so a
//           write transaction is never split across masters.
// Clock/reset: clk, synchronous active-low resetn.
// =============================================================
module axil_arb2 (
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] s0_awaddr,
    input  wire        s0_awvalid,
    output wire        s0_awready,
    input  wire [31:0] s0_wdata,
    input  wire [3:0]  s0_wstrb,
    input  wire        s0_wvalid,
    output wire        s0_wready,
    output reg  [1:0]  s0_bresp,
    output reg         s0_bvalid,
    input  wire        s0_bready,
    input  wire [31:0] s0_araddr,
    input  wire        s0_arvalid,
    output wire        s0_arready,
    output reg  [31:0] s0_rdata,
    output reg  [1:0]  s0_rresp,
    output reg         s0_rvalid,
    input  wire        s0_rready,
    input  wire [31:0] s1_awaddr,
    input  wire        s1_awvalid,
    output wire        s1_awready,
    input  wire [31:0] s1_wdata,
    input  wire [3:0]  s1_wstrb,
    input  wire        s1_wvalid,
    output wire        s1_wready,
    output reg  [1:0]  s1_bresp,
    output reg         s1_bvalid,
    input  wire        s1_bready,
    input  wire [31:0] s1_araddr,
    input  wire        s1_arvalid,
    output wire        s1_arready,
    output reg  [31:0] s1_rdata,
    output reg  [1:0]  s1_rresp,
    output reg         s1_rvalid,
    input  wire        s1_rready,
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_WRITE     = 3'd1;
    localparam [2:0] ST_WAIT_B    = 3'd2;
    localparam [2:0] ST_RESP_B    = 3'd3;
    localparam [2:0] ST_READ_ADDR = 3'd4;
    localparam [2:0] ST_WAIT_R    = 3'd5;
    localparam [2:0] ST_RESP_R    = 3'd6;

    reg [2:0] state;
    reg s0_aw_hold, s0_w_hold, s0_ar_hold;
    reg s1_aw_hold, s1_w_hold, s1_ar_hold;
    reg [31:0] s0_awaddr_reg, s0_wdata_reg, s0_araddr_reg;
    reg [3:0] s0_wstrb_reg;
    reg [31:0] s1_awaddr_reg, s1_wdata_reg, s1_araddr_reg;
    reg [3:0] s1_wstrb_reg;
    reg active_src;
    reg active_aw_pending, active_w_pending;
    reg [31:0] active_awaddr, active_wdata, active_araddr;
    reg [3:0] active_wstrb;
    reg rr_sel;

    wire s0_busy = state != ST_IDLE && active_src == 1'b0;
    wire s1_busy = state != ST_IDLE && active_src == 1'b1;
    wire s0_write_pending = s0_aw_hold && s0_w_hold;
    wire s1_write_pending = s1_aw_hold && s1_w_hold;
    wire s0_request_pending = s0_write_pending || s0_ar_hold;
    wire s1_request_pending = s1_write_pending || s1_ar_hold;

    wire s0_aw_fire = s0_awvalid && s0_awready;
    wire s0_w_fire  = s0_wvalid && s0_wready;
    wire s0_ar_fire = s0_arvalid && s0_arready;
    wire s1_aw_fire = s1_awvalid && s1_awready;
    wire s1_w_fire  = s1_wvalid && s1_wready;
    wire s1_ar_fire = s1_arvalid && s1_arready;

    assign s0_awready = !s0_aw_hold && !s0_bvalid && !s0_busy;
    assign s0_wready  = !s0_w_hold && !s0_bvalid && !s0_busy;
    assign s0_arready = !s0_ar_hold && !s0_rvalid && !s0_busy;
    assign s1_awready = !s1_aw_hold && !s1_bvalid && !s1_busy;
    assign s1_wready  = !s1_w_hold && !s1_bvalid && !s1_busy;
    assign s1_arready = !s1_ar_hold && !s1_rvalid && !s1_busy;

    assign m_awaddr  = active_awaddr;
    assign m_awvalid = state == ST_WRITE && active_aw_pending;
    assign m_wdata   = active_wdata;
    assign m_wstrb   = active_wstrb;
    assign m_wvalid  = state == ST_WRITE && active_w_pending;
    assign m_bready  = state == ST_WAIT_B;
    assign m_araddr  = active_araddr;
    assign m_arvalid = state == ST_READ_ADDR;
    assign m_rready  = state == ST_WAIT_R;

    always @(posedge clk) begin
        if (!resetn) begin
            state <= ST_IDLE;
            s0_aw_hold <= 0;
            s0_w_hold <= 0;
            s0_ar_hold <= 0;
            s1_aw_hold <= 0;
            s1_w_hold <= 0;
            s1_ar_hold <= 0;
            s0_awaddr_reg <= 0;
            s0_wdata_reg <= 0;
            s0_wstrb_reg <= 0;
            s0_araddr_reg <= 0;
            s1_awaddr_reg <= 0;
            s1_wdata_reg <= 0;
            s1_wstrb_reg <= 0;
            s1_araddr_reg <= 0;
            active_src <= 0;
            active_aw_pending <= 0;
            active_w_pending <= 0;
            active_awaddr <= 0;
            active_wdata <= 0;
            active_wstrb <= 0;
            active_araddr <= 0;
            rr_sel <= 0;
            s0_bresp <= 0;
            s0_bvalid <= 0;
            s1_bresp <= 0;
            s1_bvalid <= 0;
            s0_rdata <= 0;
            s0_rresp <= 0;
            s0_rvalid <= 0;
            s1_rdata <= 0;
            s1_rresp <= 0;
            s1_rvalid <= 0;
        end else begin
            if (s0_aw_fire) begin
                s0_aw_hold <= 1'b1;
                s0_awaddr_reg <= s0_awaddr;
            end
            if (s0_w_fire) begin
                s0_w_hold <= 1'b1;
                s0_wdata_reg <= s0_wdata;
                s0_wstrb_reg <= s0_wstrb;
            end
            if (s0_ar_fire) begin
                s0_ar_hold <= 1'b1;
                s0_araddr_reg <= s0_araddr;
            end
            if (s1_aw_fire) begin
                s1_aw_hold <= 1'b1;
                s1_awaddr_reg <= s1_awaddr;
            end
            if (s1_w_fire) begin
                s1_w_hold <= 1'b1;
                s1_wdata_reg <= s1_wdata;
                s1_wstrb_reg <= s1_wstrb;
            end
            if (s1_ar_fire) begin
                s1_ar_hold <= 1'b1;
                s1_araddr_reg <= s1_araddr;
            end

            case (state)
                ST_IDLE: begin
                    if ((rr_sel == 1'b0 && s0_request_pending) ||
                        (rr_sel == 1'b1 && !s1_request_pending && s0_request_pending)) begin
                        active_src <= 1'b0;
                        if (s0_write_pending) begin
                            active_awaddr <= s0_awaddr_reg;
                            active_wdata <= s0_wdata_reg;
                            active_wstrb <= s0_wstrb_reg;
                            active_aw_pending <= 1'b1;
                            active_w_pending <= 1'b1;
                            s0_aw_hold <= 1'b0;
                            s0_w_hold <= 1'b0;
                            state <= ST_WRITE;
                        end else begin
                            active_araddr <= s0_araddr_reg;
                            s0_ar_hold <= 1'b0;
                            state <= ST_READ_ADDR;
                        end
                    end else if (s1_request_pending) begin
                        active_src <= 1'b1;
                        if (s1_write_pending) begin
                            active_awaddr <= s1_awaddr_reg;
                            active_wdata <= s1_wdata_reg;
                            active_wstrb <= s1_wstrb_reg;
                            active_aw_pending <= 1'b1;
                            active_w_pending <= 1'b1;
                            s1_aw_hold <= 1'b0;
                            s1_w_hold <= 1'b0;
                            state <= ST_WRITE;
                        end else begin
                            active_araddr <= s1_araddr_reg;
                            s1_ar_hold <= 1'b0;
                            state <= ST_READ_ADDR;
                        end
                    end
                end
                ST_WRITE: begin
                    if (active_aw_pending && m_awready)
                        active_aw_pending <= 1'b0;
                    if (active_w_pending && m_wready)
                        active_w_pending <= 1'b0;
                    if ((!active_aw_pending || m_awready) &&
                        (!active_w_pending || m_wready))
                        state <= ST_WAIT_B;
                end
                ST_WAIT_B: begin
                    if (m_bvalid && m_bready) begin
                        if (active_src == 1'b0) begin
                            s0_bresp <= m_bresp;
                            s0_bvalid <= 1'b1;
                        end else begin
                            s1_bresp <= m_bresp;
                            s1_bvalid <= 1'b1;
                        end
                        state <= ST_RESP_B;
                    end
                end
                ST_RESP_B: begin
                    if (active_src == 1'b0 && s0_bvalid && s0_bready) begin
                        s0_bvalid <= 1'b0;
                        state <= ST_IDLE;
                        rr_sel <= 1'b1;
                    end else if (active_src == 1'b1 && s1_bvalid && s1_bready) begin
                        s1_bvalid <= 1'b0;
                        state <= ST_IDLE;
                        rr_sel <= 1'b0;
                    end
                end
                ST_READ_ADDR: begin
                    if (m_arready)
                        state <= ST_WAIT_R;
                end
                ST_WAIT_R: begin
                    if (m_rvalid && m_rready) begin
                        if (active_src == 1'b0) begin
                            s0_rdata <= m_rdata;
                            s0_rresp <= m_rresp;
                            s0_rvalid <= 1'b1;
                        end else begin
                            s1_rdata <= m_rdata;
                            s1_rresp <= m_rresp;
                            s1_rvalid <= 1'b1;
                        end
                        state <= ST_RESP_R;
                    end
                end
                ST_RESP_R: begin
                    if (active_src == 1'b0 && s0_rvalid && s0_rready) begin
                        s0_rvalid <= 1'b0;
                        state <= ST_IDLE;
                        rr_sel <= 1'b1;
                    end else if (active_src == 1'b1 && s1_rvalid && s1_rready) begin
                        s1_rvalid <= 1'b0;
                        state <= ST_IDLE;
                        rr_sel <= 1'b0;
                    end
                end
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire

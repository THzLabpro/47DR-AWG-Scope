/* Native UDP 9101 bulk loops (TXW / RXR / STAT) for tools/awg_eth/bulk.py, called through ctypes.
 *
 * Same algorithms as the Python path in bulk.py (doc/03 §4):
 *   - TXW: batches of packets, the last packet of each batch asks for an ACK that carries the FPGA's
 *     global accepted-word counter (STAT[9]); up to batches_in_flight batches are outstanding. On a
 *     counter mismatch or timeout the counter is resynchronized with STAT and sending restarts at the
 *     oldest unacknowledged batch.
 *   - RXR: sliding window of requests, each with its own deadline and resend; replies are placed by
 *     their offset, so order does not matter; late or duplicate replies are ignored by sequence.
 * The socket is the Python socket's handle (non-blocking, already bound). ctypes releases the GIL
 * for the call; the optional callback (progress + cancel) is called every CB_EVERY packets.
 *
 * Build: tools/awg_eth/native/build.ps1 (Vivado's mingw-w64 gcc), no runtime DLL dependencies.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __declspec(dllexport)

#define MAGIC 0xA7E1u
#define VERSION 1u
#define HDR 24
#define OP_TXW 0x10u
#define OP_RXR 0x11u
#define OP_STAT 0x12u
#define FLAG_ACK 0x2u
#define MAX_WINDOW 256
#define CB_EVERY 32
#define RXR_CHUNK 2040u

/* Return codes (bulk.py maps them to exceptions). */
#define RC_OK 0
#define RC_TIMEOUT 1
#define RC_STATUS 2
#define RC_CANCELLED 3
#define RC_SHORT 4
#define RC_ARGS 5
#define RC_SOCKET -1

typedef int (*awg_cb)(int64_t done, int64_t total);   /* nonzero return = cancel */

typedef struct {
    uint64_t sock;          /* SOCKET handle */
    uint32_t peer_ip;       /* network byte order (as in sockaddr_in.sin_addr) */
    uint32_t peer_port;     /* host byte order */
    double timeout_s;       /* per request / per batch */
    int32_t retries;
    uint32_t seq;           /* last sequence number used; updated on return */
    /* outputs */
    int64_t resent;         /* TXW: resent batches; RXR: resent requests */
    int64_t packets;        /* data packets sent (TXW) or replies placed (RXR) */
    int32_t error_status;   /* RC_STATUS: FPGA status code */
    uint32_t error_seq;     /* RC_STATUS: sequence of the failing reply */
    int64_t error_offset;   /* RC_TIMEOUT: word (TXW) or pair (RXR) offset; RC_SHORT: got count */
    int32_t wsa_error;      /* RC_SOCKET: WSAGetLastError() */
    double seconds;         /* wall time of the call */
} awg_ctx;

static double g_tick;

static double now_s(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * g_tick;
}

static void init_clock(void) {
    if (g_tick == 0.0) {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        g_tick = 1.0 / (double)f.QuadPart;
    }
}

static void put_header(uint8_t *h, uint32_t opcode, uint32_t seq, uint32_t addr, uint32_t count,
                       uint32_t flags) {
    memset(h, 0, HDR);
    h[0] = MAGIC & 0xFF; h[1] = MAGIC >> 8;
    h[2] = VERSION;
    h[3] = (uint8_t)opcode;
    memcpy(h + 4, &seq, 4);
    memcpy(h + 8, &addr, 4);
    h[12] = count & 0xFF; h[13] = (count >> 8) & 0xFF;
    h[14] = flags & 0xFF; h[15] = (flags >> 8) & 0xFF;
}

typedef struct {
    uint32_t opcode, seq, count, status;
} reply_t;

/* Parse a reply header in place. 0 if it is not a valid bulk reply. */
static int parse_reply(const uint8_t *b, int n, reply_t *r) {
    uint32_t reserved;
    if (n < HDR) return 0;
    if ((uint32_t)(b[0] | (b[1] << 8)) != MAGIC || b[2] != VERSION || !(b[3] & 0x80)) return 0;
    memcpy(&reserved, b + 20, 4);
    if (reserved) return 0;
    r->opcode = b[3];
    memcpy(&r->seq, b + 4, 4);
    r->count = (uint32_t)(b[12] | (b[13] << 8));
    r->status = (uint32_t)(b[16] | (b[17] << 8));
    if ((uint32_t)n != HDR + 4u * r->count) return 0;
    return 1;
}

static int send_bufs(awg_ctx *c, WSABUF *bufs, DWORD nbufs) {
    struct sockaddr_in to;
    DWORD sent;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = c->peer_ip;
    to.sin_port = htons((u_short)c->peer_port);
    for (;;) {
        if (WSASendTo((SOCKET)c->sock, bufs, nbufs, &sent, 0, (struct sockaddr *)&to, sizeof to,
                      NULL, NULL) == 0)
            return 0;
        int e = WSAGetLastError();
        if (e == WSAEWOULDBLOCK || e == WSAENOBUFS) {          /* send buffer full: wait */
            fd_set w;
            struct timeval tv = {0, 2000};
            FD_ZERO(&w);
            FD_SET((SOCKET)c->sock, &w);
            select(0, NULL, &w, NULL, &tv);
            continue;
        }
        c->wsa_error = e;
        return -1;
    }
}

static int send_one(awg_ctx *c, const uint8_t *buf, int len) {
    WSABUF b = {(ULONG)len, (char *)buf};
    return send_bufs(c, &b, 1);
}

/* Receive one datagram from the peer. Returns its length, 0 on deadline, -1 on socket error. */
static int recv_one(awg_ctx *c, uint8_t *buf, int cap, double deadline) {
    for (;;) {
        struct sockaddr_in from;
        int fl = sizeof from;
        int n = recvfrom((SOCKET)c->sock, (char *)buf, cap, 0, (struct sockaddr *)&from, &fl);
        if (n >= 0) {
            if (from.sin_addr.s_addr == c->peer_ip && ntohs(from.sin_port) == c->peer_port && n >= HDR)
                return n;
            continue;
        }
        int e = WSAGetLastError();
        if (e == WSAECONNRESET || e == WSAEMSGSIZE) continue;   /* ICMP from an old send / oversize */
        if (e != WSAEWOULDBLOCK) {
            c->wsa_error = e;
            return -1;
        }
        double remaining = deadline - now_s();
        if (remaining <= 0) return 0;
        fd_set r;
        struct timeval tv;
        long us = (long)(remaining * 1e6) + 1;
        tv.tv_sec = us / 1000000;
        tv.tv_usec = us % 1000000;
        FD_ZERO(&r);
        FD_SET((SOCKET)c->sock, &r);
        int s = select(0, &r, NULL, NULL, &tv);
        if (s == 0) return 0;
        if (s < 0) {
            c->wsa_error = WSAGetLastError();
            return -1;
        }
    }
}

static uint32_t next_seq(awg_ctx *c) {
    c->seq = c->seq + 1;
    return c->seq;
}

/* STAT: 16 words into out. */
static int do_stat(awg_ctx *c, uint32_t out[16]) {
    uint8_t req[HDR];
    uint8_t buf[2048];
    uint32_t seq = next_seq(c);
    put_header(req, OP_STAT, seq, 0, 0, 0);
    for (int attempt = 0; attempt <= c->retries; attempt++) {
        if (send_one(c, req, HDR)) return RC_SOCKET;
        double deadline = now_s() + c->timeout_s;
        for (;;) {
            int n = recv_one(c, buf, sizeof buf, deadline);
            if (n < 0) return RC_SOCKET;
            if (n == 0) break;
            reply_t r;
            if (!parse_reply(buf, n, &r) || r.seq != seq || r.opcode != (OP_STAT | 0x80)) continue;
            if (r.status) {
                c->error_status = (int32_t)r.status;
                c->error_seq = r.seq;
                return RC_STATUS;
            }
            if (r.count != 16) {
                c->error_offset = r.count;
                return RC_SHORT;
            }
            memcpy(out, buf + HDR, 64);
            return RC_OK;
        }
    }
    c->error_offset = -1;
    return RC_TIMEOUT;
}

EXPORT int awg_bulk_abi(void) { return 3; }   /* 2: awg_capture / awg_load; 3: callbacks <= 20/s */

EXPORT int awg_stat(awg_ctx *c, uint32_t *out16) {
    init_clock();
    double t0 = now_s();
    int rc = do_stat(c, out16);
    c->seconds = now_s() - t0;
    return rc;
}

typedef struct {
    int64_t batch;
    uint32_t ack_seq;
    uint32_t expected;
    int got;
    uint32_t value;
} inflight_t;

EXPORT int awg_txw(awg_ctx *c, int32_t channel, const uint32_t *words, int64_t nwords,
                   int32_t words_per_packet, int32_t batch_packets, int32_t batches_in_flight,
                   awg_cb cb) {
    init_clock();
    double t0 = now_s();
    c->resent = 0;
    c->packets = 0;
    if (channel < 0 || channel > 7 || nwords < 16 || nwords > 524288 || nwords % 16 ||
        words_per_packet < 16 || words_per_packet > 2048 || words_per_packet % 16 ||
        batch_packets < 1 || batches_in_flight < 1 || batches_in_flight > MAX_WINDOW)
        return RC_ARGS;
    int64_t npk = (nwords + words_per_packet - 1) / words_per_packet;
    int64_t nbatch = (npk + batch_packets - 1) / batch_packets;
    int32_t *failures = (int32_t *)calloc((size_t)nbatch, sizeof(int32_t));
    if (!failures) return RC_ARGS;
    inflight_t fl[MAX_WINDOW];
    int head = 0, count = 0;                     /* ring of outstanding batches */
    uint32_t stat[16];
    uint8_t hdr[HDR];
    uint8_t buf[2048];
    int rc = RC_CANCELLED;
    if (cb && cb(0, nwords)) goto out;           /* cancel before the first packet */
    rc = do_stat(c, stat);
    if (rc) goto out;
    uint32_t counter = stat[9];
    int64_t next_batch = 0, done = 0, since_cb = 0, reported = 0;
    while (done < nbatch) {
        while (next_batch < nbatch && count < batches_in_flight) {
            uint32_t base = count ? fl[(head + count - 1) % MAX_WINDOW].expected : counter;
            int64_t first = next_batch * batch_packets;
            int64_t last = first + batch_packets;
            if (last > npk) last = npk;
            uint64_t bw = 0;
            uint32_t ack_seq = 0;
            for (int64_t p = first; p < last; p++) {
                int64_t off = p * words_per_packet;
                int64_t n = nwords - off < words_per_packet ? nwords - off : words_per_packet;
                int is_last = p == last - 1;
                uint32_t seq = next_seq(c);
                if (is_last) ack_seq = seq;
                put_header(hdr, OP_TXW, seq, ((uint32_t)channel << 28) | (uint32_t)off, (uint32_t)n,
                           is_last ? FLAG_ACK : 0);
                WSABUF b[2] = {{HDR, (char *)hdr}, {(ULONG)(n * 4), (char *)(words + off)}};
                if (send_bufs(c, b, 2)) { rc = RC_SOCKET; goto out; }
                c->packets++;
                bw += (uint64_t)n;
            }
            uint64_t exp = (uint64_t)base + bw;
            inflight_t *e = &fl[(head + count) % MAX_WINDOW];
            e->batch = next_batch;
            e->ack_seq = ack_seq;
            e->expected = exp > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)exp;   /* saturates: CRC decides */
            e->got = 0;
            count++;
            next_batch++;
        }
        inflight_t *h = &fl[head];
        double deadline = now_s() + c->timeout_s;
        while (!h->got) {
            int n = recv_one(c, buf, sizeof buf, deadline);
            if (n < 0) { rc = RC_SOCKET; goto out; }
            if (n == 0) break;
            reply_t r;
            if (!parse_reply(buf, n, &r) || r.opcode != (OP_TXW | 0x80)) continue;
            if (r.status) {
                c->error_status = (int32_t)r.status;
                c->error_seq = r.seq;
                rc = RC_STATUS;
                goto out;
            }
            if (r.count != 1) continue;
            for (int i = 0; i < count; i++) {
                inflight_t *e = &fl[(head + i) % MAX_WINDOW];
                if (e->ack_seq == r.seq) {
                    memcpy(&e->value, buf + HDR, 4);
                    e->got = 1;
                    break;
                }
            }
        }
        if (h->got && h->value == h->expected) {
            counter = h->value;
            head = (head + 1) % MAX_WINDOW;
            count--;
            done++;
            since_cb += batch_packets;
            if (cb && (since_cb >= CB_EVERY || done == nbatch)) {
                since_cb = 0;
                int64_t end = (h->batch + 1) * (int64_t)batch_packets * words_per_packet;
                reported = end < nwords ? end : nwords;
                if (cb(reported, nwords)) { rc = RC_CANCELLED; goto out; }
            }
            continue;
        }
        /* A packet of this batch (or its ACK) was lost: resynchronize, resend from this batch. */
        int64_t hb = h->batch;
        failures[hb]++;
        c->resent++;
        if (failures[hb] > c->retries) {
            c->error_offset = hb * (int64_t)batch_packets * words_per_packet;
            rc = RC_TIMEOUT;
            goto out;
        }
        count = 0;
        head = 0;
        rc = do_stat(c, stat);
        if (rc) goto out;
        counter = stat[9];
        next_batch = hb;
        if (cb && cb(reported, nwords)) { rc = RC_CANCELLED; goto out; }      /* cancel check only */
    }
    rc = RC_OK;
out:
    free(failures);
    c->seconds = now_s() - t0;
    return rc;
}

typedef struct {
    int active;
    uint32_t seq;
    uint32_t offset;     /* absolute pair offset */
    uint32_t count;
    int32_t retries;
    double deadline;
} pending_t;

static int send_rxr(awg_ctx *c, int32_t slot, pending_t *p) {
    uint8_t req[HDR];
    put_header(req, OP_RXR, p->seq, ((uint32_t)slot << 28) | p->offset, p->count, 0);
    return send_one(c, req, HDR);
}

EXPORT int awg_rxr(awg_ctx *c, int32_t slot, uint32_t pair_offset, uint32_t pair_count,
                   int32_t window, uint32_t *out, awg_cb cb) {
    init_clock();
    double t0 = now_s();
    c->resent = 0;
    c->packets = 0;
    if (slot < 0 || slot > 7 || pair_count < 1 || pair_offset % 12 || pair_count % 12 ||
        pair_count > 0xFFFFFFFu || window < 1 || window > MAX_WINDOW)
        return RC_ARGS;
    pending_t pend[MAX_WINDOW];
    memset(pend, 0, sizeof pend);
    uint8_t buf[65536];
    uint32_t next_off = 0;                       /* relative to pair_offset */
    uint32_t completed = 0;
    int active = 0;
    int64_t since_cb = 0;
    int rc = RC_CANCELLED;
    if (cb && cb(0, pair_count)) goto out;       /* cancel before the first request */
    rc = RC_OK;
    while (next_off < pair_count || active) {
        double now = now_s();
        for (int i = 0; i < window && next_off < pair_count; i++) {
            if (pend[i].active) continue;
            pending_t *p = &pend[i];
            p->active = 1;
            p->seq = next_seq(c);
            p->offset = pair_offset + next_off;
            p->count = pair_count - next_off < RXR_CHUNK ? pair_count - next_off : RXR_CHUNK;
            p->retries = 0;
            p->deadline = now + c->timeout_s;
            next_off += p->count;
            active++;
            if (send_rxr(c, slot, p)) { rc = RC_SOCKET; goto out; }
        }
        double deadline = 1e300;
        for (int i = 0; i < window; i++)
            if (pend[i].active && pend[i].deadline < deadline) deadline = pend[i].deadline;
        int n = recv_one(c, buf, sizeof buf, deadline);
        if (n < 0) { rc = RC_SOCKET; goto out; }
        if (n > 0) {
            reply_t r;
            if (!parse_reply(buf, n, &r) || r.opcode != (OP_RXR | 0x80)) continue;
            int i;
            for (i = 0; i < window; i++)
                if (pend[i].active && pend[i].seq == r.seq) break;
            if (i == window) continue;               /* duplicate or late reply to a resent request */
            if (r.status) {
                c->error_status = (int32_t)r.status;
                c->error_seq = r.seq;
                rc = RC_STATUS;
                goto out;
            }
            if (r.count != pend[i].count) {
                c->error_offset = r.count;
                rc = RC_SHORT;
                goto out;
            }
            memcpy(out + (pend[i].offset - pair_offset), buf + HDR, (size_t)r.count * 4);
            completed += r.count;
            pend[i].active = 0;
            active--;
            c->packets++;
            if (cb && (++since_cb >= CB_EVERY || completed == pair_count)) {
                since_cb = 0;
                if (cb(completed, pair_count)) { rc = RC_CANCELLED; goto out; }
            }
            continue;
        }
        now = now_s();
        for (int i = 0; i < window; i++) {
            pending_t *p = &pend[i];
            if (!p->active || now < p->deadline) continue;
            if (p->retries >= c->retries) {
                c->error_offset = p->offset;
                rc = RC_TIMEOUT;
                goto out;
            }
            p->retries++;
            p->deadline = now + c->timeout_s;
            c->resent++;
            if (send_rxr(c, slot, p)) { rc = RC_SOCKET; goto out; }
        }
        if (cb && cb(completed, pair_count)) { rc = RC_CANCELLED; goto out; }
    }
out:
    c->seconds = now_s() - t0;
    return rc;
}

/* ======================================================================================
 * 9100 control registers (doc/00 §4.2) and whole capture / download sequences.
 *
 * The GUI measured ~100 ms per start-synchronized capture although the readback itself took 3 ms:
 * the arm/stop/start/poll steps were ~49 serial register round trips made from Python, each needing
 * the GIL back while the GUI thread draws. These run the same steps as Awg.capture_raw/load_words
 * in one ctypes call (GIL released) with the minimum number of round trips.
 * ====================================================================================== */
#define OP_READ 1u
#define OP_WRITE 2u
#define RC_CMD 6          /* sequence failed; awg_seq_result.failed_step / detail say why */

/* failed_step codes */
#define D_BUSY 1          /* previous RF command still busy */
#define D_NOT_READY 2     /* STATUS.ps_ready = 0 */
#define D_REJECTED 3      /* command_result != 0 */
#define D_CMD_TIMEOUT 4
#define D_START_REJECTED 5
#define D_CAP_TIMEOUT 6
#define D_BAD_COUNT 7
#define D_CRC 8

/* register offsets (awg.py REG_*) */
#define R_STATUS 0x04u
#define R_COMMAND 0x08u
#define R_TX_LENGTH 0x0Cu
#define R_TX_MASK 0x10u
#define R_CAP_STATUS 0x28u
#define R_CAP_SAMPLES 0x2Cu
#define R_TX_WR_CH 0x30u
#define R_TX_CRC 0x3Cu
#define R_CAP_CTRL 0x4Cu
#define R_CAP_TX_WORD 0x50u
#define R_CAP_LEN 0x58u
#define R_CAP_MODE 0x5Cu
#define R_TX_MODE 0x64u

typedef struct {
    int32_t failed_step;     /* D_* when RC_CMD */
    uint32_t detail;         /* STATUS / CAP_STATUS / sample count / CRC value, per failed_step */
    uint32_t command;        /* command, sample count or slot index involved */
    uint32_t status_word;    /* last STATUS read */
    uint32_t captured;       /* capture: CAP_SAMPLES */
    uint32_t cap_tx_word;    /* capture: CAP_TX_WORD */
    int64_t reg_ops;         /* 9100 round trips */
    int64_t crc_retries;     /* download: CRC mismatches that were rewritten */
    double t_control;        /* seconds in register steps */
    double t_data;           /* seconds in TXW / RXR */
    uint32_t crc_actual[8];  /* download: TX_CRC per slot */
} awg_seq_result;

typedef struct {
    awg_ctx *ctl;
    uint32_t base;
    double cmd_timeout_s;
    awg_seq_result *r;
    uint32_t status;         /* cached STATUS (valid when have_status) */
    int have_status;
} seq_t;

static int reg_xfer(seq_t *s, uint32_t op, uint32_t off, uint32_t wval, uint32_t *rval) {
    awg_ctx *c = s->ctl;
    uint8_t req[HDR + 4];
    uint8_t buf[2048];
    uint32_t seq = next_seq(c);
    uint32_t addr = s->base + off;
    put_header(req, op, seq, addr, 1, 0);
    memcpy(req + HDR, &wval, 4);
    int len = op == OP_WRITE ? HDR + 4 : HDR;
    s->r->reg_ops++;
    for (int attempt = 0; attempt <= c->retries; attempt++) {     /* same-sequence retransmission */
        if (send_one(c, req, len)) return RC_SOCKET;
        double deadline = now_s() + c->timeout_s;
        for (;;) {
            int n = recv_one(c, buf, sizeof buf, deadline);
            if (n < 0) return RC_SOCKET;
            if (n == 0) break;
            uint32_t rseq, reserved;
            memcpy(&rseq, buf + 4, 4);
            memcpy(&reserved, buf + 20, 4);
            if ((uint32_t)(buf[0] | (buf[1] << 8)) != MAGIC || buf[2] != VERSION || reserved ||
                buf[3] != (op | 0x80) || rseq != seq)
                continue;
            uint32_t status = (uint32_t)(buf[16] | (buf[17] << 8));
            if (status) {
                c->error_status = (int32_t)status;
                c->error_seq = seq;
                c->error_offset = addr;
                return RC_STATUS;
            }
            if (op == OP_READ) {
                if (n < HDR + 4) continue;
                memcpy(rval, buf + HDR, 4);
            }
            return RC_OK;
        }
    }
    c->error_offset = addr;
    return RC_TIMEOUT;
}

static int rd(seq_t *s, uint32_t off, uint32_t *v) { return reg_xfer(s, OP_READ, off, 0, v); }
static int wr(seq_t *s, uint32_t off, uint32_t v) { return reg_xfer(s, OP_WRITE, off, v, NULL); }

static int fail(seq_t *s, int step, uint32_t detail, uint32_t command) {
    s->r->failed_step = step;
    s->r->detail = detail;
    s->r->command = command;
    return RC_CMD;
}

static int seq_cancelled(void);

/* Awg.command(): check STATUS (cached when fresh), write COMMAND, poll STATUS until done. */
static int command(seq_t *s, uint32_t value) {
    int rc;
    uint32_t st;
    if (!s->have_status) {
        if ((rc = rd(s, R_STATUS, &st))) return rc;
        s->status = st;
    }
    st = s->status;
    if (st & 2) return fail(s, D_BUSY, st, value);
    if (!(st & 4)) return fail(s, D_NOT_READY, st, value);
    if ((rc = wr(s, R_COMMAND, value))) return rc;
    s->have_status = 0;
    double deadline = now_s() + s->cmd_timeout_s;
    for (long polls = 0;; polls++) {
        if ((rc = rd(s, R_STATUS, &st))) return rc;
        s->status = st;
        s->r->status_word = st;
        if (!(st & 2) && !(value == 16 && (st & 0x100))) {
            if ((st >> 4) & 3) return fail(s, D_REJECTED, st, value);
            s->have_status = 1;
            return RC_OK;
        }
        if (now_s() >= deadline) return fail(s, D_CMD_TIMEOUT, st, value);
        if (seq_cancelled()) return RC_CANCELLED;
        if (polls > 2000) Sleep(1);
    }
}

static void set_nonblocking(awg_ctx *c, u_long on) { ioctlsocket((SOCKET)c->sock, FIONBIO, &on); }

typedef int (*awg_cb3)(int32_t index, int64_t done, int64_t total);   /* nonzero return = cancel */
static __thread awg_cb3 tl_cb3;
static __thread int32_t tl_index;
static __thread double tl_next_cb;
/* A sequence calls back into Python (progress + cancel) at most every SEQ_CB_INTERVAL: each callback
 * needs the GIL, which the GUI thread can hold for tens of ms while it draws. A normal capture or
 * download finishes before the first callback is due, so it never waits for the GIL. */
#define SEQ_CB_INTERVAL 0.05
static int cb3_adapter(int64_t done, int64_t total) {
    double t = now_s();
    if (!tl_cb3 || t < tl_next_cb) return 0;
    tl_next_cb = t + SEQ_CB_INTERVAL;
    return tl_cb3(tl_index, done, total);
}
static int seq_cancelled(void) { return cb3_adapter(-1, -1); }   /* done < 0: cancel check only */
static void seq_cb_begin(awg_cb3 cb) {
    tl_cb3 = cb;
    tl_index = 0;
    tl_next_cb = now_s() + SEQ_CB_INTERVAL;
}

typedef struct {
    uint32_t base;           /* REG_BASE */
    int32_t trigger_start;   /* 1 = DAC start-synchronized (stops a running TX, START after arm) */
    int32_t check_start_rejected;   /* ABI >= V2.1: STATUS[9] */
    int32_t write_mode_len;  /* bulk ABI: write CAP_MODE and CAP_LEN */
    uint32_t cap_mode, cap_ctrl, cap_len;
    uint32_t limit;          /* max captured samples */
    int32_t n_read;
    int32_t read_slot[8];
    int32_t window;
    double cmd_timeout_s, cap_timeout_s;
} awg_cap_args;

/* Awg.capture_raw() on the bulk path: abort a stale arm, (stop), configure, arm, (start), wait,
 * read counts, then RXR every requested slot into out[i] (each >= limit/2 words). */
EXPORT int awg_capture(awg_ctx *ctl, awg_ctx *blk, const awg_cap_args *a, uint32_t **out,
                       awg_cb3 cb, awg_seq_result *r) {
    init_clock();
    memset(r, 0, sizeof *r);
    if (a->n_read < 1 || a->n_read > 8) return RC_ARGS;
    seq_t s = {ctl, a->base, a->cmd_timeout_s, r, 0, 0};
    double t0 = now_s();
    int rc, armed = 0;
    uint32_t v;
    seq_cb_begin(cb);
    set_nonblocking(ctl, 1);
    if ((rc = rd(&s, R_CAP_STATUS, &v))) goto out;
    if ((v & 5) && (rc = wr(&s, R_COMMAND, 32))) goto out;    /* stale armed/busy capture: abort */
    if (a->trigger_start) {
        if ((rc = rd(&s, R_STATUS, &s.status))) goto out;
        s.have_status = 1;
        if ((s.status & 1) && (rc = command(&s, 1))) goto out;
    }
    if (a->write_mode_len && (rc = wr(&s, R_CAP_MODE, a->cap_mode))) goto out;
    if ((rc = wr(&s, R_CAP_CTRL, a->cap_ctrl))) goto out;
    if (a->write_mode_len && (rc = wr(&s, R_CAP_LEN, a->cap_len))) goto out;
    armed = 1;
    if ((rc = command(&s, 8))) goto out;
    if (a->trigger_start) {
        if ((rc = command(&s, 2))) goto out;
        if (a->check_start_rejected && (s.status & 0x200)) {
            rc = fail(&s, D_START_REJECTED, s.status, 2);
            goto out;
        }
    }
    double deadline = now_s() + a->cap_timeout_s;
    for (long polls = 0;; polls++) {
        if ((rc = rd(&s, R_CAP_STATUS, &v))) goto out;
        if ((v & 2) && !(v & 1)) break;
        if (now_s() >= deadline) {
            uint32_t n = 0;
            rd(&s, R_CAP_SAMPLES, &n);
            rc = fail(&s, D_CAP_TIMEOUT, v, n);
            goto out;
        }
        if (seq_cancelled()) { rc = RC_CANCELLED; goto out; }
        if (polls > 2000) Sleep(1);
    }
    armed = 0;
    if ((rc = rd(&s, R_CAP_SAMPLES, &r->captured))) goto out;
    if (r->captured < 24 || r->captured > a->limit || r->captured % 24) {
        rc = fail(&s, D_BAD_COUNT, r->captured, 0);
        goto out;
    }
    if ((rc = rd(&s, R_CAP_TX_WORD, &r->cap_tx_word))) goto out;
    r->t_control = now_s() - t0;
    double t1 = now_s();
    for (int i = 0; i < a->n_read; i++) {
        tl_index = i;
        rc = awg_rxr(blk, a->read_slot[i], 0, r->captured / 2, a->window, out[i], cb ? cb3_adapter : NULL);
        if (rc) goto out;
    }
    r->t_data = now_s() - t1;
    rc = RC_OK;
out:
    if (rc && armed) {                       /* never leave the capture armed behind an error */
        int32_t save_r = ctl->retries;
        if (ctl->retries > 2) ctl->retries = 2;
        reg_xfer(&s, OP_WRITE, R_COMMAND, 32, NULL);
        ctl->retries = save_r;
    }
    set_nonblocking(ctl, 0);
    tl_cb3 = NULL;
    if (r->t_control == 0.0) r->t_control = now_s() - t0;
    return rc;
}

typedef struct {
    uint32_t base;
    int32_t pooled;          /* write TX_MODE */
    uint32_t tx_mode, length_beats, final_mask;
    int32_t n_slots;
    int32_t slot[8];
    uint32_t crc_expected[8];
    int64_t nwords;
    int32_t verify;
    int32_t words_per_packet, batch_packets, batches_in_flight;
    double cmd_timeout_s;
} awg_load_args;

/* Awg.load_words() on the bulk path: stop, clear, mask 0, (mode), length, then per slot select +
 * TXW + CRC check (up to 3 attempts), then the final mask. */
EXPORT int awg_load(awg_ctx *ctl, awg_ctx *blk, const awg_load_args *a, const uint32_t **words,
                    awg_cb3 cb, awg_seq_result *r) {
    init_clock();
    memset(r, 0, sizeof *r);
    if (a->n_slots < 1 || a->n_slots > 8) return RC_ARGS;
    seq_t s = {ctl, a->base, a->cmd_timeout_s, r, 0, 0};
    double t0 = now_s();
    int rc;
    seq_cb_begin(cb);
    set_nonblocking(ctl, 1);
    if ((rc = command(&s, 1))) goto out;                       /* stop */
    if ((rc = command(&s, 4))) goto out;                       /* clear */
    if ((rc = wr(&s, R_TX_MASK, 0))) goto out;
    if (a->pooled && (rc = wr(&s, R_TX_MODE, a->tx_mode))) goto out;
    if ((rc = wr(&s, R_TX_LENGTH, a->length_beats))) goto out;
    for (int i = 0; i < a->n_slots; i++) {
        for (int attempt = 0; attempt < 3; attempt++) {
            if ((rc = wr(&s, R_TX_WR_CH, (uint32_t)a->slot[i]))) goto out;
            double t1 = now_s();
            tl_index = i;
            rc = awg_txw(blk, a->slot[i], words[i], a->nwords, a->words_per_packet, a->batch_packets,
                         a->batches_in_flight, cb ? cb3_adapter : NULL);
            r->t_data += now_s() - t1;
            if (rc) goto out;
            if (!a->verify) break;
            if ((rc = command(&s, 16))) goto out;
            if ((rc = rd(&s, R_TX_CRC, &r->crc_actual[i]))) goto out;
            if (r->crc_actual[i] == a->crc_expected[i]) break;
            if (attempt == 2) {
                rc = fail(&s, D_CRC, r->crc_actual[i], (uint32_t)i);
                goto out;
            }
            r->crc_retries++;
        }
    }
    if ((rc = wr(&s, R_TX_MASK, a->final_mask))) goto out;
    rc = RC_OK;
out:
    set_nonblocking(ctl, 0);
    tl_cb3 = NULL;
    r->t_control = now_s() - t0 - r->t_data;
    return rc;
}

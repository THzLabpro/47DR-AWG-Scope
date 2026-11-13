#include "xparameters.h"
#include "xuartps_hw.h"
#include "xil_cache.h"
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <metal/log.h>

static void awg_metal_log(enum metal_log_level level, const char *format, ...)
{
    va_list args;
    (void)level;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
}

void awg_enable_driver_log(void)
{
    metal_set_log_handler(awg_metal_log);
    metal_set_log_level(METAL_LOG_INFO);
}

/* Preserve the startup transcript for read-only JTAG diagnostics even when
 * the single-client UART TCP bridge belongs to the MATLAB GUI. */
volatile char awg_init_log[65536] __attribute__((aligned(64)));
volatile uint32_t awg_init_log_length __attribute__((aligned(64)));

/* libxil's read() needs inbyte; providing it here keeps the SDT libxil object
 * that also defines outbyte out of the link. Same behaviour as XUartPs_RecvByte. */
char inbyte(void)
{
    while (!XUartPs_IsReceiveData(STDIN_BASEADDRESS)) {
    }
    return (char)XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET);
}

void outbyte(char c)
{
    uint32_t n = awg_init_log_length;
    if (n < sizeof(awg_init_log) - 1U) {
        awg_init_log[n] = c;
        awg_init_log[n + 1U] = '\0';
        Xil_DCacheFlushRange((INTPTR)&awg_init_log[n], 2U);
        awg_init_log_length = n + 1U;
        Xil_DCacheFlushRange((INTPTR)&awg_init_log_length,
                            sizeof(awg_init_log_length));
    }
    /* Same as XUartPs_SendByte, done with the header macros: in SDT BSPs that
     * function shares an object with libxil's outbyte, which would collide. */
    while (XUartPs_IsTransmitFull(STDOUT_BASEADDRESS)) {
    }
    XUartPs_WriteReg(STDOUT_BASEADDRESS, XUARTPS_FIFO_OFFSET, (u32)c);
}

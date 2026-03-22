/* SPDX-License-Identifier: MIT */
/*
 * Minimal RK3506 M0 firmware — UART4 hello world + GPIO heartbeat.
 *
 * Pin assignments (matching vendor AMP demo):
 *   UART4 TX → GPIO0_A2 (RMIO2)
 *   UART4 RX → GPIO0_A3 (RMIO3)
 *   Heartbeat → GPIO0_A4 (plain GPIO output, blink forever)
 *
 * No HAL, no SDK.  Raw MMIO only.
 *
 * Assumes UART4 SCLK is either already running or we configure it
 * ourselves via CRU (24 MHz oscillator, divisor 1 for 1.5 Mbaud).
 */

#include <stdint.h>

/* ── Register access helpers ────────────────────────────────────── */

#define REG32(addr)        (*(volatile uint32_t *)(addr))

/* ── UART4 (Synopsys DesignWare 16550) ──────────────────────────── */

#define UART4_BASE          0xFF0E0000U

#define UART_THR            0x00
#define UART_DLL            0x00
#define UART_DLH            0x04
#define UART_IER            0x04
#define UART_FCR            0x08
#define UART_LCR            0x0C
#define UART_MCR            0x10
#define UART_LSR            0x14
#define UART_SRR            0x88

#define UART_LCR_DLAB       (1 << 7)
#define UART_LCR_WLEN8      0x03
#define UART_LSR_THRE       (1 << 5)
#define UART_LSR_TEMT       (1 << 6)
#define UART_FCR_FIFO_EN    (1 << 0)
#define UART_FCR_RXCLR      (1 << 1)
#define UART_FCR_TXCLR      (1 << 2)
#define UART_SRR_UR         (1 << 0)
#define UART_SRR_RFR        (1 << 1)
#define UART_SRR_XFR        (1 << 2)

/* ── Pin mux: GPIO0_A2 → UART4_TX, GPIO0_A3 → UART4_RX ─────── */

/*
 * GPIO0_IOC @ 0xFF950000
 * GPIO0A_IOMUX_SEL_0 (+0x00): A0-A3, 4 bits per pin
 *   GPIO0A2: bits [11:8]   → mux 7 (RMIO)
 *   GPIO0A3: bits [15:12]  → mux 7 (RMIO)
 *
 * GPIO0A_IOMUX_SEL_1 (+0x04): A4-A7, 4 bits per pin
 *   GPIO0A4: bits [3:0]    → mux 0 (GPIO function)
 */
#define GPIO0_IOC_BASE      0xFF950000U
#define GPIO0A_IOMUX_SEL_0  (GPIO0_IOC_BASE + 0x00)
#define GPIO0A_IOMUX_SEL_1  (GPIO0_IOC_BASE + 0x04)

/* GPIO0A2: bits [11:8], write-mask [27:24] */
#define GPIO0A2_SEL_SHIFT   8
#define GPIO0A2_SEL_MASK    (0xFU << (GPIO0A2_SEL_SHIFT + 16))
#define GPIO0A2_MUX_RMIO    (7U << GPIO0A2_SEL_SHIFT)

/* GPIO0A3: bits [15:12], write-mask [31:28] */
#define GPIO0A3_SEL_SHIFT   12
#define GPIO0A3_SEL_MASK    (0xFU << (GPIO0A3_SEL_SHIFT + 16))
#define GPIO0A3_MUX_RMIO    (7U << GPIO0A3_SEL_SHIFT)

/* GPIO0A4: bits [3:0] in SEL_1, write-mask [19:16] */
#define GPIO0A4_SEL_SHIFT   0
#define GPIO0A4_SEL_MASK    (0xFU << (GPIO0A4_SEL_SHIFT + 16))
#define GPIO0A4_MUX_GPIO    (0U << GPIO0A4_SEL_SHIFT)

/*
 * RMIO: RM_IO_BASE = 0xFF910000
 *   rm_gpio0a2_sel @ +0x0088
 *   rm_gpio0a3_sel @ +0x008C
 *
 * 7-bit field [6:0], write-mask [22:16]
 */
#define RM_IO_BASE           0xFF910000U
#define RM_GPIO0A2_SEL       (RM_IO_BASE + 0x0088)
#define RM_GPIO0A3_SEL       (RM_IO_BASE + 0x008C)

#define RMIO_UART4_TX        0x09
#define RMIO_UART4_RX        0x0A
#define RMIO_WRITE_MASK      (0x7FU << 16)

/* ── GPIO0: heartbeat on A4 ─────────────────────────────────────── */

/*
 * Rockchip V2 GPIO: write-masked DR/DDR registers.
 * SWPORT_DR_L  (+0x00): data output, pins 0-15, write-mask in [31:16]
 * SWPORT_DDR_L (+0x08): direction,   pins 0-15, write-mask in [31:16]
 *   1 = output, 0 = input
 *
 * GPIO0_A4 = bit 4
 */
#define GPIO0_BASE           0xFF940000U
#define GPIO0_DR_L           (GPIO0_BASE + 0x00)
#define GPIO0_DDR_L          (GPIO0_BASE + 0x08)

#define GPIO0A4_BIT          (1U << 4)
#define GPIO0A4_WMASK        (GPIO0A4_BIT << 16)

/* ── CRU ─────────────────────────────────────────────────────────── */

#define CRU_BASE             0xFF9A0000U
#define CRU_GATE_CON11       (CRU_BASE + 0x82CU)
#define CRU_CLKSEL_CON31     (CRU_BASE + 0x37CU)

/* ── Helpers ─────────────────────────────────────────────────────── */

static void uart4_putc(char c)
{
    while (!(REG32(UART4_BASE + UART_LSR) & UART_LSR_THRE))
        ;
    REG32(UART4_BASE + UART_THR) = (uint32_t)c;
}

static void uart4_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart4_putc('\r');
        uart4_putc(*s++);
    }
}

static void uart4_flush(void)
{
    while (!(REG32(UART4_BASE + UART_LSR) & UART_LSR_TEMT))
        ;
}

/* ── Pin mux ─────────────────────────────────────────────────────── */

static void pinmux_uart4(void)
{
    /* IOMUX: GPIO0_A2 → func 7 (RMIO) */
    REG32(GPIO0A_IOMUX_SEL_0) = GPIO0A2_SEL_MASK | GPIO0A2_MUX_RMIO;

    /* IOMUX: GPIO0_A3 → func 7 (RMIO) */
    REG32(GPIO0A_IOMUX_SEL_0) = GPIO0A3_SEL_MASK | GPIO0A3_MUX_RMIO;

    /* RMIO: route to UART4 TX/RX */
    REG32(RM_GPIO0A2_SEL) = RMIO_WRITE_MASK | RMIO_UART4_TX;
    REG32(RM_GPIO0A3_SEL) = RMIO_WRITE_MASK | RMIO_UART4_RX;
}

static void pinmux_heartbeat(void)
{
    /* IOMUX: GPIO0_A4 → func 0 (GPIO) */
    REG32(GPIO0A_IOMUX_SEL_1) = GPIO0A4_SEL_MASK | GPIO0A4_MUX_GPIO;

    /* Direction: output */
    REG32(GPIO0_DDR_L) = GPIO0A4_WMASK | GPIO0A4_BIT;

    /* Start low */
    REG32(GPIO0_DR_L) = GPIO0A4_WMASK | 0;
}

/* ── CRU: UART4 clocks ──────────────────────────────────────────── */

static void cru_ungate_uart4(void)
{
    uint32_t mask = (1U << (8 + 16)) | (1U << (13 + 16));
    REG32(CRU_GATE_CON11) = mask;
}

static void cru_set_uart4_clk_24m(void)
{
    uint32_t val = 0;
    val |= (0x1FU << 24);   /* write-enable DIV [12:8] */
    val |= (0x7U << 29);    /* write-enable SEL [15:13] */
    val |= (2U << 13);      /* SEL = 2 (24M OSC) */
    REG32(CRU_CLKSEL_CON31) = val;
}

/* ── UART4 init ──────────────────────────────────────────────────── */

static void uart4_init(uint32_t clk_hz, uint32_t baud)
{
    uint32_t divisor = clk_hz / 16 / baud;

    REG32(UART4_BASE + UART_SRR) = UART_SRR_UR | UART_SRR_RFR | UART_SRR_XFR;
    for (volatile int i = 0; i < 100; i++)
        ;

    REG32(UART4_BASE + UART_FCR) = UART_FCR_FIFO_EN | UART_FCR_RXCLR | UART_FCR_TXCLR;
    REG32(UART4_BASE + UART_LCR) = UART_LCR_WLEN8 | UART_LCR_DLAB;
    REG32(UART4_BASE + UART_DLL) = divisor & 0xFF;
    REG32(UART4_BASE + UART_DLH) = (divisor >> 8) & 0xFF;
    REG32(UART4_BASE + UART_LCR) = UART_LCR_WLEN8;
    REG32(UART4_BASE + UART_MCR) = 0;
    REG32(UART4_BASE + UART_IER) = 0;
}

/* ── Delay ───────────────────────────────────────────────────────── */

static void delay_ms_approx(uint32_t ms)
{
    /*
     * M0 runs at ~200 MHz. A tight loop iteration is ~4 cycles.
     * 200000000 / 4 = 50000000 iterations/sec = 50000 iterations/ms.
     * This is approximate — no SysTick, no calibration, just vibes.
     */
    volatile uint32_t count = ms * 50000;
    while (count--)
        ;
}

/* ── Entry point ─────────────────────────────────────────────────── */

int main(void)
{
    /* Clock setup */
    cru_ungate_uart4();
    cru_set_uart4_clk_24m();

    /* Pin mux */
    pinmux_uart4();
    pinmux_heartbeat();

    /* UART4: 24 MHz / 16 / 1500000 = 1 */
    uart4_init(24000000, 1500000);

    uart4_puts("finix m0: hello from RK3506 Cortex-M0\n");
    uart4_puts("finix m0: UART4 on GPIO0_A2 (TX) / GPIO0_A3 (RX)\n");
    uart4_puts("finix m0: heartbeat on GPIO0_A4\n");
    uart4_flush();

    /* Blink forever */
    uint32_t n = 0;
    while (1) {
        /* Toggle GPIO0_A4 */
        REG32(GPIO0_DR_L) = GPIO0A4_WMASK | GPIO0A4_BIT;
        delay_ms_approx(500);

        REG32(GPIO0_DR_L) = GPIO0A4_WMASK | 0;
        delay_ms_approx(500);

        /* Periodic sign-of-life on UART */
        if ((n++ & 0x7) == 0) {
            uart4_putc('.');
        }
    }

    return 0;
}

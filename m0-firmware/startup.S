/* SPDX-License-Identifier: MIT */
/*
 * Minimal Cortex-M0 startup for RK3506 bus_m0 core.
 * No HAL, no copy table — just zero BSS and go.
 */

                .syntax  unified
                .arch    armv6-m

/* ── Vector table ───────────────────────────────────────────────── */
                .section .vectors, "a"
                .align   2
                .globl   __Vectors
__Vectors:
                .long    __StackTop            /*  0  Initial SP              */
                .long    Reset_Handler         /*  1  Reset                   */
                .long    Default_Handler       /*  2  NMI                     */
                .long    Default_Handler       /*  3  HardFault               */
                .long    0                     /*  4  Reserved (no MemManage on M0) */
                .long    0                     /*  5  Reserved (no BusFault)  */
                .long    0                     /*  6  Reserved (no UsageFault)*/
                .long    0                     /*  7  Reserved                */
                .long    0                     /*  8  Reserved                */
                .long    0                     /*  9  Reserved                */
                .long    0                     /* 10  Reserved                */
                .long    Default_Handler       /* 11  SVCall                  */
                .long    0                     /* 12  Reserved (no DebugMon)  */
                .long    0                     /* 13  Reserved                */
                .long    Default_Handler       /* 14  PendSV                  */
                .long    Default_Handler       /* 15  SysTick                 */

                /* External interrupts 0..63 — unused, but space reserved
                   so the vector table is the right size for INTMUX outputs */
                .space   (64 * 4)

/* ── Resource table (required by Linux remoteproc framework) ────── */
                .section .resource_table, "a"
                .align   2
                .globl   __resource_table
__resource_table:
                /* struct resource_table header */
                .long    1              /* version */
                .long    1              /* num entries */
                .long    0              /* reserved[0] */
                .long    0              /* reserved[1] */
                .long    20             /* offset[0] — points to carveout below */

                /* struct fw_rsc_carveout */
                .long    0              /* type = RSC_CARVEOUT */
                .long    0xFFF84000     /* da — device address (physical SRAM) */
                .long    0xFFF84000     /* pa — physical address */
                .long    0x8000         /* len — 32 KiB */
                .long    0              /* flags */
                .long    0              /* reserved */
                /* name[32] = "text\0..." (must be exactly 32 bytes) */
                .ascii   "text\0\0\0\0\0\0\0\0\0\0\0\0"
                .ascii   "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
__resource_table_end:

/* ── Reset handler ──────────────────────────────────────────────── */
                .thumb
                .section .text
                .align   2

                .thumb_func
                .globl   Reset_Handler
                .type    Reset_Handler, %function
Reset_Handler:
                /* Zero BSS */
                ldr      r1, =__bss_start__
                ldr      r2, =__bss_end__
                movs     r0, #0
.L_zero_bss:
                cmp      r1, r2
                bge      .L_zero_done
                str      r0, [r1]
                adds     r1, #4
                b        .L_zero_bss
.L_zero_done:
                /* Set MSP (belt-and-suspenders; hardware already loaded it) */
                ldr      r0, =__StackTop
                msr      msp, r0

                bl       main
                /* If main returns, spin */
.L_hang:
                wfi
                b        .L_hang

                .size    Reset_Handler, . - Reset_Handler

/* ── Default handler (infinite loop) ────────────────────────────── */
                .thumb_func
                .weak    Default_Handler
                .type    Default_Handler, %function
Default_Handler:
                b        .
                .size    Default_Handler, . - Default_Handler

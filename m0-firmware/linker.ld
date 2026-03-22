/* SPDX-License-Identifier: MIT */
/*
 * Linker script for RK3506 Cortex-M0 (bus_m0).
 *
 * The M0 sees its 48 KiB SRAM at 0x00000000 (remapped from physical
 * 0xFFF80000).  We use the first 32 KiB for code+data+stack, matching
 * the vendor gcc_bus_m0.ld.  The remaining 16 KiB is left free for
 * future shared-memory or rpmsg buffers.
 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

ENTRY(Reset_Handler)

__STACK_SIZE = 0x400;   /* 1 KiB — plenty for a hello-world */

SECTIONS
{
    .text :
    {
        KEEP(*(.vectors))
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
    } > RAM

    .resource_table :
    {
        KEEP(*(.resource_table))
        . = ALIGN(4);
    } > RAM

    .data :
    {
        . = ALIGN(4);
        *(.data)
        *(.data.*)
        . = ALIGN(4);
    } > RAM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start__ = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end__ = .;
    } > RAM

    _end = .;

    /* Stack lives at the top of RAM */
    __StackTop = ORIGIN(RAM) + LENGTH(RAM);
    __StackLimit = __StackTop - __STACK_SIZE;

    /* Sanity: fail the link if code+data overlap the stack */
    ASSERT(_end <= __StackLimit, "ERROR: .text+.data+.bss overflows into stack")
}

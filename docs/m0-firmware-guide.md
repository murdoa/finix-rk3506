# RK3506 Cortex-M0 Firmware Development Guide

Everything you need to write bare-metal firmware for the RK3506's Cortex-M0 core.
No Linux kernel knowledge required — this is pure embedded.

## The hardware

The RK3506 has a single **ARM Cortex-M0** core alongside three Cortex-A7 cores.
The M0 runs at 200 MHz from a 24 MHz oscillator. It has:

- **48 KiB SRAM** at physical `0xFFF80000`–`0xFFF8BFFF`
- **No DRAM access** — the M0's bus master is not connected to the DDR controller
- **Full peripheral access** — same MMIO address space as the A7 (GPIO, UART, SPI, I2C, timers, etc.)
- **Address remapping** — after the SIP call, the M0 sees its SRAM at `0x00000000`

### Memory map (from the M0's perspective)

After the remoteproc driver starts the M0, the address remap is active:

| M0 address       | Physical address    | Size   | Description            |
|-------------------|---------------------|--------|------------------------|
| `0x00000000`      | `0xFFF84000`        | 32 KiB | Code + data (TCM)      |
| `0x00008000`      | `0xFFF88000`        | 16 KiB | Additional SRAM        |
| `0xFF000000`+     | same                | —      | Peripherals (MMIO)     |

The first 16 KiB of physical SRAM (`0xFFF80000`–`0xFFF83FFF`) is reserved and not
available to firmware. The remoteproc driver loads firmware starting at `0xFFF84000`.

Peripheral registers are at their **physical addresses** — no remapping. The M0
accesses `0xFF0E0000` for UART4, `0xFF940000` for GPIO0, etc., same as Linux.

## ELF structure

The remoteproc framework loads ELF files, not raw binaries. Your ELF must have:

### 1. Vector table at address 0x00000000

The Cortex-M0 boots by reading two words from address 0:

| Offset | Content                          |
|--------|----------------------------------|
| 0x00   | Initial stack pointer (SP)       |
| 0x04   | Reset vector (entry point, Thumb bit set) |
| 0x08   | NMI handler                      |
| 0x0C   | HardFault handler                |
| 0x10+  | Reserved / SVCall / PendSV / SysTick / external IRQs |

The vector table must be placed in a section that links to address `0x00000000`.
We use a `.vectors` section with `KEEP()` in the linker script.

**Important**: All function pointers in the vector table must have bit 0 set
(Thumb bit). The assembler handles this automatically when you use `.long
Reset_Handler` and the symbol is defined with `.thumb_func`.

### 2. Resource table (required by Linux remoteproc)

The kernel's `rproc_elf_load_rsc_table()` searches for a section named exactly
**`.resource_table`**. If it doesn't find one, firmware loading fails with
`-EINVAL`.

A minimal resource table declares a single memory carveout:

```asm
.section .resource_table, "a"
.align   2
.globl   __resource_table
__resource_table:
    /* struct resource_table header */
    .long    1              /* version */
    .long    1              /* num entries */
    .long    0              /* reserved[0] */
    .long    0              /* reserved[1] */
    .long    20             /* offset[0] — byte offset to first entry */

    /* struct fw_rsc_carveout (type 0) */
    .long    0              /* type = RSC_CARVEOUT */
    .long    0xFFF84000     /* da — device address (physical SRAM) */
    .long    0xFFF84000     /* pa — physical address */
    .long    0x8000         /* len — 32 KiB */
    .long    0              /* flags */
    .long    0              /* reserved */
    /* name[32] — must be exactly 32 bytes */
    .ascii   "text\0\0\0\0\0\0\0\0\0\0\0\0"
    .ascii   "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
```

The `da` (device address) field tells remoteproc which physical address this
memory region maps to. The driver's `da_to_va()` callback translates between
ELF load addresses (0-based) and the ioremapped SRAM pointer.

### 3. Program headers

The ELF must have `LOAD` segments with virtual addresses in the `0x00000000`–
`0x00007FFF` range (the M0's remapped view of SRAM). The remoteproc driver's
`da_to_va()` handles the translation:

- `0x0000`–`0x7FFF` → TCM (SRAM at `0xFFF84000`)
- `0x03C00000`–`0x03CFFFFF` → shared memory region (if mapped)

## Linker script

```ld
MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

ENTRY(Reset_Handler)

__STACK_SIZE = 0x400;   /* 1 KiB */

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

    __StackTop = ORIGIN(RAM) + LENGTH(RAM);
    __StackLimit = __StackTop - __STACK_SIZE;

    ASSERT(_end <= __StackLimit, "ERROR: code+data overflows into stack")
}
```

Key points:
- **`ORIGIN = 0x00000000`** — the M0's view after address remap
- **`LENGTH = 32K`** — usable TCM region (`0xFFF84000`–`0xFFF8BFFF`)
- **`KEEP(*(.vectors))`** — prevent garbage collection of the vector table
- **`KEEP(*(.resource_table))`** — prevent garbage collection of the resource table
- **Stack at top of RAM** — grows downward from `0x8000`

## Startup code

Minimal startup in assembly. The M0 hardware reads the vector table to set SP and
jump to the reset handler, so `Reset_Handler` is the true entry point:

```asm
.syntax  unified
.arch    armv6-m

.section .vectors, "a"
.align   2
.globl   __Vectors
__Vectors:
    .long    __StackTop          /* Initial SP */
    .long    Reset_Handler       /* Reset */
    .long    Default_Handler     /* NMI */
    .long    Default_Handler     /* HardFault */
    .space   (7 * 4)             /* Reserved */
    .long    Default_Handler     /* SVCall */
    .space   (2 * 4)             /* Reserved */
    .long    Default_Handler     /* PendSV */
    .long    Default_Handler     /* SysTick */
    .space   (64 * 4)            /* External IRQs 0-63 */

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
    ldr      r0, =__StackTop
    msr      msp, r0
    bl       main
.L_hang:
    wfi
    b        .L_hang

.thumb_func
.weak    Default_Handler
.type    Default_Handler, %function
Default_Handler:
    b        .
```

## Building

### Toolchain

Use `arm-none-eabi-gcc` (bare-metal ARM GCC). In Nix:

```nix
nativeBuildInputs = [ pkgs.gcc-arm-embedded ];
```

### Compiler flags

```
CFLAGS  = -mcpu=cortex-m0 -mthumb -Os -std=c99 -Wall -Wextra -Werror -g
CFLAGS += -ffreestanding -ffunction-sections -fdata-sections

LDFLAGS = -mcpu=cortex-m0 -mthumb --specs=nosys.specs -nostartfiles
LDFLAGS += -Wl,--gc-sections -Wl,-T,linker.ld
```

- **`-mcpu=cortex-m0 -mthumb`** — target the M0's ARMv6-M ISA (Thumb only)
- **`--specs=nosys.specs`** — don't link system calls (no OS)
- **`-nostartfiles`** — we provide our own startup code
- **`-Wl,--gc-sections`** — discard unused functions (with `-ffunction-sections`)

### Build commands

```bash
arm-none-eabi-gcc $CFLAGS -c startup.S -o startup.o
arm-none-eabi-gcc $CFLAGS -c main.c -o main.o
arm-none-eabi-gcc $LDFLAGS startup.o main.o -o firmware.elf -lc -lm -lgcc
```

The output is an ELF. No `objcopy -O binary` needed — remoteproc loads ELFs
directly.

## Verifying the ELF

Before deploying, check your ELF is structurally correct:

```bash
# Entry point should be odd (Thumb bit) and in the 0x0000-0x7FFF range
arm-none-eabi-readelf -h firmware.elf | grep Entry

# LOAD segments should be at VirtAddr 0x00000000
arm-none-eabi-readelf -l firmware.elf

# Vector table: word 0 = SP (e.g. 0x8000), word 1 = Reset_Handler (odd)
arm-none-eabi-objdump -s -j .text firmware.elf | head -6

# Resource table must exist
arm-none-eabi-readelf -S firmware.elf | grep resource_table

# Disassemble to sanity check
arm-none-eabi-objdump -d -Mforce-thumb firmware.elf | head -40
```

### What correct looks like

```
Entry point address:               0x141     (odd = Thumb ✓)

Program Headers:
  Type   Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
  LOAD   0x001000 0x00000000 0x00000000 0x00398 0x00398 R E 0x1000

Contents of section .text:
 0000 00800000 41010000 ...    ← SP=0x8000, Reset=0x141
```

## Peripheral access

The M0 accesses peripherals at their physical MMIO addresses. No special mapping
needed — just cast the address to a volatile pointer:

```c
#define REG32(addr) (*(volatile uint32_t *)(addr))

/* Example: toggle GPIO0_A4 */
#define GPIO0_BASE  0xFF940000
#define GPIO0_DR_L  (GPIO0_BASE + 0x00)
#define GPIO0_DDR_L (GPIO0_BASE + 0x08)

/* Set A4 as output (bit 4, write-mask in upper 16 bits) */
REG32(GPIO0_DDR_L) = (1u << 20) | (1u << 4);

/* Set A4 high */
REG32(GPIO0_DR_L)  = (1u << 20) | (1u << 4);

/* Set A4 low */
REG32(GPIO0_DR_L)  = (1u << 20) | 0;
```

### Important: Rockchip write-mask registers

Many RK3506 registers use a **write-mask** scheme: the upper 16 bits are a mask
that enables writes to the corresponding lower 16 bits. If you don't set the
mask bits, your write is ignored.

```
Bits [31:16] = write enable mask
Bits [15:0]  = value

To set bit N:     write (1 << (N+16)) | (1 << N)
To clear bit N:   write (1 << (N+16)) | 0
```

This applies to GPIO data/direction registers, CRU gate/reset registers, GRF
mux registers, and IOC registers.

### Pin muxing

RK3506 uses two-level pin muxing:

1. **IOMUX** — selects the pin function (GPIO, UART, SPI, etc.)
   - GPIO0_IOC at `0xFF950000`, GPIO1_IOC at `0xFF4D8000`
   - 4 bits per pin, function 0 = GPIO, function 7 = RMIO

2. **RMIO** (Reconfigurable Multiplexed I/O) — selects which peripheral gets
   routed to a pin when IOMUX is set to function 7
   - RM_IO base at `0xFF910000`
   - 7-bit field per pin, with write-mask in bits [22:16]
   - Values like `0x09` = UART4_TX, `0x0A` = UART4_RX

### Clocks

The M0 firmware must enable clocks for any peripheral it uses. Linux will have
disabled unused clocks before the M0 starts.

CRU (Clock and Reset Unit) base: `0xFF9A0000`

```c
/* CRU_GATE_CONxx — write-mask register
 * Bit N in [15:0]: 0=clock enabled, 1=clock gated
 * Bit N+16 in [31:16]: write-enable for bit N
 *
 * To ungate (enable) bit N: write (1 << (N+16)) | 0
 * To gate (disable) bit N:  write (1 << (N+16)) | (1 << N)
 */
```

Example: ungate UART4 clocks (SCLK_UART4 and PCLK_UART4 in CRU_GATE_CON11):
```c
#define CRU_BASE        0xFF9A0000
#define CRU_GATE_CON11  (CRU_BASE + 0x82C)

/* Bits 8 (SCLK_UART4) and 13 (PCLK_UART4) — ungate both */
REG32(CRU_GATE_CON11) = (1u << 24) | (1u << 29);  /* mask bits 8,13 */
```

## Constraints and gotchas

### No DRAM
The M0 cannot access DDR memory. All code and data must fit in the 32 KiB TCM.
If you need to exchange data with Linux, use a shared memory region in the
peripheral address space or use mailbox registers.

### Linux will stomp your pins
The kernel configures pin mux during boot. If Linux claims a pin your firmware
uses, the M0's pin mux writes get overridden. Solutions:
- Reserve pins in the device tree (`status = "disabled"` on conflicting nodes)
- Have the M0 firmware reconfigure pins after startup (works if Linux doesn't
  continuously reassert)
- Use the `rockchip-amp` DT node to tell Linux which peripherals the M0 owns

### Linux will gate your clocks
Same issue — Linux disables unused clocks. The remoteproc DT node's `clocks`
property keeps specified clocks enabled:

```dts
mcu_rproc: mcu@fff84000 {
    compatible = "rockchip,rk3506-mcu";
    clocks = <&cru HCLK_M0>, <&cru STCLK_M0>,
             <&cru SCLK_UART4>, <&cru PCLK_UART4>;  /* keep UART4 alive */
    ...
};
```

Or: have the firmware enable its own clocks via CRU register writes.

### SRAM becomes inaccessible after SIP call
Once the remoteproc driver makes the `SIP_MCU_CFG` call to remap SRAM to TCM
mode, Linux can no longer read or write the SRAM at `0xFFF84000`. This is
one-way until reboot. You cannot hot-swap firmware — you must reboot to reload.

### No debugger (yet)
SWD (Serial Wire Debug) pins exist on the RK3506 but the switch to enable them
is undocumented. nvitya suspects it's in SGRF_MPU (`0xFF960000`). For now,
debugging is printf-over-UART or GPIO toggling.

## Delay without timers

If you don't want to set up a hardware timer, a busy-loop works for approximate
delays:

```c
static void delay_ms_approx(uint32_t ms)
{
    /* M0 at ~200 MHz, ~4 cycles per loop iteration */
    volatile uint32_t count = ms * 50000;
    while (count--)
        ;
}
```

## Complete minimal example

A complete firmware that blinks GPIO0_A4:

**main.c:**
```c
#include <stdint.h>

#define REG32(addr)  (*(volatile uint32_t *)(addr))

#define GPIO0_BASE   0xFF940000
#define GPIO0_DR_L   (GPIO0_BASE + 0x00)
#define GPIO0_DDR_L  (GPIO0_BASE + 0x08)

#define BIT4         (1u << 4)
#define WMASK4       (BIT4 << 16)

static void delay(void)
{
    volatile uint32_t n = 5000000;
    while (n--) ;
}

int main(void)
{
    /* GPIO0_A4: output */
    REG32(GPIO0_DDR_L) = WMASK4 | BIT4;

    while (1) {
        REG32(GPIO0_DR_L) = WMASK4 | BIT4;  /* high */
        delay();
        REG32(GPIO0_DR_L) = WMASK4 | 0;     /* low */
        delay();
    }
}
```

Build with the startup.S, linker.ld, and resource table from this project's
`m0-firmware/` directory.

## Nix build

See `pkgs/m0-firmware-bin.nix` for the complete Nix derivation. It produces both
an ELF (for remoteproc) and a raw binary (for reference). The ELF is installed to
`/lib/firmware/rk3506-m0.elf`.

## Deploying

Place the ELF at `/lib/firmware/rk3506-m0.elf` on the target. The remoteproc
driver loads it automatically when the `rk3506_rproc` module probes against the
DT node.

To manually control:
```bash
# Check status
cat /sys/class/remoteproc/remoteproc0/state

# Stop
echo stop > /sys/class/remoteproc/remoteproc0/state

# Change firmware (while stopped)
echo new-firmware.elf > /sys/class/remoteproc/remoteproc0/firmware

# Start
echo start > /sys/class/remoteproc/remoteproc0/state
```

Note: due to the SIP call making SRAM inaccessible, stop+start doesn't work
without a reboot. This is a known limitation.

## References

- [nvitya/rk3506-mcu](https://github.com/nvitya/rk3506-mcu) — the remoteproc
  driver and test firmware this work is based on
- [VIHAL RK3506 drivers](https://github.com/nvitya/vihal) — nvitya's hardware
  abstraction library with RK3506 support
- Rockchip RK3506 TRM V1.2 — register definitions for all peripherals
- ARM Cortex-M0 Technical Reference Manual — vector table format, exception model

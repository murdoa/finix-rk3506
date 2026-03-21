# RK3506 Cortex-M0 Core

The RK3506 has a single Cortex-M0 core alongside three Cortex-A7 cores. The M0
runs independently — it has its own clock, reset, and JTAG — and communicates
with Linux via hardware mailboxes and shared memory.

## Hardware resources

| Resource         | Details                                             |
|------------------|-----------------------------------------------------|
| Clocks           | `HCLK_M0` (id 74), `STCLK_M0` (id 104)            |
| Resets           | `SRST_H_M0` (id 90), `SRST_M0_JTAG` (id 91), `SRST_HRESETN_M0_AC` (id 10) |
| Mailboxes        | 4× at `0xff290000`–`0xff293000`, SPI 138–141        |
| Mailbox compat   | `rockchip,rk3506-mailbox`, `rockchip,rk3576-mailbox` |

The M0's SRAM base address and size are in the TRM (`docs/ignored/Rockchip RK3506
TRM V1.2 Part1.pdf`). These need to be confirmed before writing a linker script.

## Boot mechanism

The M0 is **not** booted directly by Linux. The flow is:

1. Linux's `rockchip_amp` driver (`drivers/soc/rockchip/rockchip_amp.c`) enables
   clocks and power domains for the M0.
2. The driver calls into **OP-TEE** via `sip_smc_amp_config(RK_AMP_SUB_FUNC_CPU_ON,
   cpu_id, entry_address, 0)`.
3. OP-TEE takes the M0 out of reset with the given entry point.

The driver reads CPU definitions from a DTS child node `amp-cpus`:

```dts
rockchip-amp {
    compatible = "rockchip,amp";
    clocks = <&cru HCLK_M0>, <&cru STCLK_M0>, <&cru PCLK_MAILBOX>;
    status = "okay";

    amp-cpus {
        m0 {
            id = <0x...>;        /* CPU ID — needs TRM */
            entry = <0x0 0x...>; /* physical load/entry address */
            mode = <0x...>;      /* AMP_FLAG_CPU_ARM32_T (BIT(3)) for Thumb M0 */
            boot-on = <1>;       /* 1 = start at driver probe, 0 = manual via sysfs */
        };
    };
};
```

The `mode` field uses flags: `AMP_FLAG_CPU_ARM32_T` (bit 3) for Cortex-M Thumb
mode. The M0's `id` value is SoC-specific and comes from the TRM.

### Manual control via sysfs

Once the driver probes, `/sys/rk_amp/amp_ctrl` accepts:
- `on <cpu_id>` — boot the M0
- `off <cpu_id>` — request M0 shutdown
- `status <cpu_id>` — query run state

## Communication: Linux ↔ M0

### Mailbox (low-latency signaling)

The 4 hardware mailboxes are doorbell-style: one side writes a 32-bit value, the
other gets an interrupt. No data payload beyond the register — use shared memory
for bulk transfer.

Kernel driver: `rockchip,rk3506-mailbox` (compatible with `rk3576-mailbox`
driver). Enable with `CONFIG_MAILBOX=y` + `CONFIG_ROCKCHIP_MBOX=y`.

### rpmsg (structured messaging)

`rockchip_rpmsg_softirq` provides an rpmsg transport over the mailbox. It uses
virtio rings in shared memory for variable-length messages. DTS binding:

```dts
rpmsg {
    compatible = "rockchip,rpmsg-softirq";
    rockchip,link-id = <0>;
    rockchip,vdev-nums = <1>;
    mboxes = <&mailbox0 0>;
    status = "okay";
};
```

Kernel config: `CONFIG_RPMSG_ROCKCHIP_SOFTIRQ=y`, `CONFIG_RPMSG_VIRTIO=y`.

### Shared memory

Reserve a region in the DTS that both sides can access:

```dts
reserved-memory {
    #address-cells = <1>;
    #size-cells = <1>;
    ranges;

    m0_reserved: m0@<addr> {
        reg = <0x.... 0x....>;
        no-map;
    };
};
```

The M0 firmware accesses this at the physical address directly. Linux can map it
via `/dev/mem` or a custom driver.

## Kernel config needed

Add to `structuredExtraConfig` in `pkgs/linux-rockchip-rk3506.nix`:

```nix
ROCKCHIP_AMP = yes;
MAILBOX = yes;
ROCKCHIP_MBOX = yes;
RPMSG_ROCKCHIP_SOFTIRQ = yes;
RPMSG_VIRTIO = yes;
```

## M0 firmware

The M0 firmware is a bare-metal or RTOS binary cross-compiled with
`arm-none-eabi-gcc` targeting `cortex-m0`. It needs:

- A **linker script** placing code at the M0's SRAM/entry address
- A **vector table** at the entry point (initial SP + reset handler, per ARM M-profile)
- Access to peripherals via MMIO (same physical address space as the A7 cores)

### Toolchain (Nix)

```nix
pkgs.pkgsCross.arm-embedded.buildPackages.gcc
# or
pkgs.gcc-arm-embedded
```

### RTOS options

- **FreeRTOS** — lightest, most examples for Rockchip M0 cores
- **Zephyr** — has Cortex-M0 support but no RK3506 board definition yet
- **RT-Thread** — Rockchip contributes to this, may have RK3506 BSP
- **Bare metal** — simplest for blinky / mailbox echo tests

### Rockchip HAL

Rockchip provides a HAL (hardware abstraction layer) for their MCU cores. The
RV1106 HAL is public and structurally similar. RK3506-specific register
definitions would need to come from:
- Luckfox SDK (if they publish M0 examples for Lyra)
- The TRM (register descriptions for GRF, CRU, GPIO from M0's perspective)
- Reverse-engineering

## What we don't know yet

- [ ] M0 CPU ID for the `amp-cpus` DTS node
- [ ] M0 SRAM base address and size (in TRM)
- [ ] Whether OP-TEE v2.10 on this board supports the AMP SIP calls
- [ ] Interrupt routing — which IRQs can be directed to the M0 vs A7
- [ ] Whether Luckfox has M0 examples for the Lyra (the luckfox-pico SDK is RV1103/RV1106 only)

## Minimal first test

A reasonable first goal: load a firmware that blinks or toggles a GPIO, proving
the M0 is alive. Then add mailbox echo (M0 receives a value via mailbox, sends
it back) to prove communication works.

// SPDX-License-Identifier: GPL-2.0
/*
 * Remote processor driver for the RK3506 Cortex-M0 core.
 *
 * Based on https://github.com/nvitya/rk3506-mcu by Viktor Nagy.
 * Adapted for finix-rk3506 NixOS builds.
 *
 * Loads ELF firmware into SRAM at 0xFFF84000 via the standard Linux
 * remoteproc framework (/sys/class/remoteproc/remoteproc0).
 *
 * Required device-tree node:
 *
 *   mcu_rproc: mcu@fff84000 {
 *       compatible = "rockchip,rk3506-mcu";
 *       reg = <0xfff84000 0x8000>;
 *       firmware-name = "rk3506-m0.elf";
 *       clocks = <&cru HCLK_M0>, <&cru STCLK_M0>;
 *       resets = <&cru SRST_H_M0>, <&cru SRST_M0_JTAG>,
 *                <&cru SRST_HRESETN_M0_AC>;
 *       reset-names = "h_m0", "m0_jtag", "hresetn_m0_ac";
 *   };
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/remoteproc.h>
#include <linux/of_device.h>
#include <linux/firmware.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/arm-smccc.h>
#include <linux/clk.h>
#include <linux/reset.h>
#include <linux/elf.h>

/* Forward declarations for remoteproc ELF helpers */
int rproc_elf_sanity_check(struct rproc *rproc, const struct firmware *fw);
u64 rproc_elf_get_boot_addr(struct rproc *rproc, const struct firmware *fw);
int rproc_elf_load_segments(struct rproc *rproc, const struct firmware *fw);
int rproc_elf_load_rsc_table(struct rproc *rproc, const struct firmware *fw);
struct resource_table *rproc_elf_find_loaded_rsc_table(struct rproc *rproc,
						       const struct firmware *fw);

/* ── Rockchip SIP call IDs ──────────────────────────────────────── */

#define SIP_MCU_CFG			0x82000028

#define ROCKCHIP_SIP_CONFIG_BUSMCU_0_ID		0x00
#define ROCKCHIP_SIP_CONFIG_MCU_CODE_START_ADDR	0x01

/* ── Hardware constants ─────────────────────────────────────────── */

#define RK3506_MCU_TCM_ADDR		0xFFF84000
#define RK3506_MCU_TCM_SIZE		0x8000		/* 32 KiB */

#define RK3506_MCU_SHMEM_ADDR		0x03C00000
#define RK3506_MCU_SHMEM_SIZE		0x100000	/* 1 MiB */

#define RK3506_PMU_BASE			0xFF900000
#define RK3506_CRU_BASE			0xFF9A0000
#define RK3506_GRF_BASE			0xFF288000

/* ── Driver state ───────────────────────────────────────────────── */

struct rk3506_mcu {
	struct rproc		*rproc;

	struct clk_bulk_data	*clks;
	int			num_clks;

	struct reset_control	*rst_h_m0;
	struct reset_control	*rst_m0_jtag;
	struct reset_control	*rst_hresetn_m0_ac;

	void __iomem		*tcm_virt;
	void __iomem		*shmem_virt;

	void __iomem		*regs_pmu;
	void __iomem		*regs_cru;
	void __iomem		*regs_grf;

	struct platform_device	*pdev;
};

/* ── M0 run/stop via PMU_INT_MASK_CON ───────────────────────────── */

static void rk3506_mcu_run(struct rk3506_mcu *mcu, bool run)
{
	if (run) {
		/* mcu_rst_dis_cfg=1, glb_int_mask_mcu=0 */
		writel(0x00060004, mcu->regs_pmu + 0x00C);
	} else {
		/* mcu_rst_dis_cfg=0, glb_int_mask_mcu=1 */
		writel(0x00060002, mcu->regs_pmu + 0x00C);
	}
}

/* ── Remoteproc ops ─────────────────────────────────────────────── */

static int rk3506_rproc_start(struct rproc *rproc)
{
	struct rk3506_mcu *mcu = rproc->priv;
	struct arm_smccc_res res;
	u32 entry = RK3506_MCU_TCM_ADDR;

	dev_info(&rproc->dev, "starting M0 at 0x%08X\n", entry);

	/*
	 * SIP call: configure address remap so M0 sees SRAM at 0x00000000.
	 * WARNING: after this call, SRAM at 0xFFF84000 becomes inaccessible
	 * from the A7 side (TCM mode).
	 */
	arm_smccc_smc(SIP_MCU_CFG, ROCKCHIP_SIP_CONFIG_BUSMCU_0_ID,
		      ROCKCHIP_SIP_CONFIG_MCU_CODE_START_ADDR,
		      entry, 0, 0, 0, 0, &res);
	if (res.a0) {
		dev_err(&rproc->dev, "SIP CODE_START_ADDR failed: %ld\n",
			(long)res.a0);
		return -EIO;
	}

	rk3506_mcu_run(mcu, true);
	return 0;
}

static int rk3506_rproc_stop(struct rproc *rproc)
{
	struct rk3506_mcu *mcu = rproc->priv;

	dev_info(&rproc->dev, "stopping M0\n");
	rk3506_mcu_run(mcu, false);
	return 0;
}

static void *rk3506_da_to_va(struct rproc *rproc, u64 da, size_t len,
			     bool *is_iomem)
{
	struct rk3506_mcu *mcu = rproc->priv;

	/* TCM: M0 sees 0x0000..0x7FFF */
	if (da + len <= RK3506_MCU_TCM_SIZE)
		return (__force void *)mcu->tcm_virt + da;

	/* Shared memory region */
	if (da >= RK3506_MCU_SHMEM_ADDR &&
	    da + len <= RK3506_MCU_SHMEM_ADDR + RK3506_MCU_SHMEM_SIZE)
		return (__force void *)mcu->shmem_virt + (da - RK3506_MCU_SHMEM_ADDR);

	dev_err(&rproc->dev, "invalid da 0x%llx len %zu\n", da, len);
	return NULL;
}

static const struct rproc_ops rk3506_rproc_ops = {
	.start			= rk3506_rproc_start,
	.stop			= rk3506_rproc_stop,
	.da_to_va		= rk3506_da_to_va,
	.load			= rproc_elf_load_segments,
	.find_loaded_rsc_table	= rproc_elf_find_loaded_rsc_table,
	.sanity_check		= rproc_elf_sanity_check,
	.get_boot_addr		= rproc_elf_get_boot_addr,
};

/* ── Probe / Remove ─────────────────────────────────────────────── */

static int rk3506_rproc_probe(struct platform_device *pdev)
{
	struct rproc *rproc;
	struct rk3506_mcu *mcu;
	const char *fw_name;
	int ret;

	ret = of_property_read_string(pdev->dev.of_node, "firmware-name",
				      &fw_name);
	if (ret) {
		dev_err(&pdev->dev, "missing firmware-name in DT\n");
		return ret;
	}

	rproc = rproc_alloc(&pdev->dev, dev_name(&pdev->dev),
			    &rk3506_rproc_ops, fw_name,
			    sizeof(struct rk3506_mcu));
	if (!rproc)
		return -ENOMEM;

	mcu = rproc->priv;
	mcu->rproc = rproc;
	mcu->pdev = pdev;

	/* Clocks from DT */
	mcu->num_clks = devm_clk_bulk_get_all(&pdev->dev, &mcu->clks);
	if (mcu->num_clks < 0) {
		dev_err(&pdev->dev, "failed to get clocks: %d\n", mcu->num_clks);
		ret = mcu->num_clks;
		goto err_free;
	}

	/* Memory mappings */
	mcu->tcm_virt = ioremap(RK3506_MCU_TCM_ADDR, RK3506_MCU_TCM_SIZE);
	if (!mcu->tcm_virt) {
		ret = -ENOMEM;
		goto err_free;
	}

	mcu->shmem_virt = ioremap(RK3506_MCU_SHMEM_ADDR, RK3506_MCU_SHMEM_SIZE);
	/* shmem is optional — don't fail if it can't be mapped */

	mcu->regs_pmu = ioremap(RK3506_PMU_BASE, 0x1000);
	mcu->regs_cru = ioremap(RK3506_CRU_BASE, 0x1000);
	mcu->regs_grf = ioremap(RK3506_GRF_BASE, 0x1000);
	if (!mcu->regs_pmu || !mcu->regs_cru || !mcu->regs_grf) {
		ret = -ENOMEM;
		goto err_unmap;
	}

	/* Ensure M0 is stopped before we load firmware */
	rk3506_mcu_run(mcu, false);

	/* Enable clocks */
	ret = clk_bulk_prepare_enable(mcu->num_clks, mcu->clks);
	if (ret) {
		dev_err(&pdev->dev, "failed to enable clocks: %d\n", ret);
		goto err_unmap;
	}

	/* Direct CRU writes for M0 hclk + swclktck (belt-and-suspenders) */
	writel(0x0c000000, mcu->regs_cru + 0x814);  /* CRU_GATE_CON5 */

	/* SysTick calibration value (from Rockchip U-Boot source) */
	writel(0x0bcd3d80, mcu->regs_grf + 0x090);  /* GRF_SOC_CON36 */

	/* Resets from DT */
	mcu->rst_h_m0 = devm_reset_control_get(&pdev->dev, "h_m0");
	if (IS_ERR(mcu->rst_h_m0)) {
		dev_err(&pdev->dev, "missing reset: h_m0\n");
		ret = PTR_ERR(mcu->rst_h_m0);
		goto err_clk;
	}

	mcu->rst_m0_jtag = devm_reset_control_get(&pdev->dev, "m0_jtag");
	if (IS_ERR(mcu->rst_m0_jtag)) {
		dev_err(&pdev->dev, "missing reset: m0_jtag\n");
		ret = PTR_ERR(mcu->rst_m0_jtag);
		goto err_clk;
	}

	mcu->rst_hresetn_m0_ac = devm_reset_control_get(&pdev->dev, "hresetn_m0_ac");
	if (IS_ERR(mcu->rst_hresetn_m0_ac)) {
		dev_err(&pdev->dev, "missing reset: hresetn_m0_ac\n");
		ret = PTR_ERR(mcu->rst_hresetn_m0_ac);
		goto err_clk;
	}

	/* Deassert all resets */
	reset_control_deassert(mcu->rst_m0_jtag);
	reset_control_deassert(mcu->rst_h_m0);
	reset_control_deassert(mcu->rst_hresetn_m0_ac);

	platform_set_drvdata(pdev, rproc);

	ret = rproc_add(rproc);
	if (ret)
		goto err_clk;

	return 0;

err_clk:
	clk_bulk_disable_unprepare(mcu->num_clks, mcu->clks);
err_unmap:
	if (mcu->tcm_virt)	iounmap(mcu->tcm_virt);
	if (mcu->shmem_virt)	iounmap(mcu->shmem_virt);
	if (mcu->regs_pmu)	iounmap(mcu->regs_pmu);
	if (mcu->regs_cru)	iounmap(mcu->regs_cru);
	if (mcu->regs_grf)	iounmap(mcu->regs_grf);
err_free:
	rproc_free(rproc);
	return ret;
}

static int rk3506_rproc_remove(struct platform_device *pdev)
{
	struct rproc *rproc = platform_get_drvdata(pdev);
	struct rk3506_mcu *mcu = rproc->priv;

	rk3506_rproc_stop(rproc);

	if (mcu->tcm_virt)	iounmap(mcu->tcm_virt);
	if (mcu->shmem_virt)	iounmap(mcu->shmem_virt);
	if (mcu->regs_pmu)	iounmap(mcu->regs_pmu);
	if (mcu->regs_cru)	iounmap(mcu->regs_cru);
	if (mcu->regs_grf)	iounmap(mcu->regs_grf);

	rproc_del(rproc);
	rproc_free(rproc);
	return 0;
}

static void rk3506_rproc_shutdown(struct platform_device *pdev)
{
	struct rproc *rproc = platform_get_drvdata(pdev);

	rk3506_rproc_stop(rproc);
}

static const struct of_device_id rk3506_rproc_match[] = {
	{ .compatible = "rockchip,rk3506-mcu" },
	{}
};
MODULE_DEVICE_TABLE(of, rk3506_rproc_match);

static struct platform_driver rk3506_rproc_driver = {
	.probe		= rk3506_rproc_probe,
	.remove		= rk3506_rproc_remove,
	.shutdown	= rk3506_rproc_shutdown,
	.driver = {
		.name		= "rk3506_mcu_rproc",
		.of_match_table	= rk3506_rproc_match,
	},
};

module_platform_driver(rk3506_rproc_driver);

MODULE_AUTHOR("Viktor Nagy <nvitya@gmail.com>");
MODULE_AUTHOR("finix");
MODULE_DESCRIPTION("RK3506 Cortex-M0 Remote Processor Driver");
MODULE_LICENSE("GPL v2");

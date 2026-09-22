// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2017 Microchip Corporation
 *		      Wenyou.Yang <wenyou.yang@microchip.com>
 */

#include <debug_uart.h>
#include <fdtdec.h>
#include <init.h>
#include <asm/global_data.h>
#include <asm/io.h>
#include <asm/arch/at91_common.h>
#include <asm/arch/atmel_pio4.h>
#include <asm/arch/atmel_mpddrc.h>
#include <asm/arch/atmel_sdhci.h>
#include <asm/arch/clk.h>
#include <asm/arch/gpio.h>
#include <asm/arch/sama5d2.h>
#include <dm.h>
#include <dm/uclass.h>
#include <spi.h>
#include <dm/device.h>
#include <dm/device-internal.h>
#include <env.h>
#include <linux/delay.h>

#define NEXTGEN_SCKC_OSCSEL		BIT(3)
#define NEXTGEN_SLOW_XTAL_MARGIN_MS	500

DECLARE_GLOBAL_DATA_PTR;

#ifdef CONFIG_BOARD_LATE_INIT
int board_late_init(void)
{
	struct udevice *bus, *child;
	int ret;

	ret = uclass_get_device_by_seq(UCLASS_SPI, 1, &bus);
	if (ret) {
		printf("SPI bus 1 not found: %d\n", ret);
		return 0;
	}

	device_foreach_child(child, bus) {
		if (ofnode_device_is_compatible(dev_ofnode(child),
						"sitronix,st7789v-rgb-init")) {
			ret = device_probe(child);
			// printf("ST7789 probe ret=%d\n", ret);
			break;
		}
	}

#ifdef CONFIG_VIDEO
	//at91_video_show_board_info();
#endif
	return 0;
}
#endif

#ifdef CONFIG_DEBUG_UART_BOARD_INIT
static void board_uart1_hw_init(void)
{
	atmel_pio4_set_a_periph(AT91_PIO_PORTD, 2, ATMEL_PIO_PUEN_MASK);	/* URXD1 */
	atmel_pio4_set_a_periph(AT91_PIO_PORTD, 3, 0);	/* UTXD1 */

	at91_periph_clk_enable(ATMEL_ID_UART1);
}

void board_debug_uart_init(void)
{
	board_uart1_hw_init();
}
#endif



int board_init(void)
{
	/* address of boot parameters */
	gd->bd->bi_boot_params = gd->bd->bi_dram[0].start + 0x100;


#ifdef CONFIG_CMD_USB
	board_usb_hw_init();
#endif
#ifdef CONFIG_NET
	const char *cp = env_get("ethaddr");
	if (cp)
		eth_env_set_enetaddr("ethaddr", cp);
#endif
	return 0;
}

int dram_init_banksize(void)
{
	return fdtdec_setup_memory_banksize();
}

int dram_init(void)
{
	return fdtdec_setup_mem_size_base();
}

/*
 * AT91Bootstrap may deliberately defer selection of the 32.768 kHz crystal
 * so its startup time overlaps useful U-Boot work.  OSCSEL is in the VDDBU
 * backed-up domain, so warm boots normally arrive here already on XTAL.
 */
void board_preboot_os(void)
{
	u32 sckcr = readl((void *)ATMEL_BASE_SCKC);

	if (sckcr & NEXTGEN_SCKC_OSCSEL)
		return;

	/*
	 * SAMA5D2 has no OSC32EN control here: the 32.768 kHz crystal
	 * oscillator starts from the VDDBU domain.  AT91Bootstrap's original
	 * path waited the full 1.2 s maximum before selecting it.  In the
	 * deferred profile that startup overlaps SD loading and U-Boot work;
	 * retain a conservative additional margin for the first cold-boot test.
	 */
	mdelay(NEXTGEN_SLOW_XTAL_MARGIN_MS);

	sckcr |= NEXTGEN_SCKC_OSCSEL;
	writel(sckcr, (void *)ATMEL_BASE_SCKC);

	/*
	 * Match the Linux/AT91 slow-clock driver: allow five 32.768 kHz
	 * cycles for internal resynchronisation after changing OSCSEL.
	 */
	udelay(153);
}


#define MAC24AA_MAC_OFFSET	0xfa

#ifdef CONFIG_MISC_INIT_R
int misc_init_r(void)
{
#ifdef CONFIG_I2C_EEPROM
	at91_set_ethaddr(MAC24AA_MAC_OFFSET);
#endif
	return 0;
}
#endif

/* SPL */
#ifdef CONFIG_XPL_BUILD
void spl_board_init(void)
{
}

static void ddrc_conf(struct atmel_mpddrc_config *ddrc)
{
	return;
	ddrc->md = (ATMEL_MPDDRC_MD_DBW_16_BITS | ATMEL_MPDDRC_MD_DDR2_SDRAM);

	ddrc->cr = (ATMEL_MPDDRC_CR_NC_COL_10 |
		    ATMEL_MPDDRC_CR_NR_ROW_13 |
		    ATMEL_MPDDRC_CR_CAS_DDR_CAS3 |
		    ATMEL_MPDDRC_CR_DIC_DS |
		    ATMEL_MPDDRC_CR_ZQ_LONG |
		    ATMEL_MPDDRC_CR_NB_8BANKS |
		    ATMEL_MPDDRC_CR_DECOD_INTERLEAVED |
		    ATMEL_MPDDRC_CR_UNAL_SUPPORTED);

	ddrc->rtr = 0x511;

	ddrc->tpr0 = ((7 << ATMEL_MPDDRC_TPR0_TRAS_OFFSET) |
		      (3 << ATMEL_MPDDRC_TPR0_TRCD_OFFSET) |
		      (3 << ATMEL_MPDDRC_TPR0_TWR_OFFSET) |
		      (9 << ATMEL_MPDDRC_TPR0_TRC_OFFSET) |
		      (3 << ATMEL_MPDDRC_TPR0_TRP_OFFSET) |
		      (4 << ATMEL_MPDDRC_TPR0_TRRD_OFFSET) |
		      (4 << ATMEL_MPDDRC_TPR0_TWTR_OFFSET) |
		      (2 << ATMEL_MPDDRC_TPR0_TMRD_OFFSET));

	ddrc->tpr1 = ((22 << ATMEL_MPDDRC_TPR1_TRFC_OFFSET) |
		      (23 << ATMEL_MPDDRC_TPR1_TXSNR_OFFSET) |
		      (200 << ATMEL_MPDDRC_TPR1_TXSRD_OFFSET) |
		      (3 << ATMEL_MPDDRC_TPR1_TXP_OFFSET));

	ddrc->tpr2 = ((2 << ATMEL_MPDDRC_TPR2_TXARD_OFFSET) |
		      (8 << ATMEL_MPDDRC_TPR2_TXARDS_OFFSET) |
		      (4 << ATMEL_MPDDRC_TPR2_TRPA_OFFSET) |
		      (4 << ATMEL_MPDDRC_TPR2_TRTP_OFFSET) |
		      (8 << ATMEL_MPDDRC_TPR2_TFAW_OFFSET));
}

void at91_mem_init(void)
{
	struct at91_pmc *pmc = (struct at91_pmc *)ATMEL_BASE_PMC;
	struct atmel_mpddr *mpddrc = (struct atmel_mpddr *)ATMEL_BASE_MPDDRC;
	struct atmel_mpddrc_config ddrc_config;
	u32 reg;

	ddrc_conf(&ddrc_config);

	at91_periph_clk_enable(ATMEL_ID_MPDDRC);
	writel(AT91_PMC_DDR, &pmc->scer);

	reg = readl(&mpddrc->io_calibr);
	reg &= ~ATMEL_MPDDRC_IO_CALIBR_RDIV;
	reg |= ATMEL_MPDDRC_IO_CALIBR_DDR3_RZQ_55;
	reg &= ~ATMEL_MPDDRC_IO_CALIBR_TZQIO;
	reg |= ATMEL_MPDDRC_IO_CALIBR_TZQIO_(101);
	writel(reg, &mpddrc->io_calibr);

	writel(ATMEL_MPDDRC_RD_DATA_PATH_SHIFT_ONE_CYCLE,
	       &mpddrc->rd_data_path);

	ddr3_init(ATMEL_BASE_MPDDRC, ATMEL_BASE_DDRCS, &ddrc_config);

	writel(0x3, &mpddrc->cal_mr4);
	writel(64, &mpddrc->tim_cal);
}

void at91_pmc_init(void)
{
	u32 tmp;

	/*
	 * while coming from the ROM code, we run on PLLA @ 492 MHz / 164 MHz
	 * so we need to slow down and configure MCKR accordingly.
	 * This is why we have a special flavor of the switching function.
	 */
	tmp = AT91_PMC_MCKR_PLLADIV_2 |
	      AT91_PMC_MCKR_MDIV_3 |
	      AT91_PMC_MCKR_CSS_MAIN;
	at91_mck_init_down(tmp);

	tmp = AT91_PMC_PLLAR_29 |
	      AT91_PMC_PLLXR_PLLCOUNT(0x3f) |
	      AT91_PMC_PLLXR_MUL(40) |
	      AT91_PMC_PLLXR_DIV(1);
	at91_plla_init(tmp);

	tmp = AT91_PMC_MCKR_H32MXDIV |
	      AT91_PMC_MCKR_PLLADIV_2 |
	      AT91_PMC_MCKR_MDIV_3 |
	      AT91_PMC_MCKR_CSS_PLLA;
	at91_mck_init(tmp);
}
#endif

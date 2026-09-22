// SPDX-License-Identifier: GPL-2.0+
#include <dm.h>
#include <dm/device.h>
#include <dm/read.h>
#include <dm/uclass.h>
#include <spi.h>
#include <asm/gpio.h>
#include <linux/delay.h>

#define ST7789_SWRESET 0x01
#define ST7789_SLPOUT 0x11
#define ST7789_NORON 0x13
#define ST7789_INVON 0x21
#define ST7789_DISPON 0x29
#define ST7789_MADCTL 0x36
#define ST7789_COLMOD 0x3A
#define ST7789_RAMCTRL 0xB0
#define ST7789_RGBCTRL 0xB1
#define ST7789_PORCTRL 0xB2

struct st7789_priv {
	struct gpio_desc dc;
	struct gpio_desc reset;
	bool done;
};

static int st7789_write(struct udevice *dev, bool data, const void *buf,
			size_t len)
{
	struct st7789_priv *priv = dev_get_priv(dev);
	int ret;

	ret = dm_gpio_set_value(&priv->dc, data ? 1 : 0);
	if (ret)
		return ret;

	return dm_spi_xfer(dev, len * 8, buf, NULL,
			   SPI_XFER_BEGIN | SPI_XFER_END);
}

static int st7789_cmd(struct udevice *dev, u8 cmd)
{
	return st7789_write(dev, false, &cmd, 1);
}

static int st7789_cmd_data(struct udevice *dev, u8 cmd, const u8 *data,
			   size_t len)
{
	int ret;

	ret = st7789_cmd(dev, cmd);
	if (ret)
		return ret;

	return st7789_write(dev, true, data, len);
}

static void st7789_reset(struct udevice *dev)
{
	struct st7789_priv *priv = dev_get_priv(dev);

	if (!dm_gpio_is_valid(&priv->reset))
		return;

	/*
	 * reset-gpios is active-low, so logical 1 asserts RESX.
	 * The ST7789V requires a reset pulse >10 us.  Keep a generous
	 * 20 ms pulse, then the full 120 ms reset-cancel interval so this
	 * is also safe on a warm reboot where the panel was in Sleep Out.
	 */
	dm_gpio_set_value(&priv->reset, 1);
	mdelay(20);
	dm_gpio_set_value(&priv->reset, 0);
	mdelay(120);
}

static int st7789_rgb_init(struct udevice *dev)
{
	u8 d[3];
	int ret;

	st7789_reset(dev);

	/*
	 * Hardware reset already restores the controller defaults and leaves
	 * the panel in Sleep In.  A second SWRESET is redundant here and, when
	 * issued in Sleep In, requires another 120 ms before SLPOUT.
	 */
	d[0] = 0x60;
	d[1] = 0x04;
	d[2] = 0x16;
	ret = st7789_cmd_data(dev, 0xb1, d, 3);
	if (ret)
		return ret;

	d[0] = 0x11;
	d[1] = 0xc0;
	ret = st7789_cmd_data(dev, 0xb0, d, 2);
	if (ret)
		return ret;

	ret = st7789_cmd(dev, 0x21); /* INVON */
	if (ret)
		return ret;

	d[0] = 0x66; /* RGB666 interface */
	ret = st7789_cmd_data(dev, 0x3a, d, 1);
	if (ret)
		return ret;

	ret = st7789_cmd(dev, 0x11); /* SLPOUT */
	if (ret)
		return ret;
	/*
	 * ST7789V requires 5 ms before issuing further commands after SLPOUT.
	 * Use 10 ms margin; the 120 ms restriction applies before SLPIN.
	 */
	mdelay(10);

	d[0] = 0x00;
	ret = st7789_cmd_data(dev, 0x36, d, 1); /* MADCTL */
	if (ret)
		return ret;

	ret = st7789_cmd(dev, 0x29); /* DISPON */
	if (ret)
		return ret;
	/* No mandatory post-DISPON delay in the datasheet; keep a small margin. */
	mdelay(10);

	return 0;
}

static int st7789_probe(struct udevice *dev)
{
	struct st7789_priv *priv = dev_get_priv(dev);
	int ret;

	if (priv->done)
		return 0;

	ret = gpio_request_by_name(dev, "dc-gpios", 0, &priv->dc, GPIOD_IS_OUT);
	if (ret)
		return ret;

	ret = gpio_request_by_name(dev, "reset-gpios", 0, &priv->reset,
				   GPIOD_IS_OUT);
	if (ret)
		printf("st7789: no reset gpio: %d\n", ret);

	ret = dm_spi_claim_bus(dev);
	if (ret)
		return ret;
	ret = st7789_rgb_init(dev);
	dm_spi_release_bus(dev);

	if (ret)
		return ret;

	priv->done = true;
	// printf("st7789: RGB init done via DM SPI\n");

	return 0;
}

static const struct udevice_id st7789_ids[] = {
	{ .compatible = "sitronix,st7789v-rgb-init" },
	{}
};

U_BOOT_DRIVER(st7789_spi) = {
	.name = "st7789_spi",
	.id = UCLASS_SPI_GENERIC,
	.of_match = st7789_ids,
	.probe = st7789_probe,
	.priv_auto = sizeof(struct st7789_priv),
};

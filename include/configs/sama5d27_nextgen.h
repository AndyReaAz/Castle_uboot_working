/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Configuration file for the SAMA5D27 SOM1 EK Board.
 *
 * Copyright (C) 2017 Microchip Corporation
 *		      Wenyou Yang <wenyou.yang@microchip.com>
 */

#ifndef __CONFIG_H
#define __CONFIG_H

#include "at91-sama5_common.h"

/* Supported runtime console rates for NextGen. */
#define CFG_SYS_BAUDRATE_TABLE { 115200, 230400, 460800, 921600 }

#undef CFG_SYS_AT91_MAIN_CLOCK
#define CFG_SYS_AT91_MAIN_CLOCK      12000000 /* from 12 MHz crystal */
/* SPL */

#endif

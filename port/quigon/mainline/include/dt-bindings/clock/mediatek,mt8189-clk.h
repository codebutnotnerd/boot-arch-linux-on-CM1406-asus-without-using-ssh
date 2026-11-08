/* SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause) */
/*
 * Copyright (c) 2024 MediaTek Inc.
 * Copyright (c) 2024 Collabora Ltd.
 * Author: AngeloGioacchino Del Regno <angelogioacchino.delregno@collabora.com>
 */

#ifndef _DT_BINDINGS_CLK_MT8189_H
#define _DT_BINDINGS_CLK_MT8189_H

/* APMIXEDSYS */
#define CLK_APMIXED_MAINPLL				0
#define CLK_APMIXED_UNIVPLL				1
#define CLK_APMIXED_MSDCPLL				2
#define CLK_APMIXED_MMPLL				3
#define CLK_APMIXED_MFGPLL				4
#define CLK_APMIXED_TVDPLL1				5
#define CLK_APMIXED_TVDPLL2				6
#define CLK_APMIXED_APLL1				7
#define CLK_APMIXED_APLL2				8

/* TOPCKGEN */
#define CLK_TOP_AXI_SEL					0
#define CLK_TOP_SPM_SEL					1
#define CLK_TOP_SCP_SEL					2
#define CLK_TOP_BUS_SEL					3
#define CLK_TOP_DISP_PWM_SEL				4
#define CLK_TOP_DISP0_SEL				5
#define CLK_TOP_EDP_SEL					6
#define CLK_TOP_DP_SEL					7
#define CLK_TOP_SPI0_SEL				8
#define CLK_TOP_SPI1_SEL				9
#define CLK_TOP_MSDC50_0_SEL				10
#define CLK_TOP_MSDC30_1_SEL				11
#define CLK_TOP_AUDIO_H_SEL				12
#define CLK_TOP_AUD_INTBUS_SEL				13
#define CLK_TOP_AUD_1_SEL				14
#define CLK_TOP_AUD_2_SEL				15
#define CLK_TOP_AUD_ENGEN1_SEL				16
#define CLK_TOP_AUD_ENGEN2_SEL				17
#define CLK_TOP_APLL12_CK_DIV_I2SOUT0			18
#define CLK_TOP_APLL12_CK_DIV_I2SOUT1			19
#define CLK_TOP_APLL12_CK_DIV_I2SIN0			20
#define CLK_TOP_APLL12_CK_DIV_I2SIN1			21
#define CLK_TOP_APLL12_CK_DIV_FMI2S			22
#define CLK_TOP_APLL12_CK_DIV_TDMOUT_M			23
#define CLK_TOP_APLL12_CK_DIV_TDMOUT_B			24
#define CLK_TOP_APLL_I2SOUT0_MCK_SEL			25
#define CLK_TOP_APLL_I2SOUT1_MCK_SEL			26
#define CLK_TOP_APLL_I2SIN0_MCK_SEL			27
#define CLK_TOP_APLL_I2SIN1_MCK_SEL			28
#define CLK_TOP_APLL_FMI2S_MCK_SEL			29
#define CLK_TOP_APLL_TDMOUT_MCK_SEL			30
#define CLK_TOP_APLL1_D4				31
#define CLK_TOP_APLL2_D4				32
#define CLK_TOP_MSDCPLL_D2				33
#define CLK_TOP_UNIVPLL_D2				34
#define CLK_TOP_UNIVPLL_D4				35
#define CLK_TOP_UNIVPLL_D6_D2				36
#define CLK_TOP_MMINFRA_SEL				37
#define CLK_TOP_MFG_REF_SEL				38
#define CLK_TOP_U_SEL					39
#define CLK_TOP_U_MBIST_SEL				40
#define CLK_TOP_AES_UFSFDE_SEL				41
#define CLK_TOP_USB2_PHY_RF_P0_EN			42
#define CLK_TOP_USB2_PHY_RF_P1_EN			43
#define CLK_TOP_USB2_PHY_RF_P2_EN			44
#define CLK_TOP_USB2_PHY_RF_P3_EN			45
#define CLK_TOP_USB2_PHY_RF_P4_EN			46
#define CLK_TOP_VDEC_SEL				47
#define CLK_TOP_VENC_SEL				48

/* INFRACFG_AO */
#define CLK_INFRA_AO_PMIC_AP				0
#define CLK_INFRA_AO_PMIC_TMR				1
#define CLK_INFRA_AO_SEJ				2
#define CLK_INFRA_AO_APXGPT				3
#define CLK_INFRA_AO_ICUSB				4
#define CLK_INFRA_AO_GCE				5
#define CLK_INFRA_AO_THERM				6
#define CLK_INFRA_AO_PWM_H				7
#define CLK_INFRA_AO_PWM1				8
#define CLK_INFRA_AO_PWM2				9
#define CLK_INFRA_AO_PWM3				10
#define CLK_INFRA_AO_PWM4				11
#define CLK_INFRA_AO_PWM				12
#define CLK_INFRA_AO_UART0				13
#define CLK_INFRA_AO_UART1				14
#define CLK_INFRA_AO_UART2				15
#define CLK_INFRA_AO_UART3				16
#define CLK_INFRA_AO_GCE2				17
#define CLK_INFRA_AO_CQ_DMA				18
#define CLK_INFRA_AO_BTIF				19
#define CLK_INFRA_AO_SPI0				20
#define CLK_INFRA_AO_MSDC0				21
#define CLK_INFRA_AO_MSDC1				22
#define CLK_INFRA_AO_MSDC2				23
#define CLK_INFRA_AO_MSDC0_SRC				24
#define CLK_INFRA_AO_DVFSRC				25

/* PERICFG_AO */
#define CLK_PERAO_AUDIO0				0
#define CLK_PERAO_AUDIO1				1
#define CLK_PERAO_AUDIO2				2
#define CLK_PERAO_DISP_PWM0				3
#define CLK_PERAO_SPI0_B				4
#define CLK_PERAO_SPI0_H				5
#define CLK_PERAO_SSUSB0_F				6
#define CLK_PERAO_SSUSB0_FRMCNT				7
#define CLK_PERAO_SSUSB0_H				8
#define CLK_PERAO_SSUSB0_REF				9
#define CLK_PERAO_SSUSB0_SYS				10
#define CLK_PERAO_SSUSB0_XHCI				11
#define CLK_PERAO_SSUSB1_F				12
#define CLK_PERAO_SSUSB1_FRMCNT				13
#define CLK_PERAO_SSUSB1_H				14
#define CLK_PERAO_SSUSB1_REF				15
#define CLK_PERAO_SSUSB1_SYS				16
#define CLK_PERAO_SSUSB1_XHCI				17
#define CLK_PERAO_SSUSB2_F				18
#define CLK_PERAO_SSUSB2_FRMCNT				19
#define CLK_PERAO_SSUSB2_H				20
#define CLK_PERAO_SSUSB2_REF				21
#define CLK_PERAO_SSUSB2_SYS				22
#define CLK_PERAO_SSUSB2_XHCI				23
#define CLK_PERAO_SSUSB3_F				24
#define CLK_PERAO_SSUSB3_FRMCNT				25
#define CLK_PERAO_SSUSB3_H				26
#define CLK_PERAO_SSUSB3_REF				27
#define CLK_PERAO_SSUSB3_SYS				28
#define CLK_PERAO_SSUSB3_XHCI				29
#define CLK_PERAO_SSUSB4_F				30
#define CLK_PERAO_SSUSB4_FRMCNT				31
#define CLK_PERAO_SSUSB4_H				32
#define CLK_PERAO_SSUSB4_REF				33
#define CLK_PERAO_SSUSB4_SYS				34
#define CLK_PERAO_SSUSB4_XHCI				35

/* UFSCFG */
#define CLK_UFSCFG_AO_REG_U_PHY_TOP_AHB_S_BUS		0
#define CLK_UFSCFG_AO_REG_U_SAP_CFG			1
#define CLK_UFSCFG_AO_REG_UNIPRO_RX_SYM0		2
#define CLK_UFSCFG_AO_REG_UNIPRO_RX_SYM1		3
#define CLK_UFSCFG_AO_REG_UNIPRO_SYS			4
#define CLK_UFSCFG_AO_REG_UNIPRO_TX_SYM			5
#define CLK_UFSCFG_REG_UFSHCI_AES			6
#define CLK_UFSCFG_REG_UFSHCI_U_AHB			7
#define CLK_UFSCFG_REG_UFSHCI_U_AXI			8
#define CLK_UFSCFG_REG_UFSHCI_UFS			9

/* MFGCFG */
#define CLK_MFG_BG3D					0

/* MMSYS (dispsys) */
#define CLK_MM_DISP_OVL0_4L				0
#define CLK_MM_DISP_OVL1_4L				1
#define CLK_MM_VPP_RSZ0					2
#define CLK_MM_VPP_RSZ1					3
#define CLK_MM_DISP_RDMA0				4
#define CLK_MM_DISP_RDMA1				5
#define CLK_MM_DISP_COLOR0				6
#define CLK_MM_DISP_COLOR1				7
#define CLK_MM_DISP_CCORR0				8
#define CLK_MM_DISP_CCORR1				9
#define CLK_MM_DISP_CCORR2				10
#define CLK_MM_DISP_CCORR3				11
#define CLK_MM_DISP_AAL0				12
#define CLK_MM_DISP_AAL1				13
#define CLK_MM_DISP_GAMMA0				14
#define CLK_MM_DISP_GAMMA1				15
#define CLK_MM_DISP_DITHER0				16
#define CLK_MM_DISP_DITHER1				17
#define CLK_MM_DISP_DSC_WRAP0				18
#define CLK_MM_VPP_MERGE0				19
#define CLK_MMSYS_0_DISP_DVO				20
#define CLK_MMSYS_0_DISP_DSI0				21
#define CLK_MM_DP_INTF0					22
#define CLK_MM_DPI0					23
#define CLK_MM_DISP_WDMA0				24
#define CLK_MM_DISP_WDMA1				25
#define CLK_MM_DISP_FAKE_ENG0				26
#define CLK_MM_DISP_FAKE_ENG1				27
#define CLK_MM_SMI_LARB					28
#define CLK_MM_DISP_MUTEX0				29
#define CLK_MM_DIPSYS_CONFIG				30
#define CLK_MM_DUMMY					31
#define CLK_MMSYS_1_DISP_DSI0				32
#define CLK_MMSYS_1_LVDS_ENCODER			33
#define CLK_MMSYS_1_DPI0				34
#define CLK_MMSYS_1_DISP_DVO				35
#define CLK_MM_DP_INTF					36
#define CLK_MMSYS_1_LVDS_ENCODER_CTS			37
#define CLK_MMSYS_1_DISP_DVO_AVT			38
#define CLK_MM_NR_CLK					39

/* MMINFRA_CONFIG */
#define CLK_MMINFRA_GCE_D				0
#define CLK_MMINFRA_GCE_M				1
#define CLK_MMINFRA_SMI					2
#define CLK_MMINFRA_GCE_26M				3
#define CLK_MMINFRA_CONFIG_NR_CLK			4

/* VDEC_CORE */
#define CLK_VDEC_CORE_LARB_CKEN				0
#define CLK_VDEC_CORE_VDEC_CKEN				1
#define CLK_VDEC_CORE_VDEC_ACTIVE			2
#define CLK_VDEC_CORE_NR_CLK				3

/* VEN1 */
#define CLK_VEN1_CKE0_LARB				0
#define CLK_VEN1_CKE1_VENC				1
#define CLK_VEN1_CKE2_JPGENC				2
#define CLK_VEN1_CKE3_JPGDEC				3
#define CLK_VEN1_CKE4_JPGDEC_C1				4
#define CLK_VEN1_CKE5_GALS				5
#define CLK_VEN1_CKE6_GALS_SRAM				6
#define CLK_VEN1_NR_CLK					7

/* VLP */
#define CLK_VLP_CK_SCP_SEL				0

#endif /* _DT_BINDINGS_CLK_MT8189_H */


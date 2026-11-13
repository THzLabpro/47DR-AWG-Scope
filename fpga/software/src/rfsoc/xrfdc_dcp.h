/*
 * xrfdc_dcp.h
 *
 *  Created on: 2020Äê5ÔÂ29ÈÕ
 *      Author: lichen
 */
#include "xrfdc.h"
#ifndef SRC_RFSOC_XRFDC_DCP_H_
#define SRC_RFSOC_XRFDC_DCP_H_
int RFdcDcp_initial(XRFdc *RFdcInstPtr, UINTPTR RFdcLookupKey);
int RFdcDcp_Example(XRFdc *RFdcInstPtr, spi_device * spi);


#endif /* SRC_RFSOC_XRFDC_DCP_H_ */

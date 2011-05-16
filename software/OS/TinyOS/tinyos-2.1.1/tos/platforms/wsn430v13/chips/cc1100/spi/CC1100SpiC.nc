/*
 * Copyright (c) 2005-2006 Arch Rock Corporation
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the Arch Rock Corporation nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
 * ARCHED ROCK OR ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE
 */

/**
 * Implementation of basic SPI primitives for the ChipCon CC2420 radio.
 *
 * @author Jonathan Hui <jhui@archrock.com>
 * @version $Revision: 1.3 $ $Date: 2008/11/26 10:13:31 $
 */

#include "CC1100.h"

generic configuration CC1100SpiC() {

  provides interface Resource;
  provides interface ChipSpiResource;

  // commands
  provides interface CC1100Strobe as SRES;
  provides interface CC1100Strobe as SFSTXON;
  provides interface CC1100Strobe as SXOFF;
  provides interface CC1100Strobe as SCAL;
  provides interface CC1100Strobe as SRX;
  provides interface CC1100Strobe as STX;
  provides interface CC1100Strobe as SIDLE;
  provides interface CC1100Strobe as SWOR;
  provides interface CC1100Strobe as SPWD;
  provides interface CC1100Strobe as SFRX;
  provides interface CC1100Strobe as SFTX;
  provides interface CC1100Strobe as SWORRST;
  provides interface CC1100Strobe as SNOP;

  // registers
  provides interface CC1100Register as IOCFG2;
  provides interface CC1100Register as IOCFG0;
  provides interface CC1100Register as FIFOTHR;
  provides interface CC1100Register as PKTLEN;
  provides interface CC1100Register as PKTCTRL1;
  provides interface CC1100Register as PKTCTRL0;
  provides interface CC1100Register as ADDR;
  provides interface CC1100Register as CHANNR;
  provides interface CC1100Register as FSCTRL1;
  provides interface CC1100Register as FSCTRL0;
  provides interface CC1100Register as FREQ2;
  provides interface CC1100Register as FREQ1;
  provides interface CC1100Register as FREQ0;
  provides interface CC1100Register as MDMCFG4;
  provides interface CC1100Register as MDMCFG3;
  provides interface CC1100Register as MDMCFG2;
  provides interface CC1100Register as MDMCFG1;
  provides interface CC1100Register as MDMCFG0;
  provides interface CC1100Register as DEVIATN;
  provides interface CC1100Register as MCSM2;
  provides interface CC1100Register as MCSM1;
  provides interface CC1100Register as MCSM0;

  // status
  provides interface CC1100Status as PARTNUM;
  provides interface CC1100Status as VERSION;
  provides interface CC1100Status as LQI;
  provides interface CC1100Status as RSSI;
  provides interface CC1100Status as MARCSTATE;
  provides interface CC1100Status as WORTIME1;
  provides interface CC1100Status as WORTIME0;
  provides interface CC1100Status as PKTSTATUS;
  provides interface CC1100Status as TXBYTES;
  provides interface CC1100Status as RXBYTES;

  // fifos
  provides interface CC1100Fifo as RXFIFO;
  provides interface CC1100Fifo as TXFIFO;

}

implementation {

  enum {
    CLIENT_ID = unique( "CC1100Spi.Resource" ),
  };
  
  components HplCC1100PinsC as Pins;
  components CC1100SpiWireC as Spi;
  
  ChipSpiResource = Spi.ChipSpiResource;
  Resource = Spi.Resource[ CLIENT_ID ];
  
  // commands
  SRES = Spi.Strobe[ CC1100_SRES ];
  SFSTXON = Spi.Strobe[ CC1100_SFSTXON ];
  SXOFF = Spi.Strobe[ CC1100_SXOFF ];
  SCAL = Spi.Strobe[ CC1100_SCAL ];
  SRX = Spi.Strobe[ CC1100_SRX ];
  STX = Spi.Strobe[ CC1100_STX ];
  SIDLE = Spi.Strobe[ CC1100_SIDLE ];
  SWOR = Spi.Strobe[ CC1100_SWOR ];
  SPWD = Spi.Strobe[ CC1100_SPWD ];
  SFRX = Spi.Strobe[ CC1100_SFRX ];
  SFTX = Spi.Strobe[ CC1100_SFTX ];
  SWORRST = Spi.Strobe[ CC1100_SWORRST ];
  SNOP = Spi.Strobe[ CC1100_SNOP ];

  // registers
  IOCFG2 = Spi.Reg[ CC1100_IOCFG2 ];
  IOCFG0 = Spi.Reg[ CC1100_IOCFG0 ];
  FIFOTHR = Spi.Reg[ CC1100_FIFOTHR ];
  PKTLEN = Spi.Reg[ CC1100_PKTLEN ];
  PKTCTRL1 = Spi.Reg[ CC1100_PKTCTRL1 ];
  PKTCTRL0 = Spi.Reg[ CC1100_PKTCTRL0 ];
  ADDR = Spi.Reg[ CC1100_ADDR ];
  CHANNR = Spi.Reg[ CC1100_CHANNR ];
  FSCTRL1 = Spi.Reg[ CC1100_FSCTRL1 ];
  FSCTRL0 = Spi.Reg[ CC1100_FSCTRL0 ];
  FREQ2 = Spi.Reg[ CC1100_FREQ2 ];
  FREQ1 = Spi.Reg[ CC1100_FREQ1 ];
  FREQ0 = Spi.Reg[ CC1100_FREQ0 ];
  MDMCFG4 = Spi.Reg[ CC1100_MDMCFG4 ];
  MDMCFG3 = Spi.Reg[ CC1100_MDMCFG3 ];
  MDMCFG2 = Spi.Reg[ CC1100_MDMCFG2 ];
  MDMCFG1 = Spi.Reg[ CC1100_MDMCFG1 ];
  MDMCFG0 = Spi.Reg[ CC1100_MDMCFG0 ];
  DEVIATN = Spi.Reg[ CC1100_DEVIATN ];
  MCSM2 = Spi.Reg[ CC1100_MCSM2 ];
  MCSM1 = Spi.Reg[ CC1100_MCSM1 ];
  MCSM0 = Spi.Reg[ CC1100_MCSM0 ];

  // status
  PARTNUM = Spi.Status[ CC1100_PARTNUM ];
  VERSION = Spi.Status[ CC1100_VERSION ];
  LQI = Spi.Status[ CC1100_LQI ];
  RSSI = Spi.Status[ CC1100_RSSI ];
  MARCSTATE = Spi.Status[ CC1100_MARCSTATE ];
  WORTIME1 = Spi.Status[ CC1100_WORTIME1 ];
  WORTIME0 = Spi.Status[ CC1100_WORTIME0 ];
  PKTSTATUS = Spi.Status[ CC1100_PKTSTATUS ];
  TXBYTES = Spi.Status[ CC1100_TXBYTES ];
  RXBYTES = Spi.Status[ CC1100_RXBYTES ];

  // fifos
  RXFIFO = Spi.Fifo[ CC1100_RXFIFO ];
  TXFIFO = Spi.Fifo[ CC1100_TXFIFO ];

}


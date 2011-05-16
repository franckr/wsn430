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
 * @author Jonathan Hui <jhui@archrock.com>
 * @author David Moss
 * @author Jung Il Choi Initial SACK implementation
 * @version $Revision: 1.12 $ $Date: 2009/03/02 07:02:32 $
 */

#include "CC2420.h"
#include "CC2420TimeSyncMessage.h"
#include "crc.h"
#include "message.h"

module CC1100TransmitP @safe() {

  provides interface Init;
  provides interface StdControl;
  provides interface CC2420Transmit as Send;
  provides interface RadioBackoff;
  provides interface ReceiveIndicator as EnergyIndicator;
  provides interface ReceiveIndicator as ByteIndicator;
  
  uses interface Alarm<T32khz,uint32_t> as BackoffTimer;
  uses interface CC2420Packet;
  uses interface CC2420PacketBody;
  uses interface PacketTimeStamp<T32khz,uint32_t>;
  uses interface PacketTimeSyncOffset;
  uses interface GpioInterrupt as InterruptSFD;
  uses interface GeneralIO as CSN;
  uses interface GeneralIO as SFD;

  uses interface Resource as SpiResource;
  uses interface ChipSpiResource;
  uses interface CC1100Fifo as TXFIFO;
  uses interface CC1100Strobe as SNOP;
  uses interface CC1100Strobe as STX;
  uses interface CC1100Strobe as SRX;
  uses interface CC1100Strobe as SFRX;
  uses interface CC1100Strobe as SIDLE;
  uses interface CC1100Strobe as SFTX;
  
  uses interface CC1100Status as PKTSTATUS;
  uses interface CC1100Status as MARCSTATE;
  uses interface CC1100Status as VERSION;
  uses interface CC1100Status as TXBYTES;
  
  uses interface CC1100Register as MCSM1;
  uses interface CC1100Register as IOCFG0;
  uses interface CC1100Register as IOCFG2;

  uses interface CC2420Receive;
  uses interface Leds;
}

implementation {

  typedef enum {
    S_STOPPED,
    S_STARTED,
    S_LOAD,
    S_SAMPLE_CCA,
    S_BEGIN_TRANSMIT,
    S_SFD,
    S_EFD,
    S_ACK_WAIT,
    S_CANCEL,
  } cc2420_transmit_state_t;

  // This specifies how many jiffies the stack should wait after a
  // TXACTIVE to receive an SFD interrupt before assuming something is
  // wrong and aborting the send. There seems to be a condition
  // on the micaZ where the SFD interrupt is never handled.
  enum {
    CC2420_ABORT_PERIOD = 320
  };
  
  norace message_t * ONE_NOK m_msg;
  
  norace bool m_cca;
  
  norace uint8_t m_tx_power;
  
  cc2420_transmit_state_t m_state = S_STOPPED;
  
  bool m_receiving = FALSE;
  
  uint16_t m_prev_time;
  
  /** Byte reception/transmission indicator */
  bool sfdHigh;
  
  /** Let the CC2420 driver keep a lock on the SPI while waiting for an ack */
  bool abortSpiRelease;
  
  /** Total CCA checks that showed no activity before the NoAck LPL send */
  norace int8_t totalCcaChecks;
  
  /** The initial backoff period */
  norace uint16_t myInitialBackoff;
  
  /** The congestion backoff period */
  norace uint16_t myCongestionBackoff;
  

  /***************** Prototypes ****************/
  error_t send( message_t * ONE p_msg, bool cca );
  error_t resend( bool cca );
  void loadTXFIFO();
  void attemptSend();
  void congestionBackoff();
  error_t acquireSpiResource();
  error_t releaseSpiResource();
  void signalDone( error_t err );
  
  void resetRX();
  
  
  /***************** Init Commands *****************/
  command error_t Init.init() {
    call CSN.makeOutput();
    call SFD.makeInput();
    return SUCCESS;
  }

  /***************** StdControl Commands ****************/
  command error_t StdControl.start() {
    atomic {
      call InterruptSFD.enableRisingEdge();
      m_state = S_STARTED;
      m_receiving = FALSE;
      abortSpiRelease = FALSE;
      m_tx_power = 0;
    }
    return SUCCESS;
  }

  command error_t StdControl.stop() {
    atomic {
      m_state = S_STOPPED;
      call BackoffTimer.stop();
      call InterruptSFD.disable();
      call SpiResource.release();  // REMOVE
      call CSN.set();
    }
    return SUCCESS;
  }


  /**************** Send Commands ****************/
  async command error_t Send.send( message_t* ONE p_msg, bool useCca ) {
    return send( p_msg, useCca );
  }

  async command error_t Send.resend(bool useCca) {
    return resend( useCca );
  }

  async command error_t Send.cancel() {
    atomic {
      switch( m_state ) {
      case S_LOAD:
      case S_SAMPLE_CCA:
      case S_BEGIN_TRANSMIT:
        m_state = S_CANCEL;
        break;
        
      default:
        // cancel not allowed while radio is busy transmitting
        return FAIL;
      }
    }

    return SUCCESS;
  }

  async command error_t Send.modify( uint8_t offset, uint8_t* buf, 
                                     uint8_t len ) {
    //~ call CSN.clr();
    //~ call TXFIFO_RAM.write( offset, buf, len );
    //~ call CSN.set();
    return SUCCESS;
  }
  
  /***************** Indicator Commands ****************/
  command bool EnergyIndicator.isReceiving() {
    uint8_t status;
    call CSN.clr();
    call PKTSTATUS.read(&status);
    call CSN.set();
    return !( status & ( 1<<4 ) );
  }
  
  command bool ByteIndicator.isReceiving() {
    bool high;
    atomic high = sfdHigh;
    return high;
  }
  

  /***************** RadioBackoff Commands ****************/
  /**
   * Must be called within a requestInitialBackoff event
   * @param backoffTime the amount of time in some unspecified units to backoff
   */
  async command void RadioBackoff.setInitialBackoff(uint16_t backoffTime) {
    myInitialBackoff = backoffTime + 1;
  }
  
  /**
   * Must be called within a requestCongestionBackoff event
   * @param backoffTime the amount of time in some unspecified units to backoff
   */
  async command void RadioBackoff.setCongestionBackoff(uint16_t backoffTime) {
    myCongestionBackoff = backoffTime + 1;
  }
  
  async command void RadioBackoff.setCca(bool useCca) {
  }
  
  
  inline uint32_t getTime32(uint16_t time)
  {
    uint32_t recent_time=call BackoffTimer.getNow();
    return recent_time + (int16_t)(time - recent_time);
  }

  /**
   * The CaptureSFD event is actually an interrupt from the capture pin
   * which is connected to timing circuitry and timer modules.  This
   * type of interrupt allows us to see what time (being some relative value)
   * the event occurred, and lets us accurately timestamp our packets.  This
   * allows higher levels in our system to synchronize with other nodes.
   *
   * Because the SFD events can occur so quickly, and the interrupts go
   * in both directions, we set up the interrupt but check the SFD pin to
   * determine if that interrupt condition has already been met - meaning,
   * we should fall through and continue executing code where that interrupt
   * would have picked up and executed had our microcontroller been fast enough.
   */
  async event void InterruptSFD.fired( ) {
    uint32_t time32;
    uint16_t time;
    uint8_t sfd_state = 0;
    atomic {
      time = (int16_t)(call BackoffTimer.getNow());
      time32 = getTime32(time);
      
      switch( m_state ) {
        
      case S_SFD:
        m_state = S_EFD;
        sfdHigh = TRUE;
        // in case we got stuck in the receive SFD interrupts, we can reset
        // the state here since we know that we are not receiving anymore
        m_receiving = FALSE;
        call InterruptSFD.enableFallingEdge();
        call PacketTimeStamp.set(m_msg, time32);
        //~ if (call PacketTimeSyncOffset.isSet(m_msg)) {
           //~ uint8_t absOffset = sizeof(message_header_t)-sizeof(cc2420_header_t)+call PacketTimeSyncOffset.get(m_msg);
           //~ timesync_radio_t *timesync = (timesync_radio_t *)((nx_uint8_t*)m_msg+absOffset);
           //~ // set timesync event time as the offset between the event time and the SFD interrupt time (TEP  133)
           //~ *timesync  -= time32;
           //~ call CSN.clr();
           //~ call TXFIFO_RAM.write( absOffset, (uint8_t*)timesync, sizeof(timesync_radio_t) );
           //~ call CSN.set();
        //~ }

        if ( (call CC2420PacketBody.getHeader( m_msg ))->fcf & ( 1 << IEEE154_FCF_ACK_REQ ) ) {
          // This packet requires an ACK, don't release the chip's SPI bus lock.
          abortSpiRelease = TRUE;
        }
        
        releaseSpiResource();
        call BackoffTimer.stop();

        if ( call SFD.get() ) {
          break;
        }
        /** Fall Through because the next interrupt was already received */

      case S_EFD:
        sfdHigh = FALSE;
        call InterruptSFD.enableRisingEdge();
        
        if ( (call CC2420PacketBody.getHeader( m_msg ))->fcf & ( 1 << IEEE154_FCF_ACK_REQ ) ) {
          // The packer required an ACK, we're waiting for it.
          m_state = S_ACK_WAIT;
          call BackoffTimer.start( CC2420_ACK_WAIT_DELAY );
        } else {
          // no ACK required, packet is sent.
          signalDone(SUCCESS);
        }
        
        if ( !call SFD.get() ) {
          break;
        }
        /** Fall Through because the next interrupt was already received */
        
      default:
        /* this is the SFD for received messages */
        if ( !m_receiving && sfdHigh == FALSE ) {
          sfdHigh = TRUE;
          call InterruptSFD.enableFallingEdge();
          // safe the SFD pin status for later use
          sfd_state = call SFD.get();
          call CC2420Receive.sfd( time32 );
          m_receiving = TRUE;
          m_prev_time = time;
          if ( call SFD.get() ) {
            // wait for the next interrupt before moving on
            return;
          }
          // if SFD.get() = 0, then an other interrupt happened since we
          // reconfigured CaptureSFD! Fall through
        }
        
        if ( sfdHigh == TRUE ) {
          sfdHigh = FALSE;
          call InterruptSFD.enableRisingEdge();
          m_receiving = FALSE;
          /* if sfd_state is 1, then we fell through, but at the time of
           * saving the time stamp the SFD was still high. Thus, the timestamp
           * is valid.
           * if the sfd_state is 0, then either we fell through and SFD
           * was low while we safed the time stamp, or we didn't fall through.
           * Thus, we check for the time between the two interrupts.
           * FIXME: Why 10 tics? Seams like some magic number...
           */
          if ((sfd_state == 0) && (time - m_prev_time < 10) ) {
            call CC2420Receive.sfd_dropped();
            if (m_msg)
              call PacketTimeStamp.clear(m_msg);
          }
          break;
        }
      }
    }
  }

  /***************** ChipSpiResource Events ****************/
  async event void ChipSpiResource.releasing() {
    if(abortSpiRelease) {
      call ChipSpiResource.abortRelease();
    }
  }
  
  
  /***************** CC2420Receive Events ****************/
  /**
   * If the packet we just received was an ack that we were expecting,
   * our send is complete.
   */
  async event void CC2420Receive.receive( uint8_t type, message_t* ack_msg ) {
    cc2420_header_t* ack_header;
    cc2420_header_t* msg_header;
    cc2420_metadata_t* msg_metadata;
    uint8_t* ack_buf;
    uint8_t length;

    if ( type == IEEE154_TYPE_ACK && m_msg) {
      ack_header = call CC2420PacketBody.getHeader( ack_msg );
      msg_header = call CC2420PacketBody.getHeader( m_msg );

      
      if ( m_state == S_ACK_WAIT && msg_header->dsn == ack_header->dsn ) {
        call BackoffTimer.stop();
        
        msg_metadata = call CC2420PacketBody.getMetadata( m_msg );
        ack_buf = (uint8_t *) ack_header;
        length = ack_header->length;
        
        msg_metadata->ack = TRUE;
        msg_metadata->rssi = ack_buf[ length - 1 ];
        msg_metadata->lqi = ack_buf[ length ] & 0x7f;
        signalDone(SUCCESS);
      }
    }
  }

  /***************** SpiResource Events ****************/
  event void SpiResource.granted() {
    uint8_t cur_state;

    atomic {
      cur_state = m_state;
    }

    switch( cur_state ) {
    case S_LOAD:
      loadTXFIFO();
      break;
      
    case S_BEGIN_TRANSMIT:
      attemptSend();
      break;
      
    case S_CANCEL:
      resetRX();
      releaseSpiResource();
      atomic {
        m_state = S_STARTED;
      }
      signal Send.sendDone( m_msg, ECANCEL );
      break;
      
    default:
      releaseSpiResource();
      break;
    }
  }
  
  /***************** TXFIFO Events ****************/
  /**
   * The TXFIFO is used to load packets into the transmit buffer on the
   * chip
   */
  async event void TXFIFO.writeDone( uint8_t* tx_buf, uint8_t tx_len,
                                     error_t error ) {
    
    call CSN.set();
    
    if ( m_state == S_CANCEL ) {
      atomic {
        resetRX();
      }
      releaseSpiResource();
      m_state = S_STARTED;
      signal Send.sendDone( m_msg, ECANCEL );
      
    } else if ( !m_cca ) {
      atomic {
        m_state = S_BEGIN_TRANSMIT;
      }
      attemptSend();
      
    } else {
      releaseSpiResource();
      atomic {
        m_state = S_SAMPLE_CCA;
      }
      
      signal RadioBackoff.requestInitialBackoff(m_msg);
      call BackoffTimer.start(myInitialBackoff);
    }
  }

  
  async event void TXFIFO.readDone( uint8_t* tx_buf, uint8_t tx_len, 
      error_t error ) {
  }
  
  
  /***************** Timer Events ****************/
  /**
   * The backoff timer is mainly used to wait for a moment before trying
   * to send a packet again. But we also use it to timeout the wait for
   * an acknowledgement, and timeout the wait for an SFD interrupt when
   * we should have gotten one.
   */
  async event void BackoffTimer.fired() {
    //~ uint8_t status;
    atomic {
      switch( m_state ) {
        
      case S_SAMPLE_CCA : 
        // sample CCA and wait a little longer if free, just in case we
        // sampled during the ack turn-around window
        //~ call PKTSTATUS.read(&status); // can't do that, we don't have the SpiResource
        //~ if ( status & (1<<4) ) { // channel is clear
          m_state = S_BEGIN_TRANSMIT;
          call BackoffTimer.start( CC2420_TIME_ACK_TURNAROUND );
          
        //~ } else {
          //~ congestionBackoff();
        //~ }
        break;
        
      case S_BEGIN_TRANSMIT:
      case S_CANCEL:
        if ( acquireSpiResource() == SUCCESS ) {
          attemptSend();
        }
        break;
        
      case S_ACK_WAIT:
        signalDone( SUCCESS );
        break;

      case S_SFD:
        // We didn't receive an SFD interrupt within CC2420_ABORT_PERIOD
        // jiffies. Assume something is wrong.
        resetRX();
        
        call InterruptSFD.enableRisingEdge();
        releaseSpiResource();
        signalDone( ERETRY );
        break;

      default:
        break;
      }
    }
  }
      
  /***************** Functions ****************/
  /**
   * Set up a message to be sent. First load it into the outbound tx buffer
   * on the chip, then attempt to send it.
   * @param *p_msg Pointer to the message that needs to be sent
   * @param cca TRUE if this transmit should use clear channel assessment
   */
  error_t send( message_t* ONE p_msg, bool cca ) {
    atomic {
      if (m_state == S_CANCEL) {
        return ECANCEL;
      }
      
      if ( m_state != S_STARTED ) {
        return FAIL;
      }
      
      m_state = S_LOAD;
      m_cca = cca;
      m_msg = p_msg;
      totalCcaChecks = 0;
    }
    
    if ( acquireSpiResource() == SUCCESS ) {
      loadTXFIFO();
    }

    return SUCCESS;
  }
  
  /**
   * Resend a packet that already exists in the outbound tx buffer on the
   * chip
   * @param cca TRUE if this transmit should use clear channel assessment
   */
  error_t resend( bool cca ) {

    atomic {
      if (m_state == S_CANCEL) {
        return ECANCEL;
      }
      
      if ( m_state != S_STARTED ) {
        return FAIL;
      }
      
      m_cca = cca;
      m_state = cca ? S_SAMPLE_CCA : S_BEGIN_TRANSMIT;
      totalCcaChecks = 0;
    }
    
    if(m_cca) {
      signal RadioBackoff.requestInitialBackoff(m_msg);
      call BackoffTimer.start( myInitialBackoff );
      
    } else if ( acquireSpiResource() == SUCCESS ) {
      attemptSend();
    }
    
    return SUCCESS;
  }
  
  /**
   * Attempt to send the packet we have loaded into the tx buffer on 
   * the radio chip.  The STXONCCA will send the packet immediately if
   * the channel is clear.  If we're not concerned about whether or not
   * the channel is clear (i.e. m_cca == FALSE), then STXON will send the
   * packet without checking for a clear channel.
   *
   * If the packet didn't get sent, then congestion == TRUE.  In that case,
   * we reset the backoff timer and try again in a moment.
   *
   * If the packet got sent, we should expect an SFD interrupt to take
   * over, signifying the packet is getting sent.
   */
  void attemptSend() {
    uint8_t status, state;
    bool congestion = TRUE;
    
    atomic {
      if (m_state == S_CANCEL) {
        resetRX();
        releaseSpiResource();
        
        m_state = S_STARTED;
        signal Send.sendDone( m_msg, ECANCEL );
        return;
      }
      
      
      //~ status = m_cca ? call STXONCCA.strobe() : call STXON.strobe();
      
      if (m_cca) {
        call CSN.clr();
        status = call STX.strobe();
        call CSN.set();
      } else {
        call CSN.clr();
        call SIDLE.strobe();
        call CSN.set();
        
        // wait IDLE
        do {
          call CSN.clr();
          call MARCSTATE.read(&state);
          call CSN.set();
        } while (state != 0x1); // IDLE
        
        // start TX
        call CSN.clr();
        status = call STX.strobe();
        call CSN.set();
        
      }
      // wait to be in TX or RX (pass intermediate states)
      do {
        call CSN.clr();
        status = call SNOP.strobe();
        call CSN.set();
        status = ((status >> 4) & 0x7);
      } while ( (status != 1)  && (status != 2) );
      
      if ( status == 2 ) { // if we're in TX, Channel was clear
          congestion = FALSE;
      }
      //~ if ( !( status & CC2420_STATUS_TX_ACTIVE ) ) {
        //~ status = call SNOP.strobe();
        //~ if ( status & CC2420_STATUS_TX_ACTIVE ) {
          //~ congestion = FALSE;
        //~ }
      //~ }
      
      m_state = congestion ? S_SAMPLE_CCA : S_SFD;
      //~ call CSN.set();
    }
    
    
    if ( congestion ) { // if we can't send now, release the SPI and wait
      totalCcaChecks = 0;
      releaseSpiResource();
      congestionBackoff();
    } else { // else start a safety timer
      call BackoffTimer.start(CC2420_ABORT_PERIOD);
    }
  }
  
  
  /**  
   * Congestion Backoff
   */
  void congestionBackoff() {
    atomic {
      signal RadioBackoff.requestCongestionBackoff(m_msg);
      call BackoffTimer.start(myCongestionBackoff);
    }
  }
  
  error_t acquireSpiResource() {
    error_t error = call SpiResource.immediateRequest();
    if ( error != SUCCESS ) {
      call SpiResource.request();
    }
    return error;
  }

  error_t releaseSpiResource() {
    call SpiResource.release();
    return SUCCESS;
  }

  /** 
   * Setup the packet transmission power and load the tx fifo buffer on
   * the chip with our outbound packet.  
   *
   * Warning: the tx_power metadata might not be initialized and
   * could be a value other than 0 on boot.  Verification is needed here
   * to make sure the value won't overstep its bounds in the TXCTRL register
   * and is transmitting at max power by default.
   *
   * It should be possible to manually calculate the packet's CRC here and
   * tack it onto the end of the header + payload when loading into the TXFIFO,
   * so the continuous modulation low power listening strategy will continually
   * deliver valid packets.  This would increase receive reliability for
   * mobile nodes and lossy connections.  The crcByte() function should use
   * the same CRC polynomial as the CC2420's AUTOCRC functionality.
   */
  void loadTXFIFO() {
    cc2420_header_t* header = call CC2420PacketBody.getHeader( m_msg );
    uint8_t tx_power = (call CC2420PacketBody.getMetadata( m_msg ))->tx_power;
    
    if ( !tx_power ) {
      tx_power = CC2420_DEF_RFPOWER;
    }
    
    //~ if ( m_tx_power != tx_power ) {
      //~ call TXCTRL.write( ( 2 << CC2420_TXCTRL_TXMIXBUF_CUR ) |
                         //~ ( 3 << CC2420_TXCTRL_PA_CURRENT ) |
                         //~ ( 1 << CC2420_TXCTRL_RESERVED ) |
                         //~ ( (tx_power & 0x1F) << CC2420_TXCTRL_PA_LEVEL ) );
    //~ }
    
    m_tx_power = tx_power;
    header->length -= 2; // FCS shall not be included with CC1100
    
    call CSN.clr();
    {
      uint8_t tmpLen __DEPUTY_UNUSED__ = header->length - 1;
      call TXFIFO.write(TCAST(uint8_t * COUNT(tmpLen), header), header->length + 1);
    }
  }
  
  void signalDone( error_t err ) {
    atomic m_state = S_STARTED;
    abortSpiRelease = FALSE;
    call ChipSpiResource.attemptRelease();
    signal Send.sendDone( m_msg, err );
  }
  
  // When calling this, the SpiResource must be acquired!
  void resetRX(void) {
    uint8_t state;
    
    call CSN.set();
    call CSN.clr();
    call MARCSTATE.read(&state);
    call CSN.set();
    
    switch (state) {
      case 0x11: // RXFIFO_OVERFLOW
        // flush RX
        call CSN.clr();
        call SFRX.strobe();
        call CSN.set();
        
        // wait IDLE
        do {
          call CSN.clr();
          call MARCSTATE.read(&state);
          call CSN.set();
        } while (state != 0x1); // IDLE
        
        // flush TX
        call CSN.clr();
        call SFTX.strobe();
        call CSN.set();
        
        break;
      case 0x16: // TXFIFO_UNDERFLOW
        // flush TX
        call CSN.clr();
        call SFTX.strobe();
        call CSN.set();
        
        // wait IDLE
        do {
          call CSN.clr();
          call MARCSTATE.read(&state);
          call CSN.set();
        } while (state != 0x1); // IDLE
        
        // flush RX
        call CSN.clr();
        call SFRX.strobe();
        call CSN.set();
        
        break;
        
      default: // Any other state
        // set IDLE
        call CSN.clr();
        call SIDLE.strobe();
        call CSN.set();
        
        // wait IDLE
        do {
          call CSN.clr();
          call MARCSTATE.read(&state);
          call CSN.set();
        } while (state != 0x1); // IDLE
        
        // flush TX
        call CSN.clr();
        call SFTX.strobe();
        call CSN.set();
        
        // wait IDLE
        do {
          call CSN.clr();
          call MARCSTATE.read(&state);
          call CSN.set();
        } while (state != 0x1); // IDLE
        
        
        // flush RX
        call CSN.clr();
        call SFRX.strobe();
        call CSN.set();
        
        break;
    }
    
    // wait IDLE
    do {
      call CSN.clr();
      call MARCSTATE.read(&state);
      call CSN.set();
    } while (state != 0x1); // IDLE
    
    // Set RX
    call CSN.clr();
    call SRX.strobe();
    call CSN.set();
  }
  
}


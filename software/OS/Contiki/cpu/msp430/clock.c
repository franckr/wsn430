/*
 * Copyright (c) 2005, Swedish Institute of Computer Science
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the Institute nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE INSTITUTE AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE INSTITUTE OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * This file is part of the Contiki operating system.
 *
 * @(#)$Id: clock.c,v 1.16 2008/10/10 12:36:58 nifi Exp $
 */


#include <io.h>
#include <signal.h>

#include "contiki-conf.h"

#include "sys/clock.h"
#include "sys/etimer.h"
#include "sys/rtimer.h"

#define INTERVAL (4096ULL / CLOCK_SECOND)

#define MAX_TICKS (~((clock_time_t)0) / 2)

static volatile unsigned long seconds;

static volatile clock_time_t count = 0;
/* last_tar is used for calculating clock_fine, last_ccr might be better? */
static unsigned short last_tar = 0;
/*---------------------------------------------------------------------------*/
interrupt(TIMERA1_VECTOR) timera1 (void)
{
    
    if(TAIV == 2) {

        /* HW timer bug fix: Interrupt handler called before TR==CCR.
         * Occurrs when timer state is toggled between STOP and CONT. */
        while (TACTL & MC1 && TACCR1 - TAR == 1);

        TACCR1 += INTERVAL;
        ++count;

        if(count % CLOCK_CONF_SECOND == 0) {
            ++seconds;
        }

        last_tar = TAR;

        if(etimer_pending() && (etimer_next_expiration_time() - count - 1) > MAX_TICKS)
        {
            etimer_request_poll();
            LPM4_EXIT;
        }
    }
    
}
/*---------------------------------------------------------------------------*/
clock_time_t clock_time(void)
{
    return count;
}
/*---------------------------------------------------------------------------*/
void clock_set(clock_time_t clock, clock_time_t fclock)
{
    TAR = fclock;
    TACCR1 = fclock + INTERVAL;
    count = clock;
}
/*---------------------------------------------------------------------------*/
int clock_fine_max(void)
{
    return INTERVAL;
}
/*---------------------------------------------------------------------------*/
unsigned short clock_fine(void)
{
    unsigned short t;
    /* Assign last_tar to local varible that can not be changed by interrupt */
    t = last_tar;
    /* perform calc based on t, TAR will not be changed during interrupt */
    return (unsigned short) (TAR - t);
}
/*---------------------------------------------------------------------------*/
void clock_init(void)
{
    dint();

    /* Select ACLK 32768Hz clock, divide by 8 */
    TACTL = TASSEL0 | TACLR | ID_3;

    /* Initialize ccr1 to create the X ms interval. */
    /* CCR1 interrupt enabled, interrupt occurs when timer equals CCR1. */
    TACCTL1 = CCIE;

    /* Interrupt after X ms. */
    TACCR1 = INTERVAL;

    /* Start Timer_A in continuous mode. */
    TACTL |= MC1;

    count = 0;

    /* Enable interrupts. */
    eint();

}
/*---------------------------------------------------------------------------*/

/**
 * Delay the CPU for a multiple of 0.5 us.
 */
void
clock_delay(unsigned int n)
{
    __asm__ __volatile__ (
        "1: \n"
        " dec	%[n] \n"      /* 2 cycles */
        " jne	1b \n"        /* 2 cycles */
        : [n] "+r"(n));
}
/*---------------------------------------------------------------------------*/
/**
 * Wait for a multiple of 10 ms.
 *
 */
void
clock_wait(int i)
{
  clock_time_t start;

  start = clock_time();
  while(clock_time() - start < (clock_time_t)i);
}
/*---------------------------------------------------------------------------*/
void
clock_set_seconds(unsigned long sec)
{

}
/*---------------------------------------------------------------------------*/
unsigned long
clock_seconds(void)
{
  unsigned long t1, t2;
  do {
    t1 = seconds;
    t2 = seconds;
  } while(t1 != t2);
  return t1;
}
/*---------------------------------------------------------------------------*/
rtimer_clock_t
clock_counter(void)
{
  return TAR;
}
/*---------------------------------------------------------------------------*/
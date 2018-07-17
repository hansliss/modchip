;***************************************************************************
;* Playstation Import enabler code
;* 
;* File Name            :modchip.asm
;* Title                :Playstation Import enabler code
;* Date                 :98.02.25
;* Version              :1.2
;* Support email        :Hans@Liss.pp.se
;* Target MCU           :AT90S1200A
;* Clock type		:Internal RC
;*
;* DESCRIPTION
;*
;* This code will send a Playstation region code (four characters - SCEE
;* for Europe, SCEI for Japan and SCEA for the US) as a serial bitstream
;* at about 250bps on an I/O pin, for a short time after RESET. It also
;* acts as a software jumper between two lines, and can handle blanking of
;* another signal. All these signals will go tristate after a certain time
;* to hide the chip. The processor will restart when the lid is opened and
;* closed and when the RESET switch is pressed and released.
;*
;* There is an option of connecting a pair of switches against GND to two
;* pins, and they can then be used to select between three different CNT
;* values, or disable the chip completely. The status of the switches is
;* read every time the sequence is to be started.
;*
;* A three-legged, dual-colour LED can be connected to two of the I/O pins
;* and GND.
;* It will then be used to show what the processor is doing - cycling
;* between colours when the code is being sent, turning green when it's
;* ready, turning red when disabled and yellow during a pending RESET or
;* media change.
;*
;*                       Processor chip layout
;*
;*	                      -----v-----
;*                         1 [|o        |] 20   Vcc
;*		Lid        2 [|         |] 19   Calibrate
;*		Reset      3 [|         |] 18   Green LED
;*                         4 [|         |] 17   Red LED
;*                         5 [|         |] 16   Jumper OUT
;*              Blanking   6 [|         |] 15   Data OUT
;*                         7 [|         |] 14   Jumper IN
;*	                   8 [|         |] 13   Switch 2
;*	                   9 [|         |] 12   Switch 1
;*              GND       10 [|         |] 11
;*                            -----------
;*
;*
;* This code is inspired by Scott Rider's widely distributed modchip code for
;* the PIC 12C508. The Atmel chip is far better at most of these things - 
;* stable RC speed, more registers and much more orthogonal instruction set
;* along with four times the speed of a comparable PIC. The AT90S1200 is,
;* however, more expensive than the 12C508, but OTOH it has lots more I/O pins,
;* making all these bells and whistles possible. And programming it is fun!
;* I am working with Atmels own "wavrasm" which as far as I know is 
;* available on their home page on <http://www.atmel.com>.
;*
;* Going back to Scott Rider, we can define a mapping between the pin
;* connections for his code, which appears to be the same for most of the
;* commercially available chips. Pin 1 on the PIC is Vdd, 0-7V, and pin 8 is
;* GND. Pin 5 is used for the "blanking" signal, to block the real data from
;* the CD unit. Pin 6 is the serial data stream.
;* This means that going from a 12C508 to a AT90S1200 gives the following mapping:
;*
;*    From pin    To pin
;*           1 -> 20
;*           5 -> 6
;*           6 -> 15
;*           8 -> 10
;*
;* This code was made for a modern PU-22 motherboard, which is handled
;* somewhat differently. Instead of pin 5 on the 12C508, here we usually have
;* a jumper cable between two positions on the board. In this solution,
;* the LEFT one of these points should be connected to pin 14, "Jumper IN", and
;* the RIGHT one to pin 16, "Jumper OUT".
;* You can leave the jumper in there but then the chip can never be
;* completely hidden, which may or may not be significant.
;*
;* Where to find the RESET and Lid signals on an old motherboard is left as
;* an excercise for the reader. All I know is that the Lid signal was usually
;* pin 4 on the older, 18 pin 16c84 modchips.
;*
;* More info and pictures can be found on <http://www.maxking.com>.
;* On the PU-22 board, the CD Lid signal is the one close to the CD connector,
;* and the RESET signal can be found on the upper half of the board.
;*
;* ********* *NEW for version 1.1 ***************
;* I have cleaned up the delay sections and created a single delay function,
;* together with a matching macro, WAITMS. Now the chip will read its delay
;* constants from the EEPROM making it tunable to different chip speeds.
;* There is also a subroutine "calibrate" that can be used to calibrate the
;* delay loop. Connect a pushbutton between earth and pin 19 on the chip. Keep
;* this pressed when starting the Playstation and keep it pressed for exactly
;* 10 seconds, then release it. The new delay constants will be calculated
;* and stored into the EEPROM.
;*
;* ********* *NEW for version 1.2 ***************
;* I have remade some of the Count handling. There are still three different
;* Count values available, selectable with the switch. Now, however, it is
;* possible to change those values. To _decrease_ the current count value,
;* simply boot a game and press the Calibrate button whenever you think
;* that enough pulses have passed, usually just after the copyright screen
;* has disappeared and turned black. To _increase_ the value, wait until the
;* end of the cycle and then press the button. The current Count will increase
;* by ten.
;* There is now also a way to easily recalibrate the speed with a default value
;* for 5V. Just do a normal calibration but release the button almost immediately,
;* and the calibration values will be set to 115 and 103, respectively (my
;* calculated values).
;*
;* ********* *NEW for version 1.2.1 ***************
;* Added debounce to lid and RESET switches. Added weak pullup to RESET input
;*
;***************************************************************************

.device	AT90S1200	;Prohibits use of non-implemented instructions

.include "1200def.inc"

.LISTMAC

;***** Global Register Variables


;***** Arg registers
.def	A1	=r16
.def	A2	=r17
.def	A3	=r18
.def	CNT	=r19
.def	D1	=r28
.def	D2	=r29
.def	X	=r30
.def	curC	=r23

;***** Scratch regs
.def	I	=r20
.def	J	=r21
.def	K	=r22

;***** EEPROM vars
.equ	storedD1=0
.equ	storedD2=1
.equ	storedC1=2
.equ	storedC2=3
.equ	storedC3=4

.equ	defaultD1=115
.equ	defaultD2=103
.equ	defaultC=99

;******* PORT B

;  Switches - active low: 0=off, 1=Use COUNT1, 2=Use COUNT2, 3=Use COUNT3
.equ	SWITCH1=0
.equ	SWITCH2=1

.equ	SWITCH3=7

;  "Jumper" input
.equ	JUMPIN=2

;  Subchannel data stream, output
.equ	PORTBIT=3

;  "Jumper" output
.equ	JUMPOUT=4

;  Red and green LED ouput pins
.equ	RLEDBIT=5
.equ	GLEDBIT=6

;******* PORT D

;  Reset signal, active low input
.equ	RSIG=1

;  Media change signal, active high input
.equ	LSIG=0

;  "Blanking" signal - extra pin for old PSX 4-line chips
.equ	BLANK=2

.equ	TEST=3

;Count values for short and long settings, respectively
.equ	COUNT1=86
.equ	COUNT2=93
.equ	COUNT3=99

;***** Macros
.macro	SENDONE
	cbi	DDRB,PORTBIT
.endmacro

.macro	SENDZERO
	sbi	DDRB,PORTBIT
.endmacro

.macro	LIGHTBOTH
	sbi	PORTB,GLEDBIT
	sbi	PORTB,RLEDBIT
.endmacro

.macro	LIGHTRED
	sbi	PORTB,GLEDBIT
	cbi	PORTB,RLEDBIT
.endmacro

.macro	LIGHTGRN
	cbi	PORTB,GLEDBIT
	sbi	PORTB,RLEDBIT
.endmacro

.macro	LIGHTOFF
	cbi	PORTB,GLEDBIT
	cbi	PORTB,RLEDBIT
.endmacro

.macro	WAITMS
	ldi	X,@0
	rcall	waitxms
.endmacro

; Execute the software "jumper". Five cycles.
.macro	DOJUMP
	sbis	PINB,JUMPIN
	rjmp	PC+3
	sbi	DDRB,JUMPOUT
	sbi	PORTD,TEST

	sbic	PINB,JUMPIN
	rjmp	PC+4
	sbi	DDRB,JUMPOUT
	nop
	nop

.endmacro

.equ	cyclesDJ=11

.macro	ENBLANK
	cbi	PORTD,BLANK
	sbi	DDRD,BLANK
.endmacro

.macro	DEBLANK
	cbi	PORTD,BLANK
	cbi	DDRD,BLANK
.endmacro

;***** Code

	rjmp	START		;Reset Handle

;****************************************************************************
;*
;* Subroutine 'waitxms'
;*
;* Stored vars D1 and D2 is used for calibration.
;*
;* This subroutine will wait for x ms minus one LDI+call+return.
;* The innermost loop is D1 * (5 + 1 + 1 + 2) cycles. We execute that loop
;* (+ 3 cycles for DEC+BRNI) X-1 times, and then we do the rest minus 8 cycles
;* in a separate loop (D2 * (5 + 1 + 1 + 1 + 2)). This leaves 8 cycles = 7 for
;* call/return and one for the necessary LDI X,# instruction.
;*
;***************************************************************************


waitxms:
	dec	X
	breq	vxloop20
wxloop0:
	mov	I,d1
wxloop1:
	DOJUMP
	nop
	dec	I
	brne	wxloop1

	dec	X
	brne	wxloop0

vxloop20:
	mov	I,d2
wxloop2:
	DOJUMP
	nop
	nop
	dec	I
	brne	wxloop2

	ret

.equ	cyclesD1=cyclesDJ+4
.equ	cyclesD2=cyclesDJ+5

;****************************************************************************
;*
;* Subroutine 'calibrate', called from sysinit
;*
;* Do 10000 cycles each loop, increasing r24:r25 by one each pass.
;* This subroutine will calibrate 1 ms if run during 10 sec. The switch on
;* SWITCH3 is checked for release on every pass.
;*
;* 'makecns' will calculate the delay constants d1 and d2 as follows:
;* 	d1=(n-3)/9
;* 	d2=(n-8)/10
;* and then store them to the EEPROM
;*
;****************************************************************************

calibrate:
	LIGHTRED
	ldi	r24,0
	ldi	r25,0
cloop0:
	sbic	PINB,SWITCH3
	rjmp	makecns

	ldi	I,37
cloop1:
	ldi	J,89
cloop2:
	dec	J
	brne	cloop2

	dec	I
	brne	cloop1

	inc	r25
	brne	cloop0
	inc	r24
	rjmp	cloop0

makecns:
	subi	r25,3
	sbci	r24,0

mc01:
	mov	r26,r24
	mov	r27,r25
	ldi	d1,0
l1:
	cpi	r26,0
	brne	l12
	cpi	r27,cyclesD1
	brlo	l13
l12:
	subi	r27,cyclesD1
	sbci	r26,0

	inc	d1
	rjmp	l1

l13:
	subi	r25,5
	sbci	r24,0
	ldi	d2,0
l2:
	cpi	r24,0
	brne	l22
	cpi	r25,cyclesD2
	brlo	l23
l22:
	subi	r25,cyclesD2
	sbci	r24,0

	inc	d2
	rjmp	l2

l23:
; ** If d1 is less than 5, we have a value reset at hand and will set
; ** the values to a suitable 5V default
	cpi	d1,5
	brsh	l231
	ldi	d1,defaultD1
	ldi	d2,defaultD2
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
l231:
	ldi	I,storedD1
	out	EEAR,I
	out	EEDR,d1
	sbi	EECR,EEWE
l24:
	sbic	EECR,EEWE
	rjmp	l24

	ldi	I,storedD2
	out	EEAR,I
	out	EEDR,d2
	sbi	EECR,EEWE

	LIGHTGRN
	rjmp	cont

;****************************************************************************
;*
;* Subroutine 'sendbyte'
;*
;* This subroutine will send one character to the (globally defined) I/O
;* port.
;* A 'one' is done by making the port bit an input bit and letting the
;* PSX pullup pull the line up. A 'zero' is done by making it an output
;* - the port bit data is a 'zero' during all this so the only thing
;* that changes is the port direction, which is set to 'one' for output
;* ('zero'), and 'zero' for input ('one').
;* Each bit will take 4 ms, and one start bit and two stop bits will be sent
;*
;***************************************************************************

sendbyte:
; Invert byte
	com	A1
; Send a start bit
	SENDONE
	WAITMS	4
	ldi	A2,8
sbloop0:ror	A1
	brcs	bitset
	SENDZERO
	brcc	bitclr
bitset:	SENDONE
bitclr:	WAITMS	4
	dec	A2
	brne	sbloop0
; Send two stop bits
	SENDZERO
	WAITMS	4
	WAITMS	4
	ret

;****************************************************************************
;*
;* Subroutine 'sysinit'
;*
;* This subroutine will initialize the I/O ports and check the switch
;* settings
;*
;* LED is unlit
;*
;***************************************************************************

sysinit:
; Prepare the Reset and Media Change signal inputs (no pullup)
; and the SWITCH3 portbit (internal pullup)
	cbi	DDRD,RSIG
	cbi	DDRD,LSIG
	sbi	PORTD,RSIG
	cbi	PORTD,LSIG
	cbi	DDRB,SWITCH3
	sbi	PORTB,SWITCH3

; Set the LED signals as output
	sbi	DDRB,GLEDBIT
	sbi	DDRB,RLEDBIT

	sbi	DDRD,TEST
	cbi	PORTD,TEST

; Load the stored variables from the EEPROM
	ldi	I,storedD1
	out	EEAR,I
	sbi	EECR,EERE
	in	d1,EEDR
	ldi	I,storedD2
	out	EEAR,I
	sbi	EECR,EERE
	in	d2,EEDR

	cpi	d1,255
	brne	sinit00
	ldi	d1,115
	ldi	d2,103

sinit00:

; Check if the Calibrate switch is pressed
	sbis	PINB,SWITCH3
	rjmp	calibrate

; Check the DIP switch to see whether we should go tristate or which count calue
; to select
	cbi	DDRB,SWITCH1
	sbi	PORTB,SWITCH1
	cbi	DDRB,SWITCH2
	sbi	PORTB,SWITCH2

	sbic	PINB,SWITCH1
	rjmp	sinit1
	sbis	PINB,SWITCH2
	rjmp	passive
	ldi	curC,storedC2
	rjmp	sinitx

sinit1:
	sbic	PINB,SWITCH2
	rjmp	sinit3
	ldi	curC,storedC1
	rjmp	sinitx

sinit3:
	ldi	curC,storedC3

sinitx:
	out	EEAR,curC
	sbi	EECR,EERE
	in	CNT,EEDR

	cpi	CNT,255
	brne	sinitx1
	ldi	CNT,99

sinitx1:
	SENDONE
	cbi	PORTB,PORTBIT


; Prepare the "jumper" bits. The input will have a pullup and the output
; will assume there is a pullup, and send the bits in the same way as the
; data is sent on PORTBIT. 
	cbi	DDRB,JUMPOUT
	cbi	DDRB,JUMPIN
	sbi	PORTB,JUMPIN
	cbi	PORTB,JUMPOUT

	ldi	k,3
	ret

;****************************************************************************
;*
;* Subroutine 'init'
;*
;* This subroutine will wait for 50 ms and then take the I/O port bit low,
;* then wait for 1164 ms more before returning. 850 ms into the latter, the
;* blanking bit is taken low.
;*
;***************************************************************************

init:
	WAITMS	50
;make pin go low as output
	SENDZERO
	ldi	A2,17
iloop1:	WAITMS	50
	dec	A2
	brne	iloop1
	ENBLANK
	ldi	A2,6
iloop2:	WAITMS	50
	dec	A2
	brne	iloop2
	WAITMS	14
	ret

;****************************************************************************
;*
;* Subroutine 'sendcode'
;*
;* This subroutine will send a four-byte string to the (globally defined)
;* I/O port a specified number of times, then return.
;*
;***************************************************************************

sendcode:
	cbi	PORTD,TEST
	mov	A3,CNT
scloop0:
	rcall	clight

	WAITMS	72
	ldi	A1,'S'
	rcall	sendbyte
	ldi	A1,'C'
	rcall	sendbyte
	ldi	A1,'E'
	rcall	sendbyte
	ldi	A1,'E'
	rcall	sendbyte

	cbi	PORTD,TEST

	dec	A3

; Check if the Calibrate switch is pressed. If it is,
; terminate the loop here and store the new value for
; this particular COUNT in the EEPROM

	sbis	PINB,SWITCH3
	rjmp	screcal

	brne	scloop0
	ret

screcal:
	sbis	PINB,SWITCH3
	rjmp	screcal

	sub	CNT,A3
	out	EEAR,curC
	out	EEDR,CNT
	sbi	EECR,EEWE
scrc01:
	sbic	EECR,EEWE
	rjmp	scrc01

	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125

	ret

;****************************************************************************
;*
;* Subroutine 'clight'
;*
;* This subroutine will set the color of the color LED to one of three states:
;* red, green or both
;*
;***************************************************************************

clight:
	mov	A1,K
	ror	A1
	brcs	lowset
	cbi	PORTB,GLEDBIT
	brcc	lowclr
lowset:	sbi	PORTB,GLEDBIT	
lowclr:	ror	A1
	brcs	hiset
	cbi	PORTB,RLEDBIT
	brcc	hiclr
hiset:	sbi	PORTB,RLEDBIT
hiclr:	dec	K
	brne	cret
	ldi	K,3
cret:	ret

;****************************************************************************
;*
;* Subroutine 'cont'
;*
;* This subroutine will do whatever the processor is supposed to do after
;* sending the code for the specified time. For now this means to loop,
;* possibly restarting on reset or "open lid"
;*
;***************************************************************************

cont:
	DEBLANK
	cbi	DDRB,PORTBIT
	cbi	PORTB,PORTBIT
	cbi	DDRB,JUMPOUT
	cbi	DDRB,JUMPIN
	cbi	PORTB,JUMPIN
	cbi	PORTB,JUMPOUT
	ldi	K,255

cont0:
	dec	K
	cpi	K,0
	brne	cont01
	cbi	PORTD,TEST
	ldi	K,255
cont01:	WAITMS	1
	DOJUMP
	sbis	PIND,RSIG
	rjmp	rcheck
	sbic	PIND,LSIG
	rjmp	lcheck
	sbis	PINB,SWITCH3
	rjmp	countup
	rjmp	cont0

; Wait for Reset button release
rcheck:
	WAITMS	1
	LIGHTBOTH
	sbis	PIND,RSIG
	rjmp	rcheck
	rjmp	START
	
; Wait for Close
lcheck:
	WAITMS	1
	LIGHTBOTH
	sbic	PIND,LSIG
	rjmp	lcheck
	rjmp	START

; Increase the current COUNT value by 10 if the
; calibrate button is pressed.

countup:
	sbis	PINB,SWITCH3
	rjmp	countup

	subi	CNT,-10
	out	EEAR,curC
	out	EEDR,CNT
	sbi	EECR,EEWE
cu01:
	sbic	EECR,EEWE
	rjmp	cu01

	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125
	LIGHTBOTH
	WAITMS	125
	LIGHTGRN
	WAITMS	125

	rjmp	cont0
	

;****************************************************************************
;*
;* Subroutine 'passive'
;*
;* This subroutine will just put the 'chip' in passive, tristate mode.
;* LED will be red
;*
;***************************************************************************

passive:
	sbi	DDRB,GLEDBIT
	sbi	DDRB,RLEDBIT
	LIGHTRED

	rjmp	cont

;****************************************************************************
;*
;* Main Program
;*
;* This program calls the routines "sysinit", "init", "sendcode" and "cont"
;* in that order.
;*
;***************************************************************************

;***** Main Program Register Variables

START:
; Init ports
	rcall sysinit
; Do the initial signalling. The LED will be set to green after this
	rcall init
	rcall	sendcode

	LIGHTGRN

; ..and go wait for better weather or possibly a RESET
	rjmp	cont

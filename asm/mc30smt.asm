;***************************************************************************
;* Playstation Import enabler code
;* 
;* File Name            :modchip.asm
;* Title                :Playstation Import enabler code
;* Date                 :99-04-22
;* Version              :1.3
;* Support email        :Hans@Liss.pp.se
;* Target MCU           :AT90S1200
;* Clock type		:2MHz ceramic resonator or equiv.
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
;*		Lid        2 [|         |] 19   
;*		Reset      3 [|         |] 18   
;*                         4 [|         |] 17   
;*                         5 [|         |] 16   Calibrate
;*              Blanking   6 [|         |] 15   LED
;*              Data OUT   7 [|         |] 14   
;*	        Jumper IN  8 [|         |] 13   Switch 2
;*	        Jumper OUT 9 [|         |] 12   Switch 1
;*              GND       10 [|         |] 11
;*                            -----------
;*
;*
;* This code is inspired by Scott Rider's widely distributed modchip code for
;* the PIC 12C508. The Atmel chip is far better at most of these things - 
;* many more registers and much more orthogonal instruction set along with
;* four times the speed of a comparable PIC. The AT90S1200 is, however, more
;* expensive than the 12C508, but OTOH it has lots more I/O pins,
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
;*           6 -> 7
;*           8 -> 10
;*
;* This code was made for a modern PU-22 motherboard, which is handled
;* somewhat differently. Instead of pin 5 on the 12C508, here we usually have
;* a jumper cable between two positions on the board. In this solution,
;* the LEFT one of these points should be connected to "Jumper IN", and
;* the RIGHT one to "Jumper OUT".
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
;* ********* *NEW for version 1.3   ***************
;* The default timing is now calibrated for an AT90S1200 with a 2MHz ceramic
;* resonator, and the default Count value is calibrated for Final Fantasy VIII,
;* which works just fine with this code. All the features are still there but
;* they are mostly unnecessary now..
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
.def	STATE	=r24

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

;.equ	defaultD1=115
;.equ	defaultD2=103
.equ	defaultD1=$FE
.equ	defaultD2=$FD
.equ	defaultC=100

;******* PORT B

;  Switches - active low: 0=off, 1=Use COUNT1, 2=Use COUNT2, 3=Use COUNT3
.equ	SWITCH1=0
.equ	SWITCH2=1

.equ	SWITCH3=4

;  Red and green LED ouput pins
.equ	LEDBIT=3
;.equ	GLEDBIT=6

;******* PORT D

;  Media change signal, active high input
.equ	LSIG=0

;  Reset signal, active low input
.equ	RSIG=1

;  "Blanking" signal - extra pin for old PSX 4-line chips
.equ	BLANK=2

;  Subchannel data stream, output
.equ	PORTBIT=3

;  "Jumper" input
.equ	JUMPIN=4

;  "Jumper" output
.equ	JUMPOUT=5

;Count values for short and long settings, respectively
.equ	COUNT1=172
.equ	COUNT2=186
.equ	COUNT3=198

;***** Macros
.macro	SENDONE
	cbi	DDRD,PORTBIT
.endmacro

.macro	SENDZERO
	sbi	DDRD,PORTBIT
.endmacro

.macro	LIGHTBOTH
	sbi	DDRB,LEDBIT
.endmacro

.macro	LIGHTRED
	sbi	DDRB,LEDBIT
.endmacro

.macro	LIGHTGRN
	cbi	DDRB,LEDBIT
.endmacro

.macro	LIGHTOFF
	cbi	DDRB,LEDBIT
.endmacro

.macro	WAITMS
	ldi	X,@0
	rcall	waitxms
.endmacro

; Execute the software "jumper". Five cycles.
.macro	DOJUMP
	sbis	PIND,JUMPIN
	sbi	DDRD,JUMPOUT
	sbic	PIND,JUMPIN
	cbi	DDRD,JUMPOUT
.endmacro

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
	nop
	nop
	nop
	nop
	nop
	nop
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
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	dec	I
	brne	wxloop2

	ret

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
	cpi	r27,9
	brlo	l13
l12:
	subi	r27,9
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
	cpi	r25,10
	brlo	l23
l22:
	subi	r25,10
	sbci	r24,0

	inc	d2
	rjmp	l2

l23:
; ** If d1 is less than 5, we have a value reset at hand and will set
; ** the values to a suitable 5V default
	cpi	d1,30
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

; Set the LED signal as input
	cbi	PORTB,LEDBIT

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
	ldi	d1,defaultD1
	ldi	d2,defaultD2

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
	ldi	CNT,defaultC

sinitx1:
	SENDONE
	cbi	PORTD,PORTBIT


; Prepare the "jumper" bits. The input will have a pullup and the output
; will assume there is a pullup, and send the bits in the same way as the
; data is sent on PORTBIT. 
	cbi	DDRD,JUMPOUT
	cbi	DDRD,JUMPIN
	sbi	PORTD,JUMPIN
	cbi	PORTD,JUMPOUT

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
	ldi	STATE,1
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
	ret

scloop:
	mov	A3,CNT
scloop0:
	rcall sendcode
	cpi	STATE,5
	brlo	scw00
	rjmp	scw05

; Measure one pulse length (between 5 and 90) on the
; Jumper input and set the counter to three after 4 speed
; changes
scw00:
	ldi	a1,0
scw01:
	sbic	PIND,JUMPIN
	rjmp	scw01
	sbi	DDRD,JUMPOUT
scw012:
	sbis	PIND,JUMPIN
	rjmp	scw012
	cbi	DDRD,JUMPOUT

scw02:
	sbis	PIND,JUMPIN
	rjmp	scw03
	inc a1
	rjmp	scw02

scw03:
	sbi	DDRD,JUMPOUT
	cpi	a1,7
	brlo	scw01
	cpi	a1,90
	brsh	scw01
	cpi	a1,35
	brlo	fast
	sbrs	STATE,0
	rjmp	sinc
	
scw04:
; Check if the Calibrate switch is pressed. If it is,
; terminate the loop here and store the new value for
; this particular COUNT in the EEPROM

	sbis	PINB,SWITCH3
	rjmp	screcal

	dec	A3

	brne	scloop0
	ret
;---------------------------------
; Help routines for the pulse length measurement state machine
fast:
	sbrc	STATE,0
	rjmp	sinc
	rjmp	scw04

sinc:
	inc	STATE
;	cpi	STATE,5
;	breq	terminate
	rjmp	scw04

terminate:
	ldi	A3,6
	rjmp	scw04

scw05:
	rcall sendcode
	rcall sendcode
	ldi	A1,40
scw055:
	WAITMS	250
	dec	A1
	brne	scw055
	rcall sendcode
	rcall sendcode
	rcall sendcode
	rcall sendcode
	rcall sendcode
	rcall sendcode
	rjmp	scw04
; --------------------------------

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
	dec	K
	breq	low
	sbi	DDRB,LEDBIT
	brne	cret
low:	cbi	DDRB,LEDBIT
	ldi	K,2
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
	cbi	DDRD,PORTBIT
	cbi	PORTD,PORTBIT
	cbi	DDRD,JUMPOUT
	cbi	DDRD,JUMPIN
	cbi	PORTD,JUMPIN
	cbi	PORTD,JUMPOUT

cont0:
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
	LIGHTOFF

	rjmp	cont

;****************************************************************************
;*
;* Main Program
;*
;* This program calls the routines "sysinit", "init", "scloop" and "cont"
;* in that order.
;*
;***************************************************************************

;***** Main Program Register Variables

START:
; Init ports
	rcall sysinit
; Do the initial signalling. The LED will be set to green after this
	rcall init
	rcall	scloop

	LIGHTGRN

; ..and go wait for better weather or possibly a RESET
	rjmp	cont

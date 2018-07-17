;***************************************************************************
;* Playstation Import enabler code
;* 
;* File Name            :modchip.asm
;* Title                :Playstation Import enabler code
;* Date                 :98.03.08
;* Version              :2.0b
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

;******* PORT B

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

.macro	WAITMSP
	ldi	X,@0
	rcall	waitxmsp
.endmacro

; Execute the software "jumper". Five cycles.
.macro	DOJUMP
	sbis	PINB,JUMPIN
	sbi	DDRB,JUMPOUT
	sbic	PINB,JUMPIN
	cbi	DDRB,JUMPOUT
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
;* Stored vars D1 is used for calibration.
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

waitxmsp:
	dec	X
	breq	vxploop20
wxploop0:
	mov	I,d1
wxploop1:
	nop
	nop
	nop
	nop
	nop
	nop
	dec	I
	brne	wxploop1

	dec	X
	brne	wxploop0

vxploop20:
	mov	I,d2
wxploop2:
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	dec	I
	brne	wxploop2

	ret

;****************************************************************************
;*
;* Subroutine 'makecns' will calculate the delay constants d1 and d2 as follows:
;* 	d1=(n-3)/9
;* 	d2=(n-8)/10
;* and then store them to the EEPROM
;*
;****************************************************************************

makecns:
	ret

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
;* Subroutine 'waitbyte'
;*
;***************************************************************************

waitbyte:
; Invert byte
	com	A1
; Wait for start bit
wb00:
	sbic	PINB,PORTBIT
	rjmp	wb00
wb01:
	sbis	PINB,PORTBIT
	rjmp	wb01
	
	WAITMSP	6

	ldi	A2,8
wbloop0:
	ror	A1
	brcs	wbitset
	brcc	wbitclr
wbitset:
	sbic	PINB,PORTBIT
	rjmp	wbloop1
	sec
	ret
		
wbitclr:
	sbis	PINB,PORTBIT
	rjmp	wbloop1
	sec
	ret
		
wbloop1:
	WAITMSP	4
	dec	A2
	brne	wbloop0
; Expect two stop bits

	LIGHTGRN
	sbis	PINB,PORTBIT
	rjmp	waitok
waitnok:
	sec
	ret

waitok:
	WAITMSP	5
;	sbic	PINB,PORTBIT
;	rjmp	waitnok

	clc
	ret

readbyte:
	ldi	A1,0
; Wait for start bit
rb00:
	sbic	PINB,PORTBIT
	rjmp	rb00
rb01:
	sbis	PINB,PORTBIT
	rjmp	rb01
	
	WAITMSP	1

	sbis	PINB,PORTBIT
	rjmp	rb01
	
	WAITMSP	1

	sbis	PINB,PORTBIT
	rjmp	rb01
	
	WAITMSP	1
	sbis	PINB,PORTBIT

	rjmp	rb01
	
	WAITMSP	3

	ldi	A2,8
rbloop0:
	sbic	PINB,PORTBIT
	rjmp	rbitset
	clc
	rjmp	rbloop1
rbitset:
	sec
rbloop1:
	ror	A1
	WAITMSP	4
	dec	A2
	brne	rbloop0
	com	A1
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

	cbi	DDRB,PORTBIT
	sbi	PORTB,PORTBIT

	cbi	DDRB,JUMPOUT
	cbi	DDRB,JUMPIN
	cbi	PORTB,JUMPIN
	cbi	PORTB,JUMPOUT

	ldi	k,0

	ret

;****************************************************************************
;*
;* Subroutine 'init'
;*
;***************************************************************************

init:	
	ldi	d1,115
	ldi	d2,103
	WAITMSP	255

iloop1:
	sbic	PINB,PORTBIT
	rjmp	iloop1

	ret

;*****************************************************************************
;*
;* Subroutine 'sync'
;* We know that the first character we will receive is an 'S', hex 53.
;* 01010011 -> 10101100 -> 10011010100
;* This means we will get a bitstream of 10011, if we count the start bit
;* (data on the port is inverted and sent LSB first).
;* We use the first five bits of 4 ms each, producing a loop that increments
;* r24,r25 each 10 cycles. This means that for 20 ms, we have 2 ms worth of
;* 'count' in r24,r25. This is divided by two and used as calibration value.
;*
;*****************************************************************************

sync:
	sbis	PINB,PORTBIT
	rjmp sync

	ldi	r24,0
	ldi	r25,0

sloop10:
	nop
	nop
sloop1:
	nop
	sbis	PINB,PORTBIT
	rjmp	sloop2A
	nop
	inc	r25
	brne	sloop10
	inc	r24
	rjmp	sloop1

sloop2A:
	mov	r0,r24
	mov	r1,r25
	rjmp	sloop21
	
sloop20:
	nop
	nop
sloop2:
	nop
	sbic	PINB,PORTBIT
	rjmp	sloop3A
	nop
sloop21:
	inc	r25
	brne	sloop20
	inc	r24
	brne	sloop2
	sec
	ret

sloop3A:
	mov	r2,r24
	mov	r3,r25
	rjmp	sloop31
	
sloop30:
	nop
	nop
sloop3:
	nop
	sbis	PINB,PORTBIT
	rjmp	sdoneA
	nop
sloop31:
	inc	r25
	brne	sloop30
	inc	r24
	brne	sloop3
	sec
	ret
	
sdoneA:
	mov	r4,r24
	mov	r5,r25
	rjmp	sdone
	
sdone:
	lsr	r24
	ror	r25

	LIGHTRED
	cpi	r24,0
	brne	sd01
	sec
	ret

sd01:
	cpi	r24,$20
	brlo	sd02
	sec
	ret

sd02:	
	LIGHTOFF
	subi	r25,8
	sbci	r24,0
	ldi	d1,0
l1:
	cpi	r24,0
	brne	l12
	cpi	r25,9
	brlo	l13
l12:
	subi	r25,9
	sbci	r24,0

	inc	d1
	rjmp	l1

l13:

;* Now wait for rest of character, 010100 (including stop bits)
	WAITMSP	4

	ldi	r24,255
sd10:
	sbic	PINB,PORTBIT
	rjmp	sd2
	dec	r24
	brne	sd10
	sec
	ret

sd2:
	WAITMSP	4

	ldi	r24,255
sd20:
	sbis	PINB,PORTBIT
	rjmp	sd3
	dec	r24
	brne	sd20
	sec
	ret

sd3:
	WAITMSP	4

	ldi	r24,255
sd30:
	sbic	PINB,PORTBIT
	rjmp	sd4
	dec	r24
	brne	sd30
	sec
	ret

sd4:
	WAITMSP	4
	ldi	r24,255
sd40:
	sbis	PINB,PORTBIT
	rjmp	sd5
	dec	r24
	brne	sd40
	sec
	ret

sd5:
	WAITMSP	4
	sbic	PINB,PORTBIT
	rjmp	waitnok
	WAITMSP	4
	sbic	PINB,PORTBIT
	rjmp	waitnok

	clc
	ret


expsend:
	ldi	d1,115
	ldi	d2,103
	sbis	PIND,RSIG
	rjmp	rcheck
	sbic	PIND,LSIG
	rjmp	lcheck
	LIGHTRED
	rjmp	es0

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

	LIGHTRED

es0:
;	rcall	sync
;	brcs	es0

	rcall	readbyte
	cpi	A1,'S'
	brne	es1

	rcall	savebyte

	rcall	readbyte
	cpi	A1,'C'
	brne	es1

	rcall	savebyte

	rcall	readbyte
	cpi	A1,'E'
	brne	es1

	rcall	savebyte

;	ldi	A1,'S'
;	rcall	waitbyte
;	brcs	es0

;	LIGHTBOTH

;	ldi	A1,'C'
;	rcall	waitbyte
;	brcs	expsend

;	ldi	A1,'E'
;	rcall	waitbyte
;	brcs	expsend

	LIGHTGRN

	ENBLANK
	sbi	PORTB,JUMPIN
	cbi	PORTB,PORTBIT
	cbi	DDRB,PORTBIT
	
	ldi	A1,'E'
	rcall	sendbyte
	DEBLANK
	cbi	DDRB,JUMPOUT
	cbi	DDRB,JUMPIN
	cbi	PORTB,JUMPIN
	cbi	PORTB,JUMPOUT
	cbi	DDRB,PORTBIT

	WAITMSP	70

	rjmp	expsend

es1:
	rcall	savebyte
	rjmp	es0

savebyte:
	cpi	A1,0
	breq	sb01
	cpi	k,$40
	brne	sb00
	ldi	k,0
sb00:
	sbic	EECR,EEWE
	rjmp	sb00
	out	EEAR,K
	out	EEDR,A1
	sbi	EECR,EEWE

	inc	k
sb01:
	ret
	
;**********************************************	


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
	rcall	sysinit

	rcall	init

	rjmp	expsend

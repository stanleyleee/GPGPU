# 
# Copyright (C) 2011-2014 Jeff Bush
# 
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
# 
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Library General Public License for more details.
# 
# You should have received a copy of the GNU Library General Public
# License along with this library; if not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
# Boston, MA  02110-1301, USA.
# 

;
; When the processor boots, only one hardware thread will be enabled.  This will
; begin execution at address 0, which will jump immediately to _start.
; This thread will perform static initialization (for example, calling global
; constructors).  When it has completed, it will set a control register to enable 
; the other threads, which will also branch through _start. However, they will branch 
; over the initialization routine and go to main directly.
;

					.text
					.globl _start
					.align 4
					.type _start,@function
_start:				
					; Set up stack
					getcr s0, 0			; get my strand ID
					shl s0, s0, 16		; 64k bytes per stack
					load_32 sp, stacks_base
					sub_i sp, sp, s0	; Compute stack address

					; Set the strand enable mask to the other threads will start.
					move s0, 0xffffffff
					setcr s0, 30

skip_init:			call main
					setcr s0, 29 ; Stop thread, mostly for simulation
done:				goto done

stacks_base:		.long 0x100000
init_array_start:	.long __init_array_start
init_array_end:		.long __init_array_end

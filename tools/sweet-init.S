/*
 * SWEET bring-up init v17: what did wait4 see?
 *
 * v16's dots filled the screen, which means wait4 returned instead of blocking --
 * the forked child was already gone.  This version stops talking after the
 * verdict, so the numbers survive on screen:
 *
 *   *** SWEET userspace v17: fork+exec, wait4 ***
 *    P001              parent pid
 *    W###              raw wait status  (low 7 bits = signal, bits 8..15 = exit code)
 *    R###              wait4's return value
 *    E### (only when carry was set)  errno
 *   then silence.
 *
 * Reading it: signal 4 SIGILL / 5 SIGTRAP / 6 SIGABRT / 10 SIGBUS / 11 SIGSEGV
 * tell us the child died of an exception, an exit code in bits 8..15 means it
 * exited by itself, and ECHILD (10 on Darwin/BSD? no -- 4) means it was never
 * there at all.
 */
#define SYS_write		4
#define SYS_open		5
#define SYS_fork		2
#define SYS_wait4		7
#define SYS_getpid		20
#define SYS_execve		59
#define O_RDONLY		0
#define O_RDWR			2

	.text
	.globl	_start
	.p2align 2
_start:
	mov	x9, sp
	and	x9, x9, #~15
	mov	sp, x9

	adr	x0, path_console
	mov	x1, #O_RDWR
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cs	hang
	mov	x19, x0

	bl	p_banner

	mov	x16, #SYS_fork
	svc	#0x80
	b.cs	frk_fail
	cbnz	x0, parent

	/* ---- child: say who we are, then swap ourselves out ---- */
	bl	p_sp
	adr	x1, s_C
	adr	x2, s_C_end
	sub	x2, x2, x1
	bl	write_console
	mov	x16, #SYS_getpid
	svc	#0x80
	bl	write_dec
	bl	write_nl

	sub	sp, sp, #64
	adr	x3, s_init
	str	x3, [sp]
	str	xzr, [sp, #8]
	str	xzr, [sp, #16]

	adr	x0, path_init
	mov	x1, sp
	add	x2, sp, #16
	mov	x16, #SYS_execve
	svc	#0x80
	b.cc	hang
	mov	x20, x0			/* errno of the first attempt */

	adr	x0, path_init2
	mov	x1, sp
	add	x2, sp, #16
	mov	x16, #SYS_execve
	svc	#0x80
	b.cc	hang

	/* exec failed inside the child: report and stop */
	bl	p_sp
	adr	x1, s_F
	adr	x2, s_F_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x20
	bl	write_dec
	bl	write_nl
	b	hang

	/* ---- parent ---- */
parent:
	mov	x21, x0			/* child pid */
	bl	p_sp
	adr	x1, s_P
	adr	x2, s_P_end
	sub	x2, x2, x1
	bl	write_console
	mov	x16, #SYS_getpid
	svc	#0x80
	bl	write_dec
	bl	write_nl

	sub	sp, sp, #64
	str	xzr, [sp]
	mov	x0, x21
	mov	x1, sp
	mov	x2, #0
	mov	x3, #0
	mov	x16, #SYS_wait4
	svc	#0x80
	mov	x22, x0			/* return value (pid or -1) */
	cset	x23, cs			/* carry set => error */

	bl	p_sp
	adr	x1, s_W
	adr	x2, s_W_end
	sub	x2, x2, x1
	bl	write_console
	ldr	x0, [sp]
	bl	write_dec
	bl	write_nl

	bl	p_sp
	adr	x1, s_R
	adr	x2, s_R_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x22
	bl	write_dec
	bl	write_nl

	add	sp, sp, #64

	cbz	x23, hang		/* no error, nothing more to say */

	bl	p_sp
	adr	x1, s_E
	adr	x2, s_E_end
	sub	x2, x2, x1
	bl	write_console
	bl	write_dec
	bl	write_nl
	b	hang

frk_fail:
	bl	p_sp
	adr	x1, s_EF
	adr	x2, s_EF_end
	sub	x2, x2, x1
	bl	write_console
	bl	write_nl
	b	hang

p_banner:
	stp	x29, x30, [sp, #-16]!
	adr	x1, s_banner
	adr	x2, s_banner_end
	sub	x2, x2, x1
	bl	write_console
	ldp	x29, x30, [sp], #16
	ret

p_sp:
	stp	x29, x30, [sp, #-16]!
	adr	x1, s_space
	adr	x2, s_space_end
	sub	x2, x2, x1
	bl	write_console
	ldp	x29, x30, [sp], #16
	ret

/* write(x19, x1, x2) */
write_console:
	mov	x0, x19
	mov	x16, #SYS_write
	svc	#0x80
	ret

write_nl:
	adr	x1, s_nl
	adr	x2, s_nl_end
	sub	x2, x2, x1
	b	write_console

/* decimal, exactly 3 digits, x0 = value */
write_dec:
	stp	x29, x30, [sp, #-16]!
	sub	sp, sp, #32
	mov	x1, sp
	mov	x11, x0
	mov	x13, #100
	udiv	x14, x11, x13
	mul	x15, x14, x13
	sub	x11, x11, x15
	add	x14, x14, #'0'
	strb	w14, [x1]
	mov	x13, #10
	udiv	x14, x11, x13
	mul	x15, x14, x13
	sub	x11, x11, x15
	add	x14, x14, #'0'
	strb	w14, [x1, #1]
	add	x11, x11, #'0'
	strb	w11, [x1, #2]
	mov	x2, #3
	bl	write_console
	add	sp, sp, #32
	ldp	x29, x30, [sp], #16
	ret

hang:
	b	hang

	.p2align 3
path_console:
	.asciz	"/dev/console"
path_init:
	.asciz	"/sbin/launchd"
path_init2:
	.asciz	"/usr/appleinternal/sbin/launchd.development"
s_init:
	.asciz	"init"
s_banner:
	.ascii	"\n*** SWEET userspace v17: fork+exec, wait4 ***\n"
s_banner_end:
s_space:
	.ascii	" "
s_space_end:
s_P:
	.ascii	"P"
s_P_end:
s_C:
	.ascii	"C"
s_C_end:
s_W:
	.ascii	"W"
s_W_end:
s_R:
	.ascii	"R"
s_R_end:
s_E:
	.ascii	"E"
s_E_end:
s_F:
	.ascii	"F"
s_F_end:
s_EF:
	.ascii	"ERRF"
s_EF_end:
s_nl:
	.ascii	"\n"
s_nl_end:

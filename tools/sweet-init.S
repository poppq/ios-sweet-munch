/*
 * SWEET bring-up init v16: does the forked child ever run?
 *
 * v14: fork returned the parent branch (x0 = child pid, no error) but the child
 *      never wrote a byte.
 * v15: execve("/sbin/launchd") works -- the blob restarts itself forever, so a
 *      fresh image loads fine and process replacement is functional.
 *
 * So the open question is exactly "was the child ever scheduled?".  This version
 * gives that question a unique signature:
 *
 *   *** SWEET userspace v16: fork+exec ***
 *    P001        parent, pid 1, now parked in wait4(child)
 *    C###        child, its own pid, then it execve()s /sbin/launchd
 *
 * If the child runs at all, its exec loop floods the screen with banners -- the
 * parent's single line cannot be confused with that.  If the screen stays put
 * after "P001", the child was created but never scheduled.
 * When wait4 returns, the parent prints " W###" with the wait status.
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

	/* ---- child ---- */
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

	adr	x0, path_init2
	mov	x1, sp
	add	x2, sp, #16
	mov	x16, #SYS_execve
	svc	#0x80
	b.cc	hang

	bl	p_sp
	adr	x1, s_F
	adr	x2, s_F_end
	sub	x2, x2, x1
	bl	write_console
	bl	write_nl
child_dots:
	adr	x1, s_c
	adr	x2, s_c_end
	sub	x2, x2, x1
	bl	write_console
	b	child_dots

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

	sub	sp, sp, #64		/* wait status lives at [sp] */
	mov	x0, x21
	mov	x1, sp
	mov	x2, #0
	mov	x3, #0
	mov	x16, #SYS_wait4
	svc	#0x80

	bl	p_sp
	adr	x1, s_W
	adr	x2, s_W_end
	sub	x2, x2, x1
	bl	write_console
	ldr	x0, [sp]
	bl	write_dec
	add	sp, sp, #64
	bl	write_nl

parent_dots:
	adr	x1, s_B
	adr	x2, s_B_end
	sub	x2, x2, x1
	bl	write_console
	b	parent_dots

frk_fail:
	bl	p_sp
	adr	x1, s_EF
	adr	x2, s_EF_end
	sub	x2, x2, x1
	bl	write_console
	bl	write_nl
	b	parent_dots

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
	.ascii	"\n*** SWEET userspace v16: fork+exec ***\n"
s_banner_end:
s_space:
	.ascii	" "
s_space_end:
s_P:
	.ascii	" P"
s_P_end:
s_C:
	.ascii	" C"
s_C_end:
s_W:
	.ascii	" W"
s_W_end:
s_F:
	.ascii	" F"
s_F_end:
s_EF:
	.ascii	" ERRF"
s_EF_end:
s_nl:
	.ascii	"\n"
s_nl_end:
s_c:
	.ascii	"c"
s_c_end:
s_B:
	.ascii	"."
s_B_end:

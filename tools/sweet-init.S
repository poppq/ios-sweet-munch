/*
 * SWEET bring-up init v18: two live processes
 *
 * v17 proved the forked child really runs -- a second process (pid 2) printed
 * its own "P" line of its own accord.  The only wrong thing was my test: this
 * kernel does not hand the child x0 = 0 out of fork(), so both processes took
 * the parent branch, and the parent's wait4(2) came back ECHILD (R010 / E001)
 * because XNU never registered the child in pid 1's children list either.
 *
 * Branching by process identity instead of by the fork return value fixes it:
 * read getpid() before fork, compare after.
 *
 *   *** SWEET userspace v21: quiet probe, hang after banner ***
 *    P001        parent, pid 1
 *    C002        child, pid 2
 *   then the parent writes "P" and the child writes "c" without pausing, so an
 *   interleaved run like "PccPPcPcccP..." proves both tasks are alive and
 *   sharing one console fd.
 */
#define SYS_write		4
#define SYS_open		5
#define SYS_fork		2
#define SYS_getpid		20
#define SYS_select		93
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
	b	hang

	mov	x16, #SYS_getpid
	svc	#0x80
	mov	x20, x0			/* my pid, before the fork */

	mov	x16, #SYS_fork
	svc	#0x80
	b.cs	frk_fail

	mov	x16, #SYS_getpid
	svc	#0x80
	mov	x22, x0			/* my pid, after the fork */
	cmp	x22, x20
	b.eq	parent

	/* ---- child ---- */
	bl	p_sp
	adr	x1, s_C
	adr	x2, s_C_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x22
	bl	write_dec
	bl	write_nl
child_loop:
	adr	x1, s_c
	adr	x2, s_c_end
	sub	x2, x2, x1
	bl	write_console
	b	child_loop

	/* ---- parent ---- */
parent:
	bl	p_sp
	adr	x1, s_P
	adr	x2, s_P_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x22
	bl	write_dec
	bl	write_nl
parent_loop:
	adr	x1, s_B
	adr	x2, s_B_end
	sub	x2, x2, x1
	bl	write_console
	b	parent_loop

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
s_banner:
	.ascii	"\n*** SWEET userspace v21: quiet probe, hang after banner ***\n"
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
s_EF:
	.ascii	"ERRF"
s_EF_end:
s_nl:
	.ascii	"\n"
s_nl_end:
s_c:
	.ascii	"c"
s_c_end:
s_B:
	.ascii	"P"
s_B_end:

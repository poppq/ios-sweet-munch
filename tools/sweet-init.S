/*
 * SWEET bring-up init v15: execve
 *
 * v14 showed argc = 0 (a flat LC_UNIXTHREAD binary gets no argv), and that a
 * successful fork() only came back on the parent side -- the child never wrote
 * a byte.  So process *creation* is the open question, and the shortest way to
 * answer it is execve: replace this very process with a fresh load of the same
 * blob out of mockfs.
 *
 * The boot log tried two paths in order, so the loader settled on the second:
 *     attempting to load /usr/appleinternal/sbin/launchd.development
 *     attempting to load /sbin/launchd
 * That is where mockfs serves our init, so execve("/sbin/launchd") re-loads it.
 *
 *   *** SWEET userspace v15: execve ***
 *   E001  first run, pid 1, now trying to exec
 *   (on failure) F<errno>  then dots forever
 *
 * If execve succeeds the image restarts itself: the banner and "E" line appear
 * again, endlessly.  A flood of banners and no "F" proves exec works.
 */
#define SYS_write		4
#define SYS_open		5
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
	bl	p_sp
	adr	x1, s_E
	adr	x2, s_E_end
	sub	x2, x2, x1
	bl	write_console
	mov	x16, #SYS_getpid
	svc	#0x80
	bl	write_dec
	bl	write_nl

	/* build argv/envp on the stack, well below sp */
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
	b.cc	hang			/* success never returns */
	mov	x20, x0			/* errno */

	/* second candidate path */
	adr	x0, path_init2
	mov	x1, sp
	add	x2, sp, #16
	mov	x16, #SYS_execve
	svc	#0x80
	b.cc	hang

	/* both failed: report the first errno, then keep ticking */
	bl	p_sp
	adr	x1, s_F
	adr	x2, s_F_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x20
	bl	write_dec
	bl	write_nl

dot_loop:
	adr	x1, s_dot
	adr	x2, s_dot_end
	sub	x2, x2, x1
	bl	write_console
	b	dot_loop

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
	.ascii	"\n*** SWEET userspace v15: execve ***\n"
s_banner_end:
s_space:
	.ascii	" "
s_space_end:
s_E:
	.ascii	"E"
s_E_end:
s_F:
	.ascii	"F"
s_F_end:
s_nl:
	.ascii	"\n"
s_nl_end:
s_dot:
	.ascii	"."
s_dot_end:

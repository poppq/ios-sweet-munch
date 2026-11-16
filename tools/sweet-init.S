/*
 * SWEET bring-up init v13: every name in /dev, and how many there are
 *
 * v12 proved the whole chain works: console fd 0, /dev fd 1, one
 * getdirentries64 call returned 792 bytes, the first record had d_reclen 32,
 * d_namlen 1 and the name "." -- so the dirent layout is
 *   d_reclen u16 @16, d_namlen u16 @18, d_name @21
 * This version walks every record of every 4 KiB chunk, prints each name on
 * its own line, and finishes with " END nnn".
 *
 *   v<console fd> D</dev fd>   then one line per name, then " END nnn"
 *   a dot every 0.5 s after that, so a live process is obvious
 *
 * Every routine saves x29/x30; sp stays 16-byte aligned; the record buffer
 * lives below the entry frame and the basep slot just above it.
 *
 * Position independent, no relocations, no writable data.
 */
#define SYS_write		4
#define SYS_open		5
#define SYS_getdirentries64	344
#define O_RDONLY		0
#define O_RDWR			2

#define DIRENT_RECLEN		16
#define DIRENT_NAMLEN		18
#define DIRENT_NAME		21
#define BUF_LEN			1024
#define ENTRY_MAX		120

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

	/* open("/dev") */
	adr	x0, path_dev
	mov	x1, #O_RDONLY
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cs	p_devfail
	mov	x20, x0

	bl	p_sp
	adr	x1, s_v
	adr	x2, s_v_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x19
	bl	write_dec

	bl	p_sp
	adr	x1, s_d
	adr	x2, s_d_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x20
	bl	write_dec
	bl	write_nl

	/* buffer below the entry frame, basep slot just above it */
	mov	x0, #(BUF_LEN + 64)
	sub	x22, sp, x0		/* [sp-1088, sp-64) */
	mov	x0, #72
	sub	x23, sp, x0		/* basep at sp-72, outside the buffer */

	mov	x21, #0			/* entries printed */

chunk:
	mov	x0, x20
	mov	x1, x22
	mov	x2, #BUF_LEN
	mov	x3, x23
	mov	x16, #SYS_getdirentries64
	svc	#0x80
	b.cs	p_gdefail
	cbz	x0, done		/* end of the directory */
	add	x24, x22, x0		/* end pointer for this chunk */
	mov	x25, x22		/* cursor */

record:
	cmp	x25, x24
	b.hs	chunk
	ldrh	w26, [x25, #DIRENT_RECLEN]
	cbz	w26, done		/* broken record, stop here */
	ldrh	w27, [x25, #DIRENT_NAMLEN]
	cbz	w27, next
	mov	x0, #64
	cmp	x27, x0
	b.ls	1f
	mov	x27, x0			/* clamp a runaway name length */
1:
	add	x1, x25, #DIRENT_NAME
	mov	x2, x27
	bl	write_console		/* the name */
	bl	write_nl
	add	x21, x21, #1

next:
	mov	x0, #ENTRY_MAX
	cmp	x21, x0
	b.hs	done
	add	x25, x25, x26
	b	record

done:
	bl	p_sp
	adr	x1, s_end
	adr	x2, s_end_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x21
	bl	write_dec
	bl	write_nl

tick:
	adr	x1, dot
	adr	x2, dot_end
	sub	x2, x2, x1
	bl	write_console
	movz	x10, #0x928
	lsl	x10, x10, #12		/* 0x928000 = 9,600,000 ticks = 0.5 s */
	bl	busy_wait
	b	tick

p_devfail:
	bl	p_sp
	adr	x1, s_devfail
	adr	x2, s_devfail_end
	sub	x2, x2, x1
	bl	write_console
	bl	write_nl
	b	tick

p_gdefail:
	bl	p_sp
	adr	x1, s_gdefail
	adr	x2, s_gdefail_end
	sub	x2, x2, x1
	bl	write_console
	bl	write_nl
	b	tick

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

/* spin in EL0 for x10 ticks */
busy_wait:
	mrs	x11, cntvct_el0
	add	x11, x11, x10
1:	mrs	x12, cntvct_el0
	cmp	x12, x11
	b.lo	1b
	ret

hang:
	b	hang

	.p2align 3
path_console:
	.asciz	"/dev/console"
path_dev:
	.asciz	"/dev"
s_banner:
	.ascii	"\n*** SWEET userspace v13: devfs names ***\n"
s_banner_end:
s_space:
	.ascii	" "
s_space_end:
s_v:
	.ascii	"v"
s_v_end:
s_d:
	.ascii	"D"
s_d_end:
s_end:
	.ascii	" END"
s_end_end:
s_devfail:
	.ascii	"ERRdev"
s_devfail_end:
s_gdefail:
	.ascii	"ERRgde"
s_gdefail_end:
s_nl:
	.ascii	"\n"
s_nl_end:
dot:
	.ascii	"."
dot_end:

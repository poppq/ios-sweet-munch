/*
 * SWEET bring-up init: mockfs serves the RAM disk itself as /sbin/launchd,
 * so this static binary is PID 1. Version 2 goes past the first write: it
 * opens the console, mounts devfs on /dev, then walks /dev with
 * getdirentries64 and prints every device node it finds. That exercises the
 * mount, vnode and VFS plumbing launchd depends on, and tells us which
 * drivers published anything at all. It then stays alive: init exiting
 * panics the kernel.
 *
 * tools/mkinit.py wraps the assembled __text into a static Mach-O, so this
 * must stay position independent with no relocations and no writable data:
 * every reference is adr (PC-relative), buffers live on the stack.
 *
 * Raw XNU syscalls: number in x16, svc #0x80, carry set on error.
 */
#define SYS_write		4
#define SYS_open		5
#define SYS_getpid		20
#define SYS_select		93
#define SYS_mount		167
#define SYS_getdirentries64	344
#define O_RDONLY		0
#define O_RDWR			2

	.text
	.globl	_start
	.p2align 2
_start:
	/*
	 * The kernel enters a static binary with sp at argc, aligned only to
	 * what the argument/apple strings happened to need. Using a misaligned
	 * sp as a base register raises an SP alignment fault (SIGBUS) on real
	 * hardware (QEMU does not check), so align it like crt0/dyld do.
	 */
	mov	x9, sp
	and	x9, x9, #~15
	mov	sp, x9

	/* console: the one fd every later message goes through */
	adr	x0, path_console
	mov	x1, #O_RDWR
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cs	hang			/* no console: nothing to report to */
	mov	x19, x0

	adr	x1, banner
	adr	x2, banner_end
	sub	x2, x2, x1
	bl	write_console

	/* mount("devfs", "/dev") -> 0 or errno */
	adr	x0, fs_devfs
	adr	x1, path_dev
	mov	x2, #0
	mov	x3, #0
	mov	x16, #SYS_mount
	svc	#0x80
	mov	x20, x0

	adr	x1, msg_mount
	adr	x2, msg_mount_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x20
	bl	print_num
	bl	print_nl

	/* walk /dev and print every node name */
	adr	x0, path_dev
	mov	x1, #O_RDONLY
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cs	no_dir
	mov	x21, x0

	sub	sp, sp, #1104		/* 1024-byte dirent buffer + off_t, 16-aligned */
	mov	x23, sp
	add	x24, sp, #1024
	str	xzr, [x24]
	mov	x22, #0			/* nodes seen */

rd_loop:
	mov	x0, x21
	mov	x1, x23
	mov	x2, #1024
	mov	x3, x24
	mov	x16, #SYS_getdirentries64
	svc	#0x80
	b.cs	rd_close
	cbz	x0, rd_close
	mov	x25, x0			/* bytes this call */
	mov	x26, #0			/* consumed */
	mov	x27, x23		/* cursor */

rd_each:
	ldrh	w11, [x27, #16]		/* d_reclen */
	ldrh	w12, [x27, #18]		/* d_namlen */
	cbz	w12, rd_next		/* skip the '.' slots */
	cbz	w11, rd_close		/* malformed: stop */
	add	x1, x27, #21		/* d_name */
	mov	x2, x12
	bl	write_console
	bl	print_nl
	add	x22, x22, #1
rd_next:
	add	x27, x27, x11
	add	x26, x26, x11
	cmp	x26, x25
	b.lo	rd_each
	b	rd_loop

rd_close:
	add	sp, sp, #1104
	adr	x1, msg_nodes
	adr	x2, msg_nodes_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x22
	bl	print_num
	bl	print_nl
	b	alive

no_dir:
	adr	x1, msg_nodir
	adr	x2, msg_nodir_end
	sub	x2, x2, x1
	bl	write_console
	mov	x0, x20			/* show the open's errno */
	bl	print_num
	bl	print_nl

alive:
	/* select(0, NULL, NULL, NULL, &5s) as a portable sleep */
	mov	x0, #0
	mov	x1, #0
	mov	x2, #0
	mov	x3, #0
	adr	x4, five_sec
	mov	x16, #SYS_select
	svc	#0x80

	adr	x1, tick_msg
	adr	x2, tick_msg_end
	sub	x2, x2, x1
	bl	write_console
	b	alive

/* write(x19, x1, x2) */
write_console:
	mov	x0, x19
	mov	x16, #SYS_write
	svc	#0x80
	ret

/* print x0 in decimal (no leading zeros, 0 prints "0") */
print_num:
	sub	sp, sp, #48
	add	x11, sp, #47
	mov	x12, x0
	mov	x13, #0
1:	mov	x14, #10
	udiv	x15, x12, x14
	mul	x16, x15, x14
	sub	x14, x12, x16
	add	x14, x14, #'0'
	strb	w14, [x11, #-1]!
	add	x13, x13, #1
	mov	x12, x15
	cbnz	x12, 1b
	mov	x1, x11
	mov	x2, x13
	bl	write_console
	add	sp, sp, #48
	ret

print_nl:
	adr	x1, nl
	adr	x2, nl_end
	sub	x2, x2, x1
	b	write_console

hang:
	b	hang

	.p2align 3
five_sec:
	.quad	5			/* tv_sec */
	.quad	0			/* tv_usec */
path_console:
	.asciz	"/dev/console"
path_dev:
	.asciz	"/dev"
fs_devfs:
	.asciz	"devfs"
nl:
	.ascii	"\n"
nl_end:
banner:
	.ascii	"\n*** SWEET userspace v2: PID 1, devfs probe ***\n"
banner_end:
msg_mount:
	.ascii	"SWEET init: mount devfs returned "
msg_mount_end:
msg_nodes:
	.ascii	"SWEET init: device nodes listed above, count "
msg_nodes_end:
msg_nodir:
	.ascii	"SWEET init: open /dev failed, errno "
msg_nodir_end:
tick_msg:
	.ascii	"SWEET init: still alive\n"
tick_msg_end:

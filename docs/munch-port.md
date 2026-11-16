# munch（Redmi K40S，SM8250）移植状态

目标机：Xiaomi munch / 22021211RC / 骁龙 870（SM8250 / kona）/ 8GB / A/B 双槽 /
EMUI 版本线 `V14.0.4.0.TLMEUXM`（国行机刷欧版），Android 13，已解锁 BL。
用户空间：iPhone X（D22AP）iOS 16.7.16 原版，与 sweet 方案一致。

## 1. 数据来源

本机没有 root，`/proc/device-tree/*` 的节点内容被 SELinux 拒绝
（`sysfs` 标签，`shell` uid 2000 读 `reg`/`model` 全部 Permission denied，
只有目录名可列）。因此所有硬件参数来自两个可复现的来源：

1. **小米官方设备树源码**（`MiCode/kernel_devicetree`，分支 `munch-s-oss`）：
   `qcom/kona.dts` + `qcom/munch-sm8250-overlay.dts`（含 `munch-sm8250.dtsi`、
   `xiaomi-sm8250-common.dtsi`）。编译流程见第 4 节，产出 `munch-final.dtb`。
2. **真机 adb 实测**（无 root 可读的部分）：`getprop`、分区表、
   `/sys/bus/spi/devices`、`/proc/meminfo`。

两边的交叉验证结果一致，见第 3 节。

## 2. mkadt 设备档

`tools/mkadt.py` 增加了 `BOARDS` 表与 `--device` 参数（默认 `sweet`，行为不变）：

```bash
python3 tools/mkadt.py munch.adt --device munch        # 生成
python3 tools/mkadt.py munch.adt --device munch --dump # 校验
```

| 项 | sweet | munch | 依据 |
|---|---|---|---|
| dram-base | 0xb0000000 | **0xc0000000** | 真机实测（见第 7 节）：ABL 递过来的 `/memory` 第二段，整段无任何保留区；此前的 0xb2000000 是推导值，已废弃 |
| dram-size | 0x4d000000 | **0x1bf00000**（448MB − 1MB panic log） | 实测第二段 `0xc0000000 + 0x1c000000`，不跨 bank |
| framebuffer | 0x9c000000 | 0x9c000000 | 两边都是 `cont_splash_region`；munch 该区为 `0x9c000000–0x9e300000`（36MB），23MB 画布放得下 |
| GICD / GICR | 0x17a00000 / 0x17a60000 | 同 | munch DTS `interrupt-controller@17a00000` reg=`0x17a00000 0x10000 0x17a60000 0x100000`，与 sweet 完全一致 |
| UFS | 0x1d84000 | 同 | munch DTS `ufshc@1d84000` reg=`0x1d84000 0x3000 0x1d90000 0x8000` |
| CPU | 6×A55 + 2×A76 | 4×A55 + 3×A77 + 1×A77 prime | MPIDR 0x000–0x700 与 sweet 顺序相同 |
| 频率 | 1.80 / 2.30 GHz | 1.80 / 2.42 / 3.19 GHz | 骁龙 870 规格 |
| 内存频率 | 1866 MHz | 2133 MHz | LPDDR5-2133 |
| compatible | `xiaomi,sweet,qcom,sm7150` | `xiaomi,sweet,xiaomi,munch,qcom,sm8250` | `xiaomi,sweet` 必须保留：SweetPlatformExpert 及其驱动按这个名字匹配 |

**结论：shim 无需改动。** `shim/shim.c`（GICD 0x17a00000、GICR 0x17a60000）、
`shim/console.h` / `shim/mmu.h`（FB 0x9c000000）里硬编码的三个地址，
在 munch 上全部成立，无需 per-board 编译。

## 3. 交叉验证

| 项 | 编译出的 DTB | 真机 |
|---|---|---|
| 触控总线 | `/soc/spi@990000` + `focaltech@0` | `/sys/bus/spi/devices/990000.spi` |
| 触控中断/复位 | GPIO 39 / GPIO 33 | munch DTS 同源 |
| 触控范围 | 10800×24000，10 点，SPI 6MHz | munch DTS 同源 |
| UFS + ICE | `0x1d84000` + `0x1d90000` | munch DTS 同源 |
| 内存总量 | 8GB（物理），静态保留区 22 个共 342MB | MemTotal 7,795,916 kB（Android 上报）；ABL 只递 2 段低地址，见第 7 节 |

## 4. 从源码编译 munch 设备树

```bash
# 依赖：apt install device-tree-compiler；内核树 sparse-checkout 需要
# include/dt-bindings、include/uapi、include/linux
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I stub -I <kernel>/include -I <kernel>/include/uapi -I <dt>/qcom \
    <dt>/qcom/kona.dts -o kona.pp.dts
dtc -@ -I dts -O dtb -o kona_symbols.dtb kona.pp.dts     # -@ 生成 __symbols__ 供 fdtoverlay 用
cpp ... <dt>/qcom/munch-sm8250-overlay.dts -o munch.pp.dts
dtc -I dts -O dtb -o munch.dtbo munch.pp.dts
fdtoverlay -i kona_symbols.dtb -o munch.dtb munch.dtbo
```

两个坑（已绕过）：

* 小米未公开 camera 子树，`kona.dtsi` 第 5186 行 `#include "camera/kona-camera.dtsi"`
  找不到 → 用空 stub 目录 `stub/camera/kona-camera.dtsi` 顶上（iOS 无相机支持，不影响）。
* overlay 引用 `cam_cci0` / `cam_cci1` 两个标签（本应来自上面那个 camera 子树）→
  在基座 dts 尾部补两个 `status = "disabled"` 的占位节点后 `fdtoverlay` 才能合并。
* `kona.pp.dts` 里 `/memory` 的 reg 是空的：DDR 容量由 ABL 启动时填充，所有
  Qualcomm 机都这样，不是编译缺漏。

## 5. 待办 / 未验证项

1. **真实 `/memory` 布局未读到**（SELinux 挡住）。当前 dram-base/size 是按
   “避开全部静态行驶区 + 不跨 4GB”推的保守值，不是实测值。若第一次启动在
   极早期挂死（无 console 输出），优先怀疑这里，可用官方 fastboot 包里的
   `boot.img`（同版本 `V14.0.4.0.TLMEUXM`，MD5 `878c063852326e9abadcd4c92eba591b`）
   里的 DTB 校正。
2. `--highmem`（上半 bank，0x1_00000000 起）未按 munch 校正：sm8250 8GB 的上半区
   大小与 sweet 的 `0xfcc00000` 不同，等实测 FDT 再改。
3. 相机子树占位，iOS 侧无驱动，先不管。
4. 触控 / 显示 / 电源的 iOS 侧驱动尚未开始（sm8250 与 sm7150 的 GENI-SPI、
   TLMM 中断号一致，驱动可复用 sweet 的实现，只需换设备树参数）。
5. `research/ipsw-x/d22ap.adt` 尚未提取（缺 IPSW），所以生成的 ADT 里没有
   `/product` 节点；这只影响 iOS 用户空间的 MobileGestalt，不影响 XNU 早期启动。

## 6. M0 诊断镜像（不写任何分区）

`shim/build.sh` 在不给 payload 时会产出一个"自检 + UFS 探测"镜像：
读到 ABL 传来的活 FDT 后打印 DTB 魔数、MMU 映射、GIC 探测、内部 UFS 探测结果，
然后约 3 分钟后自动 reset。正好可以用 `fastboot boot` 直接跑一次，
**不写 boot/dtbo/userdata 任何一个分区**，出错长按电源键 10 秒即可回 Android。

构建（云主机上已验证）：

```bash
sudo apt install -y gcc-aarch64-linux-gnu gawk cpio mkbootimg device-tree-compiler
cp build/munch-final.dtb dtb/boot_unpacked/dtb     # 用第 4 节编译出的 munch 设备树
cd shim && ./build.sh                              # -> out/shim-boot.img（约 1.0MB）
python3 ../tools/unpack_bootv2.py out/shim-boot.img /tmp/chk   # 校验 dtb 已装入
```

Ubuntu 22.04 的两个环境下小坑（已在 `shim/build.sh` 里兼容）：

* binutils 2.38 没有 `--no-warn-rwx-segments`（2.39 才有），脚本现在会探测 ld 能力后决定传不传。
* `truncate` 依赖 awk 的 `strtonum`，mawk 没有，需要装 `gawk`。

预期屏幕（`fastboot boot` 后几秒内）：

```
SHIM     sweet milestone 4: xnu loader
LOADER   <没有 payload 的原因>
UFS      probe done, reset in ~3 min
```

UFS 那行会带出内部 UFS host 的探测结果——这是第一个真正读到你手机硬件的证据
（`ufshc@1d84000`）；如果屏幕一片红或空白，说明 fbcon 的 `0x9c000000`
在这台机器上不是活的 splash 区，需要改用别的地址重编。

执行（手机在 fastboot 下）：

```bash
adb reboot bootloader
fastboot boot shim-boot.img
```

**注意**：`fastboot boot` 只做临时启动，不落盘；但镜像跑完会自动重启回 Android，
中途不要拔线。若卡住不动，长按电源 + 音量下 10 秒强制重启。

## 7. 真机验证（M0.5，2026-11-14，全部 `fastboot boot` 不写盘）

三版诊断镜像依次上机，屏幕输出（红底黄字，fbcon 0x9c000000）实录：

| 项 | 实测值 | 意义 |
|---|---|---|
| FDT | `at=0xAFDFD000 magic=0xD00DFEED total=0x000D7974 rsvmap=0x28` | ABL 在开机时把 FDT 搬到 0xAFDFD000 并改写；891,764 字节，比我们编入的 855,218 大 36KB |
| `/memory` 段数 | `MEMRANGES = 2` | 只有两段，**没有** 0x1_00000000 以上的高 bank |
| 内存段 1 | `0x80000000 + 0x3BB00000` | 0x80000000–0xBBB00000，955MB；含 cont_splash、disp_rdump 等全部静态保留区 |
| 内存段 2 | `0xC0000000 + 0x1C000000` | 0xC0000000–0xDC000000，448MB；**整段干净**，最高保留区只到 0xB1400000 |
| 保留区数量 | `RSVMEM = 0x22`（34 个） | 我们的 DTB 只有 22 个，差的 12 个是 ABL 现场加的 |
| 计时器 | `CNTFRQ = 0x124F800` = 19,200,000 Hz | 与 `mkadt.py` 的 TIMEBASE、shim `to_us()` 假设一致 |
| 本核 MPIDR | `0x81000000` | CPU0，与 ADT `cpus` 的 MPIDR 0x000 对应（Aff0 位在 bit0-7） |
| UFS | `UFS milestone 5 probe (read-only)` 全 rc=0，读出真机 GPT | `ufshc@1d84000` 探测成功；persist/persistbak/logdump/minidump/rawdump/cust/super/rescue/userdata(lba 0x2A0000) 全部与 Android 侧一致 |
| 关机复位 | `RESET in 20s` 后不动 | kona 上 PSCI SYSTEM_RESET 没生效，需长按电源 10 秒；已加 SYSTEM_RESET2 两种尝试，未复测 |

**关键结论**：我们 DTB 里 `/memory` 的 `reg = <0 0 0 0>` 是空的，屏幕上那些地址全是 ABL 现场填的。
因此 `dram-base` 必须以实测为准——这就是 `BOARDS['munch']` 从 `0xb2000000/0x4d000000`
改成 `0xc0000000/0x1c000000` 的原因。

**未解**：手机 SKU 标称 6GB（Android 上报 MemTotal 7,795,916 kB ≈ 7.4GiB，二者本身就矛盾），
而 `fastboot boot` 路径下 ABL 只递了 1.4GB 低地址。可能的解释是高 bank 只在正常 ABL
启动流程里出现，或 fastboot-boot 有意裁掉。这条要在拿到官方 fastboot 包里的 `boot.img`
DTB（或将来用自建 ABL/直接读 DDR）之后交叉验证；在此之前 ADT 只用确认干净的那 448MB。

### 复现步骤（Windows + fastboot）

```powershell
# 1. 手机在 Android、adb 可见时先写好 fastboot 接口 GUID（进 fastboot 后写会掉设备）
.\fix_fastboot_guid3.ps1
# 2. 临时启动诊断镜像（不写任何分区）
.\boot_any.ps1 -Image .\shim-boot-munch3.img
```

`boot_any.ps1` 会 `adb reboot bootloader`、轮询 `fastboot devices`、再 `fastboot boot`，
日志写 `ios-boot\boot.log`。看到 `Sending 'boot.img' OKAY` → `Booting OKAY` → `Finished`
即成功。屏幕转红后手机不初始化 USB，adb/fastboot 都看不到设备，属正常；长按电源 10 秒回 Android。

三版镜像留档（云主机 `ios-sweet/shim/out/`）：

| 版本 | 内容 | 大小 | MD5 |
|---|---|---|---|
| v1 | 自检 + UFS 探测 | 1,044,480 | `C1A265F09E06DC189E16CFC777C9826F` |
| v2 | + FDT dump / CNTFRQ / MPIDR | 1,044,480 | `BFDADA6763AB46935C1492A016FDB261` |
| v3 | + MEMRANGES 全段打印（最多 4 段） | 1,044,480 | `6EA58888339B3EA5DB739D0E86C749C8` |

构建踩坑：shim 镜像里**不能出现 ABS64 重定位**（`build.sh` 会 `grep -c ABS64` 直接报错）。
用 `const char *tbl[8]` 这类指针表会把字符串地址写进 `.data.rel.ro` 变成 6 个 ABS64；
改成 `switch` 选字面量同样产生 6 个（编译器合成跳转表）。唯一干净写法是**逐个 `if` 直接写字面量**
（配合 `mem_base()/mem_size()` 这种无表辅助函数）。

## 8. XNU 构建的 CI 现状（2026-11-14）

XNU 只能在 macOS + Xcode 上编，云主机是 Linux，所以构建走 GitHub Actions：

1. 仓库 `poppq/ios-sweet-munch`（public）。推送方式：因为本地 ios-sweet 是浅克隆、
   推新仓库会报 `did not receive expected object`，改为把工作区 `rsync` 到干净目录、
   `git init` 后单提交推送。
2. 触发：`POST /repos/poppq/ios-sweet-munch/actions/workflows/xnu.yml/dispatches`，
   inputs `macos_version=13.5 kernel_config=DEVELOPMENT machine_config=SWEET keep_going=true`。
3. **踩坑：`runs-on: macos-14` 在该账号上直接 `cancelled`**，注解是
   `The configuration 'macos-14-arm64-us-default' is not supported`。
   实测标签可用性：`macos-15` / `macos-latest` 正常，`macos-13` 长期排队，
   `macos-14` 不可用。
4. **副作用**：macos-15 镜像只有 Xcode 16.x / 26.x（实测 `/Applications` 清单：
   16.0.0–16.4、26.0–26.3），没有上游依赖的 Xcode 15。上游注释说明
   Xcode 16 的 `iig` 会生成带 `IORPC.kernelContent` 的头，而 xnu-8796 没有该成员。
   现在固定用最低档 `Xcode_16.0.0.app` 试编，`keep_going=true` 一次收集全部错误。

## 9. iOS 侧素材（已落地）

- `iPhone10,3` 的 `16.7.16 (20H392)` IPSW 完整下载 6,171,035,648 字节，
  `087-86698-044.dmg` 4,730,814,044B（OS rootfs）、`kernelcache.release.iphone10b` 18,204,358B。
- `Firmware/all_flash/DeviceTree.d22ap.im4p` 33,719B → 用 `tools/adt.py` 的 `im4p_payload()`
  解出 `d22ap.adt` 186,084 字节（`dtre`，未加密）。
- `tools/mkadt.py --device munch` 生成的 `munch.adt` 从 10,100B 变成 **12,784B**，
  `--dump` 里 `/product` 有 `product-name = 'iPhone X'`——没有这节点 MobileGestalt 会认错机型。
- Apple CDN 单连接限速约 50KB/s，24 路并发分片才能到 13–67MB/s 聚合。

未完成：APFS→HFS+ 根镜像（`tools/mkiosroot.sh` 需要 `apfs-fuse` + `mkfs.hfsplus`），
以及 TLMM 按键 / GENI-SPI FocalTech 触控 / 显示驱动均未写。

## 10. 真机首次跑起自建 XNU（2026-11-14 22:50）

第一次把 CI 编出来的内核真正塞进 `fastboot boot` 并跑起来。链路：
`kernel.development.sweet`（17,188,640B）→ `tools/mkpayload.py`（`virt_base 0xfffffe0006000000`、
`entry 0xfffffe000748c488`，payload 16,596,224B）→ `shim/build.sh` → `shim-boot-munch-xnu-v.img`
（17,637,376B，MD5 `5376D2F2F2165BE92F5E48CF1C2A24B4`）→ `fastboot boot`（`Sending 17224 KB OKAY` /
`Booting OKAY` / `Finished`）。

### 10.1 boot-args 的两个必要项

第一版 `debug=0x8 serial=3 cpus=8 keepsyms=1` 只出到 `sweet early 20: kprintf startup complete`
就没声了。原因是 `-enable_kprintf_spam` 没给（NOTES.md 第 313 行的要求）：DEVELOPMENT 配置下
kprintf 默认被静音，且 patch 0012 在 mark 20 之后关掉早期控制台。改成

```
debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -v
```

重打包后帧缓冲控制台上出现完整内核日志（白字黑底，1080×2400 上 `FBCON_SCALE=2`）。

### 10.2 实际跑到的位置（屏幕原文，按输出顺序）

```
OSLog stream configured: stream: 8192 bytes, cache: 2112 bytes / verification: 0
Telemetry: Sampling all tasks once per 1 second
Scheduler: Default of clutch / Setting scheduler priority decay band limit 10
standard timeslicing quantum is 10000 us / standard background quantum is 2500 us
msg_table_max_disp1 = 54  mach_kobj_count = 374
BANK subsystem is initialized / IPC_PTHREAD_PRIORITY subsystem is initialized
panic_trace: PE_arm_debug_enable_trace enter/exit
kdp_core zlib memory 0x8000 / Registered coredump handler for kernel
Serial requested, consistent debug disabled ... configuring debugging over serial
Initializing serial KDP
boot version: sweet-shim
"name" not a kext / "AAPL,phandle" not a kext
ulock_initialize>thread_max=2560, ull_hash_buckets=1024
SWEET PRNG: HMAC-SHA256 registered
SWEET pthread: libpthread-514.100.2 registered
SWEET AMFI: built-in interface registered (XML entitlements)
calling mpo_policy_init for vnguard
Security policy loaded: Guarded vnode policy (vnguard)
SWEET: trust caches unavailable (Image4/AMFI not installed)
keepsyms boot arg specified; keeping Linkedit segment for symbols.
No POST boot-arg set.
SWEET: starting device-tree platform expert
SWEET: platform expert registered
SWEET AKS: AppleKeyStore registered (no passcode, unlocked)
SWEET WDT: IOWatchdog registered (accepts check-ins, never fires)
SWEET SURF: IOCoreSurfaceRoot registered
SWEET HID: buttons registered (test every 0 s)
SWEET HID: touch registered
SWEET BATTERY: static fallback, 100% 4200mV external=1 charging=0
[0]ml_processor_register>pset_find(cluster_id=0) returned pset 0
[0]ml_processor_register>cpu_id 0xffffffe166f86f900 cluster_id 0 cpu_number 0 is type 0
SWEET FB: AppleCLCD 1080x2400 stride 4320 at 0x9c000000, default surface 1, presented as 1125x2436
SWEET CPU: requested=1 selected=1 (limit=0)
cpu_start() cpu: 0
SWEET CPU: cpu=0 entered initCPU mpidr=0x0 EL1 IRQs=1
SWEET CPU: cpu=0 mpidr=0x0 came alive; SGI1 OK
Copyright (c) 1982, 1986, 1989, 1991, 1993 The Regents of the University of California.
MAC Framework successfully initialized
using 1528 buffer headers and 1528 cluster IO buffer headers
SWEET CPU: 1/1 CPUs initialized, SGI1 verified
"vm_compressor_mode" is 4
zone_init: pgzalloc 0xffffffe1008820000:0xffffffe1009174000 (9M) (29 8 slots)
zone_init: map VM 0xffffffe1009174000:0xfffffe14d5cd8000 (19G)
zone_init: map RO / GEN0 / GEN1 / GEN2 / GEN3 / DATA / metadata / metaBits / extra
VM bootstrap done; 85 maps, 165 entries and 502 holes left
IOKit IOMD setOwnership ENABLED
IOKit subsystem is initialized          <-- 屏幕最后一行，之后再无输出
```

也就是说：MMU/TTBR0 切换、pmap、串口与帧缓冲控制台、VM bootstrap、IOKit、平台专家、
AKS/WDT/SURF/HID/静态电池/CPU 拓扑与 SGI1 自检全部通过，卡在 `bsd_init` 的最后一段。

### 10.3 停在 bsd_init 末段的原因判断

`IOKit subsystem is initialized` 之后就是找根文件系统。这次启动既没传 `--ramdisk`，也没给
`rd=md0`，ADT `/chosen/memory-map` 里没有 `RAMDisk`，patch 0022 那条「无 IOMedia 也能找根盘」
的路径也没有盘可找——所以卡在这里是**符合预期**的，不是崩溃。

下一步（唯一缺口）：`tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img` 造 HFS+ 根，
再用 `mkpayload.py --ramdisk root.img` 塞进 payload，boot-args 带 `rd=md0`。

`mkiosroot.sh` 依赖 `apfs-fuse`（读 UDIF/APFS）+ `mkfs.hfsplus` + `rsync -aH`，并且要
`mount -t hfsplus -o loop` 才能写入镜像。当前云主机是容器（无 `/dev/fuse`、无 `/dev/loop`、
`mount` 返回 permission denied），这条链路在容器里做不了，需另找有 mount 权限的执行环境，
见第 11 节。

### 10.4 复位不生效仍然成立

`shim` 的 `reset()`（PSCI `SYSTEM_RESET` + `SYSTEM_RESET2` 两次尝试）在 kona 上依然无效，
内核跑飞之后只能长按电源 10 秒回 Android。内核运行期间手机不初始化 USB，`adb`/`fastboot`
都不可见，这是正常的（不是刷机失败）。

## 11. 根镜像的环境限制（2026-11-14 23:10 实测）

云主机实测能力：

| 检查项 | 结果 |
| --- | --- |
| `/dev/fuse` | 不存在 |
| `/dev/loop*` | 不存在 |
| 免密 sudo | 可用（`sudo -n true` 返回 0） |
| `sudo mount -t tmpfs` | `permission denied`（容器无 CAP_SYS_ADMIN） |
| apfs-fuse / mkfs.hfsplus / 7z / dmg2img | 均未安装（`hfsprogs` apt 有候选包） |

结论：容器里既不能 FUSE 挂 APFS，也不能 loop 挂 HFS+，`mkiosroot.sh` 的原始流程走不通。
可选替代路径（尚未实施）：

1. QEMU-TCG 小虚拟机：apt 装 `qemu-system-arm`，起一个 aarch64 virt 的 Debian，
   把 IPSW 与输出镜像走 9p/virtio 共享，在虚拟机里跑 `mkiosroot.sh`。不需要 KVM/特权。
2. 纯用户态 APFS 读取（`libfsapfs` 或自实现）后直接写 HFS+ 镜像，完全绕开 mount，
   但要自己处理 LZBITMAP 压缩，工作量大。
3. 找一台有完整 Linux 权限的机器（用户自己的 PC 装 WSL2 亦可，本机实测未装 WSL）。

## 12. 持久化内核日志通道：两个被门控掉的开关（2026-11-16 实测）

目标是绕开"拍照读屏"：内核把全部 printf 也写进一个环形缓冲区，再由内核线程定期把它刷到某个分区的尾部，事后用 TWRP 的 root adb 把这段读回来解码。这条链路本身是通的（引导内核对 → 刷日志 → TWRP `dd` 读 1025 块 → 拉到 PC），但连续两次读回都是全 0，最后定位到两处门控：

1. **写权限要显式打开**。`xnu/patches/0030-sweet-ufs-writes.patch` 里写支持由 boot-arg `ufsrw` 决定：`PE_parse_boot_argn("ufsrw", &rw, sizeof(rw)); ... su.writable = (rw != 0);`，而 `sweet_log_start()` 开头就是 `if (!on || !su.writable || ...) return;`。cmdline 里没有 `ufsrw=1` 时分区一律按只读处理，日志线程进去第一句就返回，分区尾部当然全是 0x00 —— 这**不能**当成"内核没跑到 `bsd_init`"的证据。
2. **分区块数必须 ≥ 2×1025**。同一个 `sweet_log_start()` 里还有 `su.nblocks < 2 * SWEET_LOG_BLOCKS` 的检查（`SWEET_LOG_BLOCKS = 1 + 4MiB/4KiB = 1025`）。munch 的 `logfs`（`/dev/block/sda13`）正好 8,388,608B = **2048** 个 4KiB 块，比 2050 少两块，条件永远不成立。

因此可选的目标分区要同时满足：能被 GPT 按名字找到、块数 ≥ 2050、写它不伤用户数据。munch 上实测的分区尺寸：

| 分区 | 设备 | 大小 | 块数（4KiB） | 备注 |
| --- | --- | --- | --- | --- |
| `logfs` | sda13 | 8 MiB | 2048 | 差 2 块，**不够** |
| `oops` | sda15 | 16 MiB | 4096 | 内核 oops 转储区，够用（当前使用） |
| `logdump` | sda25 | 64 MiB | 16384 | 备选 |
| `minidump` | sda26 | 96 MiB | 24576 | 备选 |
| `userdata` | sda34 | 105.6 GiB | 巨大 | 会写坏用户数据尾部 4MiB，**不要用** |

测法（TWRP 内，root adb）：`blockdev --getsize64 /dev/block/sda15` 得 16777216，`dd if=/dev/block/sda15 of=/tmp/x bs=4096 skip=3071 count=1025` 取出尾部 1025 块（`skip = 总块数 - 1025`），`adb pull` 回 PC 后看头 8 字节是否为 `SWEETLOG`。

**现状**：带 `rd=ufsroot0 ufsroot=oops ufsrw=1 sweetlog=1 ...` 的镜像在真机引导后，`oops` 尾部 MD5 确实变了（基线 `2a467354…` → `b21a119b…`），但整块 16MiB 里搜不到 `SWEETLOG`，里面的内容是 Android 自己的内核 dmesg（MIUI 的 pstore 机制写的）。也就是说：**写进去的是 Android 的日志，不是我们的**，说明这轮内核仍未走到 `sweet_ufs_rootdev()`（该函数在 `IOFindBSDRoot` 里被调用，找不到分区会 `panic`）。

下一步（已实施，等 CI 出内核）：见第 13 节。

## 13. 屏幕里程碑（patch 0082）：用编号代替猜

"屏幕停在 `mig_table_max_displ = 54 mach_kobj_count = 374`"这件事一直无法解释：从该打印点到 `bsd_init` 之间，xnu 原本就没有无条件 printf；而帧缓冲控制台写满会回绕，屏幕从上到下不能当执行顺序。与其继续从照片里猜，不如让内核自己报进度。

已有机制：`xnu/patches/0010` 的 `sweet_early.c` 直接往 cont_splash 帧缓冲（PA `0x9c000000`）画字，`0012` 在拆掉 bootstrap TTBR0 之前把这块的 VA 重映射到 `VM_MIN_KERNEL_ADDRESS + ARM_TT_L2_SIZE` 的内核别名，所以打点在 `arm_vm_init` 之后依然有效。但 `0012` 在 `arm_init.c` 里加了一句 `if (serial_exists) { sweet_early_disable(); }` —— 我们的 fbcon 在 `serial_init()` 里当作串口注册成功，于是打点恰好在 stage 20（`kprintf startup complete`）被关掉，之后屏幕上再也没有打点。

patch 0082 做三件事：

1. `arm_init.c`：不再因为 `serial_exists` 关闭打点（`earlyfb=0` 可恢复旧行为）。
2. `sweet_early.c`：允许 stage 到 99，底部色块按 `stage % 22` 重排，避免 stage 变大后写到屏幕外。
3. `startup.c` 与 `bsd_init.c`：在 `kernel_bootstrap()`、`kernel_bootstrap_thread()`、`bsd_init()` 的每一步后面各打一个编号，共 40 个：

| 编号 | 位置 |
| --- | --- |
| 21–22 | `console_init` / `sched_init` 之后 |
| 23 | `STARTUP_SUB_MACH_IPC` 全部跑完（就是 `mig_table_max_displ` 那句的来源） |
| 24–28 | `PMAP_ACTIVATE_KERNEL` / `mapping_free_prime` / `machine_init` / `thread_machine_init_template` / `clock_init` |
| 29–31 | `task_init` / `thread_init` / `workq_init` |
| 32–33 | 创建 bootstrap 线程、`load_context` |
| 34–40 | `idle_thread_create` / `sched_startup` / `thread_daemon_init` / `STARTUP_SUB_THREAD_CALL` / `mapping_adjust` / `clock_service_create` / `device_service_create` |
| 41–44 | `kdp_init` / `STARTUP_SUB_SYSCTL` / `PE_init_iokit` / `STARTUP_SUB_EARLY_BOOT` |
| 45–50 | `initialize_screen` / commpage / `STARTUP_SUB_LOCKDOWN` / `OSKextRemoveKextBootstrap` / `machine_lockdown` / `PE_lockdown_iokit` |
| 51–53 | 进入 `bsd_init` / `bsd_init` 开头 / `bsd_autoconf`（内含 `IOKitBSDInit`，也就是 UFS 根分区打开与日志线程启动的地方） |
| 54–57 | `IOFindBSDRoot` 前后、`vfs_mountroot` 前后 |
| 58–60 | 拿到根 vnode / `load_init_program` 前后 |

屏幕上最后一个编号就是真正卡住的位置，比任何照片堆栈都可靠。补丁已在模拟树上验证可干净应用（4 个文件 26 个 hunk），本地克隆里 commit `4e8f1c2`，CI 正在编。

### 13.1 第一次真机结果：卡在 `bsd_autoconf` 之内

`shim-boot-mile.img`（MD5 `22a12960…`，内核 SHA256 `38ff0806…`）在 munch 上引导后，屏幕上完整打出了 21–52，**没有 53**。也就是说：`bsd_init()` 已经进入，但 `bsd_autoconf()` 没有返回。

同一张照片还暴露出一个此前被误读的事实：**普通 `printf` 在 `mig_table_max_displ` 之后就断了**（此后屏幕上出现的 `zone_init`、`VM bootstrap done` 等其实是更早写下的、被回绕覆盖后残留的内容），而 `sweet_early_mark` 走的是帧缓冲直写的独立通道，一路写到 52。所以"屏幕停在 `mig_table_max_displ`"从来不是卡在那句打印，只是那之后普通 console 输出没了。

由此可知，之前放弃的持久化日志（logfs 2048 块 / oops 里读到 MIUI dmesg）并没有推翻任何结论：内核确实没走到 `IOFindBSDRoot`。

patch 0083 把 `bsd_init()` 函数体从入口到 `bsd_autoconf()` 之间的每一步都打上编号（61–82），因为这段全程没有任何 printf，是唯一还完全黑暗的区域：

| 编号 | 位置 |
| --- | --- |
| 61 | `kauth_init` 之后 |
| 62 | proc/cred 初始化、`execargs_cache` 分配之后 |
| 63 | `mac_policy_initbsd` + credential 关联之后 |
| 64 | `chgproccnt` 之后 |
| 65 | `kmem_suballoc`（`bsd_pageable_map`）之后 |
| 66 | `bsd_bufferinit`（会起 `bcleanbuf_thread`）之后 |
| 67 | `IOKitInitializeTime` 之后 |
| 68 | `vfsinit`（各文件系统注册，含内建 HFS）之后 |
| 69 | `mbinit` 之后 |
| 70 | `aio_init` 之后 |
| 71 | `pshm_cache_init` / `psem_cache_init` 之后 |
| 72 | `dlil_init` 之后 |
| 73 | `domaininit` 之后 |
| 74 | `skywalk_init` 之后 |
| 75 | `necp_init` / `netagent_init` 之后 |
| 76 | `memorystatus_init` 之后 |
| 77 | `sysctl_mib_init` 之后 |
| 78–79 | `kminit()` 前后 |
| 80 | `pseudo_inits` 全部跑完之后 |
| 81–82 | `IOKitBSDInit()` 前后 |

### 13.2 第二个断点：`IOKitInitializeTime()` 等 RTC

`shim-boot-mile3.img`（内核 SHA256 `aa700a7d…`，MD5 `48d3b0f8…`）打出 61–66，最后一个编号是 **66 `bsd_bufferinit done`**，没有 67 —— 卡在 `IOKitInitializeTime()`。

源码在 `iokit/Kernel/IOStartIOKit.cpp`：

```c
void IOKitInitializeTime(void) {
	mach_timespec_t t = { 30, 0 };
#ifndef BCM2837
	IOService::waitForService(IOService::resourceMatching("IORTC"), &t);
#endif
	clock_initialize_calendar();
}
```

它在等一个 `IORTC` 资源。我们的 platform expert 只挂了 AppleCLCD / FocalTech / 假电池这些，**没有任何 RTC 驱动**（munch 的 RTC 在 PMIC 里，要走 SPMI，我们没有 SPMI 驱动），所以 `IORTC` 永远不会被 publish，这个 wait 也就永远不会返回——整机卡在这里，连一口气都不动。

patch 0084：SWEET 下跳过 `IORTC` 的等待（保留 `clock_initialize_calendar()`，时间从零起算），并在这一小段加 83–85 编号，确认它确实过去了。

顺带说明一个设计后果：现在内核没有真实墙上时间，`clock_initialize_calendar()` 会以 1970 年或 boot 时间为基准。等以后接了 PMIC RTC（或从 shim 塞一个 RTC 资源）再补。


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

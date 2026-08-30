---
title: 内核模块入门：hello 与 my_gpio 字符设备
date: 2026-08-30 03:45:00
description: 从 hello.ko 到 misc 字符设备 /dev/mygpio0——file_operations 就是裸机函数指针表的内核版；udev 放权非 root 点灯；内核模块=给跑着的内核打热补丁
tags: [RPi, Linux, Driver, Kernel, Lab]
---

# 内核模块入门：hello 与 my_gpio 字符设备

> **状态声明**：本章为「先成文、后实跑」的实验设计，**未在真机执行**；以
> [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline|ch01]] 升级后的 Bookworm（内核 ≥ 6.6）
> 为前提，代码为本系列的**代码资产**，实跑后按实测修正。所有「预期输出」均为待实测核销占位。

## 本章装备清单

| 分类     | 装备                       | 价格/状态 | 用途                                |
| -------- | -------------------------- | --------- | ----------------------------------- |
| 已有     | 树莓派 4B + MicroSD + 网线 | ✅        | 实验主体                            |
| 已有     | 笔记本（SSH 客户端）       | ✅        | 远程操作、看文档                    |
| 需购买   | 杜邦线 + LED + 330Ω 电阻   | ~¥10      | 接在 GPIO17 上，肉眼可见的电平证据  |
| 建议购买 | 万用表                     | ~¥50      | 量 GPIO17 对 GND 电平，核对 3.3V/0V |

> 本章是纯软件章（写内核代码），但 LED 是唯一「肉眼可见」的输出——强烈建议接上再跑。

### 本章会遇到的词

| 词              | 一句话预览                                               |
| --------------- | -------------------------------------------------------- |
| 内核模块（.ko） | 给正在运行的内核「热插拔」的一段代码，免重启             |
| vermagic        | 模块里烙的内核版本指纹；头文件版本对不上就拒装           |
| insmod / rmmod  | 装载 / 卸载模块的两把螺丝刀                              |
| 字符设备        | Linux 三大设备类之一，像文件一样按字节流 read/write      |
| misc 设备       | 主设备号 10 的「共享公寓」，单设备一条龙注册             |
| 主/次设备号     | 内核给设备编的门牌：楼栋号 + 房间号                      |
| file_operations | 驱动的函数指针表：open/read/write 各指向谁               |
| VFS             | 内核的虚拟文件系统层，把 read() 系统调用分派到具体驱动   |
| udev            | 用户态设备管理守护进程：设备一出现就建 /dev 节点、定权限 |
| ioremap         | 把物理寄存器地址翻译成内核可安全访问的虚拟地址           |

## 目标（先结论）

两个模块拿下内核侧的两件小事，并建立本系列最重要的一个认知锚点：

1. **hello.ko**：模块的最小生命周期——insmod（insert module，装载模块的命令）→ init
   （模块入口函数）→ rmmod（remove module，卸载）→ exit（出口函数），dmesg（读内核日志
   缓冲区的命令）看到双行打印。
2. **my_gpio.ko**：misc（杂项）类字符设备（按字节流读写的设备，见 §3.1）。
   `echo 1 > /dev/mygpio0` 点亮 GPIO17 的 LED，非 root 可写（udev 放权，udev 是用户态设备
   管理守护进程，见 §3.4），`/sys` 节点（sysfs，内核导出到用户态的状态目录树）可读回电平，
   strace（系统调用追踪器）里看得见那次 `write(3, "1\n", 2)`。

锚点：**file_operations 就是裸机「函数指针表」的内核版**。你在 F429 工程里早就写过——把
`init/send/recv` 回调塞进自己的外设驱动结构体，main 里按表调用；内核把这张表标准化成
`struct file_operations`，由 VFS 在每次系统调用时替你分派。

> 📖 **术语卡：file_operations 结构体**
> **是什么**：内核驱动里的一张函数指针表：open/read/write/release 各指向谁，由驱动填写。
> **为什么存在**：内核不关心你的硬件是什么，只按这张表调用——「协议即接口」。
> **类比**：套接字操作表/VFS 的多态分发——同一个 read() 调用，落到不同驱动干不同活。
> ⚠️ 类比边界：VFS 还有权限/锁在前面挡着，驱动函数是被剥光后直接调的。

> 📖 **术语卡：VFS（Virtual File System，虚拟文件系统）**
> **是什么**：内核里「打开/读/写」请求的统一收发室：把 `read()` 按目标类型转给具体文件系统或设备驱动的 file_operations。
> **为什么存在**：让 `cat 文件`、`cat /dev/mygpio0`、`cat /sys/...` 走同一条用户态代码路径。
> **类比**：网络栈里的协议分发层——同一个 socket 接口底下挂 TCP/UDP 各自的实现。
> ⚠️ 类比边界：VFS 分发靠函数指针表，不做协议解析；它只认「这是不是个可打开的东西」。

| #    | 做通标准                                                  | 对应    |
| ---- | --------------------------------------------------------- | ------- |
| R2.1 | insmod/rmmod 成功，dmesg 出现模块打印                     | hello   |
| R2.2 | `echo 1 > /dev/mygpio0` 电平变化；udev 放权后非 root 可写 | my_gpio |
| R2.3 | sysfs 节点读回引脚状态                                    | my_gpio |

## 1. 备台：内核头与版本咬合

```bash
sudo apt update && sudo apt full-upgrade     # 先把内核升到最新并重启
sudo apt install raspberrypi-kernel-headers build-essential
ls -l /lib/modules/$(uname -r)/build         # 必须存在（指向刚升的内核源准备目录）
```

两个包：`raspberrypi-kernel-headers`（树莓派内核头文件——编译模块所需的内核「半成品源码」与构建骨架）、`build-essential`（gcc/make 编译工具套装）。

**命令拆解：** `ls -l /lib/modules/$(uname -r)/build`

| 部分                        | 作用                                                         |
| --------------------------- | ------------------------------------------------------------ |
| `uname -r`                  | 打印运行中内核的版本号，如 `6.6.62-v8+`                      |
| `/lib/modules/<版本>/build` | 每个已装内核一间的「头文件仓库」，build 是指向准备目录的软链 |

**你会看到**：一条指向 `/usr/src/...` 或类似目录的软链接。
**失败了先查**：build 不存在 = headers 没装或版本不是当前内核（apt 升级后没重启）。

> 📖 **术语卡：vermagic（version magic，版本指纹）**
> **是什么**：编译时烙进每个 .ko 的一串内核版本+编译配置指纹（内核版本、SMP、抢占模型等）。
> **为什么存在**：模块与内核同吃一锅饭（共享同一地址空间），ABI 稍有不符就是内存 corruption，
> 所以加载时内核逐字比对，不一致直接拒收。
> **类比**：rpm 的 `so` 依赖版本号检查——但这里是内核态，错配不是报错而是爆炸。
> ⚠️ 类比边界：rpm 错配顶多拒绝运行；内核模块错配可能污染状态，`modprobe --force` 强装是自残。

坑在「版本咬合」：headers 包装的是**仓库里最新**内核的头文件，`uname -r` 是**运行中**内核。
apt 升完内核必须**重启再编译**，否则 vermagic 对不上，insmod 报 invalid module format。

## 2. hello.ko：模块的最小生命周期

```c
// hello.c — 模块生命周期的最小教具
#include <linux/module.h>
#include <linux/init.h>

static int __init hello_init(void)
{
    pr_info("hello: module loaded\n");   /* pr_info=内核打印宏，落进 dmesg */
    return 0;
}

static void __exit hello_exit(void)
{
    pr_info("hello: module unloaded\n");
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
```

```text
# Makefile（注意：配方行必须是真正的 TAB）
obj-m += hello.o
obj-m += my_gpio.o

KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
```

```bash
make
sudo insmod hello.ko && dmesg | tail -2
sudo rmmod hello && dmesg | tail -1
```

**命令拆解：** `$(MAKE) -C $(KDIR) M=$(CURDIR) modules`——模块编译的全部机关：

| 部分               | 作用                                                            |
| ------------------ | --------------------------------------------------------------- |
| `-C $(KDIR)`       | 先切进内核准备目录，借用内核**自己的**顶层 Makefile 与配置      |
| `M=$(CURDIR)`      | 告诉内核构建系统「我的模块源码在当前目录」，编译完把 .ko 送回来 |
| `modules`          | 目标名：只编模块，不编内核本体                                  |
| `obj-m += hello.o` | 「把 hello.o 编成模块」的登记表；.o 由同名 .c 自动生成          |

**你会看到**：一堆中间文件后出现 `hello.ko` 与 `my_gpio.ko`。
**失败了先查**：`No rule to make target` 多半是配方行用了空格而不是 TAB。

**命令拆解：** `sudo insmod hello.ko && dmesg | tail -2`

| 部分       | 作用                                 |
| ---------- | ------------------------------------ |
| `insmod`   | 把编译好的内核模块装进正在运行的内核 |
| `hello.ko` | 内核对象文件（ko=kernel object）     |
| `sudo`     | 装模块要 root（等于直接改内核本体）  |

**你会看到**：命令本身沉默；`dmesg` 里出现 `hello: module loaded`。
**失败了先查**：`Invalid module format`——九成是 vermagic 不匹配（§1 的重启再编译）。

`rmmod hello` 反向卸载：参数是**模块名**（hello）而非文件名；卸载前提是引用计数归零（`lsmod` 可查）。

`MODULE_LICENSE("GPL")` 不只是声明：不写（或写 proprietary）的模块照样能加载，但内核被
**taint**（打「非纯净」标记：`cat /proc/sys/kernel/tainted` 非 0，含义是「此后崩溃官方不
背锅」），且 GPL-only 符号一律拒绝链接——内核世界的开源合规检查点，跑在链接期（GPL-only
符号=内核里标注了 `EXPORT_SYMBOL_GPL` 的接口，只许声明了 GPL 的模块用）。

## 3. my_gpio：misc 字符设备

### 3.1 设计决策：misc_register，不自己开号

> 📖 **术语卡：字符设备与主/次设备号**
> **是什么**：字符设备=按字节流顺序访问的设备（对照：块设备按扇区随机访问，如 SD 卡；
> 网络设备不走文件接口）。每个设备节点有一对门牌号：主号标识驱动（哪栋楼），次号区分
> 该驱动下的具体设备（哪个房间），`ls -l /dev` 里逗号分隔的两段数字就是它们。
> **为什么存在**：`open("/dev/mygpio0")` 时内核按主号找到驱动、把次号递给它。
> **类比**：端口号前还有个协议号——IP 地址定位主机，协议+端口才定位到服务。
> ⚠️ 类比边界：设备号是静态注册的内核资源，端口号没有全局注册簿。

| 路线                           | 样板量     | 设备号                    | 适用                       |
| ------------------------------ | ---------- | ------------------------- | -------------------------- |
| `misc_register()`              | 最少       | 主 10（内核代管），次动态 | 单设备原型/教具——**选它**  |
| `alloc_chrdev_region()` + cdev | 多约 30 行 | 主号动态 + 自管次号       | 需要次设备号体系（多实例） |

> 📖 **术语卡：misc 设备（miscellaneous，杂项设备）**
> **是什么**：主设备号固定为 10 的「共享公寓」：内核的 misc 框架替你管 cdev 注册与设备
> 节点创建，驱动只交一张名字+fops 的登记表（`misc_register()` 一次搞定）。
> **为什么存在**：只为「一个驱动一个设备」的原型省掉 30 行设备号簿记样板。
> **类比**：把域名挂在公共服务下的子域名——不用自己买楼（主号），只领一间房（次号）。
> ⚠️ 类比边界：次号动态分配，重启后可能变；生产多实例设备仍应自管主次号。

理由：misc 主设备号 10 是内核代管的「共享公寓」——注册即由 devtmpfs（内核态的设备节点
自动生成器，/dev 的初始填充者）自动出现
`/dev/mygpio0`，udev 直接可用；教学目标在 file_operations（函数指针表），不在设备号簿记。
（`alloc_chrdev_region()`+cdev 是自己申请主设备号、自己注册 cdev 结构体的全套自管路线，
cdev=内核里代表「一个字符设备实现」的结构体。）

### 3.2 全代码

```c
// my_gpio.c — misc 字符设备：/dev/mygpio0 直控一根 BCM2711 GPIO（教学版）
// 寄存器算术与 ch02 完全一致；基址故意硬编码，ch06（设备树）来治这个毛病。
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/init.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/device.h>

#define GPIO_BASE_PHYS 0xFE200000UL     /* BCM2711 GPIO，手册事实 */
#define GPFSEL(n)      ((0x00 + (n) * 4))
#define GPSET0         0x1C
#define GPCLR0         0x28
#define GPLEV0         0x34

static unsigned int gpio_line = 17;
module_param(gpio_line, uint, 0444);
MODULE_PARM_DESC(gpio_line, "BCM 编号的 GPIO 线（默认 17）");

static void __iomem *gpio_base;

static void mygpio_dir_out(void)
{
    u32 shift = (gpio_line % 10) * 3;
    u32 v = ioread32(gpio_base + GPFSEL(gpio_line / 10));
    v = (v & ~(7u << shift)) | (1u << shift);      /* 001=输出，RMW 只动自己的位 */
    iowrite32(v, gpio_base + GPFSEL(gpio_line / 10));
}

static void mygpio_set(int val)
{
    iowrite32(1u << gpio_line, gpio_base + (val ? GPSET0 : GPCLR0));
}

static int mygpio_open(struct inode *inode, struct file *file)
{
    pr_info("mygpio: open\n");
    return 0;
}

static ssize_t mygpio_write(struct file *f, const char __user *buf,
                            size_t count, loff_t *ppos)
{
    char k;
    if (!count || copy_from_user(&k, buf, 1))
        return -EFAULT;
    if (k != '0' && k != '1')
        return -EINVAL;
    mygpio_set(k - '0');
    return count;                                  /* 告诉 VFS：全消费掉了 */
}

static ssize_t mygpio_read(struct file *f, char __user *buf,
                           size_t count, loff_t *ppos)
{
    char state = '0' + !!(ioread32(gpio_base + GPLEV0) & (1u << gpio_line));
    if (*ppos > 0 || count < 2)
        return 0;                                  /* 第二次 read 返回 EOF */
    if (copy_to_user(buf, (char[]){ state, '\n' }, 2))
        return -EFAULT;
    *ppos = 2;
    return 2;
}

static const struct file_operations mygpio_fops = {
    .owner = THIS_MODULE,
    .open  = mygpio_open,
    .write = mygpio_write,
    .read  = mygpio_read,
};

static ssize_t state_show(struct device *dev,
                          struct device_attribute *attr, char *buf)
{
    u32 lev = ioread32(gpio_base + GPLEV0);
    return sprintf(buf, "%u\n", !!(lev & (1u << gpio_line)));
}
static DEVICE_ATTR_RO(state);

static struct miscdevice mygpio_misc = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = "mygpio0",                            /* → /dev/mygpio0 */
    .fops  = &mygpio_fops,
};

static int __init mygpio_init(void)
{
    int ret;
    gpio_base = ioremap(GPIO_BASE_PHYS, 0x1000);
    if (!gpio_base)
        return -ENOMEM;
    /* 故意不 request_mem_region()：pinctrl 驱动已从设备树领走该区域，
     * 申请会 -EBUSY。cat /proc/iomem | grep -i fe200 能看到「房契」。
     * 生产驱动的正确姿势是 platform 驱动经 DT 拿资源——ch06 治理。 */
    mygpio_dir_out();
    ret = misc_register(&mygpio_misc);
    if (ret) {
        iounmap(gpio_base);
        return ret;
    }
    device_create_file(mygpio_misc.this_device, &dev_attr_state);
    pr_info("mygpio: /dev/mygpio0 ready, line=%u\n", gpio_line);
    return 0;
}

static void __exit mygpio_exit(void)
{
    device_remove_file(mygpio_misc.this_device, &dev_attr_state);
    misc_deregister(&mygpio_misc);
    mygpio_set(0);
    iounmap(gpio_base);
    pr_info("mygpio: unloaded\n");
}

module_init(mygpio_init);
module_exit(mygpio_exit);
MODULE_LICENSE("GPL");
```

三处对位读法：GPFSEL 的 RMW 位算术**一字未改**地搬进内核；`iowrite32/ioread32` 替代裸指针
解引用（Device 内存要有序/屏障访问）；`copy_from_user` 是用户态/内核态的边界海关。

> 📖 **术语卡：ioremap / ioread32 / iowrite32**
> **是什么**：ioremap 把**物理**寄存器地址（如 0xFE200000）映射成内核**虚拟**地址；此后
> 一律用 ioread32/iowrite32 这对访问器读写，不再解引用裸指针。
> **为什么存在**：内核跑在 MMU 开启的虚拟地址空间，物理地址不能直接用；访问器同时保证
> 编译器不重排、访问宽度不缩水（Device 内存不讲常识）。
> **类比**：F429 上 `(volatile uint32_t*)0xFE200000` 的强制转换——内核版=映射+访问宏全家桶。
> ⚠️ 类比边界：裸机一个指针走天下；内核拿到的是**新的**虚拟地址，用完要 iounmap 归还。

> 📖 **术语卡：copy_from_user / copy_to_user**
> **是什么**：跨用户态/内核态边界搬运数据的专用函数：write 路径把用户缓冲区抄进内核，
> read 路径反向。失败（指针非法）返回非 0，驱动按惯例折算成 `-EFAULT`。
> **为什么存在**：用户传来的指针不可信——直接解引用内核就替野指针买单（崩溃/安全漏洞）；
> 这对函数内部带合法性兜底。
> **类比**：海关查验的行李转运——人（用户进程）不进来，货（数据）经检查后转交。
> ⚠️ 类比边界：它只验「地址可访问」，不验内容合法，内容校验（本章的 `'0'/'1'`）是驱动自己的事。

代码里其余几个新面孔：`module_param(gpio_line, uint, 0444)`（声明模块参数——insmod 时可
`insmod my_gpio.ko gpio_line=27` 覆盖）；`DEVICE_ATTR_RO(state)`（一键生成 `/sys/.../state`
只读属性文件，读它=调 state_show）；`MISC_DYNAMIC_MINOR`（次设备号由 misc 框架动态分配）。

### 3.3 编译、加载、使用

```bash
make && sudo insmod my_gpio.ko
ls -l /dev/mygpio0                          # misc 主号 10，次号动态
echo 1 | sudo tee /dev/mygpio0              # LED 亮
echo 0 | sudo tee /dev/mygpio0              # LED 灭
cat /proc/iomem | grep -i fe200             # 看 pinctrl 持有的「房契」
```

insmod 的拆解同 §2（hello.ko 换成 my_gpio.ko 而已）。真正的新面孔是 tee：

**命令拆解：** `echo 1 | sudo tee /dev/mygpio0`

| 部分           | 作用                                                                |
| -------------- | ------------------------------------------------------------------- |
| `echo 1`       | 输出 `1\n` 到标准输出                                               |
| `\|`           | 管道：把前者 stdout 接到后者 stdin                                  |
| `sudo tee`     | sudo 只对 tee 生效；tee 把收到的字节同时写进文件**和**自己的 stdout |
| `/dev/mygpio0` | tee 眼里的「普通文件」，实际是我们的设备节点                        |

**为什么不用 `sudo echo 1 > /dev/mygpio0`**：重定向 `>` 是**你的 shell** 干的，发生在 sudo
之外——sudo 提权的是 echo，打开文件的还是普通用户，照样 Permission denied。
**你会看到**：tee 把 `1` 回显到终端，LED 亮。

最后一行是查「房契」：`/proc/iomem`（内核导出的物理内存占用表——谁领走了哪段物理地址一目了然），
`grep -i fe200`（-i 忽略大小写）过滤出 GPIO 基址 0xFE200000 所在行——持有者应是 pinctrl 驱动。

### 3.4 udev 放权：非 root 可写

> 📖 **术语卡：udev**
> **是什么**：用户态设备管理守护进程：监听内核的设备事件，为每个设备在 /dev 下建节点，
> 并按 `/etc/udev/rules.d/*.rules` 规则文件定属主、属组与权限。
> **为什么存在**：设备节点的「谁能读写」是驱动安全边界的最后一公里，规则化=不用手改权限。
> **类比**：你的主场——DHCP 上线设备后自动推配置。设备插上（uevent）→ 匹配规则 → 落权限。
> ⚠️ 类比边界：udev 只管节点元数据，不转发数据；真正读写仍走驱动的 file_operations。

```bash
sudo tee /etc/udev/rules.d/99-mygpio.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="misc", KERNEL=="mygpio0", GROUP="gpio", MODE="0660"
EOF
sudo udevadm control --reload && sudo udevadm trigger -c add -s misc
getent group gpio && id                      # pi 应在 gpio 组（RPi 传统，待核对）
echo 1 > /dev/mygpio0                        # 无 sudo，LED 亮
```

规则一行读法（逗号分隔的「匹配键==值」+「赋值键=值」）：`ACTION=="add"`（设备加入事件才
命中）、`SUBSYSTEM=="misc"`、`KERNEL=="mygpio0"`（匹配 misc 子系统里名叫 mygpio0 的设备）、
`GROUP="gpio"` + `MODE="0660"`（节点属组设 gpio，属主属组可读写、其他人不给）。

**命令拆解：** `sudo udevadm control --reload && sudo udevadm trigger -c add -s misc`

| 部分                       | 作用                                             |
| -------------------------- | ------------------------------------------------ |
| `udevadm control --reload` | 让 udev 守护进程重读规则目录（新规则至此才生效） |
| `udevadm trigger`          | 对**已在**的设备补发一轮事件——不用拔插重装模块   |
| `-c add -s misc`           | 补发 add 事件（-c），只对 misc 子系统（-s）      |
| `&&`                       | 前一条成功才执行下一条（规则没重载就触发是白忙） |

**你会看到**：命令沉默；`ls -l /dev/mygpio0` 的组变为 gpio、模式 0660。
**失败了先查**：`id` 里看不到 gpio 组——`usermod -aG gpio $USER` 后**重登**才生效；再用 `udevadm info /dev/mygpio0` 核对规则命中。

三层放权哲学一眼看穿：`/dev/mem` 不放（ch02，root only）；`/dev/gpiochip0` 出厂放给 gpio 组
（ch03）；自家节点自己写 udev 规则（本章）——**设备节点权限就是驱动的安全边界**。

## 4. 证据链：strace 里看那一次 write

```bash
strace -e trace=openat,write -s 32 sh -c 'echo 1 > /dev/mygpio0'
```

**命令拆解：** `strace -e trace=openat,write -s 32 sh -c 'echo 1 > /dev/mygpio0'`

| 部分                    | 作用                                                     |
| ----------------------- | -------------------------------------------------------- |
| `strace`                | 系统调用追踪器：用 ptrace 机制贴身记录进程的每个系统调用 |
| `-e trace=openat,write` | 只看这两类调用（openat=打开文件的系统调用），屏蔽噪音    |
| `-s 32`                 | 字符串参数最多打印 32 字节（不然缓冲区全 dump 出来）     |
| `sh -c '...'`           | 起一个 shell 执行命令串——重定向发生在被追踪的子进程里    |

**失败了先查**：找不到设备节点（misc_register 没成功，先 `dmesg` 看模块日志）。

预期看见 `openat("/dev/mygpio0", O_WRONLY...)` 之后紧跟一次 `write(3, "1\n", 2) = 2`——
**一次 echo 就是一次 write 系统调用**，内核在 `mygpio_write` 里替你完成 GPSET 寄存器写。
用户态的「写文件」与裸机的「写寄存器」在 VFS 这张函数指针表上接了头。

## 预期输出（待实测核销）

```text
$ sudo insmod hello.ko && sudo rmmod hello && dmesg | tail -2
hello: module loaded
hello: module unloaded

$ sudo insmod my_gpio.ko && dmesg | tail -1
mygpio: /dev/mygpio0 ready, line=17

$ strace -e trace=write -s 32 sh -c 'echo 1 > /dev/mygpio0' 2>&1 | grep write
write(3, "1\n", 2)                             # LED 亮

$ cat /sys/devices/virtual/misc/mygpio0/state
1
```

## 与 F429/裸机对照

| 概念     | F429 裸机                             | Linux 内核模块                          |
| -------- | ------------------------------------- | --------------------------------------- |
| 驱动骨架 | 自己的结构体塞函数指针，main 里按表调 | file_operations 标准化这张表，VFS 分派  |
| 更新方式 | 停机烧录（openocd，冷更新）           | insmod 热插入（毫秒级，不停机）——热补丁 |
| 谁来调用 | 我的 main / 中断向量直接调            | 框架调：系统调用到达时被 VFS 选中       |
| 崩溃半径 | HardFault = 整机                      | 模块 panic = 整机（没有进程边界兜底）   |

表里几个裸机词顺手展开：HardFault（Cortex-M 内核的致命异常——野指针/非法访问直接整机死机，相当于把段错误升级成断电）；
openocd（开源烧录调试器，经 SWD/JTAG 把固件写进 MCU）；中断向量（MCU 里中断服务函数入口地址的跳转表）。

两句话记住本章：

- **insmod 之于烧录**，就是给跑着的发动机换火花塞之于整台换发动机——合法且快，但手一抖
  整机爆缸；[[2026-08-30-rpi-lab-ch05-request-irq-vs-nvic|ch05（request_irq）]]把威胁模型放大到中断上下文。
- my_gpio 故意硬编码 `0xFE200000`——F429 世界里「代码里写死地址」天经地义，Linux 世界里
  这是被设备树取代的旧习俗，[[2026-08-30-rpi-lab-ch06-device-tree-overlay-spi|ch06]] 专门清算它。

## 待核对清单

- raspberrypi-kernel-headers 与 Bookworm 内核的版本咬合、vermagic 报错实际文案
- misc 设备 sysfs 路径的确切形态（/sys/devices/virtual/misc/mygpio0/state?）
- /proc/iomem 中 GPIO 区域的持有者名称与基址行
- udev trigger 子命令写法（`-c add -s misc`）在 Bookworm 的实际行为；pi 用户默认组里是否有 gpio
- `mygpio_read` 的读法语义（cat 一次 = open+read+read(EOF) 两轮）用 strace 验证

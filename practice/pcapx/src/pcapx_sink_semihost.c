/*
 * pcapx_sink_semihost.c —— 半托管文件 sink（QEMU -semihosting 直写宿主机磁盘）
 *
 * 规格：docs/spec/pcapx.md（SINK_OPEN_FAIL hint 提示 / DROP 行为）
 * 冻结接口：include/pcapx.h（pcapx_sink_t vtable / pcapx_sink_semihost_new）
 *
 * 机制（源码实读，ESP-IDF v6.0.2）：
 *  - esp_vfs_semihost_register(base_path)（components/vfs/include/esp_vfs_semihost.h）
 *    把半托管驱动挂进 VFS；base_path 长度受 ESP_VFS_PATH_MAX=15 限制
 *    （components/vfs/include/esp_vfs.h:45）。
 *  - fopen("/tmp/cap.pcap","wb") 走 newlib → VFS；VFS 命中挂载点后把
 *    「剥掉前缀的剩余路径」传给驱动（vfs.c 的 translate_path：
 *    `return src_path + vfs->path_prefix_len;`）。即驱动只收到 "cap.pcap"。
 *  - 半托管驱动接口 v2「Absolute path support is dropped」
 *    （components/vfs/openocd_semihosting.h 的 SEMIHOSTING_DRV_VERSION 注释），
 *    宿主侧（QEMU/OpenOCD）以「自己进程的 CWD + 收到的相对路径」解析落盘：
 *    /tmp 只是目标机侧的 VFS 挂载名，宿主机上文件落在 QEMU 进程 cwd 下，
 *    文件名是 basename（cap.pcap）。要把文件收进指定宿主目录，就从那个
 *    目录启动 QEMU。
 *
 * 失败模式（对应契约 SINK_OPEN_FAIL）：
 *  - QEMU 未加 -semihosting：esp_cpu_dbgr_is_attached()（xtensa 读 DSRSET，
 *    components/xtensa/include/xt_utils.h）为假 →
 *    esp_vfs_semihost_register() 返回 ESP_ERR_NOT_SUPPORTED（vfs_semihost.c
 *    打 "OpenOCD is not connected!"）；即使 register 侥幸通过，fopen 也会因
 *    FAIL_IF_NO_DEBUGGER() 以 EIO 失败。两种情况本文件都打
 *    E (t) pcapx: SINK_OPEN_FAIL path=... hint='qemu 需追加 -semihosting'。
 *
 * QEMU 直连模式（SIMCALL fallback，S3 集成实证 2026-08-27）：
 *  - Espressif QEMU 的 -semihosting **不模拟 OpenOCD attach**（DSRSET 恒 0），
 *    esp_vfs_semihost 整条 VFS 路径在 QEMU 下必失败；IDF 自己也注明 ARM 约定
 *    "not compatible with Xtensa ISS and QEMU for Xtensa"
 *    （components/vfs/openocd_semihosting.h）。
 *  - QEMU 实际拦截的是 **SIMCALL 指令 + Xtensa ISS 调用号**（V7 Unix 风格编号：
 *    exit=1/read=3/write=4/open=5/close=6/lseek=19，a3..a6 传参、a2 返回、a3
 *    errno），实现见 espressif/qemu target/xtensa/xtensa-semi.c HELPER(simcall)。
 *  - register 返回 ESP_ERR_NOT_SUPPORTED 时本 sink 退化为 raw SIMCALL 直连：
 *    open/write/close 直接作用于宿主文件，路径取 basename（复刻 VFS 通路
 *    「剥挂载前缀」行为），文件落在 QEMU 进程 cwd。
 *  - flags 陷阱：QEMU 把 a4 原样透传给**宿主** open()，而 guest newlib 的
 *    O_CREAT=0x200/_FTRUNC=0x400 与宿主 Linux x86_64（0x40/0x200）位定义
 *    互换取值不同——必须用显式宿主位常数，禁止 <fcntl.h> 宏。
 *
 * 写路径：writer 任务上下文（契约允许阻塞）。VFS 模式每次 write 后立即
 * fflush——lab 流程用 timeout 击杀 QEMU，应用收不到 detach 机会，不 flush 的
 * stdio 缓冲会整段丢失；每包一次半托管 SYS_WRITE 的代价在 lab 规模可忽略。
 * SIMCALL 模式每次 write 即宿主 write(2)，天然落盘，无需 flush。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_vfs.h"
#include "esp_vfs_semihost.h"

#include "pcapx.h"

#define TAG "pcapx"

/* stdio 缓冲：所有 write 都会跟着 fflush，缓冲只为合并「同一次 write 内」
 * 可能的多段 fwrite（此处单段）+ 降低 newlib 默认 128B 缓冲的系统调用粒度 */
#define SEMIHOST_IO_BUF_LEN 4096

/* 构造器接受的 guest 侧完整路径上限（含结尾 NUL） */
#define SEMIHOST_PATH_MAX 128

/* QEMU 直连模式（见文件头注释）：Kconfig 开关 + 仅 xtensa（RISC-V 无 SIMCALL） */
#if defined(__XTENSA__) && defined(CONFIG_PCAPX_SEMIHOST_SIMCALL_FALLBACK)
#define PCAPX_SIMCALL_FALLBACK 1
#else
#define PCAPX_SIMCALL_FALLBACK 0
#endif

/* Xtensa ISS 调用号（espressif/qemu target/xtensa/xtensa-semi.c，S3 实读） */
#define ISS_SYS_WRITE 4L
#define ISS_SYS_OPEN  5L
#define ISS_SYS_CLOSE 6L

/* 宿主 Linux x86_64 的 O_WRONLY|O_CREAT|O_TRUNC = 1|0100|01000 = 0x241。
 * QEMU 把 flags 原样透传给宿主 open()，guest newlib 的 O_* 位定义不同源
 * （O_CREAT=0x200/O_TRUNC=0x400），禁止用 <fcntl.h> 宏组装此值 */
#define ISS_OPEN_WRONLY_CREAT_TRUNC 0x241L

#if PCAPX_SIMCALL_FALLBACK
/* SIMCALL 原语：a2=调用号，a3..a6=参数；返回值 a2、errno a3（QEMU 写回） */
static long semihost_simcall(long nr, long a3, long a4, long a5, long a6,
                             long *errno_out)
{
    register long v2 asm("a2") = nr;
    register long v3 asm("a3") = a3;
    register long v4 asm("a4") = a4;
    register long v5 asm("a5") = a5;
    register long v6 asm("a6") = a6;
    __asm__ __volatile__("simcall" : "+r"(v2), "+r"(v3)
                                 : "r"(v4), "r"(v5), "r"(v6)
                                 : "memory");
    if (errno_out != NULL) {
        *errno_out = v3;
    }
    return v2;
}
#endif

typedef struct {
    pcapx_sink_t base;                        /* 必须是首成员 */
    char name_buf[SEMIHOST_PATH_MAX + 16];    /* "semihost:<path>"，ATTACH 行 sink= 取值 */
    char guest_path[SEMIHOST_PATH_MAX];       /* fopen 用的 guest 侧完整路径 */
    char base_path[ESP_VFS_PATH_MAX + 2];     /* VFS 挂载点 = guest_path 的 dirname */
    FILE *f;
    bool simcall_mode; /* QEMU 直连模式：不经 VFS/newlib，raw SIMCALL 宿主 fd */
    long host_fd;      /* simcall_mode 下的宿主文件描述符 */
    bool we_registered; /* 本 sink 是否执行了 register（close 时才 unregister） */
    uint32_t bytes_written;
    uint32_t writes;
    uint8_t iobuf[SEMIHOST_IO_BUF_LEN];
} semihost_sink_t;

static esp_err_t semihost_open(pcapx_sink_t *s)
{
    semihost_sink_t *me = (semihost_sink_t *)s;
    if (me->f != NULL || me->simcall_mode) {
        return ESP_ERR_INVALID_STATE;
    }

    /* guest_path 形如 "/tmp/cap.pcap"：dirname 作 VFS 挂载点，basename 交给
     * 半托管驱动（最终落在宿主 QEMU 进程 cwd 下，见文件头注释） */
    const char *slash = strrchr(me->guest_path, '/');
    if (slash == NULL || slash[1] == '\0') {
        /* 没有目录部分（非绝对路径）或 basename 为空 */
        ESP_LOGE(TAG, "SINK_OPEN_FAIL path=%s reason=bad_path", me->guest_path);
        return ESP_ERR_INVALID_ARG;
    }
    size_t dlen = (size_t)(slash - me->guest_path);
    if (dlen == 0) {
        dlen = 1; /* "/cap.pcap" → 挂载点 "/" */
    }
    if (dlen > ESP_VFS_PATH_MAX) {
        ESP_LOGE(TAG, "SINK_OPEN_FAIL path=%s reason=mount_path_too_long(%u>%d)",
                 me->guest_path, (unsigned)dlen, ESP_VFS_PATH_MAX);
        return ESP_ERR_INVALID_ARG;
    }
    memcpy(me->base_path, me->guest_path, dlen);
    me->base_path[dlen] = '\0';

    esp_err_t err = esp_vfs_semihost_register(me->base_path);
    if (err == ESP_OK) {
        me->we_registered = true;
    } else if (err == ESP_ERR_INVALID_STATE) {
        /* 已有同路径挂载（上一次 close 未能注销，或应用自己挂的）——复用 */
        ESP_LOGI(TAG, "semihost mount %s already registered, reuse", me->base_path);
    }
#if PCAPX_SIMCALL_FALLBACK
    else if (err == ESP_ERR_NOT_SUPPORTED) {
        /* QEMU：-semihosting 不置 DSRSET，VFS 驱动拒绝（"OpenOCD is not
         * connected!"）。退化为 raw SIMCALL 直连宿主文件（文件头注释）。
         * basename 与 VFS 通路「剥挂载前缀」行为一致：落在 QEMU cwd 下 */
        long host_errno = 0;
        long fd = semihost_simcall(ISS_SYS_OPEN, (long)(slash + 1),
                                   ISS_OPEN_WRONLY_CREAT_TRUNC, 0644, 0,
                                   &host_errno);
        if (fd < 0) {
            /* 契约观察点行（hint 固定文案）+ SIMCALL 专属 detail 行：
             * QEMU 直连模式下 open 失败的典型原因是 basename 非法（如 "."
             * → EISDIR=21）或 QEMU cwd 不可写，detail 行给出 host errno */
            ESP_LOGE(TAG, "SINK_OPEN_FAIL path=%s hint='qemu 需追加 -semihosting'",
                     me->guest_path);
            ESP_LOGE(TAG, "SINK_OPEN_FAIL path=%s reason=simcall_open errno=%ld",
                     me->guest_path, host_errno);
            return ESP_FAIL;
        }
        me->simcall_mode = true;
        me->host_fd = fd;
        me->bytes_written = 0;
        me->writes = 0;
        ESP_LOGI(TAG, "SINK_OPEN sink=semihost-qemu-simcall path=%s fd=%ld "
                      "host_cwd_rel=1", me->guest_path, fd);
        return ESP_OK;
    }
#endif
    else {
        /* 典型：ESP_ERR_NOT_SUPPORTED（无 fallback 编译）—— 调试器未 attach */
        ESP_LOGE(TAG, "SINK_OPEN_FAIL path=%s hint='qemu 需追加 -semihosting'",
                 me->guest_path);
        return err;
    }

    me->f = fopen(me->guest_path, "wb");
    if (me->f == NULL) {
        ESP_LOGE(TAG, "SINK_OPEN_FAIL path=%s hint='qemu 需追加 -semihosting'",
                 me->guest_path);
        if (me->we_registered) {
            esp_vfs_semihost_unregister(me->base_path);
            me->we_registered = false;
        }
        return ESP_FAIL;
    }
    setvbuf(me->f, (char *)me->iobuf, _IOFBF, sizeof(me->iobuf));

    me->bytes_written = 0;
    me->writes = 0;
    ESP_LOGI(TAG, "SINK_OPEN sink=semihost path=%s host_cwd_rel=1", me->guest_path);
    return ESP_OK;
}

static esp_err_t semihost_write(pcapx_sink_t *s, const void *buf, size_t len)
{
    semihost_sink_t *me = (semihost_sink_t *)s;
    if (me->simcall_mode) {
        if (me->host_fd < 0) {
            return ESP_ERR_INVALID_STATE;
        }
        if (len == 0) {
            return ESP_OK;
        }
        long host_errno = 0;
        long w = semihost_simcall(ISS_SYS_WRITE, me->host_fd, (long)buf, (long)len,
                                  0, &host_errno);
        if (w != (long)len) {
            ESP_LOGE(TAG, "SINK_WRITE_FAIL path=%s wrote=%ld want=%u host_errno=%ld",
                     me->guest_path, w, (unsigned)len, host_errno);
            return ESP_FAIL;
        }
        me->bytes_written += (uint32_t)len;
        me->writes++;
        return ESP_OK; /* 宿主 write(2) 直达，无 stdio 缓冲可 flush */
    }

    if (me->f == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (len == 0) {
        return ESP_OK;
    }
    size_t w = fwrite(buf, 1, len, me->f);
    if (w != len) {
        ESP_LOGE(TAG, "SINK_WRITE_FAIL path=%s wrote=%u want=%u ferror=%d",
                 me->guest_path, (unsigned)w, (unsigned)len, ferror(me->f));
        return ESP_FAIL;
    }
    /* 见文件头：timeout 击杀 QEMU 的 lab 流程要求落盘及时性优先 */
    if (fflush(me->f) != 0) {
        ESP_LOGE(TAG, "SINK_FLUSH_FAIL path=%s", me->guest_path);
        return ESP_FAIL;
    }
    me->bytes_written += (uint32_t)len;
    me->writes++;
    return ESP_OK;
}

static esp_err_t semihost_close(pcapx_sink_t *s)
{
    semihost_sink_t *me = (semihost_sink_t *)s;

    if (me->simcall_mode) {
        if (me->host_fd < 0) {
            return ESP_OK; /* open 失败后 core 仍调 close 的情况，幂等处理 */
        }
        semihost_simcall(ISS_SYS_CLOSE, me->host_fd, 0, 0, 0, NULL);
        me->host_fd = -1;
        me->simcall_mode = false;
        ESP_LOGI(TAG, "SINK_CLOSE sink=semihost-qemu-simcall path=%s bytes=%u writes=%u",
                 me->guest_path, (unsigned)me->bytes_written, (unsigned)me->writes);
        return ESP_OK;
    }

    if (me->f == NULL) {
        return ESP_OK; /* open 失败后 core 仍调 close 的情况，幂等处理 */
    }
    fflush(me->f);
    fclose(me->f);
    me->f = NULL;

    esp_err_t err = ESP_OK;
    if (me->we_registered) {
        err = esp_vfs_semihost_unregister(me->base_path);
        if (err != ESP_OK) {
            /* 不致命：挂载点残留只会让下次 attach 走「复用」分支 */
            ESP_LOGW(TAG, "semihost unregister %s: %s", me->base_path, esp_err_to_name(err));
        }
        me->we_registered = false;
    }
    ESP_LOGI(TAG, "SINK_CLOSE sink=semihost path=%s bytes=%u writes=%u",
             me->guest_path, (unsigned)me->bytes_written, (unsigned)me->writes);
    return err;
}

static void semihost_free(pcapx_sink_t *s)
{
    free(s); /* 单块分配（含 name/guest_path/base_path/iobuf），见构造器 */
}

pcapx_sink_t *pcapx_sink_semihost_new(const char *host_path)
{
    if (host_path == NULL || host_path[0] == '\0') {
        return NULL;
    }
    semihost_sink_t *me = calloc(1, sizeof(*me));
    if (me == NULL) {
        return NULL;
    }
    if (snprintf(me->name_buf, sizeof(me->name_buf), "semihost:%s", host_path)
        >= (int)sizeof(me->name_buf)) {
        free(me);
        return NULL; /* 路径过长：视作构造失败（内存口径之外的显式拒绝） */
    }
    strlcpy(me->guest_path, host_path, sizeof(me->guest_path));

    me->base.name = me->name_buf;
    me->base.open = semihost_open;
    me->base.write = semihost_write;
    me->base.close = semihost_close;
    me->base.free_fn = semihost_free;
    me->host_fd = -1; /* calloc 归零的 0 是合法宿主 fd，显式置无效 */
    return &me->base;
}

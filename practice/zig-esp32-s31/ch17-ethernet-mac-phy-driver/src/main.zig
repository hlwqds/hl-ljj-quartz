//! ch17-ethernet-mac-phy-driver：把驱动按“可判读的阶段”跑一遍。
//!
//! 九个阶段，每个阶段都先打印“我准备做什么”，再打印“读回来是什么”：
//!
//!   0. banner —— 这次跑的是哪个形态、哪个时钟
//!   1. 时钟与复位 —— 门控位、MAC 版本寄存器（复位是否真的生效）
//!   2. 引脚 —— IO_MUX 的 MCU_SEL 快照（RGMII 6 出 6 入 + MDC/MDIO）
//!   3. MDIO —— 分频档位、扫 PHY、读 ID/BMSR/ANAR/ANLPAR/千兆状态
//!   4. MAC —— MACCR/MACFF/MAC 地址的读回值
//!   5. DMA —— 软复位、BUSMODE/OPMODE 的读回值
//!   6. 描述符环 —— 每个描述符的物理地址与 OWN 位
//!   7. TX —— 发一帧最小以太网帧，打印 TDES0 的最终值与耗时
//!   8. RX —— 轮询环，打印收到的帧（或“这一轮没有帧”）
//!   9. 收尾 —— 统计 + 待真机验证清单
//!
//! **本章不开中断**：`MIE = 0`、DMA 中断使能全 0，收发都靠轮询。
//! 中断方式在 17.8 里作为对照给出：ETS_SBD_INTR 是中断源 98，
//! 矩阵寄存器 INTERRUPT_CORE0_SBD_INTR_MAP_REG = 0x20585000 + 0x188。

const build_options = @import("build_options");

const descs = @import("descs.zig");
const emac = @import("emac.zig");
const hw = @import("hw.zig");
const log = @import("log.zig");
const phy = @import("phy.zig");
const pins = @import("pins.zig");
const regs = @import("regs.zig");

const mdio_timeout_us: u32 = 2_000;
const dma_reset_timeout_us: u32 = 10_000;
const tx_timeout_us: u32 = 10_000;
const rx_timeout_us: u32 = 50_000;

/// 我们自己分配的本地管理 MAC 地址（第一字节 bit1 = 1 表示本地管理，
/// 且不是组播）。真机上应换成 eFuse 里的 MAC。
const local_mac: [6]u8 = .{ 0x02, 0x00, 0x5A, 0x31, 0x17, 0x01 };

fn printMac(prefix: []const u8, a: [6]u8) void {
    log.line("{s}{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        prefix, a[0], a[1], a[2], a[3], a[4], a[5],
    });
}

fn stageClocks() bool {
    log.raw("-- 1) clocks: HP_SYS_CLKRST.EMAC_CTRL0 + CNNT reset + DMA soft reset + RGMII mux\n");
    emac.enableBusClock();
    log.line("clk: emac_sys_clk_en={d} (hp_sys_clkrst+0x{x} bit0)", .{
        @intFromBool(emac.busClockEnabled()), regs.clkrst_emac_ctrl0,
    });

    emac.resetRegisters();
    const ver = emac.macVersion();
    log.line("rst: mac_version=0x{x:0>8} snps=0x{x:0>2} user=0x{x:0>2} (expect snps=0x37)", .{
        ver, ver & 0xFF, (ver >> 8) & 0xFF,
    });
    log.line("rst: hw_feature=0x{x:0>8} (dma+0x{x})", .{ emac.hwFeature(), regs.dma.hw_feature });

    // 第三轮：先把 RGMII 的 pad 切到 EMAC 功能（`pins.initRgmii()`），再开时钟。
    // 理由：TX/RX 复位时钟（`rst_clk_tx_n`/`rst_clk_rx_n`）两轮都读回 0，
    // 而第二轮的时钟阶段跑在 `stagePins()` 之前——125 MHz 可能根本没有出口。
    pins.initRgmii();

    // 顺序很重要：IDF 的 esp_eth_mac_new_esp32() 在写 DMA 软复位**之前**
    // 就把数据接口时钟（RGMII mux + ref clock）打开了（emac_esp_config_data_interface
    // → emac_hal_clock_enable_rgmii），emac_esp32_init() 才做 SWR。SWR 的文档原话是
    // 「在所有 ETH_MAC 时钟域里都完成后才自清零」——先开时钟，再复位。
    emac.enableRgmiiClocks();
    const ref = emac.readRefClock();
    log.line("clk: rgmii mux + ref_clk sel={d} div={d} en={d} (125MHz = src/(div+1))", .{
        ref.sel, ref.div, @intFromBool(ref.enabled),
    });

    const before = emac.readClockState();
    log.line("clk: gmac_ctrl0=0x{x:0>8} mem_clk_force_on={d} rst_clk_tx_n={d} rst_clk_rx_n={d} cactive={d}", .{
        before.raw,                           @intFromBool(before.mem_clk_forced), @intFromBool(before.tx_clk_released),
        @intFromBool(before.rx_clk_released), @intFromBool(before.axi_active),
    });

    // DMA 软复位必须在**所有** MAC/DMA 寄存器编程之前：SWR 会把 MAC 的
    // 配置寄存器一起清回默认值（gmac_reg.h 的 SWR 说明）。
    if (emac.resetDma(dma_reset_timeout_us)) |_| {
        log.line("rst: dma swr cleared (busmode=0x{x:0>8})", .{hw.readReg(regs.gmac + regs.dma.bus_mode)});
    } else |e| {
        const after = emac.readClockState();
        log.line("rst: dma soft reset failed: {s} (busmode=0x{x:0>8})", .{
            @errorName(e), hw.readReg(regs.gmac + regs.dma.bus_mode),
        });
        log.line("clk: after swr gmac_ctrl0=0x{x:0>8} rst_clk_tx_n={d} rst_clk_rx_n={d} cactive={d}", .{
            after.raw,                      @intFromBool(after.tx_clk_released), @intFromBool(after.rx_clk_released),
            @intFromBool(after.axi_active),
        });
        return false;
    }
    return true;
}

fn stagePins(mdc: u5, mdio: u5) void {
    log.raw("-- 2) pins: RGMII data/clk via IO_MUX func 2, MDC/MDIO via GPIO matrix\n");
    pins.initRgmii();
    pins.initMdio(mdc, mdio);

    var first_out: ?u32 = null;
    var first_in: ?u32 = null;
    for (pins.rgmii_pins) |p| {
        const snap = pins.iomuxSnapshot(p.gpio);
        if (p.input) {
            if (first_in == null) first_in = snap;
        } else {
            if (first_out == null) first_out = snap;
        }
    }
    if (first_out) |s| {
        log.line("pin: txd0(gpio8) mcu_sel={d} ie={d} drv={d} raw=0x{x:0>8}", .{
            pins.mcuSel(s), @intFromBool(pins.inputEnabled(s)), (s >> regs.iomux.drv_shift) & 0x3, s,
        });
    }
    if (first_in) |s| {
        log.line("pin: rxc(gpio14) mcu_sel={d} ie={d} raw=0x{x:0>8}", .{
            pins.mcuSel(s), @intFromBool(pins.inputEnabled(s)), s,
        });
    }
    log.line("pin: mdc=gpio{d} mdio=gpio{d} (matrix: mdc out={d} mdo out={d} mdi in={d})", .{
        mdc, mdio, regs.sig_gmii_mdc_out, regs.sig_gmii_mdo_out, regs.sig_gmii_mdi_in,
    });
    log.line("pin: mdc_out_sel=0x{x} mdio_out_sel=0x{x} mdio_in_sel=0x{x}", .{
        hw.readReg(regs.gpioOutSelAddr(mdc)),
        hw.readReg(regs.gpioOutSelAddr(mdio)),
        hw.readReg(regs.gpioInSelAddr(regs.sig_gmii_mdi_in)),
    });
    log.raw("pin: TODO 待真机验证 - RGMII 组别（GPIO8-19 vs 36-47）与 MDC/MDIO 脚号以原理图为准\n");
}

fn stageMdio() ?emac.PhySnapshot {
    log.raw("-- 3) MDIO: CSR divider + PHY scan + ID/BMSR/ANAR/ANLPAR/GbT\n");
    emac.setCsrDiv(regs.csr_div_safest);
    const div_value = hw.readReg(regs.gmac + regs.mac.gmii_addr);
    log.line("mdio: csr_div={d} (/{d}) gmiiaddr.csr=0x{x}", .{
        regs.csr_div_safest,
        regs.csr_divisors[regs.csr_div_safest],
        (div_value >> regs.gmii_addr.csr_shift) & regs.gmii_addr.csr_mask,
    });

    if (build_options.skip_mdio) {
        log.raw("mdio: skipped by -Dskip-mdio=true\n");
        return null;
    }

    const phy_addr = emac.scanPhy(mdio_timeout_us) orelse {
        log.raw("mdio: no PHY responded (all ids are 0x0000 or 0xffff)\n");
        log.raw("mdio: 可能原因: MDC/MDIO 脚号不对、PHY 无 3.3V、或 RGMII 组别选错\n");
        return null;
    };

    const snap = emac.readPhy(phy_addr, mdio_timeout_us) catch |e| {
        log.line("mdio: read at addr={d} failed: {s}", .{ phy_addr, @errorName(e) });
        return null;
    };
    log.line("mdio: phy_addr={d} ident=0x{x:0>8} oui=0x{x:0>6} model={d} rev={d} vendor={s}", .{
        snap.addr, snap.ident.raw, snap.ident.oui, snap.ident.model, snap.ident.revision, snap.ident.vendor(),
    });

    var caps_buf: [64]u8 = undefined;
    log.line("mdio: bmsr=0x{x:0>4} link={d} an_done={d} caps={s}", .{
        snap.bmsr,
        @intFromBool((snap.bmsr & phy.bmsr.link_up) != 0),
        @intFromBool((snap.bmsr & phy.bmsr.an_complete) != 0),
        phy.bmsrCaps(&caps_buf, snap.bmsr),
    });
    log.line("mdio: anar=0x{x:0>4} anlpar=0x{x:0>4} gb_ctrl=0x{x:0>4} gb_status=0x{x:0>4}", .{
        snap.anar, snap.anlpar, snap.gb_ctrl, snap.gb_status,
    });

    const g = phy.negotiated1000(snap.gb_status);
    const mode = if (g != .unknown) g else phy.negotiatedFromPar(snap.anar, snap.anlpar);
    log.line("mdio: negotiated={s} (1000T_lp={d} local_rx_ok={d} master={d})", .{
        phy.modeName(mode),
        @intFromBool((snap.gb_status & phy.gb_t_status_bits.lp_1000_fd) != 0),
        @intFromBool((snap.gb_status & phy.gb_t_status_bits.local_rx_ok) != 0),
        @intFromBool((snap.gb_status & phy.gb_t_status_bits.master) != 0),
    });
    return snap;
}

fn stageMac(snap: ?emac.PhySnapshot) void {
    log.raw("-- 4) MAC: MACCR/MACFF + MAC address0\n");
    // 协商结果只用来选速度；协商失败时按 1000M 全双工先配（诊断优先）。
    var speed: emac.Speed = .m1000;
    if (snap) |s| {
        const g = phy.negotiated1000(s.gb_status);
        const mode = if (g != .unknown) g else phy.negotiatedFromPar(s.anar, s.anlpar);
        speed = switch (mode) {
            .m1000_fd => .m1000,
            .m100_fd, .m100_hd => .m100,
            .m10_fd, .m10_hd => .m10,
            .unknown => .m1000,
        };
    }
    const cfg = emac.initMacConfig(speed, true);
    emac.setMacAddress(local_mac);

    // TE/RE 此刻必须还是 0：它们由 startDma 按 TE→ST→SR→RE 的顺序打开
    // （IDF emac_hal_start 的实测经验，见 emac.zig 的注释）。
    log.line("mac: cr=0x{x:0>8} (te={d} re={d} dm={d} ps={d} fes={d} apcs={d} ipc={d})", .{
        emac.readMacConfig(),
        @intFromBool((cfg & regs.config.tx) != 0),
        @intFromBool((cfg & regs.config.rx) != 0),
        @intFromBool((cfg & regs.config.dm) != 0),
        @intFromBool((cfg & regs.config.ps) != 0),
        @intFromBool((cfg & regs.config.fes) != 0),
        @intFromBool((cfg & regs.config.apcs) != 0),
        @intFromBool((cfg & regs.config.ipc) != 0),
    });
    log.line("mac: ff=0x{x:0>8} (promiscuous={d} receive_all={d})", .{
        emac.readFrameFilter(),
        @intFromBool((emac.readFrameFilter() & regs.frame_filter.promiscuous) != 0),
        @intFromBool((emac.readFrameFilter() & regs.frame_filter.receive_all) != 0),
    });
    printMac("mac: addr0=", emac.readMacAddress());
    log.line("mac: speed={s} duplex=full (autoneg -> MAC 需要软件跟随)", .{@tagName(speed)});
}

fn stageDma() bool {
    log.raw("-- 5) DMA: BUSMODE/OPMODE (soft reset 已在阶段 1 做过)\n");
    const bus = emac.initDmaDefaults();
    log.line("dma: busmode=0x{x:0>8} (pbl={d} atds={d} aal={d} mb={d} swr={d})", .{
        bus,
        regs.pbl_beats,
        @intFromBool((bus & regs.bus_mode.alt_desc_size) != 0),
        @intFromBool((bus & regs.bus_mode.addr_align) != 0),
        @intFromBool((bus & regs.bus_mode.mixed_burst) != 0),
        @intFromBool((bus & regs.bus_mode.sw_reset) != 0),
    });
    log.line("dma: opmode=0x{x:0>8} intrenable=0x{x:0>8}", .{
        emac.opMode(), hw.readReg(regs.gmac + regs.dma.intr_enable),
    });
    return true;
}

fn stageRings() void {
    log.raw("-- 6) rings: descriptor addresses + OWN bits\n");
    emac.initTxRing();
    emac.initRxRing(true);
    emac.setRingAddresses();
    log.line("ring: desc_size={d}B tx_len={d} rx_len={d} rx_buf={d}B", .{
        descs.desc_bytes, emac.tx_ring_len, emac.rx_ring_len, emac.rx_buf_size,
    });

    var i: usize = 0;
    while (i < emac.tx_ring_len) : (i += 1) {
        log.line("ring: tx[{d}] @0x{x:0>8} des0=0x{x:0>8} next=0x{x:0>8}", .{
            i, @intFromPtr(&emac.tx_ring[i]), emac.tx_ring[i].des0, emac.tx_ring[i].buffer2_or_next,
        });
    }
    i = 0;
    while (i < emac.rx_ring_len) : (i += 1) {
        log.line("ring: rx[{d}] @0x{x:0>8} des0=0x{x:0>8} buf=0x{x:0>8} len={d}", .{
            i,
            @intFromPtr(&emac.rx_ring[i]),
            emac.rx_ring[i].des0,
            emac.rx_ring[i].buffer1,
            emac.rx_ring[i].des1 & descs.rdes1.size1_mask,
        });
    }
    const base = emac.ringPointers();
    log.line("ring: dma rx_base=0x{x:0>8} tx_base=0x{x:0>8}", .{
        base.rx, base.tx,
    });
}

fn stageTx() void {
    log.raw("-- 7) tx: one 60-byte frame (broadcast, ethertype 0x88b5)\n");
    const bcast = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const payload = "ch17 zig s31 emac probe";
    const frame = emac.buildTestFrame(bcast, local_mac, 0x88B5, payload);

    emac.startDma();
    const serve = emac.macTeRe();
    log.line("tx: start order TE->ST->SR->RE done: te={d} re={d} opmode=0x{x:0>8} status=0x{x:0>8}", .{
        @intFromBool(serve.te), @intFromBool(serve.re), emac.opMode(), emac.dmaStatus(),
    });
    log.line("tx: frame_len={d}", .{frame.len});

    const t0 = hw.nowUs();
    const des0 = emac.txFrame(frame.len, tx_timeout_us) catch |e| {
        log.line("tx: failed {s} after {d}us (des0=0x{x:0>8} status=0x{x:0>8})", .{
            @errorName(e), hw.elapsedUs(t0), emac.tx_ring[0].des0, emac.dmaStatus(),
        });
        return;
    };
    log.line("tx: done in {d}us des0=0x{x:0>8} err=0x{x:0>8} status=0x{x:0>8}", .{
        hw.elapsedUs(t0), des0, descs.txErrorMask(des0), emac.dmaStatus(),
    });
    log.raw("tx: TODO 待真机验证 - TDES0.own 是否被 DMA 清掉、err 是否为 0\n");
}

fn stageRx() void {
    log.raw("-- 8) rx: poll ring once (50ms budget)\n");
    const t0 = hw.nowUs();
    var got: u32 = 0;
    while (hw.elapsedUs(t0) < rx_timeout_us) {
        const frame = emac.rxPoll(rx_timeout_us) catch |e| {
            if (e == error.RxError) {
                log.line("rx: error frame des0=0x{x:0>8} err=0x{x:0>8}", .{
                    emac.last_rx_err_des0, descs.rxErrorMask(emac.last_rx_err_des0),
                });
                continue;
            }
            log.line("rx: poll failed: {s}", .{@errorName(e)});
            return;
        };
        if (frame) |f| {
            got += 1;
            log.line("rx: frame#{d} desc[{d}] len={d} des0=0x{x:0>8} err=0x{x:0>8}", .{
                got, f.desc_index, f.len, f.des0, descs.rxErrorMask(f.des0),
            });
            log.line("rx:   dst={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} src={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} type=0x{x:0>4}", .{
                f.head[0],                                f.head[1], f.head[2], f.head[3], f.head[4],  f.head[5],
                f.head[6],                                f.head[7], f.head[8], f.head[9], f.head[10], f.head[11],
                (@as(u16, f.head[12]) << 8) | f.head[13],
            });
            if (got >= 4) break;
        } else break;
    }
    if (got == 0) {
        log.raw("rx: no frame in this window (expected if the PHY has no link partner)\n");
        log.raw("rx: TODO 待真机验证 - 插网线后应至少收到 PHY 的 LLD/自协商帧或广播 ARP\n");
    }
    log.line("rx: frames={d} errs={d} timeouts={d} status=0x{x:0>8}", .{
        emac.stats.rx_frames, emac.stats.rx_err, emac.stats.rx_timeouts, emac.dmaStatus(),
    });
}

fn stageSummary() void {
    log.raw("-- 9) summary\n");
    const ref = emac.readRefClock();
    log.line("sum: tx started={d} done={d} err={d}", .{
        emac.stats.tx_started, emac.stats.tx_done, emac.stats.tx_err,
    });
    log.line("sum: ref_clk sel={d} div={d} en={d} (src: 0=MPLL 1=CPLL 2=APLL)", .{
        ref.sel, ref.div, @intFromBool(ref.enabled),
    });
    log.raw("sum: TODO 待真机验证 清单\n");
    log.raw("sum:   1) MDIO 能扫到 PHY（ID != 0x0000/0xffff）\n");
    log.raw("sum:   2) PHY ID 的 OUI 与原理图上的 PHY 厂商一致\n");
    log.raw("sum:   3) GPIO13(TXC) 上是 125MHz、占空比 50%\n");
    log.raw("sum:   4) 自协商到 1000M 全双工（bmsr.link=1）\n");
    log.raw("sum:   5) TX 一帧后 TDES0.own 被清、err=0\n");
    log.raw("sum:   6) 插网线后 RX 环能进包（至少 ARP/LLDP）\n");
    log.raw("sum:   7) 之后接 18 章 ARP/ICMP，才算“ping 通”验收\n");
}

pub export fn main() noreturn {
    hw.initTimer();
    const boot_us = hw.nowUs();

    log.raw("ch17-ethernet-mac-phy-driver | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.line("build: skip_mdio={d} pbl={d} mdio_timeout={d}us", .{
        @intFromBool(build_options.skip_mdio), regs.pbl_beats, mdio_timeout_us,
    });
    log.raw("clock: TIMG0 T0 1MHz (XTAL 40MHz / 40), MIE=0, polling only\n");

    const wdt = hw.disableRtcWdt();
    log.line("wdt: rtc before=0x{x} after=0x{x} tries={d}", .{ wdt.before, wdt.after, wdt.tries });

    if (!stageClocks()) {
        log.raw("main: clocks/reset unusable, halting (do not debug DMA on a dead clock)\n");
        hw.halt();
    }
    stagePins(pins.default_mdc, pins.default_mdio);
    const snap = stageMdio();
    stageMac(snap);
    if (!stageDma()) {
        log.raw("main: DMA unusable, halting (this is a hard stop, not a warning)\n");
        hw.halt();
    }
    stageRings();
    stageTx();
    stageRx();
    stageSummary();

    emac.stopDma();
    log.line("main: done in {d}us, halting", .{hw.elapsedUs(boot_us)});
    hw.halt();
}

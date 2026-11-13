#!/usr/bin/env python3
"""S31 HIL runner 骨架（离线交付，未上板、未运行）。

设计原则：
- 默认 --dry-run 只打印计划，绝不打开串口、烧录或吸合继电器。
- 真实模式必须由配置 allow_hardware=true 显式解锁；缺依赖/缺配置时直接报错，
  不伪造成功。
- 只依赖 Python 3.10+ 标准库；串口捕获在真实模式下才动态导入 pyserial。

用法：
    python tools/s31-production/hil/hil.py \
        --config tools/s31-production/hil/config.example.json \
        --suite smoke --dry-run

退出码：0 成功；1 步骤失败；2 配置/依赖/参数错误。
"""

from __future__ import annotations

import argparse
import codecs
import json
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

EXIT_OK = 0
EXIT_STEP_FAILED = 1
EXIT_CONFIG = 2

SUITES = ("smoke", "fault", "link", "soak")
MAX_PLANNED_CYCLES = 500
RESULT_SCHEMA = '{"ok": bool, "suite": str, "dry_run": bool, "steps": [...], "artifacts": [...], "error": str?}'


def repo_root() -> Path:
    """仓库根：hil.py -> hil/ -> s31-production/ -> tools/ -> repo。"""
    return Path(__file__).resolve().parents[3]


def resolve_repo_path(value: str) -> Path:
    """配置里的相对路径按仓库根解析，与 README 口径一致；绝对路径原样保留。"""
    path = Path(value).expanduser()
    return path if path.is_absolute() else repo_root() / path


class HilError(Exception):
    """所有可预期错误的基类；exit_code 决定进程退出码。"""

    exit_code = EXIT_CONFIG


class ConfigError(HilError):
    """配置缺字段、类型错误或无法读取。"""


class DependencyError(HilError):
    """缺少 pyserial / esptool / 继电器命令等运行依赖。"""


class StepError(HilError):
    """真实执行期间的单步失败。"""

    exit_code = EXIT_STEP_FAILED


@dataclass
class Step:
    sid: str
    kind: str
    name: str
    params: dict[str, Any] = field(default_factory=dict)
    status: str = "pending"
    detail: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.sid,
            "kind": self.kind,
            "name": self.name,
            "status": self.status,
            "detail": self.detail,
            "params": self.params,
        }


# ---------------------------------------------------------------------------
# 配置加载与校验
# ---------------------------------------------------------------------------


def _require_str(cfg: dict[str, Any], key: str, where: str = "配置") -> str:
    value = cfg.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{where} 字段 {key!r} 必须是非空字符串")
    return value


def _require_int(cfg: dict[str, Any], key: str, where: str, default: int) -> int:
    value = cfg.get(key, default)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ConfigError(f"{where} 字段 {key!r} 必须是整数")
    return value


def _assertion_list(value: Any, where: str) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ConfigError(f"{where} 必须是数组")
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise ConfigError(f"{where}[{index}] 必须是对象")
        name = item.get("name", f"assert-{index}")
        pattern = item.get("pattern")
        if not isinstance(pattern, str) or not pattern:
            raise ConfigError(f"{where}[{index}].pattern 必须是非空字符串")
        try:
            re.compile(pattern)
        except re.error as exc:
            raise ConfigError(f"{where}[{index}].pattern 不是合法正则: {exc}") from exc
        timeout_s = item.get("timeout_s", 10)
        if not isinstance(timeout_s, (int, float)) or isinstance(timeout_s, bool) or timeout_s <= 0:
            raise ConfigError(f"{where}[{index}].timeout_s 必须是正数")
        required = item.get("required", True)
        if not isinstance(required, bool):
            raise ConfigError(f"{where}[{index}].required 必须是布尔值")
        normalized.append(
            {
                "name": str(name),
                "pattern": pattern,
                "timeout_s": float(timeout_s),
                "required": required,
            }
        )
    return normalized


def validate_config(cfg: dict[str, Any]) -> None:
    if not isinstance(cfg, dict):
        raise ConfigError("配置根节点必须是 JSON 对象")

    _require_str(cfg, "port")
    _require_int(cfg, "baud", "配置", 115200)
    _require_str(cfg, "firmware")
    if "artifacts_dir" in cfg:
        _require_str(cfg, "artifacts_dir")

    allow = cfg.get("allow_hardware", False)
    if not isinstance(allow, bool):
        raise ConfigError("字段 'allow_hardware' 必须是布尔值")

    build = cfg.get("build", {})
    if not isinstance(build, dict):
        raise ConfigError("字段 'build' 必须是对象")
    build_enabled = build.get("enabled", False)
    if not isinstance(build_enabled, bool):
        raise ConfigError("build.enabled 必须是布尔值")
    build_command = build.get("command", [])
    if not isinstance(build_command, list) or any(not isinstance(x, str) or not x for x in build_command):
        raise ConfigError("build.command 必须是字符串数组")
    if build_enabled and not build_command:
        raise ConfigError("build.enabled=true 时 build.command 不能为空")
    if "cwd" in build:
        _require_str(build, "cwd", "build")
    build_timeout = build.get("timeout_s", 600)
    if not isinstance(build_timeout, (int, float)) or isinstance(build_timeout, bool) or build_timeout <= 0:
        raise ConfigError("build.timeout_s 必须是正数")

    flash = cfg.get("flash")
    if not isinstance(flash, dict):
        raise ConfigError("字段 'flash' 必须是对象")
    _require_str(flash, "esptool", "flash")
    _require_str(flash, "chip", "flash")
    _require_str(flash, "offset", "flash")
    _require_int(flash, "baud", "flash", 460800)
    extra = flash.get("extra_args", [])
    if not isinstance(extra, list) or any(not isinstance(x, str) for x in extra):
        raise ConfigError("flash.extra_args 必须是字符串数组")

    relay = cfg.get("relay")
    if not isinstance(relay, dict):
        raise ConfigError("字段 'relay' 必须是对象")
    command = relay.get("command")
    if not isinstance(command, list) or not command or any(not isinstance(x, str) or not x for x in command):
        raise ConfigError("relay.command 必须是非空字符串数组")
    joined = " ".join(command)
    for placeholder in ("{channel}", "{state}"):
        if placeholder not in joined:
            raise ConfigError(f"relay.command 必须包含占位符 {placeholder}")
    _require_int(relay, "power_channel", "relay", 1)
    _require_int(relay, "reset_channel", "relay", 2)
    _require_int(relay, "settle_ms", "relay", 500)
    _require_int(relay, "reset_pulse_ms", "relay", 200)
    if "on_value" in relay:
        _require_str(relay, "on_value", "relay")
    if "off_value" in relay:
        _require_str(relay, "off_value", "relay")

    capture = cfg.get("capture", {})
    if not isinstance(capture, dict):
        raise ConfigError("字段 'capture' 必须是对象")
    duration = capture.get("duration_s", 20)
    if not isinstance(duration, (int, float)) or isinstance(duration, bool) or duration <= 0:
        raise ConfigError("capture.duration_s 必须是正数")
    stop = capture.get("stop_pattern")
    if stop is not None:
        if not isinstance(stop, str) or not stop:
            raise ConfigError("capture.stop_pattern 必须是非空字符串或 null")
        try:
            re.compile(stop)
        except re.error as exc:
            raise ConfigError(f"capture.stop_pattern 不是合法正则: {exc}") from exc
    encoding = capture.get("encoding", "utf-8")
    if not isinstance(encoding, str) or not encoding:
        raise ConfigError("capture.encoding 必须是非空字符串")
    try:
        codecs.lookup(encoding)
    except LookupError as exc:
        raise ConfigError(f"capture.encoding 不是已知编码: {encoding}") from exc

    _assertion_list(cfg.get("assertions"), "assertions")
    for section in ("link", "fault", "soak"):
        block = cfg.get(section, {})
        if not isinstance(block, dict):
            raise ConfigError(f"字段 {section!r} 必须是对象")
        _assertion_list(block.get("assertions"), f"{section}.assertions")
        if section in ("fault", "soak"):
            cycles = block.get("cycles", 1 if section == "fault" else 10)
            if not isinstance(cycles, int) or isinstance(cycles, bool) or cycles < 1:
                raise ConfigError(f"{section}.cycles 必须是正整数")
            if cycles > MAX_PLANNED_CYCLES:
                raise ConfigError(f"{section}.cycles={cycles} 超过计划上限 {MAX_PLANNED_CYCLES}")
        if section == "fault":
            off_ms = block.get("power_off_ms", 800)
            if not isinstance(off_ms, (int, float)) or isinstance(off_ms, bool) or off_ms <= 0:
                raise ConfigError("fault.power_off_ms 必须是正数")
        if section == "soak":
            interval = block.get("cycle_interval_s", 2)
            if not isinstance(interval, (int, float)) or isinstance(interval, bool) or interval < 0:
                raise ConfigError("soak.cycle_interval_s 必须是非负数")
            soak_duration = block.get("duration_s", duration)
            if not isinstance(soak_duration, (int, float)) or isinstance(soak_duration, bool) or soak_duration <= 0:
                raise ConfigError("soak.duration_s 必须是正数")


def load_config(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ConfigError(f"配置文件不存在或不是文件: {path}")
    try:
        raw = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ConfigError(f"配置文件不是合法 UTF-8 编码: {path}: {exc}") from exc
    except OSError as exc:
        raise ConfigError(f"无法读取配置文件 {path}: {exc}") from exc
    try:
        cfg = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ConfigError(f"配置文件不是合法 JSON: {path}: {exc}") from exc
    validate_config(cfg)
    return cfg


# ---------------------------------------------------------------------------
# 计划构建（dry-run 与真实模式共用）
# ---------------------------------------------------------------------------


def suite_assertions(suite: str, cfg: dict[str, Any]) -> list[dict[str, Any]]:
    base = _assertion_list(cfg.get("assertions"), "assertions")
    if suite in ("link", "fault", "soak"):
        block = cfg.get(suite, {})
        override = block.get("assertions") if isinstance(block, dict) else None
        if override is not None:
            return _assertion_list(override, f"{suite}.assertions")
    return base


def relay_params(cfg: dict[str, Any], action: str, channel: int) -> dict[str, Any]:
    relay = cfg["relay"]
    return {
        "action": action,
        "channel": channel,
        "command": list(relay["command"]),
        "on_value": relay.get("on_value", "on"),
        "off_value": relay.get("off_value", "off"),
        "settle_ms": int(relay.get("settle_ms", 500)),
        "pulse_ms": int(relay.get("reset_pulse_ms", 200)),
        "timeout_s": float(relay.get("timeout_s", 5)),
    }


def flash_params(cfg: dict[str, Any]) -> dict[str, Any]:
    flash = cfg["flash"]
    cmd = [
        flash.get("esptool", "esptool.py"),
        "--chip",
        flash.get("chip", "esp32s31"),
        "--port",
        cfg["port"],
        "--baud",
        str(int(flash.get("baud", 460800))),
        "write_flash",
        str(flash.get("offset", "0x10000")),
        str(resolve_repo_path(cfg["firmware"])),
    ]
    cmd.extend(str(item) for item in flash.get("extra_args", []))
    return {"cmd": cmd, "timeout_s": float(flash.get("timeout_s", 300))}


def capture_params(
    cfg: dict[str, Any],
    sid: str,
    duration_s: float,
    assertions: list[dict[str, Any]],
) -> dict[str, Any]:
    capture = cfg.get("capture", {})
    return {
        "port": cfg["port"],
        "baud": int(cfg["baud"]),
        "duration_s": float(duration_s),
        "encoding": capture.get("encoding", "utf-8"),
        "stop_patterns": [a["pattern"] for a in assertions],
        "stop_pattern": capture.get("stop_pattern"),
        "log_name": f"{sid}.log",
    }


def wait_params(ms: float) -> dict[str, Any]:
    return {"ms": float(ms)}


def build_plan(suite: str, cfg: dict[str, Any]) -> list[Step]:
    if suite not in SUITES:
        raise ConfigError(f"未知 suite {suite!r}，可选: {', '.join(SUITES)}")

    capture = cfg.get("capture", {})
    soak = cfg.get("soak", {})
    fault = cfg.get("fault", {})
    assertions = suite_assertions(suite, cfg)
    # 抓取窗口取 capture.duration_s 与所有断言 timeout_s 的较大值；
    # 全部断言正则命中后仍会提前结束，避免无谓等待。
    duration = max(
        float(capture.get("duration_s", 20)),
        max((a["timeout_s"] for a in assertions), default=0.0),
    )

    build = cfg.get("build", {})
    steps: list[Step] = [
        Step(
            "build",
            "build",
            "构建固件（可选）",
            {
                "enabled": build.get("enabled", False),
                "command": list(build.get("command", [])),
                "cwd": build.get("cwd"),
                "timeout_s": float(build.get("timeout_s", 600)),
            },
        ),
        Step(
            "preflight",
            "preflight",
            "预检配置、固件与工具链",
            {
                "checks": [
                    "固件文件存在",
                    "esptool 可执行文件可解析",
                    "继电器命令可执行文件可解析",
                    "pyserial 已安装（真实串口抓取需要）",
                ]
            },
        )
    ]

    if suite == "smoke":
        steps.extend(
            [
                Step("power-on", "relay", "上电（释放掉电状态）", relay_params(cfg, "power_on", cfg["relay"]["power_channel"])),
                Step("flash", "flash", "使用 esptool 烧录固件", flash_params(cfg)),
                Step("reset", "relay", "复位脉冲", relay_params(cfg, "reset_pulse", cfg["relay"]["reset_channel"])),
                Step("capture", "capture", f"抓串口输出（最多 {duration:g}s）", capture_params(cfg, "capture", duration, assertions)),
                Step("assert", "assert", "按正则断言启动输出", {"assertions": assertions}),
            ]
        )

    elif suite == "link":
        steps.extend(
            [
                Step("power-on", "relay", "上电", relay_params(cfg, "power_on", cfg["relay"]["power_channel"])),
                Step("flash", "flash", "使用 esptool 烧录固件", flash_params(cfg)),
                Step("reset", "relay", "复位脉冲", relay_params(cfg, "reset_pulse", cfg["relay"]["reset_channel"])),
                Step("capture", "capture", f"抓取链路/DHCP 日志（最多 {duration:g}s）", capture_params(cfg, "capture", duration, assertions)),
                Step("assert", "assert", "断言链路/DHCP 日志", {"assertions": assertions}),
            ]
        )

    elif suite == "fault":
        cycles = int(fault.get("cycles", 5))
        off_ms = float(fault.get("power_off_ms", 800))
        steps.extend(
            [
                Step("power-on", "relay", "上电", relay_params(cfg, "power_on", cfg["relay"]["power_channel"])),
                Step("flash", "flash", "使用 esptool 烧录固件", flash_params(cfg)),
            ]
        )
        for index in range(1, cycles + 1):
            prefix = f"fault-{index:02d}"
            steps.extend(
                [
                    Step(f"{prefix}-power-off", "relay", f"第 {index} 轮掉电", relay_params(cfg, "power_off", cfg["relay"]["power_channel"])),
                    Step(f"{prefix}-wait", "wait", f"第 {index} 轮保持掉电 {off_ms:g}ms", wait_params(off_ms)),
                    Step(f"{prefix}-power-on", "relay", f"第 {index} 轮恢复上电", relay_params(cfg, "power_on", cfg["relay"]["power_channel"])),
                    Step(f"{prefix}-capture", "capture", f"第 {index} 轮抓取恢复日志（最多 {duration:g}s）", capture_params(cfg, f"{prefix}-capture", duration, assertions)),
                    Step(f"{prefix}-assert", "assert", f"第 {index} 轮断言恢复行为", {"assertions": assertions}),
                ]
            )

    else:  # soak
        cycles = int(soak.get("cycles", 10))
        interval_s = float(soak.get("cycle_interval_s", 2))
        soak_duration = max(
            float(soak.get("duration_s", duration)),
            max((a["timeout_s"] for a in assertions), default=0.0),
        )
        steps.extend(
            [
                Step("power-on", "relay", "上电", relay_params(cfg, "power_on", cfg["relay"]["power_channel"])),
                Step("flash", "flash", "使用 esptool 烧录固件", flash_params(cfg)),
            ]
        )
        for index in range(1, cycles + 1):
            prefix = f"soak-{index:02d}"
            steps.extend(
                [
                    Step(f"{prefix}-reset", "relay", f"第 {index} 轮复位", relay_params(cfg, "reset_pulse", cfg["relay"]["reset_channel"])),
                    Step(f"{prefix}-capture", "capture", f"第 {index} 轮抓取启动日志（最多 {soak_duration:g}s）", capture_params(cfg, f"{prefix}-capture", soak_duration, assertions)),
                    Step(f"{prefix}-assert", "assert", f"第 {index} 轮断言启动", {"assertions": assertions}),
                ]
            )
            if interval_s > 0:
                steps.append(Step(f"{prefix}-interval", "wait", f"第 {index} 轮间隔 {interval_s:g}s", wait_params(interval_s * 1000)))

    return steps


def describe_step(step: Step) -> str:
    params = step.params
    kind = step.kind
    if kind == "preflight":
        return "只做只读检查：" + "、".join(params["checks"])
    if kind == "build":
        if not params["enabled"]:
            return "跳过构建（build.enabled=false，使用预构建固件）"
        suffix = f"（cwd={params['cwd']}）" if params.get("cwd") else ""
        return f"将执行构建: {' '.join(params['command'])}{suffix}"
    if kind == "flash":
        return "将执行: " + " ".join(params["cmd"])
    if kind == "relay":
        channel = params["channel"]

        def render(value: str) -> str:
            return " ".join(token.replace("{channel}", str(channel)).replace("{state}", value) for token in params["command"])

        if params["action"] == "reset_pulse":
            return f"将吸合复位通道 {channel} -> {params['on_value']}: {render(params['on_value'])}，{params['pulse_ms']}ms 后释放"
        state = params["on_value"] if params["action"] == "power_on" else params["off_value"]
        return f"将切换通道 {channel} -> {state}: {render(state)}"
    if kind == "capture":
        return f"将打开串口 {params['port']} @ {params['baud']}，最多抓 {params['duration_s']:g}s，日志写入 artifacts/{params['log_name']}"
    if kind == "wait":
        return f"将等待 {params['ms']:g}ms"
    if kind == "assert":
        names = "、".join(a["name"] for a in params["assertions"]) or "（无断言）"
        return f"将在最近一次串口日志上断言: {names}"
    return ""


# ---------------------------------------------------------------------------
# 执行器
# ---------------------------------------------------------------------------


class Runner:
    def __init__(self, cfg: dict[str, Any], suite: str, dry_run: bool) -> None:
        self.cfg = cfg
        self.suite = suite
        self.dry_run = dry_run
        self.log_text = ""
        self.artifacts: list[dict[str, str]] = []
        self.failed = False
        self.first_error: Optional[HilError] = None
        self.run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")

    # -- 入口 ---------------------------------------------------------------

    def run(self, steps: list[Step]) -> None:
        if self.dry_run:
            for step in steps:
                step.status = "planned"
                step.detail = describe_step(step)
            return

        for step in steps:
            try:
                self._execute(step)
                step.status = "ok"
            except HilError as exc:
                step.status = "error"
                step.detail = str(exc)
                self.failed = True
                self.first_error = exc
                break
            except Exception as exc:  # 防止第三方库抛出非预期异常时无上下文
                wrapped = StepError(f"步骤 {step.sid} 意外失败: {type(exc).__name__}: {exc}")
                step.status = "error"
                step.detail = str(wrapped)
                self.failed = True
                self.first_error = wrapped
                break

        if self.failed:
            for step in steps:
                if step.status == "pending":
                    step.status = "skipped"

    def _execute(self, step: Step) -> None:
        handlers = {
            "build": self._exec_build,
            "preflight": self._exec_preflight,
            "flash": self._exec_flash,
            "relay": self._exec_relay,
            "capture": self._exec_capture,
            "wait": self._exec_wait,
            "assert": self._exec_assert,
        }
        handler = handlers.get(step.kind)
        if handler is None:
            raise StepError(f"未知步骤类型: {step.kind}")
        handler(step)
        if not step.detail:
            step.detail = "完成"

    # -- 各步骤 -------------------------------------------------------------

    def _exec_build(self, step: Step) -> None:
        params = step.params
        if not params["enabled"]:
            step.detail = "跳过：build.enabled=false，使用预构建固件"
            return
        cmd = list(params["command"])
        cwd = params.get("cwd")
        cwd_path: Optional[Path] = None
        if cwd:
            cwd_path = resolve_repo_path(cwd)
            if not cwd_path.is_dir():
                raise StepError(f"build.cwd 不存在或不是目录: {cwd_path}")
        print(f"[hil] 构建: {' '.join(cmd)}", file=sys.stderr)
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(cwd_path) if cwd_path is not None else None,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=float(params["timeout_s"]),
                check=False,
            )
        except FileNotFoundError as exc:
            raise DependencyError(f"无法启动构建命令 {cmd[0]!r}: {exc}") from exc
        except subprocess.TimeoutExpired as exc:
            raise StepError(f"构建超时（>{params['timeout_s']}s）") from exc
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-8:]
            raise StepError(f"构建失败 rc={proc.returncode}: " + " | ".join(tail))
        step.detail = "构建成功 rc=0"

    def _exec_preflight(self, step: Step) -> None:
        problems: list[str] = []
        notes: list[str] = []

        firmware = resolve_repo_path(self.cfg["firmware"])
        if not firmware.is_file():
            problems.append(f"固件文件不存在: {firmware}")

        esptool = str(self.cfg["flash"].get("esptool", "esptool.py"))
        if shutil.which(esptool) is None:
            problems.append(f"未找到 esptool 可执行文件: {esptool!r}（检查 PATH 或 flash.esptool）")

        relay_cmd = self.cfg["relay"]["command"]
        relay_exe = relay_cmd[0]
        if shutil.which(relay_exe) is None:
            problems.append(f"未找到继电器命令可执行文件: {relay_exe!r}（检查 PATH 或 relay.command）")

        try:
            import importlib.util

            if importlib.util.find_spec("serial") is None:
                problems.append("未安装 pyserial（真实串口抓取需要: python -m pip install pyserial）")
        except (ImportError, ValueError) as exc:  # 极端环境下的解释器问题
            problems.append(f"无法检查 pyserial: {exc}")

        notes.append(f"串口: {self.cfg['port']} @ {self.cfg['baud']}")
        if problems:
            raise DependencyError("预检失败: " + "；".join(problems))
        step.detail = "预检通过: " + "；".join(notes)

    def _exec_flash(self, step: Step) -> None:
        params = step.params
        cmd = list(params["cmd"])
        print(f"[hil] 烧录: {' '.join(cmd)}", file=sys.stderr)
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=float(params["timeout_s"]),
                check=False,
            )
        except FileNotFoundError as exc:
            raise DependencyError(f"无法启动烧录命令 {cmd[0]!r}: {exc}") from exc
        except subprocess.TimeoutExpired as exc:
            raise StepError(f"烧录超时（>{params['timeout_s']}s）") from exc
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-8:]
            raise StepError(f"esptool 烧录失败 rc={proc.returncode}: " + " | ".join(tail))
        step.detail = f"烧录成功 rc=0（{Path(self.cfg['firmware']).name}）"

    def _exec_relay(self, step: Step) -> None:
        params = step.params
        channel = int(params["channel"])
        command = list(params["command"])

        def switch(value: str) -> None:
            cmd = [token.replace("{channel}", str(channel)).replace("{state}", value) for token in command]
            print(f"[hil] 继电器: {' '.join(cmd)}", file=sys.stderr)
            try:
                proc = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=float(params["timeout_s"]),
                    check=False,
                )
            except FileNotFoundError as exc:
                raise DependencyError(f"无法启动继电器命令 {cmd[0]!r}: {exc}") from exc
            except subprocess.TimeoutExpired as exc:
                raise StepError(f"继电器命令超时（>{params['timeout_s']}s）: {' '.join(cmd)}") from exc
            if proc.returncode != 0:
                tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-4:]
                raise StepError(f"继电器命令失败 rc={proc.returncode}: " + " | ".join(tail))

        action = params["action"]
        if action == "power_on":
            switch(params["on_value"])
            time.sleep(int(params["settle_ms"]) / 1000.0)
            step.detail = f"通道 {channel} -> {params['on_value']}，稳定 {params['settle_ms']}ms"
        elif action == "power_off":
            switch(params["off_value"])
            time.sleep(int(params["settle_ms"]) / 1000.0)
            step.detail = f"通道 {channel} -> {params['off_value']}，稳定 {params['settle_ms']}ms"
        elif action == "reset_pulse":
            switch(params["on_value"])
            time.sleep(int(params["pulse_ms"]) / 1000.0)
            switch(params["off_value"])
            step.detail = f"复位通道 {channel} 脉冲 {params['pulse_ms']}ms"
        else:
            raise StepError(f"未知继电器动作: {action}")

    def _exec_wait(self, step: Step) -> None:
        ms = float(step.params["ms"])
        time.sleep(ms / 1000.0)
        step.detail = f"等待 {ms:g}ms"

    def _exec_capture(self, step: Step) -> None:
        params = step.params
        encoding = params["encoding"]
        try:
            import serial  # type: ignore[import-not-found]
        except ImportError as exc:
            raise DependencyError("缺少 pyserial，无法抓取串口（python -m pip install pyserial）") from exc

        stop_patterns = [re.compile(p) for p in params["stop_patterns"]]
        stop_pattern = re.compile(params["stop_pattern"]) if params.get("stop_pattern") else None
        port = self.cfg["port"]
        baud = int(self.cfg["baud"])
        deadline = time.monotonic() + float(params["duration_s"])
        text = ""
        early = "达到时长上限"

        try:
            ser = serial.Serial(port, baud, timeout=0.1)
        except Exception as exc:  # pyserial 的 SerialException 及底层 OSError
            raise StepError(f"无法打开串口 {port} @ {baud}: {exc}") from exc

        try:
            while time.monotonic() < deadline:
                try:
                    data = ser.read(4096)
                except Exception as exc:
                    raise StepError(f"读取串口失败: {exc}") from exc
                if not data:
                    continue
                text += data.decode(encoding, errors="replace")
                if stop_patterns and all(rx.search(text) for rx in stop_patterns):
                    early = "全部断言正则已命中"
                    break
                if stop_pattern is not None and stop_pattern.search(text):
                    early = "命中 capture.stop_pattern"
                    break
        finally:
            try:
                ser.close()
            except Exception:
                pass

        self.log_text = text
        step.detail = f"收到 {len(text)} 字符，提前结束原因: {early}" if text else "串口无输出"
        self._write_artifact("serial_log", params["log_name"], text)

    def _exec_assert(self, step: Step) -> None:
        assertions = step.params["assertions"]
        if not self.log_text:
            raise StepError("没有可断言的串口输出：capture 未产生任何字符")
        if not assertions:
            step.detail = "无断言（assertions 为空）"
            return

        missing_required: list[str] = []
        missing_optional: list[str] = []
        hits: list[str] = []
        for item in assertions:
            matched = re.search(item["pattern"], self.log_text) is not None
            if matched:
                hits.append(item["name"])
            elif item["required"]:
                missing_required.append(f"{item['name']} /{item['pattern']}/")
            else:
                missing_optional.append(item["name"])

        if missing_required:
            raise StepError("断言失败: " + "；".join(missing_required))
        detail = f"命中 {len(hits)} 条断言"
        if missing_optional:
            detail += "；可选未命中: " + "、".join(missing_optional)
        step.detail = detail

    # -- 产物 ---------------------------------------------------------------

    def _write_artifact(self, kind: str, name: str, content: str) -> None:
        directory = resolve_repo_path(self.cfg.get("artifacts_dir", "tools/s31-production/hil/artifacts"))
        path = directory / f"{self.run_id}-{self.suite}-{name}"
        try:
            directory.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        except OSError as exc:
            raise StepError(f"无法写入产物 {path}: {exc}") from exc
        self.artifacts.append({"kind": kind, "path": str(path)})

    # -- 结果 ---------------------------------------------------------------

    def result(self, steps: list[Step]) -> dict[str, Any]:
        result: dict[str, Any] = {
            "ok": not self.failed,
            "suite": self.suite,
            "dry_run": self.dry_run,
            "steps": [step.to_json() for step in steps],
            "artifacts": list(self.artifacts),
        }
        if self.first_error is not None:
            result["error"] = str(self.first_error)
        return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hil.py",
        description="S31 HIL runner（离线骨架）。默认只支持 --dry-run；真实硬件动作需要 allow_hardware=true。",
        epilog=f"JSON 结果结构: {RESULT_SCHEMA}",
    )
    parser.add_argument(
        "--config",
        required=True,
        metavar="PATH",
        help="JSON 配置路径，例如 tools/s31-production/hil/config.example.json",
    )
    parser.add_argument(
        "--suite",
        default="smoke",
        choices=SUITES,
        help="测试分层：smoke（默认）/ fault / link / soak",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="只打印计划，不打开串口、不烧录、不吸合继电器",
    )
    return parser


def print_plan(suite: str, steps: list[Step], dry_run: bool) -> None:
    mode = "dry-run（不接触硬件）" if dry_run else "真实执行"
    print(f"[hil] suite={suite} mode={mode} steps={len(steps)}", file=sys.stderr)
    for index, step in enumerate(steps, 1):
        print(f"[hil] {index:02d}. {step.sid:<24} {step.detail}", file=sys.stderr)


def main(argv: Optional[list[str]] = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except (AttributeError, ValueError, OSError):
            pass
    parser = build_parser()
    args = parser.parse_args(argv)
    config_path = Path(args.config)
    steps: list[Step] = []
    runner: Optional[Runner] = None
    plan_printed = False

    try:
        cfg = load_config(config_path)
        if not args.dry_run and not cfg.get("allow_hardware", False):
            raise ConfigError(
                "真实硬件动作被 allow_hardware=false 挡住；确认台架安全后在配置中显式设为 true，"
                "或使用 --dry-run 只查看计划"
            )

        steps = build_plan(args.suite, cfg)
        runner = Runner(cfg, args.suite, args.dry_run)
        print_plan(args.suite, steps, args.dry_run)
        plan_printed = True
        runner.run(steps)
        result = runner.result(steps)
        exit_code = EXIT_OK if result["ok"] else EXIT_STEP_FAILED

    except HilError as exc:
        exit_code = exc.exit_code
        if runner is not None:
            result = runner.result(steps)
            result["ok"] = False
            result["error"] = str(exc)
            if not plan_printed:
                print_plan(args.suite, steps, args.dry_run)
        else:
            result = {
                "ok": False,
                "suite": args.suite,
                "dry_run": bool(args.dry_run),
                "steps": [step.to_json() for step in steps],
                "artifacts": [],
                "error": str(exc),
            }
        print(f"[hil] 错误: {exc}", file=sys.stderr)

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

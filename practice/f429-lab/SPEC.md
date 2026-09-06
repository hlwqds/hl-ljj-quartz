# F429 实验室 · practice 套件说明

对应内容系列 [[f429-lab|F429 裸机实验室]]。工程命名 `chNN-slug`/`主题-slug`，
寄存器级裸机（arm-none-eabi-gcc + 自写 startup/ld，不用 HAL/CubeMX），
控制台统一 **USART1 PA9/PA10 → CH340 → /dev/ttyUSB0 @115200**。

新工程规则：`practice/f429-lab/<slug>/` 自含 startup.S/ld/Makefile/README；
真机烧录 openocd + DAP（`interface/cmsis-dap.cfg` + `target/stm32f4x.cfg`）。

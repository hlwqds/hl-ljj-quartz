/*
 * ch05-clock-reset-wdt / idf-bootstrap
 *
 * 这个 app_main 永远不会被执行：idf.py build 产出的应用镜像只是副产品，
 * tools/flash.sh 会把 flash_args 里的应用行换成 Zig 的 zig-out/bin/app.bin，
 * 所以真正跑在板子上的是 _start + main，而不是这里。
 *
 * 它存在的唯一理由：IDF 的构建要求 main 组件提供一个 app_main，缺了会链接失败；
 * 有了它，构建才能走完，从而产出二级 bootloader、分区表与 flash_args。
 *
 * 注意：二级 bootloader 的时钟配置与看门狗配置来自这个工程生成的 sdkconfig
 * （例如 CONFIG_BOOTLOADER_WDT_*）。改这里会改变 bootloader 行为，进而改变
 * 应用启动时的“默认环境”，属于本章要观察的对象之一。
 */

void app_main(void)
{
}

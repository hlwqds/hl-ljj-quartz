/* 目标侧走 mbedTLS；宿主测试注入自己的 md5 后不会调到这里，
 * 但链接器要符号：测试 main 里给一个 abort 定义。 */
#include <stdint.h>
#include <stddef.h>
int mbedtls_md5(const unsigned char *in, size_t len, unsigned char out[16]);

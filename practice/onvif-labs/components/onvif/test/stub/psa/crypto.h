/* 宿主测试桩：组件目标侧走 PSA，宿主测试注入 md5 后后此路径不可达——
 * 仅需类型/常量/符号定义满足编译链接。 */
#include <stdint.h>
#include <stddef.h>

typedef int psa_status_t;
typedef uint32_t psa_algorithm_t;
#define PSA_SUCCESS ((psa_status_t)0)
#define PSA_ALG_MD5 ((psa_algorithm_t)0x0300000e) /* PSA 规范真实编码 */

psa_status_t psa_hash_compute(psa_algorithm_t alg, const uint8_t *input, size_t input_len,
                              uint8_t *hash, size_t hash_size, size_t *hash_length);

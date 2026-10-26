#pragma once
#include <stddef.h>
typedef void *TaskHandle_t;
uint16_t uxTaskGetStackHighWaterMark(TaskHandle_t xTask);

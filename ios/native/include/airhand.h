// Airhand 的 iOS 核心（Rust 静态库 libairhand_ios.a）的 C 接口，实现见 ../src/lib.rs。
//
// * 句柄：start 返回非 0 的 int64_t，之后的调用都带着它；stop 之后作废。
// * 命令和事件是 UTF-8 的 JSON 字符串；返回的字符串用 ah_string_free 释放，字节用 ah_bytes_free 释放。
// * Rust 不回调 Swift（日志除外）：Swift 的线程用 poll 阻塞地取。
#ifndef AIRHAND_H
#define AIRHAND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// level：1 错误 / 2 警告 / 3 信息 / 4 调试 / 5 跟踪；msg 只在调用期间有效
typedef void (*ah_log_fn)(int32_t level, const char *msg);

void ah_init(const char *filter, ah_log_fn log);
int32_t ah_protocol_version(void);
// 合法返回 NULL，否则返回原因
char *ah_check_fingerprint(const char *fp);
void ah_string_free(char *s);
void ah_bytes_free(uint8_t *p, size_t len);

// ── 控制端 ──
int64_t ah_ctl_start(const char *cfg, char **err);
void ah_ctl_stop(int64_t h);
char *ah_ctl_poll_event(int64_t h, int32_t timeout_ms);
char *ah_ctl_call(int64_t h, const char *json);
// 1：有数据（*out / *len，用 ah_bytes_free 释放）；0：等不到；-1：会话不在了
int32_t ah_ctl_poll_session(int64_t h, uint32_t sid, int32_t timeout_ms, uint8_t **out, size_t *len);
void ah_ctl_ack(int64_t h, uint32_t sid, uint32_t seq);
void ah_ctl_mic(int64_t h, uint32_t sid, const uint8_t *data, size_t len);

// ── 剪贴板里的文件 ──
char *ah_files_list(int64_t key, const char *path, bool recursive);
int64_t ah_files_open(int64_t key, const char *path, int64_t size, int64_t mtime);
int64_t ah_files_read(int64_t file, int64_t offset, uint8_t *buf, size_t len);
void ah_files_close(int64_t file);
void ah_files_ready(int64_t key);

// ── 被控端 ──
int64_t ah_host_start(const char *cfg, char **err);
void ah_host_stop(int64_t h);
char *ah_host_poll_event(int64_t h, int32_t timeout_ms);
// 成功返回 NULL，否则返回原因
char *ah_host_call(int64_t h, const char *json);
char *ah_host_tick(int64_t h);
bool ah_host_wait_window(int64_t h, int32_t timeout_ms);
// flags：bit0 关键帧，bit1 参数集；codec：0 H.264 / 1 HEVC / 2 AV1
void ah_host_video(int64_t h, const uint8_t *data, size_t len, int32_t flags, int64_t capture_us,
                   int32_t codec, int32_t width, int32_t height);
void ah_host_audio(int64_t h, const uint8_t *data, size_t len, int64_t capture_us);

#ifdef __cplusplus
}
#endif

#endif

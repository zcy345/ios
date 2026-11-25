//! Airhand 的 iOS 核心：Swift 经 C ABI（`include/airhand.h`）调用。和 Android（JNI）共用 `airhand-mobile`：
//!
//! * 控制端（`ah_ctl_*`）：看 / 操作别的设备；
//! * 被控端（`ah_host_*`）：屏幕广播扩展里的网络部分，采集和编码在 Swift 那边（ReplayKit、VideoToolbox）；
//! * 剪贴板里的文件（`ah_files_*`）。
//!
//! 约定（和 JNI 那边一样）：
//! * 句柄：`start` 返回非 0 的 `int64_t`，之后的调用都带着它；`stop` 之后作废；
//! * 命令和事件是 UTF-8 的 JSON 字符串。Rust 返回的字符串由调用方用 [`ah_string_free`] 释放，
//!   字节用 [`ah_bytes_free`] 释放；
//! * Rust 不回调 Swift（日志除外）：Swift 的线程用 `poll` 阻塞地取。
//! * 入口都不让 panic 穿出去。

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, Once};
use std::time::Duration;

use airhand_mobile::ctl::{Ctl, LinkSettings};
use airhand_mobile::host::{Host, HostConfig};
use airhand_mobile::files;
use airhand_proto::session::Codec;

pub use airhand_mobile::{hex, unhex};

// ───────────────────────────── 句柄、字符串 ─────────────────────────────

static NEXT: AtomicI64 = AtomicI64::new(1);
static CTLS: LazyLock<Mutex<HashMap<i64, Arc<Ctl>>>> = LazyLock::new(Mutex::default);
static HOSTS: LazyLock<Mutex<HashMap<i64, Arc<Host>>>> = LazyLock::new(Mutex::default);

fn ctl(h: i64) -> Option<Arc<Ctl>> {
    CTLS.lock().unwrap().get(&h).cloned()
}

fn host(h: i64) -> Option<Arc<Host>> {
    HOSTS.lock().unwrap().get(&h).cloned()
}

/// # Safety
/// `s` 为空或者是以 0 结尾的字符串
unsafe fn read_str(s: *const c_char) -> Option<String> {
    if s.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(s) }.to_str().ok().map(str::to_owned)
}

fn out_str(s: Option<String>) -> *mut c_char {
    match s {
        // JSON 里不会有 0（字符串里的 0 会被转义），保险起见去掉
        Some(s) => CString::new(s.replace('\0', ""))
            .map(CString::into_raw)
            .unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

/// 出错时把原因写进 `err`（调用方释放）
unsafe fn set_err(err: *mut *mut c_char, msg: String) {
    if !err.is_null() {
        unsafe { *err = out_str(Some(msg)) };
    }
}

fn timeout(ms: i32) -> Duration {
    Duration::from_millis(ms.max(0) as u64)
}

fn guard<T>(default: T, f: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(default)
}

/// # Safety
/// `ptr` 为空或者在调用方的整个调用期间指向 `len` 个可读的字节
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

/// 释放 Rust 返回的字符串
///
/// # Safety
/// `s` 是这个库返回的字符串（或空），只释放一次
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// 释放 Rust 返回的字节（[`ah_ctl_poll_session`]）
///
/// # Safety
/// `p` / `len` 是这个库返回的（或空），只释放一次
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_bytes_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)) });
    }
}

// ───────────────────────────── 日志 ─────────────────────────────

/// Swift 的日志函数：`level` 1 错误 / 2 警告 / 3 信息 / 4 调试 / 5 跟踪，`msg` 只在调用期间有效
pub type LogFn = extern "C" fn(level: i32, msg: *const c_char);

static LOGGER: Mutex<Option<LogFn>> = Mutex::new(None);

struct Line {
    level: i32,
    buf: Vec<u8>,
}

impl std::io::Write for Line {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for Line {
    fn drop(&mut self) {
        while self.buf.last().is_some_and(|c| *c == b'\n') {
            self.buf.pop();
        }
        self.buf.retain(|c| *c != 0);
        let f = *LOGGER.lock().unwrap();
        match (f, CString::new(std::mem::take(&mut self.buf))) {
            (Some(f), Ok(msg)) => f(self.level, msg.as_ptr()),
            (None, Ok(msg)) => eprintln!("{}", msg.to_string_lossy()),
            _ => {}
        }
    }
}

struct MakeLine;

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for MakeLine {
    type Writer = Line;
    fn make_writer(&'a self) -> Line {
        Line {
            level: 3,
            buf: Vec::new(),
        }
    }
    fn make_writer_for(&'a self, meta: &tracing::Metadata<'_>) -> Line {
        let level = match *meta.level() {
            tracing::Level::ERROR => 1,
            tracing::Level::WARN => 2,
            tracing::Level::INFO => 3,
            tracing::Level::DEBUG => 4,
            tracing::Level::TRACE => 5,
        };
        Line {
            level,
            buf: Vec::new(),
        }
    }
}

/// 初始化日志（只生效一次）。`filter` 是 `tracing` 的 EnvFilter 语法，例如 `info,quinn=warn`；
/// `log` 为空时写到 stderr
///
/// # Safety
/// `filter` 为空或者是以 0 结尾的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_init(filter: *const c_char, log: Option<LogFn>) {
    let filter = unsafe { read_str(filter) }.unwrap_or_else(|| "info".into());
    *LOGGER.lock().unwrap() = log;
    static ONCE: Once = Once::new();
    ONCE.call_once(move || {
        let filter = tracing_subscriber::EnvFilter::try_new(&filter)
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_ansi(false)
            .with_target(true)
            .without_time()
            .with_writer(MakeLine)
            .try_init();
        std::panic::set_hook(Box::new(|info| tracing::error!("panic: {info}")));
        tracing::info!(
            version = env!("CARGO_PKG_VERSION"),
            protocol = airhand_proto::SIGNAL_VERSION,
            "airhand native library loaded"
        );
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn ah_protocol_version() -> i32 {
    airhand_proto::SIGNAL_VERSION as i32
}

/// 校验服务器证书指纹：合法返回空，否则返回原因（英文）
///
/// # Safety
/// `fp` 为空或者是以 0 结尾的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_check_fingerprint(fp: *const c_char) -> *mut c_char {
    let fp = unsafe { read_str(fp) }.unwrap_or_default();
    out_str(
        airhand_link::net::parse_fingerprint(&fp)
            .err()
            .map(|e| e.to_string()),
    )
}

// ───────────────────────────── 控制端 ─────────────────────────────

/// 开始连接服务器（自动重连）。配置见 `airhand_mobile::ctl::LinkSettings`。失败返回 0，原因写进 `err`
///
/// # Safety
/// `cfg` 是以 0 结尾的字符串；`err` 为空或者可写
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_ctl_start(cfg: *const c_char, err: *mut *mut c_char) -> i64 {
    let Some(cfg) = (unsafe { read_str(cfg) }) else {
        unsafe { set_err(err, "null config".into()) };
        return 0;
    };
    let cfg: LinkSettings = match serde_json::from_str(&cfg) {
        Ok(c) => c,
        Err(e) => {
            unsafe { set_err(err, format!("bad config: {e}")) };
            return 0;
        }
    };
    match guard(Err(anyhow::anyhow!("panic")), || Ctl::start(&cfg)) {
        Ok(c) => {
            let h = NEXT.fetch_add(1, Ordering::Relaxed);
            CTLS.lock().unwrap().insert(h, c);
            h
        }
        Err(e) => {
            unsafe { set_err(err, format!("{e:#}")) };
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ah_ctl_stop(h: i64) {
    let c = CTLS.lock().unwrap().remove(&h);
    guard((), move || drop(c));
}

/// 服务事件（JSON），等不到返回空
#[unsafe(no_mangle)]
pub extern "C" fn ah_ctl_poll_event(h: i64, timeout_ms: i32) -> *mut c_char {
    let Some(c) = ctl(h) else {
        return std::ptr::null_mut();
    };
    out_str(guard(None, || c.poll_event(timeout(timeout_ms))))
}

/// 执行命令（JSON），返回 `{"ok":...}` 或 `{"err":Problem}`。`connect` 会阻塞到有结果
///
/// # Safety
/// `json` 是以 0 结尾的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_ctl_call(h: i64, json: *const c_char) -> *mut c_char {
    let json = unsafe { read_str(json) }.unwrap_or_default();
    let r = match ctl(h) {
        Some(c) => guard(
            r#"{"err":{"kind":"failed","detail":"panic"}}"#.to_string(),
            || c.call(&json),
        ),
        None => r#"{"err":{"kind":"notConnected"}}"#.to_string(),
    };
    out_str(Some(r))
}

/// 取会话的下一条数据：媒体包（第一个字节 1 / 2 / 3）或者会话事件（JSON，第一个字节是 `{`）。
/// 返回 1 并写入 `out` / `len`（用 [`ah_bytes_free`] 释放）；等不到返回 0；会话不在了返回 -1
///
/// # Safety
/// `out`、`len` 可写
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_ctl_poll_session(
    h: i64,
    sid: u32,
    timeout_ms: i32,
    out: *mut *mut u8,
    len: *mut usize,
) -> i32 {
    let Some(c) = ctl(h) else {
        return -1;
    };
    if !c.has_session(sid) {
        return -1;
    }
    match guard(None, || c.poll_session(sid, timeout(timeout_ms))) {
        Some(b) => {
            let b = b.into_boxed_slice();
            unsafe {
                *len = b.len();
                *out = Box::into_raw(b).cast::<u8>();
            }
            1
        }
        None => 0,
    }
}

/// 界面收到了这一帧（累积确认）
#[unsafe(no_mangle)]
pub extern "C" fn ah_ctl_ack(h: i64, sid: u32, seq: u32) {
    if let Some(c) = ctl(h) {
        guard((), || c.ack(sid, seq));
    }
}

/// 麦克风的一个声音包（`airhand_proto::media` 的声音包：24 字节的头 + Opus）
///
/// # Safety
/// `data` 指向 `len` 个可读的字节
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_ctl_mic(h: i64, sid: u32, data: *const u8, len: usize) {
    let data = unsafe { bytes(data, len) };
    if let Some(c) = ctl(h) {
        guard((), || c.mic(sid, data));
    }
}

// ───────────────────────────── 剪贴板里的文件 ─────────────────────────────

/// 列出对方复制的文件里的目录（`path` 是 JSON 数组）：`{"entries":[...]}` 或 `{"error":"..."}`。阻塞的
///
/// # Safety
/// `path` 是以 0 结尾的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_files_list(key: i64, path: *const c_char, recursive: bool) -> *mut c_char {
    let path = unsafe { read_str(path) }.unwrap_or_default();
    out_str(Some(guard(r#"{"error":"io"}"#.to_string(), || {
        files::list(key, &path, recursive)
    })))
}

/// 打开对方的一个文件（读的时候才取）：文件的编号，公告不在了是 0
///
/// # Safety
/// `path` 是以 0 结尾的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_files_open(key: i64, path: *const c_char, size: i64, mtime: i64) -> i64 {
    let path = unsafe { read_str(path) }.unwrap_or_default();
    guard(0, || files::open(key, &path, size, mtime))
}

/// 从 `offset` 开始读到 `buf` 里：读了多少（0 是到末尾了），出错是负数。阻塞的
///
/// # Safety
/// `buf` 指向 `len` 个可写的字节
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_files_read(file: i64, offset: i64, buf: *mut u8, len: usize) -> i64 {
    if buf.is_null() {
        return -1;
    }
    let buf = unsafe { std::slice::from_raw_parts_mut(buf, len) };
    guard(-1, || files::read(file, offset.max(0) as u64, buf))
}

#[unsafe(no_mangle)]
pub extern "C" fn ah_files_close(file: i64) {
    guard((), || files::close(file));
}

#[unsafe(no_mangle)]
pub extern "C" fn ah_files_ready(key: i64) {
    guard((), || files::ready(key));
}

// ───────────────────────────── 被控端 ─────────────────────────────

/// 开始做被控端（配置见 `airhand_mobile::host::HostConfig`）。失败返回 0，原因写进 `err`
///
/// # Safety
/// `cfg` 是以 0 结尾的字符串；`err` 为空或者可写
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_host_start(cfg: *const c_char, err: *mut *mut c_char) -> i64 {
    let Some(cfg) = (unsafe { read_str(cfg) }) else {
        unsafe { set_err(err, "null config".into()) };
        return 0;
    };
    let cfg: HostConfig = match serde_json::from_str(&cfg) {
        Ok(c) => c,
        Err(e) => {
            unsafe { set_err(err, format!("bad config: {e}")) };
            return 0;
        }
    };
    match guard(Err(anyhow::anyhow!("panic")), || Host::start(cfg)) {
        Ok(host) => {
            let h = NEXT.fetch_add(1, Ordering::Relaxed);
            HOSTS.lock().unwrap().insert(h, host);
            h
        }
        Err(e) => {
            unsafe { set_err(err, format!("{e:#}")) };
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ah_host_stop(h: i64) {
    let host = HOSTS.lock().unwrap().remove(&h);
    guard((), move || drop(host));
}

#[unsafe(no_mangle)]
pub extern "C" fn ah_host_poll_event(h: i64, timeout_ms: i32) -> *mut c_char {
    let Some(host) = host(h) else {
        return std::ptr::null_mut();
    };
    out_str(guard(None, || host.poll_event(timeout(timeout_ms))))
}

/// 执行 `airhand_mobile::host::Op`：成功返回空，否则返回原因
///
/// # Safety
/// `json` 是以 0 结尾的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_host_call(h: i64, json: *const c_char) -> *mut c_char {
    let json = unsafe { read_str(json) }.unwrap_or_default();
    let Some(host) = host(h) else {
        return out_str(Some("no host".into()));
    };
    out_str(
        guard(Err(anyhow::anyhow!("panic")), || host.call(&json))
            .err()
            .map(|e| format!("{e:#}")),
    )
}

/// 编码线程每一轮调用：设置变了、要关键帧时返回 JSON（`airhand_mobile::host::video::Tick`），否则空
#[unsafe(no_mangle)]
pub extern "C" fn ah_host_tick(h: i64) -> *mut c_char {
    let Some(host) = host(h) else {
        return std::ptr::null_mut();
    };
    out_str(guard(None, || {
        host.video_hub()
            .tick()
            .and_then(|t| serde_json::to_string(&t).ok())
    }))
}

/// 等到至少一个观看者能再收一帧（在途控制）。超时返回 false
#[unsafe(no_mangle)]
pub extern "C" fn ah_host_wait_window(h: i64, timeout_ms: i32) -> bool {
    let Some(host) = host(h) else {
        return true;
    };
    guard(true, || host.video_hub().wait_window(timeout(timeout_ms)))
}

/// 编码器的一个输出（H.264 / HEVC 是 Annex-B）。`flags`：bit0 关键帧，bit1 参数集；`codec`：0 H.264 / 1 HEVC / 2 AV1
///
/// # Safety
/// `data` 指向 `len` 个可读的字节
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ah_host_video(
    h: i64,
    data: *const u8,
    len: usize,
    flags: i32,
    capture_us: i64,
    codec: i32,
    width: i32,
    height: i32,
) {
    let Some(host) = host(h) else { return };
    let data = unsafe { bytes(data, len) };
    let codec = match codec {
        1 => Codec::H265,
        2 => Codec::AV1,
        _ => Codec::H264,
    };
    guard((), || {
        host.video_hub().push(
            data,
            flags & 1 != 0,
            flags & 2 != 0,
            capture_us.max(0) as u64,
            codec,
            width.clamp(0, u16::MAX as i32) as u16,
            height.clamp(0, u16::MAX as i32) as u16,
        )
    });
}

/// 一个 Opus 包（48 kHz 立体声，20 ms）
///
/// # Safety
/// `data` 指向 `len` 个可读的字节
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ah_host_audio(h: i64, data: *const u8, len: usize, capture_us: i64) {
    let Some(host) = host(h) else { return };
    let data = unsafe { bytes(data, len) };
    guard((), || host.audio_hub().push(data, capture_us.max(0) as u64));
}

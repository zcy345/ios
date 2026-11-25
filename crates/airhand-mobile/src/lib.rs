//! Airhand 的手机核心：Android（JNI，`android/native`）和 iOS（C ABI，`ios/native`）共用。
//!
//! * [`ctl`]：控制端（看 / 操作别的设备），包装 `airhand_link` 的控制端服务；
//! * [`host`]：被控端（手机被别人看 / 操作）：网络部分在这里，采集、编码、注入输入在各平台自己那边；
//! * 数据交换尽量简单：命令和事件是 JSON 字符串，画面 / 声音是字节。核心不回调界面：
//!   界面的线程用 `poll*` 阻塞地取（见 [`queue`]）。

pub mod ctl;
pub mod files;
pub mod host;
pub mod queue;
pub mod rt;
mod session_queue;

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex<const N: usize>(s: &str) -> Option<[u8; N]> {
    let s = s.trim();
    if s.len() != N * 2 {
        return None;
    }
    let mut out = [0u8; N];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_roundtrip() {
        let b = [0u8, 1, 0xab, 0xff];
        assert_eq!(hex(&b), "0001abff");
        assert_eq!(unhex::<4>("0001abff"), Some(b));
        assert_eq!(unhex::<4>("0001ABFF"), Some(b));
        assert_eq!(unhex::<4>("0001ab"), None);
        assert_eq!(unhex::<2>("zzzz"), None);
    }
}

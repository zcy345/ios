# 在 iPhone 上安装 Airhand 直连版

需要 iOS 17 或更高版本，以及一台已运行 Airhand 直连版的电脑。iPhone 发起连接时，手机与电脑之间使用 QUIC，首次连接由电脑上的配对码授权。

## 用 Windows 安装 IPA

1. 在 Windows 上下载 64 位 Sideloadly，按官网 Windows 下载提示安装 Apple 网页版 iTunes 和 iCloud。请使用下载页提供的 Apple 链接。[Sideloadly 官网](https://sideloadly.io/)
2. 用可传数据的 USB 线连接 iPhone，解锁并点「信任此电脑」。打开 Sideloadly，在设备列表选中这台 iPhone。
3. 将 `Airhand-Direct-iPhone.ipa` 拖进 Sideloadly，使用 Apple ID Sideload 模式，输入自己的 Apple 账户，点击 **Start**，按提示完成登录及双重认证。等窗口显示 **Done**。免费账户可用，签名有效期为 7 天，可以用同一账户刷新。[Sideloadly 安装与续签](https://sideloadly.io/)
4. 在 iPhone 的「设置 → 隐私与安全性 → 开发者模式」打开开关，按提示重启，解锁后确认「开启」。若打开 Airhand 时提示未受信任，请到「设置 → 通用 → VPN 与设备管理」选择刚才签名的账户并信任。[Apple 开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) · [Sideloadly 常见问题](https://sideloadly.io/faq)
5. 如果签名提示不支持 App Groups 或广播扩展，而且你只需要用 iPhone 控制电脑，可在 Sideloadly 的高级选项勾选移除扩展后重新签名安装。移除广播扩展会使「共享本机」无法广播 iPhone 屏幕。[Sideloadly 扩展选项](https://sideloadly.io/)

## 连接电脑

让 iPhone 和电脑连到同一局域网。打开 Airhand，在「远程 → IP / 域名」输入电脑的地址，点「连接」，并允许访问本地网络。默认端口是 UDP 4433，使用其他端口时可输入 `地址:端口`。IPv6 带端口的格式为 `[IPv6地址]:端口`。

出现配对提示后，打开 Windows 通知区域的 Airhand 托盘菜单，将里面的 6 位配对码填到 iPhone。下次可直接点「我的设备」。直连时「设置」里的中转服务器地址可留空。

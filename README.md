# Mulee

**一个纯粹的 macOS 下载器。** HTTP、BT / 磁力、ed2k、视频，一个软件全搞定。
开源，免费，永不加广告。

> 🚧 项目处于早期设计阶段，还没有可用版本。

[English](#english)

---

## 为什么做 Mulee

在 Mac 上下载东西，往往要装好几个软件：一个管 HTTP，一个管 BT，一个管驴子，一个下视频……
每个软件都有自己的界面和设置，功能有的缺、有的重复，有的还带广告。

Mulee 想把这些合成一个：**一个入口、一套设置、一个下载队列。**

## 计划支持

| 类型 | 说明 |
|---|---|
| HTTP / HTTPS / FTP | 多线程分段下载，断点续传 |
| BT / 磁力链接 | 选择文件下载，可设置做种策略（默认分享率 1:1） |
| ed2k（电驴） | 原生支持，老资源可以长期挂着慢慢等 |
| 迅雷链接 `thunder://` | 自动解析出原始链接，交给对应的下载引擎 |
| 视频 | 基于 [yt-dlp](https://github.com/yt-dlp/yt-dlp)，重点保障 YouTube 和 Bilibili |
| 自动解压 | 下载完成后自动解压，支持按规则自动填密码，修复 GBK / Big5 等编码的文件名乱码 |

以及：

- Swift 原生界面，只支持 Apple Silicon
- 菜单栏常驻，显示实时速度
- 浏览器扩展（Safari / Chrome）
- 可设为 `magnet:` / `ed2k:` / `thunder:` / `.torrent` 的默认打开程序
- 下载时防止系统睡眠
- 多语言界面

## 不做什么

为了让 Mulee 保持专注，以下内容**不在计划内**：

- ❌ 广告，任何形式都不会有
- ❌ 内置资源搜索、资源推荐或种子站。Mulee 只是一个下载工具
- ❌ 迅雷加速网络（P2SP）。迅雷链接只做解析
- ❌ Windows / Linux 版本

## 许可证

[GPL-3.0](LICENSE)

Mulee 只是一个下载工具，请只下载你有权获取的内容。

---

<a id="english"></a>

## English

**Mulee is a no-nonsense download manager for macOS.** HTTP, BitTorrent / magnet, ed2k and video sites, all in one native app.
Open source, free, and never any ads.

> 🚧 Early design stage. No usable release yet.

**Planned:** multi-connection HTTP/FTP, BitTorrent and magnet links, native ed2k, `thunder://` link decoding, video downloads powered by yt-dlp (YouTube and Bilibili first), and auto-extraction with password rules and filename encoding repair. Native Swift UI for Apple Silicon, a menu bar item, browser extensions, default handler for magnet / ed2k / thunder / .torrent, and sleep prevention while downloading.

**Not planned:** ads, built-in resource search, Xunlei's P2SP acceleration network, Windows or Linux builds.

Licensed under [GPL-3.0](LICENSE). Please only download content you have the right to access.

---

Made with ❤️ by [CQAGC](https://www.cqagc.com)

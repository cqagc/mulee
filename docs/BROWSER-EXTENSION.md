# 浏览器扩展入口

扩展通过系统打开以下 URL（每个参数值单独用 `encodeURIComponent` 编码）：

```
mulee://add?url=<下载链接>&url=<另一个下载链接>&referrer=<来源页面地址>&text=<选中文字>
```

- 只支持 `add`，不支持路径、账号、端口或片段。
- `url` 可重复，必须有至少一条下载链接；支持 LinkParser 识别的 magnet、ed2k、thunder、HTTP、HTTPS、FTP、视频页面和远程 .torrent。
- 一次最多 200 个 url 参数，解析出的链接也不能超过 200 条。整个编码后入口 URL 最多 1,048,576 个 UTF-8 字节，超限拒绝整次请求。
- `file://`、本地绝对路径、相对路径和 thunder 内包裹的本地种子一律拒绝；即使与有效链接混合也拒绝。入口不会读取网页指定的本地文件。
- `referrer` 可选，只接收 HTTP/HTTPS 页面地址，随确认后的任务保存为 `sourcePageURL`。自动解压的「来源网站」规则优先匹配该地址，旧任务继续匹配下载链接。
- `text` 可选。启用「从下载页面的文字里识别解压密码」时，识别「解压密码：xxx」「密码: xxx」「password: xxx」，支持全角冒号和英文大小写。密码随草稿保存在内存，解压期间临时使用钥匙串，完成后移除；不写进 tasks.json。
- 所有有效请求只激活或创建主窗口并预填「新建下载」面板，用户确认后才开始下载。已有主窗口优先接收外部事件，已有面板会追加内容，多链接合并在一个面板中。

```javascript
const entry = new URL('mulee://add');
for (const link of downloadLinks) {
    entry.searchParams.append('url', link);
}
entry.searchParams.set('referrer', location.href);
entry.searchParams.set('text', window.getSelection()?.toString() ?? '');
location.href = entry.href;
```

系统也可以直接把 magnet、ed2k、thunder 链接和本地 .torrent 文件交给 Mulee；同样先确认。默认程序仅在设置·通用·默认打开方式中由用户主动设置，启动和注册自检不会抢占默认。

Debug 自检可通过 `-MuleeOpenURLDiagnostics YES` 输出收到的预填链接（不输出页面文字或密码）；常规 OpenURL 日志仅记录链接数及已有任务数。

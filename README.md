# Snipaste to Codex

一个轻量的 Windows 桥接工具：使用 Snipaste 完成截图和标注后，图片会静默进入本地队列；鼠标侧键可以在任何应用里开关 Codex 听写；当用户主动回到 Codex 时，图片按截图顺序自动粘贴到当前输入框。程序不会自动发送消息，也不会主动切换、缩放或移动 Codex 窗口。

## 要求

- Windows 10/11
- Codex 桌面应用
- [Snipaste](https://www.snipaste.com/)

当前版本不会安装或捆绑 Snipaste。

## 交给 Codex 安装

把下面这句话发给 Codex：

```text
请安装并使用这个 Skill，帮我完成 Snipaste to Codex 的安装和自检：
https://github.com/robotLiberator/snipaste-to-codex/tree/main/skills/install-snipaste-to-codex
```

这个 Skill 会在缺少 Snipaste 时优先使用 Windows Package Manager 的官方来源安装，并在完成后检查后台程序、截图队列和开机启动项。

## 安装

在 Windows PowerShell 中运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\SnipasteToCodex.ps1 -Install
```

安装脚本会使用 Windows 自带的 C# 编译器生成一个很小的独立 EXE。安装后程序随当前用户登录自动启动，不需要常驻 PowerShell，也不依附于 Codex 进程。单独重启 Codex 不会关闭桥接程序；如果后台程序被手动退出，重新运行 `-Install` 即可启动。

## 使用

1. 按 `F1` 使用 Snipaste 截图并标注。
2. 点击 Snipaste 的复制/完成按钮。
3. 可以继续截取多张图片，过程中 Codex 不会被切到前台。
4. 主动回到 Codex，排队的图片会依次粘贴到当前输入框。
5. 输入统一要求并自行发送。

### 后台语音输入

- 默认按鼠标“前进”侧键（`XButton2`），可在其他软件中直接开始 Codex 听写；再按一次会执行 Codex 的“转录并发送”。
- 整个过程通过 Windows 的辅助功能接口调用当前 Codex 对话里的真实听写按钮，不会把 Codex 切到前台。
- 右键系统托盘中的程序图标，可以改用“后退”侧键（`XButton1`）或关闭这项功能。
- Codex 需要保持运行，并停留在一个含输入框的对话页面；首次使用麦克风时，仍需按 Windows/Codex 的提示授予权限。

## 自检与卸载

```powershell
.\SnipasteToCodex.ps1 -SelfTest
.\SnipasteToCodex.ps1 -Uninstall
```

源码和安装逻辑均位于单个 `SnipasteToCodex.ps1` 文件中。安装时会生成 `%LOCALAPPDATA%\SnipasteToCodex\SnipasteToCodex.exe`，日常只运行这个轻量程序，不使用 AutoHotkey、服务器或 Codex 私有接口。后台听写使用 Windows UI Automation 调用 Codex 已公开给辅助功能系统的按钮。


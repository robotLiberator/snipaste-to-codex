# Snipaste to Codex

一个轻量的 Windows 剪贴板桥：使用 Snipaste 完成截图和标注后，图片会静默进入本地队列；当用户主动回到 Codex 时，图片按截图顺序自动粘贴到当前输入框。程序不会自动发送消息，也不会主动切换、缩放或移动 Codex 窗口。

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

安装后程序随当前用户登录自动启动。

## 使用

1. 按 `F1` 使用 Snipaste 截图并标注。
2. 点击 Snipaste 的复制/完成按钮。
3. 可以继续截取多张图片，过程中 Codex 不会被切到前台。
4. 主动回到 Codex，排队的图片会依次粘贴到当前输入框。
5. 输入统一要求并自行发送。

## 自检与卸载

```powershell
.\SnipasteToCodex.ps1 -SelfTest
.\SnipasteToCodex.ps1 -Uninstall
```

所有实现均位于单个 `SnipasteToCodex.ps1` 文件中，不使用 AutoHotkey、服务器或 Codex 私有接口。


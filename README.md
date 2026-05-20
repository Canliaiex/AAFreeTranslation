**中文** | [**English**](README.en.md) | [**Русский**](README.ru.md)

---

# AAFreeTranslation

上古世纪聊天翻译插件（支持中文、英文、俄文三种语言互译）。需要配合 PowerShell 翻译服务一起使用。

> **运行环境要求：Windows PowerShell 5.1**（系统自带，无需额外安装）。

## 使用方法

### 1. 启动翻译服务

双击 `run.bat` 运行 PowerShell 翻译后台。

> 启动后窗口最小化时会自动收起到系统托盘，双击托盘图标即可重新显示窗口。
>
> 注意：如果需要使用 `Shift+Enter` 发送消息，请**以管理员身份运行** `run.bat`（右键 → 以管理员身份运行）。

### 2. 安装插件

将 `AAFreeTranslation` 文件夹放到 `文档\AAFreeTo\Addon\` 目录内，然后在 `addons.txt` 文件中添加一行 `AAFreeTranslation`。

### 3. 游戏内配置

进入游戏后，点击右下角的设置菜单 → **ADDON**，在 ADDON 窗口右下角点击刷新图标载入插件，然后在插件列表中选择本插件，点击右侧的设置按钮进行配置。

避免手动编辑文件，请使用上述设置窗口来配置插件：

| 项目 | 说明 |
|------|------|
| 自动翻译 | 开启后自动翻译收到的聊天消息 |
| 输入翻译 | 开启后显示手动翻译输入窗口 |
| 翻译引擎 | Google 翻译 或 AI 翻译 |
| API 地址 / Key / 模型名 | AI 翻译模式下需填写（默认使用智谱 GLM-4-Flash） |

> AI 翻译模式下，输入模型和输出模型可分别配置。如无特殊需求，两项填写相同的模型即可。

## 文件说明

| 文件 | 用途 |
|------|------|
| `run.bat` | 启动翻译服务（双击运行） |
| `main.lua` | 游戏插件 |
| `settings_page.lua` | 游戏内设置面板 |
| `monitor_translation_v2.ps1` | PowerShell 翻译服务 |
| `config.ini` | 配置文件（在游戏内修改，不要手动编辑） |
| `ai_prompts.json` | AI 翻译提示词 |
| `cache/` | 插件与服务的通信缓存目录 |

## 已知问题

- 当游戏 UI 中存在编辑框控件时，发送翻译结果可能会把译文粘贴到非聊天编辑框控件中。

## 注意事项

- 当前已知测试过的模型：`glm-4-flash`、`deepseek-v4-flash`
- 如果使用其他模型且该模型带有"思考"（Reasoning/Thinking）功能，需在 `monitor_translation_v2.ps1` 的 `Invoke-ChatAPI` 函数中添加禁用思考的代码，参考已有写法：

```csharp
// 禁用 deepseek 模型的思考功能（代码已内置，如需自定义可参考）
if (model != null && model.IndexOf("deepseek", StringComparison.OrdinalIgnoreCase) >= 0)
    body["thinking"] = new Hashtable { { "type", "disabled" } };
```

---

如果遇到崩溃或其他问题，欢迎在 GitHub 提交 [Issue](https://github.com/Canliaiex/AAFreeTranslation/issues) 反馈。

---

> 原始插件基于 [aac-addon-cant_read](https://github.com/michaelqtz/aac-addon-cant_read) 项目修改而来。

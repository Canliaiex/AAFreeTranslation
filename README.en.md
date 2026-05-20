[**中文**](README.md) | **English** | [**Русский**](README.ru.md)

---

# AAFreeTranslation

ArcheAge chat translation addon (supports Chinese, English, Russian). Requires the PowerShell translation service to run.

## Usage

### 1. Start the Translation Service

Double-click `run.bat` to launch the PowerShell translation backend.

> When minimized, the window will hide to the system tray. Double-click the tray icon to show it again.
>
> Note: If you need to use `Shift+Enter` to send messages, run `run.bat` **as Administrator** (right-click → Run as administrator).

### 2. Install the Addon

Place the `AAFreeTranslation` folder into `Documents\AAFreeTo\Addon\`, then add a line `AAFreeTranslation` to the `addons.txt` file.

### 3. In-Game Configuration

Open the settings menu in the bottom-right corner → **ADDON**, click the refresh icon in the bottom-right of the ADDON window to load the addon, select this addon from the list, then click the Settings button on the right to configure.

Avoid editing files manually. Use the settings window described above to configure the addon:

| Item | Description |
|------|------------|
| Auto Translate | Automatically translate incoming chat messages |
| Input Translate | Show the manual translation input window |
| Translation Engine | Google Translate or AI Translate |
| API URL / Key / Model Name | Required for AI translation mode (default: GLM-4-Flash) |

> In AI translation mode, the input model and output model can be configured separately. If you have no special requirements, simply set both to the same model.

## File Overview

| File | Purpose |
|------|---------|
| `run.bat` | Start the translation service (double-click) |
| `main.lua` | Game addon |
| `settings_page.lua` | In-game settings panel |
| `monitor_translation_v2.ps1` | PowerShell translation service |
| `config.ini` | Configuration (edit in-game, do not modify manually) |
| `ai_prompts.json` | AI translation prompts |
| `cache/` | Communication cache directory between addon and service |

## Known Issues

- When the game UI contains an edit box control, sending translated text may paste the result into the wrong edit box instead of the chat input.

## Notes

- Confirmed tested models: `glm-4-flash`, `deepseek-v4-flash`
- If using other models with Reasoning/Thinking capabilities, add code to disable thinking in the `Invoke-ChatAPI` function in `monitor_translation_v2.ps1` (around line 508). Reference:

```powershell
# Disable thinking for deepseek models
if ($model -like '*deepseek*') { $body.thinking = @{ type = "disabled" } }
```

---

If you encounter crashes or other issues, please submit an [Issue](https://github.com/Canliaiex/AAFreeTranslation/issues) on GitHub.

---

> This addon is based on [aac-addon-cant_read](https://github.com/michaelqtz/aac-addon-cant_read).


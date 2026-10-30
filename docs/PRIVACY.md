# MyParrot Privacy Policy ／ 隱私政策

_Last updated: 2026-10-29. This document applies to both the open-source (GitHub) build and the Mac App Store build of MyParrot._

## English

**What MyParrot collects: nothing.** MyParrot has no account, no analytics, no crash reporter and no advertising SDK. It does not collect, store or transmit any personal data to the developer or to any third party.

**What stays on your Mac.** Recordings, transcripts, notes and meeting minutes are written as ordinary files into the folder you choose. Deleting those files deletes the data; there is no copy anywhere else.

**Speech recognition and on-device models.** Live and post-recording transcription with the “macOS native” engine uses Apple’s on-device speech recognition (`requiresOnDeviceRecognition` is on); audio never leaves your Mac. Optional transcript correction, meeting minutes and translation with “Apple on-device model” or “Apple Translation” also run on the device. Language packs for Apple Translation are downloaded by macOS itself, not by MyParrot.

**Network connections MyParrot makes.** The App Store build makes exactly one kind of outbound connection: when you press “Download” for a Whisper model, it downloads the model file from `huggingface.co`. Hugging Face sees your IP address and the file name, nothing else. The GitHub build additionally checks `api.github.com` for new releases at launch (can be turned off in Settings). Nothing about you, your recordings or your transcripts is sent in either case.

**Optional third-party backends (GitHub build only).** If you choose Claude CLI or Codex CLI as a backend, transcript text is sent to that provider through the command-line tool installed on your Mac, under your own account and their privacy terms. MyParrot asks for confirmation before enabling such a backend. The App Store build does not offer these backends.

**Permissions.** Microphone and system audio are used only to record; calendar access (read-only) is used only for the optional meeting reminder; notifications are used only for that reminder. You can revoke each permission in System Settings at any time; MyParrot keeps working with the remaining features.

**Retention and deletion.** Data lives only in files you can see. Delete the files, or delete the app, and nothing remains elsewhere.

**Coordination files in your recordings folder.** While recording, MyParrot keeps a small hidden folder `.myparrot/` inside your recordings folder (a lease file, a status file updated every second, and control commands). They let the app, the command-line tool and the App Store build coordinate when they share a folder. They contain the meeting name, the recording file path and timestamps, nothing else. If the folder is synced (Google Drive, iCloud) or shared, those services and anyone who can write to the folder can see them and could stop or pause a running recording, the same way they could delete your recordings; keep recordings in a folder you control.

**Contact.** Questions: open an issue at https://github.com/tingyulu/MyParrot/issues.

## 繁體中文

**MyParrot 收集什麼：沒有。** 沒有帳號、沒有分析、沒有崩潰回報、沒有廣告 SDK；不會把任何個人資料傳給開發者或第三方。

**留在你 Mac 上的東西。** 錄音、逐字稿、筆記與會議記錄都是普通檔案，存在你自己選的資料夾；刪掉檔案就刪掉資料，別處沒有副本。

**語音辨識與本機模型。** 用「macOS 原生」引擎做即時與會後逐字稿時，走 Apple 的裝置內語音辨識（已開 `requiresOnDeviceRecognition`），音訊不出機。選「Apple 本機模型」或「Apple 翻譯」做校正、會議記錄、翻譯，也都在裝置上跑；翻譯語言包由 macOS 自己下載，不經 MyParrot。

**MyParrot 會連的網路。** App Store 版只有一種出機連線：你按「下載」Whisper 模型時，從 `huggingface.co` 抓模型檔，對方只看得到 IP 與檔名。GitHub 版另外會在啟動時連 `api.github.com` 查新版（設定可關）。兩種情況都不會送出任何關於你、你的錄音或逐字稿的資料。

**選用的第三方後端（只有 GitHub 版）。** 若你選 Claude CLI 或 Codex CLI 當後端，逐字稿文字會經由你機器上的指令列工具、用你自己的帳號送到該供應商，適用他們的隱私條款；MyParrot 開啟前會先問你。App Store 版不提供這些後端。

**權限。** 麥克風與系統音訊只用來錄音；行事曆（唯讀）只用在選用的會議提醒；通知只用在該提醒。你隨時可以在系統設定撤回任一權限，MyParrot 會用剩下的功能繼續運作。

**保存與刪除。** 資料只存在你看得到的檔案裡；刪檔或刪 app，別處什麼都不剩。

**錄音夾裡的協調檔。** 錄音中 MyParrot 會在錄音夾裡維護一個隱藏的 `.myparrot/` 資料夾（租約檔、每秒更新的狀態檔、控制指令），讓 app、指令列工具與 App Store 版共用同一個資料夾時互相協調。內容只有會議名稱、錄音檔路徑與時間。資料夾若在同步（Google Drive、iCloud）或共享狀態，這些服務與任何能寫入該資料夾的人看得到它們，也能像刪掉你的錄音一樣停止或暫停正在進行的錄音；請把錄音放在你自己控制的資料夾。

**聯絡。** 有問題請到 https://github.com/tingyulu/MyParrot/issues 開 issue。

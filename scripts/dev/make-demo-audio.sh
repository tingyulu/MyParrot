#!/bin/bash
# GATE-08(TEST_PLAN AA 節,2026-11-05):效能閘用的合成對話音檔——左聲道＝對方、右聲道＝你,兩人輪流講、句間 0.7 s,
# 兩軌各墊 -54 dBFS 粉紅噪(whisper 對長靜音會幻覺,8/23 README 截圖配方)。固定內容 ⇒ 每次閘的負載可比。
# 不拿 ~/Documents/MyParrot 的真錄音(會中內容會變成逐字稿留在測試夾;真檔請用 perf-gate.py --audio 另指)。
#
# 用法:scripts/dev/make-demo-audio.sh [輸出.m4a] [--force] [--rounds N]
#   預設輸出 ~/Library/Caches/MyParrot-perfgate/demo-dialogue.m4a;已存在就不重做(--force 重做);預設 3 輪 ≈ 3 分鐘。
# 需要:macOS `say`(語音 Meijia 中文（台灣）)、ffmpeg、ffprobe。
set -euo pipefail

OUT="${1:-$HOME/Library/Caches/MyParrot-perfgate/demo-dialogue.m4a}"
FORCE=0; ROUNDS=3
shift $(( $# > 0 ? 1 : 0 )) || true
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --rounds) ROUNDS="${2:?--rounds 要正整數}"; case "$ROUNDS" in ""|*[!0-9]*|0*) echo "--rounds 要正整數(1～20):$ROUNDS"; exit 2;; esac; [ "$ROUNDS" -le 20 ] || { echo "--rounds 最多 20"; exit 2; }; shift ;;
    *) echo "未知參數:$1"; exit 2 ;;
  esac
  shift
done
case "$OUT" in /*) ;; *) echo "輸出要絕對路徑:$OUT"; exit 2 ;; esac
for tool in say ffmpeg ffprobe; do command -v "$tool" >/dev/null || { echo "❌ 缺 $tool"; exit 1; }; done
say -v '?' | grep -q 'Meijia' || { echo "❌ 沒有語音 Meijia(系統設定 → 輔助使用 → 朗讀內容 下載「美佳」)"; exit 1; }

if [ -f "$OUT" ] && [ "$FORCE" = 0 ]; then
  echo "已存在,不重做:$OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT") s;--force 重做)"
  exit 0
fi
mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d -t myparrot-demo-audio)"
trap 'rm -rf "$TMP"' EXIT

# 兩人輪流的中性會議對話(避開 Meijia 常聽錯的詞;內容不重要,負載與節奏才重要)。
A=(
  "我們先對一下今天的三個議題,第一個是上線時間。"
  "上週的量測結果已經放進共用資料夾,大家可以先看一下。"
  "這個部分我建議分成兩個階段做,先把基本功能穩定下來。"
  "客戶那邊的回饋主要集中在速度和介面兩塊。"
  "如果資源不夠,我們可以把第三項延到下個月。"
  "測試環境明天就會準備好,請大家把要驗的案例列出來。"
  "這裡有一個風險,就是外部服務的回應時間不穩定。"
  "我來負責整理會議記錄,今天下班前發給大家。"
  "剛才提到的數字我再確認一次,週五前給正式版本。"
  "下一次會議我們把預算的部分一起談完。"
  "目前看起來進度還在掌握之中,沒有需要升級處理的問題。"
  "最後一點,請大家更新一下各自的工作狀態。"
)
B=(
  "好,我這邊的狀況是後端已經完成八成,剩下的是錯誤處理。"
  "我看過了,有兩個地方的數字跟我手上的對不起來,等一下私下對。"
  "同意,第一階段我可以在兩週內交出來。"
  "介面的問題我們已經在改,下個版本會一起出去。"
  "延後沒問題,但要先跟業務那邊說一聲。"
  "我會在今天晚上把案例清單放上去。"
  "這個我有準備備案,超過三秒就切到本機快取。"
  "謝謝,記得把待辦事項標上負責人和日期。"
  "沒問題,我這邊也會同步更新文件。"
  "好,那我先把預算表的草稿準備好。"
  "我這邊有一個小問題想請教,登入流程要不要一起調整。"
  "收到,我今天會把狀態都更新完。"
)

sil() { # sil <秒> <輸出.wav>
  ffmpeg -v error -y -f lavfi -i "anullsrc=r=48000:cl=mono" -t "$1" -c:a pcm_f32le "$2"
}
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

: > "$TMP/left.txt"; : > "$TMP/right.txt"
GAP=0.7
i=0
for (( r=0; r<ROUNDS; r++ )); do
  for (( k=0; k<${#A[@]}; k++ )); do
    for side in A B; do
      if [ "$side" = A ]; then text="${A[$k]}"; rate=170; else text="${B[$k]}"; rate=185; fi
      f="$TMP/s_${i}.wav"
      say -v "Meijia" -r "$rate" --data-format=LEF32@48000 -o "$f" "$text"
      d="$(dur "$f")"
      sil "$d" "$TMP/z_${i}.wav"
      sil "$GAP" "$TMP/g_${i}.wav"
      if [ "$side" = A ]; then
        printf "file '%s'\nfile '%s'\n" "$f" "$TMP/g_${i}.wav" >> "$TMP/left.txt"
        printf "file '%s'\nfile '%s'\n" "$TMP/z_${i}.wav" "$TMP/g_${i}.wav" >> "$TMP/right.txt"
      else
        printf "file '%s'\nfile '%s'\n" "$TMP/z_${i}.wav" "$TMP/g_${i}.wav" >> "$TMP/left.txt"
        printf "file '%s'\nfile '%s'\n" "$f" "$TMP/g_${i}.wav" >> "$TMP/right.txt"
      fi
      i=$((i+1))
    done
  done
done

ffmpeg -v error -y -f concat -safe 0 -i "$TMP/left.txt"  -c:a pcm_f32le "$TMP/L.wav"
ffmpeg -v error -y -f concat -safe 0 -i "$TMP/right.txt" -c:a pcm_f32le "$TMP/R.wav"
# 粉紅噪 -54 dBFS(振幅 0.002)混進兩軌,長度跟語音軌一樣;再 join 成立體聲 AAC。
for ch in L R; do
  ffmpeg -v error -y -i "$TMP/$ch.wav" -f lavfi -i "anoisesrc=color=pink:amplitude=0.002:r=48000:seed=7" \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=first:normalize=0[a]" -map "[a]" -c:a pcm_f32le "$TMP/${ch}n.wav"
done
ffmpeg -v error -y -i "$TMP/Ln.wav" -i "$TMP/Rn.wav" \
  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]" -map "[a]" -c:a aac -b:a 160k "$OUT"

echo "✅ $OUT"
echo "   時長 $(dur "$OUT") s、$i 句、$ROUNDS 輪;sha256 $(shasum -a 256 "$OUT" | cut -c1-16)…"
ffmpeg -nostats -i "$OUT" -af 'astats=metadata=1:reset=0' -f null - 2>&1 | grep -E 'Channel: |RMS level dB' | head -4 | sed 's/^.*\] /   /'

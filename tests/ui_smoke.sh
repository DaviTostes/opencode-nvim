#!/usr/bin/env bash
# Real-UI smoke test: needs tmux. Drives Neovim in a terminal and asserts that
# the plugin never moves the focus or the insert mode away from the prompt.
#
#   make ui-smoke
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="opencode-nvim-smoke-$$"
LOG="/tmp/opencode/ui_smoke.log"
mkdir -p /tmp/opencode
rm -f "$LOG"

cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null; }
trap cleanup EXIT

tmux new-session -d -s "$SESSION" -x 160 -y 45
# UI_SMOKE_USER_CONFIG=1 runs with the user's own Neovim config (useful to check
# that the config itself does not pin a focus-stealing combination).
if [ "${UI_SMOKE_USER_CONFIG:-0}" = "1" ]; then
  tmux send-keys -t "$SESSION" "nvim -c 'luafile $ROOT/tests/ui_smoke.lua'" Enter
else
  tmux send-keys -t "$SESSION" "nvim -u NONE --cmd 'set rtp+=$ROOT' -c 'luafile $ROOT/tests/ui_smoke.lua'" Enter
fi
sleep 3

for _ in $(seq 1 20); do
  [ -f "$LOG" ] && grep -q READY "$LOG" && break
  sleep 0.3
done

tmux send-keys -t "$SESSION" ':OpencodeAsk' Enter
sleep 1
tmux send-keys -t "$SESSION" 'hello there'
sleep 0.4
# run the scroll check from insert mode, without leaving it
tmux send-keys -t "$SESSION" C-o ':lua _G.ui_check()' Enter
sleep 2
# a real submit: <CR> in the prompt
tmux send-keys -t "$SESSION" Enter
sleep 1.5
# the agent asks a question while we are typing: answer it from the dialog
sleep 3.5
tmux send-keys -t "$SESSION" '1'
sleep 4

echo "--- ui smoke log ---"
cat "$LOG"

fail=0
grep -q '^FAIL' "$LOG" && fail=1
grep -q '^DONE$' "$LOG" || fail=1
# after the real <CR> the prompt must still be focused and inserting
tail -3 "$LOG" | grep -q 'window=input mode=i' || {
  echo "UI SMOKE: the prompt lost the focus or the insert mode after sending"
  fail=1
}
grep -q 'DONE-QUESTION' "$LOG" || { echo "UI SMOKE: the question flow did not finish"; fail=1; }
if [ "$fail" -ne 0 ]; then
  echo "UI SMOKE: FAILED"
  exit 1
fi
echo "UI SMOKE: ok"

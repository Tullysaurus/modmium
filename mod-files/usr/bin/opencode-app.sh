#!/bin/bash
# written by Claude
# Apps menu entry: installs opencode on first run (if it isn't already),
# makes sure its install/data lives on stateful instead of the tiny rootfs,
# then drops into a plain-text request/response loop instead of opencode's
# normal TUI - the TUI's panes, mouse handling, and truecolor theme don't
# render usably on a bare VT console.

source /usr/lib/libmosh.sh

OPENCODE_DATA_DIR="/usr/local/opencode-data"
MODEL="opencode/hy3-free" # OpenCode Zen's free model - these rotate out without notice, so if this errors, run `opencode` normally once, check the /models list for a current free option, and update this line

setup_tmpdir() {
  # /tmp is mounted noexec on ChromeOS, which breaks opencode's installer
  # when it extracts/executes files from a temp dir. Redirect to stateful,
  # which allows exec, and persist it so future logins don't need this
  # script to have set it first.
  mkdir -p /usr/local/tmp
  export TMPDIR=/usr/local/tmp
  grep -q '^export TMPDIR=/usr/local/tmp$' /root/.bashrc 2>/dev/null \
    || echo 'export TMPDIR=/usr/local/tmp' >> /root/.bashrc
}

setup_data_dir() {
  # Keep opencode's actual data (auth, cache, sessions) on the roomy
  # stateful partition instead of the small rootfs. Bonus: it survives a
  # "Change ChromeOS Version" reinstall since stateful isn't touched by that.
  mkdir -p "$OPENCODE_DATA_DIR"
  if [[ -d /root/.opencode && ! -L /root/.opencode ]]; then
    cp -r /root/.opencode/. "$OPENCODE_DATA_DIR"/ 2>/dev/null
    rm -rf /root/.opencode
  fi
  ln -sfn "$OPENCODE_DATA_DIR" /root/.opencode
}

install_opencode() {
  command -v opencode &>/dev/null && return
  run_with_feedback "Installing opencode..." bash -c "curl -fsSL https://opencode.ai/install | bash" \
    || fail "${R}Failed to install opencode. Connect to the internet and try again.${N}"
  command -v opencode &>/dev/null \
    || fail "${R}opencode installed but isn't on PATH yet - open a new shell and pick this menu item again.${N}"
}

chat_loop() {
  clear
  echo -e "${B}OpenCode chat${N} (model: ${G}${MODEL}${N})"
  echo -e "${D}Type 'exit' or 'quit' to return to the menu.${N}\n"
  while true; do
    read -rep "> " input
    [[ -z "$input" ]] && continue
    [[ "$input" == "exit" || "$input" == "quit" ]] && break
    opencode run --model "$MODEL" "$input"
    echo
  done
}

setup_tmpdir
setup_data_dir
install_opencode
chat_loop

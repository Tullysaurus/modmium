#!/bin/bash
# written by Claude
# Apps menu entry: installs opencode on first use (if it isn't already),
# keeps its binary and data on stateful instead of the small rootfs, then
# drops into a plain-text request/response loop instead of opencode's normal
# TUI - the TUI's panes, mouse handling, and truecolor theme don't render
# usably on a bare VT console.

source /usr/lib/libmosh.sh

# MOSH always runs as root; pin HOME so it doesn't matter whether sudo kept
# the caller's, since every path below is derived from it.
export HOME=/root
OPENCODE_DATA_DIR="/usr/local/opencode-data"
OPENCODE_BIN="$HOME/.opencode/bin/opencode"
OPENCODE_WORKSPACE="/usr/local/opencode-workspace"
MODEL_CONF="/usr/local/config/opencode-model.conf"
DEFAULT_MODEL="opencode/hy3-free" # OpenCode Zen's free model - these rotate out without notice; see pick_model()

setup_env() {
  # /tmp is mounted noexec on ChromeOS, which breaks the opencode installer
  # when it unpacks and runs files from a temp dir. Stateful allows exec.
  mkdir -p /usr/local/tmp
  export TMPDIR=/usr/local/tmp

  # The installer reads $SHELL unconditionally under 'set -u' (even with
  # --no-modify-path), so an unset SHELL - common in a bare VT - aborts it.
  export SHELL="${SHELL:-/bin/bash}"

  # opencode keeps sessions/cache/logs under the XDG dirs, which default to
  # $HOME on the ~3GB rootfs. Point them at stateful so they can't fill it.
  export XDG_DATA_HOME="$OPENCODE_DATA_DIR/xdg/data"
  export XDG_CACHE_HOME="$OPENCODE_DATA_DIR/xdg/cache"
  export XDG_STATE_HOME="$OPENCODE_DATA_DIR/xdg/state"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

  # Without this the binary below is never found, and every visit to this
  # menu item would reinstall opencode from scratch.
  case ":$PATH:" in
    *":$HOME/.opencode/bin:"*) ;;
    *) export PATH="$HOME/.opencode/bin:$PATH" ;;
  esac
}

setup_data_dir() {
  # Keep the install itself on the roomy stateful partition. As a bonus it
  # survives a "Change ChromeOS Version" reinstall, which only replaces the
  # rootfs.
  mkdir -p "$OPENCODE_DATA_DIR" "$OPENCODE_WORKSPACE"
  if [[ -e $HOME/.opencode && ! -L $HOME/.opencode ]]; then
    cp -a "$HOME/.opencode/." "$OPENCODE_DATA_DIR"/ 2>/dev/null
    rm -rf "$HOME/.opencode"
  fi
  ln -sfn "$OPENCODE_DATA_DIR" "$HOME/.opencode"
}

install_opencode() {
  [[ -x $OPENCODE_BIN ]] && return
  for dep in curl tar; do
    command -v "$dep" &>/dev/null \
      || fail "${R}'$dep' is missing, so opencode can't be installed. Connect to the internet and open a menu that installs the dev packages first.${N}"
  done
  # --no-modify-path: the installer would otherwise append a PATH line to
  # /root/.bashrc, which Modmium overwrites on every update - setup_env
  # handles PATH for this script, and the shipped .bashrc handles shells.
  run_with_feedback "Installing opencode (this only happens once)..." \
    bash -c "curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path" \
    || fail "${R}Failed to install opencode. Connect to the internet and try again.${N}"
  [[ -x $OPENCODE_BIN ]] \
    || fail "${R}The opencode installer finished but left no binary at $OPENCODE_BIN.${N}"
}

pick_model() {
  # Free Zen models get retired without notice, so allow overriding the
  # default without editing this script.
  model="$DEFAULT_MODEL"
  if [[ -s $MODEL_CONF ]]; then
    local configured
    configured=$(grep -v '^[[:space:]]*#' "$MODEL_CONF" | grep -m1 '[^[:space:]]' | xargs)
    [[ -n $configured ]] && model="$configured"
  fi
}

ensure_auth() {
  # opencode needs a provider logged in before 'run' will work. Only offer
  # this once; if credentials expire later, the hint in chat_loop points
  # back here.
  [[ -f $OPENCODE_DATA_DIR/.auth_done ]] && return
  echo -e "${Y}opencode needs a provider signed in before it can answer anything.${N}"
  if confirm_destructive "Sign in now? (pick a provider, then follow the prompts)"; then
    if opencode auth login; then
      mkdir -p "$OPENCODE_DATA_DIR"
      touch "$OPENCODE_DATA_DIR/.auth_done"
    else
      echo -e "${R}Sign-in didn't complete. You can retry from the chat prompt with 'login'.${N}"
      sleep 2
    fi
  fi
}

chat_loop() {
  cd "$OPENCODE_WORKSPACE" || cd /tmp || return
  clear
  echo -e "${B}OpenCode chat${N} (model: ${G}${model}${N})"
  echo -e "${D}Commands: 'exit'/'quit' to return to the menu, 'login' to sign in again,"
  echo -e "'model <name>' to switch model (saved to $MODEL_CONF).${N}\n"
  while true; do
    read -rep "> " input
    input=$(echo "$input" | xargs)
    [[ -z "$input" ]] && continue
    case "$input" in
      exit|quit)
        break
        ;;
      login)
        opencode auth login && touch "$OPENCODE_DATA_DIR/.auth_done"
        continue
        ;;
      "model "*)
        model="${input#model }"
        mkdir -p "$(dirname "$MODEL_CONF")"
        echo "$model" > "$MODEL_CONF"
        echo -e "${G}Now using ${model}.${N}"
        continue
        ;;
    esac
    if ! opencode run --model "$model" "$input"; then
      echo -e "${R}That request failed.${N} If the model was retired, run ${B}opencode${N} once to see the current list (/models), then type ${B}model <name>${N} here. If it's an auth problem, type ${B}login${N}."
    fi
    echo
  done
}

log_action "Opened OpenCode chat"
setup_env
setup_data_dir
install_opencode
pick_model
ensure_auth
chat_loop

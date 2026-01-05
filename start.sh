#!/usr/bin/env bash
set -euo pipefail

# ==========
# 設定（必要なら環境変数で上書き）
# ==========
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
CODE_SERVER_BIND_ADDR="${CODE_SERVER_BIND_ADDR:-127.0.0.1}"
CODE_SERVER_AUTH="${CODE_SERVER_AUTH:-none}"   # none|password
CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-password}"

# 拡張インストールを無効化したい場合: INSTALL_CODE_SERVER_EXTENSIONS=0
INSTALL_CODE_SERVER_EXTENSIONS="${INSTALL_CODE_SERVER_EXTENSIONS:-1}"
# セット毎にON/OFF
INSTALL_AI_EXTENSIONS="${INSTALL_AI_EXTENSIONS:-1}"
INSTALL_PYTHON_EXTENSIONS="${INSTALL_PYTHON_EXTENSIONS:-1}"
INSTALL_DEVOPS_EXTENSIONS="${INSTALL_DEVOPS_EXTENSIONS:-1}"

# 拡張リストを外部ファイルで管理したい場合（1行1拡張、#コメントOK）
# 例: CODE_SERVER_EXTENSIONS_FILE=/root/extensions.txt
CODE_SERVER_EXTENSIONS_FILE="${CODE_SERVER_EXTENSIONS_FILE:-}"

# もしくは env で上書き（空白/改行区切り）
# 例: CODE_SERVER_EXTENSIONS="eamodio.gitlens esbenp.prettier-vscode"
CODE_SERVER_EXTENSIONS="${CODE_SERVER_EXTENSIONS:-}"

# Codex CLI を npm で入れる（rootなら通常の -g、非rootならprefixをユーザー領域へ）
NPM_PREFIX="${NPM_PREFIX:-$HOME/.local}"

# systemd が無いコンテナ等で、最後に code-server を foreground 起動したい場合:
# AUTO_START_CODE_SERVER=1
AUTO_START_CODE_SERVER="${AUTO_START_CODE_SERVER:-0}"

# ==========
# ユーティリティ
# ==========
log()  { echo -e "\033[1;32m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[err  ]\033[0m $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
init_privilege() {
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
    log "running as root (sudoなしで進めます)"
  else
    have sudo || die "sudo が見つかりません（rootで実行するか sudo を入れてください）"
    SUDO="sudo"
    log "running as non-root (sudoを使います)"
  fi
}

ensure_local_bin_on_path() {
  mkdir -p "$HOME/.local/bin"
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

install_base_packages() {
  log "依存パッケージ（curl/git/tar/ca-certificates/python3）をインストールします"
  if have apt-get; then
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y curl git tar ca-certificates python3
  elif have dnf; then
    ${SUDO} dnf install -y curl git tar ca-certificates python3
  elif have yum; then
    ${SUDO} yum install -y curl git tar ca-certificates python3
  elif have pacman; then
    ${SUDO} pacman -Sy --noconfirm curl git tar ca-certificates python
  else
    warn "未対応のパッケージマネージャです。curl/git/tar/python3 を手動で入れてください。"
  fi
}

install_code_server() {
  log "code-server を公式 install.sh でインストールします"
  curl -fsSL https://code-server.dev/install.sh | sh
  ensure_local_bin_on_path

  if ! have code-server; then
    die "code-server が PATH で見つかりません。PATH を確認してください。"
  fi
  log "code-server: $(code-server --version | head -n 1 || true)"
}

write_code_server_config() {
  log "code-server の設定ファイルを作成します"
  local cfg_dir="$HOME/.config/code-server"
  local cfg_file="$cfg_dir/config.yaml"
  mkdir -p "$cfg_dir"

  if [[ "$CODE_SERVER_AUTH" == "password" ]]; then
    if [[ -z "$CODE_SERVER_PASSWORD" ]]; then
      CODE_SERVER_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    fi
  else
    CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-}"
  fi

  cat > "$cfg_file" <<EOF
bind-addr: ${CODE_SERVER_BIND_ADDR}:${CODE_SERVER_PORT}
auth: ${CODE_SERVER_AUTH}
password: "${CODE_SERVER_PASSWORD}"
cert: false
EOF

  chmod 600 "$cfg_file"
  log "config: $cfg_file"
}

systemd_is_usable() {
  have systemctl || return 1
  systemctl is-system-running >/dev/null 2>&1 || return 1
  return 0
}

setup_systemd_service() {
  if ! systemd_is_usable; then
    warn "systemd が動いていないためサービス化はスキップします"
    return 0
  fi

  if ${SUDO} systemctl list-unit-files | grep -qE '^code-server@\.service'; then
    log "systemd unit (code-server@.service) を利用して起動設定します"
    ${SUDO} systemctl enable --now "code-server@${USER}"
    return 0
  fi

  log "systemd unit を作成します"
  local home_dir code_server_bin
  home_dir="$(eval echo "~${USER}")"
  code_server_bin="$(command -v code-server)"

  local svc_name="code-server-${USER}.service"
  local svc_path="/etc/systemd/system/${svc_name}"

  ${SUDO} tee "$svc_path" >/dev/null <<EOF
[Unit]
Description=code-server for ${USER}
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
Environment=HOME=${home_dir}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${home_dir}/.local/bin
WorkingDirectory=${home_dir}
ExecStart=${code_server_bin} --config ${home_dir}/.config/code-server/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl enable --now "$svc_name"
}

ensure_node_and_npm() {
  if have npm && have node; then
    log "node: $(node --version 2>/dev/null || true) / npm: $(npm --version 2>/dev/null || true)"
    return 0
  fi

  log "npm が無いので Node.js / npm をインストールします（OS標準パッケージ）"
  if have apt-get; then
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y nodejs npm
  elif have dnf; then
    ${SUDO} dnf install -y nodejs npm
  elif have yum; then
    ${SUDO} yum install -y nodejs npm
  elif have pacman; then
    ${SUDO} pacman -Sy --noconfirm nodejs npm
  else
    die "node/npm を自動導入できませんでした。手動で Node.js + npm を入れてから再実行してください。"
  fi

  have npm || die "npm のインストールに失敗しました"
  have node || die "node のインストールに失敗しました"
  log "node: $(node --version 2>/dev/null || true) / npm: $(npm --version 2>/dev/null || true)"
}

install_codex_cli_npm() {
  log "Codex CLI を npm でインストールします（@openai/codex）"
  ensure_node_and_npm
  ensure_local_bin_on_path

  if [[ "${EUID}" -eq 0 ]]; then
    npm install -g @openai/codex
  else
    mkdir -p "$NPM_PREFIX/bin"
    npm config set prefix "$NPM_PREFIX" >/dev/null
    export PATH="$NPM_PREFIX/bin:$PATH"
    npm install -g @openai/codex
  fi

  have codex && log "codex version: $(codex --version 2>/dev/null || true)" || warn "codex が PATH で見つかりません"
}

# ==========
# Extensions
# ==========
default_extensions() {
  local exts=()

  # --- Core（ほぼ全員入れる枠）
  exts+=(
    "eamodio.gitlens"
    "mhutchie.git-graph"
    "EditorConfig.EditorConfig"
    "esbenp.prettier-vscode"
    "dbaeumer.vscode-eslint"
    "redhat.vscode-yaml"
    "streetsidesoftware.code-spell-checker"
    "yzhang.markdown-all-in-one"
    "DavidAnson.vscode-markdownlint"
    "christian-kohler.path-intellisense"
  )

  # --- Python / DS
  if [[ "$INSTALL_PYTHON_EXTENSIONS" == "1" ]]; then
    exts+=(
      "ms-python.python"
      "ms-toolsai.jupyter"
      "ms-pyright.pyright"
    )
  fi

  # --- DevOps（必要なら）
  if [[ "$INSTALL_DEVOPS_EXTENSIONS" == "1" ]]; then
    exts+=(
      "ms-azuretools.vscode-docker"
      "hashicorp.terraform"
      "ms-kubernetes-tools.vscode-kubernetes-tools"
    )
  fi

  # --- AI（Cursorっぽさ寄せ）
  if [[ "$INSTALL_AI_EXTENSIONS" == "1" ]]; then
    exts+=(
      "Continue.continue"
      "saoudrizwan.claude-dev"
      "Codeium.codeium"
    )
  fi

  printf "%s\n" "${exts[@]}"
}

load_extensions() {
  local exts=()

  if [[ -n "$CODE_SERVER_EXTENSIONS" ]]; then
    # 空白/改行区切りを配列化
    while IFS= read -r tok; do
      [[ -n "$tok" ]] && exts+=("$tok")
    done < <(printf "%s" "$CODE_SERVER_EXTENSIONS" | tr ' ' '\n' | sed '/^\s*$/d')
    printf "%s\n" "${exts[@]}"
    return 0
  fi

  if [[ -n "$CODE_SERVER_EXTENSIONS_FILE" ]]; then
    [[ -f "$CODE_SERVER_EXTENSIONS_FILE" ]] || die "CODE_SERVER_EXTENSIONS_FILE が見つかりません: $CODE_SERVER_EXTENSIONS_FILE"
    while IFS= read -r line; do
      # コメント除去 + trim
      line="${line%%#*}"
      line="$(echo "$line" | xargs || true)"
      [[ -z "$line" ]] && continue
      exts+=("$line")
    done < "$CODE_SERVER_EXTENSIONS_FILE"
    printf "%s\n" "${exts[@]}"
    return 0
  fi

  default_extensions
}

install_code_server_extensions() {
  [[ "$INSTALL_CODE_SERVER_EXTENSIONS" == "1" ]] || { log "拡張インストールはスキップします"; return 0; }

  log "code-server 拡張を一括インストールします（Open VSX前提）"
  local ok=() ng=()

  while IFS= read -r ext; do
    [[ -z "$ext" ]] && continue
    log "  -> $ext"
    if code-server --install-extension "$ext" >/tmp/code_server_ext_install.log 2>&1; then
      ok+=("$ext")
    else
      ng+=("$ext")
      warn "     失敗: $ext"
      tail -n 8 /tmp/code_server_ext_install.log >&2 || true
    fi
  done < <(load_extensions)

  log "拡張インストール結果: OK=${#ok[@]} / NG=${#ng[@]}"
  if [[ "${#ng[@]}" -gt 0 ]]; then
    warn "見つからない/互換性NGの拡張（Open VSX未掲載など）の可能性があります:"
    printf "  - %s\n" "${ng[@]}" >&2
  fi
}

print_next_steps() {
  echo
  log "✅ セットアップ完了"
  echo "code-server: http://127.0.0.1:${CODE_SERVER_PORT} （SSHトンネル経由でアクセス）"
  if [[ "$CODE_SERVER_AUTH" == "password" ]]; then
    echo "password: ${CODE_SERVER_PASSWORD}"
  else
    echo "auth: none（SSHトンネル前提）"
  fi
  echo
  echo "手動起動（systemd無しの場合）:"
  echo "  code-server --config \"$HOME/.config/code-server/config.yaml\""
}

main() {
  init_privilege
  install_base_packages
  install_code_server
  write_code_server_config

  # ここで拡張を入れておく（起動前）
  install_code_server_extensions

  # systemd がある環境ならサービス化
  setup_systemd_service

  # Codex CLI
  install_codex_cli_npm

  print_next_steps

  if [[ "$AUTO_START_CODE_SERVER" == "1" ]]; then
    log "AUTO_START_CODE_SERVER=1 のため、foregroundで起動します"
    exec code-server --config "$HOME/.config/code-server/config.yaml"
  fi
}

main "$@"

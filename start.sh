#!/usr/bin/env bash
set -euo pipefail

# ==========
# 設定（必要なら環境変数で上書き）
# ==========
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
CODE_SERVER_BIND_ADDR="${CODE_SERVER_BIND_ADDR:-127.0.0.1}"
# SSHトンネル前提なら none が楽。パスワード運用なら password にして CODE_SERVER_PASSWORD を設定
CODE_SERVER_AUTH="${CODE_SERVER_AUTH:-none}"   # none|password
CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-}"

# 非root時のみ npm の global prefix をユーザー領域へ
NPM_PREFIX="${NPM_PREFIX:-$HOME/.local}"

# ==========
# ユーティリティ
# ==========
log()  { echo -e "\033[1;32m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[err  ]\033[0m $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# rootならsudo不要、非rootならsudo必須
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

  # 永続化（bash/zsh/profile）
  local profile_file
  if [[ -n "${BASH_VERSION:-}" ]]; then
    profile_file="$HOME/.bashrc"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    profile_file="$HOME/.zshrc"
  else
    profile_file="$HOME/.profile"
  fi

  # rootのときも /root に追記されるだけなので問題なし
  if [[ -f "$profile_file" ]] && ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$profile_file"; then
    {
      echo ''
      echo '# added by start.sh'
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$profile_file"
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
  # rootならシステム領域に入ることが多い／非rootでもOK
  curl -fsSL https://code-server.dev/install.sh | sh

  ensure_local_bin_on_path

  if ! have code-server; then
    die "code-server が PATH で見つかりません。再ログインするか PATH を確認してください。"
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
  # systemctlがあってもコンテナだと動かないケースが多いのでガード
  have systemctl || return 1
  systemctl is-system-running >/dev/null 2>&1 || return 1
  return 0
}

setup_systemd_service() {
  if ! systemd_is_usable; then
    warn "systemd が動いていないためサービス化はスキップします（必要なら手動起動してください）"
    return 0
  fi

  # code-server@.service があるならそれを使う
  if ${SUDO} systemctl list-unit-files | grep -qE '^code-server@\.service'; then
    log "systemd unit (code-server@.service) を利用して起動設定します"
    ${SUDO} systemctl enable --now "code-server@${USER}"
    return 0
  fi

  # 無ければ自前ユニットを作る
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

  if [[ "${EUID}" -eq 0 ]]; then
    # rootなら素直にグローバルへ（/usr/local など）
    npm install -g @openai/codex
  else
    # 非rootなら sudo npm を避けてユーザー領域へ
    mkdir -p "$NPM_PREFIX/bin"
    npm config set prefix "$NPM_PREFIX" >/dev/null
    ensure_local_bin_on_path
    npm install -g @openai/codex
  fi

  if have codex; then
    log "codex version: $(codex --version 2>/dev/null || true)"
  else
    warn "codex が PATH で見つかりません。npmのprefix/binがPATHに入っているか確認してください。"
  fi
}

print_next_steps() {
  echo
  log "✅ セットアップ完了"
  echo
  echo "起動方法（systemd が無い/動かない場合）:"
  echo "  code-server --config \"$HOME/.config/code-server/config.yaml\""
  echo
  echo "ローカルPCからSSHトンネル（例）:"
  echo "  ssh -N -L ${CODE_SERVER_PORT}:127.0.0.1:${CODE_SERVER_PORT} ${USER}@<server>"
  echo
  echo "ブラウザ:"
  echo "  http://127.0.0.1:${CODE_SERVER_PORT}"
  echo
  echo "Codex:"
  echo "  codex"
  echo
  if [[ "$CODE_SERVER_AUTH" == "password" ]]; then
    echo "code-server password: ${CODE_SERVER_PASSWORD}"
  else
    echo "code-server auth: none（SSHトンネル前提）"
  fi
}

main() {
  init_privilege
  install_base_packages
  install_code_server
  write_code_server_config
  setup_systemd_service
  install_codex_cli_npm
  print_next_steps
}

main "$@"

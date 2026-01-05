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

# Codex CLI を npm でグローバル（ユーザー領域）に入れるための prefix
NPM_PREFIX="${NPM_PREFIX:-$HOME/.local}"

# ==========
# ユーティリティ
# ==========
log()  { echo -e "\033[1;32m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[err  ]\033[0m $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_not_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    die "rootではなく、普段のユーザーで実行してください（sudo権限は使います）"
  fi
  have sudo || die "sudo が見つかりません"
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

  if [[ -f "$profile_file" ]] && ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$profile_file"; then
    {
      echo ''
      echo '# added by setup_webide.sh'
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$profile_file"
  fi
}

install_base_packages() {
  log "依存パッケージ（curl/git/tar/ca-certificates/python3）をインストールします"
  if have apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y curl git tar ca-certificates python3
  elif have dnf; then
    sudo dnf install -y curl git tar ca-certificates python3
  elif have yum; then
    sudo yum install -y curl git tar ca-certificates python3
  elif have pacman; then
    sudo pacman -Sy --noconfirm curl git tar ca-certificates python
  else
    warn "未対応のパッケージマネージャです。curl/git/tar/python3 を手動で入れてください。"
  fi
}

install_code_server() {
  log "code-server を公式 install.sh でインストールします"
  # 公式: curl -fsSL https://code-server.dev/install.sh | sh
  curl -fsSL https://code-server.dev/install.sh | sh
  ensure_local_bin_on_path

  if ! have code-server; then
    die "code-server が PATH で見つかりません。~/.local/bin を PATH に入れて再ログイン後、再実行してください。"
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

setup_systemd_service() {
  if ! have systemctl; then
    warn "systemctl が無いので systemd サービス化はスキップします。必要なら手動で code-server を起動してください。"
    return 0
  fi

  # インストール方法によっては code-server@.service がある
  if sudo systemctl list-unit-files | grep -qE '^code-server@\.service'; then
    log "systemd unit (code-server@.service) を利用して起動設定します"
    sudo systemctl enable --now "code-server@${USER}"
    return 0
  fi

  # 無ければ自前ユニットを作る
  log "systemd unit を作成します（standalone導入でも動く）"
  local home_dir code_server_bin
  home_dir="$(eval echo "~${USER}")"
  code_server_bin="$(command -v code-server)"

  local svc_name="code-server-${USER}.service"
  local svc_path="/etc/systemd/system/${svc_name}"

  sudo tee "$svc_path" >/dev/null <<EOF
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

  sudo systemctl daemon-reload
  sudo systemctl enable --now "$svc_name"
}

ensure_node_and_npm() {
  if have npm && have node; then
    log "node: $(node --version 2>/dev/null || true) / npm: $(npm --version 2>/dev/null || true)"
    return 0
  fi

  log "npm が無いので Node.js / npm をインストールします（OS標準パッケージ）"
  if have apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y nodejs npm
  elif have dnf; then
    sudo dnf install -y nodejs npm
  elif have yum; then
    sudo yum install -y nodejs npm
  elif have pacman; then
    sudo pacman -Sy --noconfirm nodejs npm
  else
    die "node/npm を自動導入できませんでした。手動で Node.js + npm を入れてから再実行してください。"
  fi

  have npm || die "npm のインストールに失敗しました（OS標準パッケージが古い等の可能性）"
  have node || die "node のインストールに失敗しました"
  log "node: $(node --version 2>/dev/null || true) / npm: $(npm --version 2>/dev/null || true)"
}

install_codex_cli_npm() {
  log "Codex CLI を npm でインストールします（@openai/codex）"
  ensure_node_and_npm
  ensure_local_bin_on_path

  # グローバル prefix が書き込み不可なら、ユーザー領域に切り替える（sudo npm を避けたい）
  local current_prefix current_bin
  current_prefix="$(npm config get prefix 2>/dev/null || echo "")"
  current_bin="${current_prefix}/bin"

  if [[ -n "$current_prefix" && -d "$current_bin" && -w "$current_bin" ]]; then
    log "npm global prefix は書き込み可: $current_prefix"
  else
    log "npm global prefix をユーザー領域へ: $NPM_PREFIX"
    mkdir -p "$NPM_PREFIX/bin"
    npm config set prefix "$NPM_PREFIX" >/dev/null
  fi

  # 公式: npm i -g @openai/codex
  npm install -g @openai/codex

  if ! have codex; then
    warn "codex が PATH で見つかりません。再ログインして ~/.local/bin が PATH に入っているか確認してください。"
  else
    log "codex version: $(codex --version 2>/dev/null || true)"
  fi
}

print_next_steps() {
  echo
  log "✅ セットアップ完了"
  echo
  echo "次のステップ:"
  echo "  1) ローカルPCからSSHトンネル（例）"
  echo "     ssh -N -L ${CODE_SERVER_PORT}:127.0.0.1:${CODE_SERVER_PORT} ${USER}@<server>"
  echo
  echo "  2) ローカルPCのブラウザで開く"
  echo "     http://127.0.0.1:${CODE_SERVER_PORT}"
  echo
  echo "  3) サーバ上のターミナルで Codex"
  echo "     codex"
  echo "     ※ 初回はサインインが走ります"
  echo
  if [[ "$CODE_SERVER_AUTH" == "password" ]]; then
    echo "code-server password: ${CODE_SERVER_PASSWORD}"
  else
    echo "code-server auth: none（SSHトンネル前提）"
  fi
  echo
  if have systemctl; then
    if sudo systemctl list-unit-files | grep -qE '^code-server@\.service'; then
      echo "service:"
      echo "  sudo systemctl status code-server@${USER}"
      echo "  sudo systemctl restart code-server@${USER}"
    else
      echo "service:"
      echo "  sudo systemctl status code-server-${USER}.service"
      echo "  sudo systemctl restart code-server-${USER}.service"
    fi
  fi
}

main() {
  ensure_not_root
  install_base_packages
  install_code_server
  write_code_server_config
  setup_systemd_service
  install_codex_cli_npm
  print_next_steps
}

main "$@"

#!/usr/bin/env bash
# codex-cli-manager.sh
# Debian/Ubuntu Codex CLI 管理脚本：查看状态、安装、更新、配置中转、执行策略、Telegram 聊天通道。
#
# 用法：
#   bash codex-cli-manager.sh
#
# 功能：
# - 启动后默认检索当前服务器 Codex 安装情况。
# - 根据是否已安装自动推荐“安装”或“更新”。
# - 支持安装 / 更新 Codex CLI。
# - 支持写入 OpenAI-compatible 中转配置。
# - 支持选择默认安全模式或“全部允许执行、不再询问”的高风险模式。
# - 支持安装/更新/管理 Telegram 聊天通道集成：woosungchoi/codex-telegram-bot。
#
# 注意：
# - 必须 root 执行；不询问用户名。
# - 默认安装到当前执行用户 HOME 下。root 执行就是 /root/.codex。
# - 当前 Codex 自定义 provider 主要使用 Responses API。
# - 你的中转必须支持 /v1/responses；只支持 /v1/chat/completions 的中转不兼容。

set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "[ERROR] 第 ${LINENO} 行执行失败，请检查上方错误信息。" >&2' ERR

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""

CODEX_INSTALLED="no"
CODEX_CMD=""
CODEX_VERSION=""
CODEX_CANDIDATES=""
CODEX_HOME_SIZE="unknown"

CONFIG_FILE=""
ENV_FILE=""
CONFIG_EXISTS="no"
ENV_EXISTS="no"
CONFIG_MODEL=""
CONFIG_PROVIDER=""
CONFIG_BASE_URL=""
CONFIG_APPROVAL=""
CONFIG_SANDBOX=""
ENV_HAS_KEY="no"

BASE_URL=""
API_KEY=""
MODEL_NAME=""
APPROVAL_POLICY="on-request"
SANDBOX_MODE="workspace-write"
EXECUTION_PROFILE_DESC="默认安全模式：workspace-write + on-request"

TELEGRAM_DIR=""
TELEGRAM_ENV_FILE=""
TELEGRAM_SERVICE_FILE="/etc/systemd/system/codex-telegram-bot.service"
TELEGRAM_SERVICE_NAME="codex-telegram-bot.service"
TELEGRAM_REPO_URL="https://github.com/woosungchoi/codex-telegram-bot.git"

TELEGRAM_INSTALLED="no"
TELEGRAM_ENV_EXISTS="no"
TELEGRAM_SERVICE_EXISTS="no"
TELEGRAM_SERVICE_ENABLED="unknown"
TELEGRAM_SERVICE_ACTIVE="unknown"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ALLOWED_USER_IDS=""
TELEGRAM_ALLOWED_CHAT_IDS=""
TELEGRAM_ALLOWED_THREAD_IDS=""
TELEGRAM_WORKDIR=""
TELEGRAM_LANGUAGE="en"
TELEGRAM_TIME_ZONE="Asia/Shanghai"
TELEGRAM_LOCALE="zh-CN"
TELEGRAM_SKIP_GIT_REPO_CHECK="false"

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "本脚本需要 root 权限。请使用 root 登录后执行，或使用：sudo bash $0"
  fi

  TARGET_USER="$(id -un)"
  TARGET_HOME="${HOME:-}"
  if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  fi
  TARGET_GROUP="$(id -gn)"

  [[ -n "$TARGET_USER" ]] || die "无法识别当前用户。"
  [[ -d "$TARGET_HOME" ]] || die "当前用户 HOME 目录不存在：$TARGET_HOME"

  CONFIG_FILE="$TARGET_HOME/.codex/config.toml"
  ENV_FILE="$TARGET_HOME/.codex/proxy.env"
  TELEGRAM_DIR="$TARGET_HOME/codex-telegram-bot"
  TELEGRAM_ENV_FILE="$TELEGRAM_DIR/.env"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，不确定是否为 Debian 系系统。"
  # shellcheck disable=SC1091
  . /etc/os-release

  local id="${ID:-}"
  local like="${ID_LIKE:-}"

  if [[ "$id" != "debian" && "$id" != "ubuntu" && "$like" != *"debian"* ]]; then
    die "当前系统不是 Debian/Ubuntu/Debian-like：ID=${id}, ID_LIKE=${like}。本脚本只面向 Debian 系服务器。"
  fi

  OS_PRETTY="${PRETTY_NAME:-$id}"
}

detect_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64|arm64)
      ARCH_DETECTED="$arch"
      ;;
    *)
      die "暂不支持该架构：${arch:-unknown}。建议使用 amd64 或 arm64。"
      ;;
  esac
}

dedupe_lines() {
  awk '!seen[$0]++'
}

toml_get_top_value() {
  local key="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  awk -v k="$key" '
    BEGIN { in_section=0 }
    /^[[:space:]]*\[/ { in_section=1 }
    in_section == 0 {
      line=$0
      sub(/#.*/, "", line)
      if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
        sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

toml_get_provider_value() {
  local key="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  awk -v k="$key" '
    BEGIN { in_provider=0 }
    /^[[:space:]]*\[model_providers\.proxy\][[:space:]]*$/ { in_provider=1; next }
    /^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\[model_providers\.proxy\][[:space:]]*$/ {
      if (in_provider == 1) exit
    }
    in_provider == 1 {
      line=$0
      sub(/#.*/, "", line)
      if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
        sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

inspect_codex() {
  CODEX_INSTALLED="no"
  CODEX_CMD=""
  CODEX_VERSION=""
  CODEX_CANDIDATES=""
  CODEX_HOME_SIZE="unknown"

  CONFIG_EXISTS="no"
  ENV_EXISTS="no"
  CONFIG_MODEL=""
  CONFIG_PROVIDER=""
  CONFIG_BASE_URL=""
  CONFIG_APPROVAL=""
  CONFIG_SANDBOX=""
  ENV_HAS_KEY="no"

  local candidates_tmp
  candidates_tmp="$(mktemp)"

  {
    [[ -x "$TARGET_HOME/.codex/bin/codex" ]] && echo "$TARGET_HOME/.codex/bin/codex"
    [[ -x "$TARGET_HOME/.local/bin/codex" ]] && echo "$TARGET_HOME/.local/bin/codex"
    [[ -x "/usr/local/bin/codex" ]] && echo "/usr/local/bin/codex"
    [[ -x "/usr/bin/codex" ]] && echo "/usr/bin/codex"
    command -v codex 2>/dev/null || true
  } | sed '/^[[:space:]]*$/d' | dedupe_lines > "$candidates_tmp"

  if [[ -s "$candidates_tmp" ]]; then
    CODEX_INSTALLED="yes"
    CODEX_CMD="$(head -n 1 "$candidates_tmp")"
    CODEX_CANDIDATES="$(paste -sd ', ' "$candidates_tmp")"
    CODEX_VERSION="$("$CODEX_CMD" --version 2>/dev/null || true)"
    [[ -n "$CODEX_VERSION" ]] || CODEX_VERSION="unknown"
  fi

  rm -f "$candidates_tmp"

  if [[ -d "$TARGET_HOME/.codex" ]]; then
    CODEX_HOME_SIZE="$(du -sh "$TARGET_HOME/.codex" 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$CODEX_HOME_SIZE" ]] || CODEX_HOME_SIZE="unknown"
  else
    CODEX_HOME_SIZE="not found"
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    CONFIG_EXISTS="yes"
    CONFIG_MODEL="$(toml_get_top_value "model" "$CONFIG_FILE")"
    CONFIG_PROVIDER="$(toml_get_top_value "model_provider" "$CONFIG_FILE")"
    CONFIG_APPROVAL="$(toml_get_top_value "approval_policy" "$CONFIG_FILE")"
    CONFIG_SANDBOX="$(toml_get_top_value "sandbox_mode" "$CONFIG_FILE")"
    CONFIG_BASE_URL="$(toml_get_provider_value "base_url" "$CONFIG_FILE")"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    ENV_EXISTS="yes"
    if grep -q '^export[[:space:]]\+CODEX_PROXY_API_KEY=' "$ENV_FILE" 2>/dev/null; then
      ENV_HAS_KEY="yes"
    fi
  fi

}

inspect_telegram() {
  TELEGRAM_INSTALLED="no"
  TELEGRAM_ENV_EXISTS="no"
  TELEGRAM_SERVICE_EXISTS="no"
  TELEGRAM_SERVICE_ENABLED="unknown"
  TELEGRAM_SERVICE_ACTIVE="unknown"

  if [[ -d "$TELEGRAM_DIR" ]]; then
    TELEGRAM_INSTALLED="yes"
  fi

  if [[ -f "$TELEGRAM_ENV_FILE" ]]; then
    TELEGRAM_ENV_EXISTS="yes"
  fi

  if [[ -f "$TELEGRAM_SERVICE_FILE" ]]; then
    TELEGRAM_SERVICE_EXISTS="yes"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    TELEGRAM_SERVICE_ENABLED="$(systemctl is-enabled "$TELEGRAM_SERVICE_NAME" 2>/dev/null || true)"
    [[ -n "$TELEGRAM_SERVICE_ENABLED" ]] || TELEGRAM_SERVICE_ENABLED="unknown"

    TELEGRAM_SERVICE_ACTIVE="$(systemctl is-active "$TELEGRAM_SERVICE_NAME" 2>/dev/null || true)"
    [[ -n "$TELEGRAM_SERVICE_ACTIVE" ]] || TELEGRAM_SERVICE_ACTIVE="unknown"
  fi
}

print_status() {
  echo
  echo "================ Codex 当前安装情况 ================"
  echo "系统信息：${OS_PRETTY:-unknown}"
  echo "系统架构：${ARCH_DETECTED:-unknown}"
  echo "当前用户：$TARGET_USER"
  echo "HOME目录：$TARGET_HOME"
  echo

  if [[ "$CODEX_INSTALLED" == "yes" ]]; then
    echo "Codex状态：已安装"
    echo "Codex版本：$CODEX_VERSION"
    echo "Codex路径：$CODEX_CMD"
    echo "其他路径：${CODEX_CANDIDATES:-无}"
  else
    echo "Codex状态：未检测到 codex 命令"
  fi

  echo "Codex目录：$TARGET_HOME/.codex"
  echo "目录占用：$CODEX_HOME_SIZE"
  echo

  echo "配置文件：$CONFIG_FILE"
  echo "配置状态：$CONFIG_EXISTS"
  if [[ "$CONFIG_EXISTS" == "yes" ]]; then
    echo "当前模型：${CONFIG_MODEL:-未配置}"
    echo "Provider ：${CONFIG_PROVIDER:-未配置}"
    echo "Base URL ：${CONFIG_BASE_URL:-未配置}"
    echo "审批策略：${CONFIG_APPROVAL:-未配置}"
    echo "沙箱模式：${CONFIG_SANDBOX:-未配置}"
  fi

  echo
  echo "密钥文件：$ENV_FILE"
  echo "密钥状态：$ENV_EXISTS"
  echo "API Key ：$ENV_HAS_KEY"
  echo
  echo "Telegram集成目录：$TELEGRAM_DIR"
  echo "Telegram安装状态：$TELEGRAM_INSTALLED"
  echo "Telegram配置状态：$TELEGRAM_ENV_EXISTS"
  echo "Telegram服务文件：$TELEGRAM_SERVICE_EXISTS"
  echo "Telegram服务启用：$TELEGRAM_SERVICE_ENABLED"
  echo "Telegram服务运行：$TELEGRAM_SERVICE_ACTIVE"
  echo "===================================================="
  echo
}

choose_action() {
  local default_action
  if [[ "$CODEX_INSTALLED" == "yes" ]]; then
    default_action="2"
  else
    default_action="1"
  fi

  echo "请选择操作："
  echo "  1) 安装 Codex CLI，并配置中转"
  echo "  2) 更新 Codex CLI，可选择是否重写中转配置"
  echo "  3) 只查看安装情况并退出"
  echo "  4) 仅重写中转配置"
  echo "  5) 仅配置 Codex 执行策略"
  echo "  6) 安装/管理聊天通道集成（Telegram）"
  echo
  echo "根据当前检测结果，默认推荐：$default_action"
  read -r -p "请输入选项 [${default_action}]: " ACTION
  ACTION="${ACTION:-$default_action}"

  case "$ACTION" in
    1|2|3|4|5|6) ;;
    *) die "无效选项：$ACTION" ;;
  esac
}

install_deps() {
  log "安装前置依赖：curl、ca-certificates、git、jq、tar、xz-utils、bubblewrap、gawk 等"
  apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    tar \
    gzip \
    xz-utils \
    unzip \
    bubblewrap \
    sudo \
    gawk
}

read_config() {
  echo
  read -r -p "请输入中转 Base URL（建议填到 /v1，例如 https://api.example.com/v1）: " BASE_URL
  BASE_URL="$(printf '%s' "$BASE_URL" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
  [[ -n "$BASE_URL" ]] || die "Base URL 不能为空。"

  BASE_URL="${BASE_URL%/}"

  if [[ "$BASE_URL" != http://* && "$BASE_URL" != https://* ]]; then
    die "Base URL 必须以 http:// 或 https:// 开头。"
  fi

  if [[ "$BASE_URL" != */v1 ]]; then
    warn "你输入的 URL 不是以 /v1 结尾。OpenAI-compatible 中转通常应该填到 /v1。"
    read -r -p "是否自动追加 /v1？[Y/n]: " append_v1
    append_v1="${append_v1:-Y}"
    if [[ "$append_v1" =~ ^[Yy]$ ]]; then
      BASE_URL="${BASE_URL}/v1"
    fi
  fi

  read -r -s -p "请输入 API Key（不会回显）: " API_KEY
  echo
  [[ -n "$API_KEY" ]] || die "API Key 不能为空。"

  read -r -p "请输入模型名（例如 gpt-5.5-codex、gpt-5.5、你的中转别名）: " MODEL_NAME
  MODEL_NAME="$(printf '%s' "$MODEL_NAME" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
  [[ -n "$MODEL_NAME" ]] || die "模型名不能为空。"

  echo
  log "将使用："
  echo "  Base URL : $BASE_URL"
  echo "  Model    : $MODEL_NAME"
  echo "  API Key  : 已隐藏"
  echo
  read -r -p "确认写入以上中转配置？[Y/n]: " confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]] || die "用户取消。"
}

toml_escape() {
  # TOML basic string escaping: backslash and double quote.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_single_quote() {
  # 输出可被 shell 安全 source 的单引号字符串。
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

install_codex_by_official_installer() {
  log "尝试使用 OpenAI 官方 standalone installer 安装 / 升级 Codex CLI 最新版本"
  export HOME="$TARGET_HOME"
  export USER="$TARGET_USER"
  export LOGNAME="$TARGET_USER"

  local tmp_bin=""
  local old_path="$PATH"

  # Debian/Ubuntu 默认 /usr/bin/awk 可能是 mawk。
  # Codex 官方 installer 曾出现 SHA256SUMS 解析失败问题，这里临时让 awk 指向 gawk。
  if command -v gawk >/dev/null 2>&1; then
    tmp_bin="$(mktemp -d)"
    ln -sf "$(command -v gawk)" "$tmp_bin/awk"
    export PATH="$tmp_bin:$PATH"
  fi

  local ok=0
  if curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh; then
    ok=1
  fi

  export PATH="$old_path"
  if [[ -n "$tmp_bin" ]]; then
    rm -rf "$tmp_bin"
  fi

  [[ "$ok" -eq 1 ]]
}

ensure_node_for_npm_fallback() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local major
    major="$(node -v | sed 's/^v//' | cut -d. -f1)"
    if [[ "$major" =~ ^[0-9]+$ && "$major" -ge 18 ]]; then
      log "检测到 Node.js：$(node -v)，npm：$(npm -v)"
      return 0
    fi
    warn "当前 Node.js 版本过低：$(node -v)。Codex 通常要求 Node.js 18+，将尝试通过 apt 安装。"
  fi

  log "安装 npm fallback 所需依赖：nodejs、npm"
  apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs npm

  command -v node >/dev/null 2>&1 || die "node 安装失败。"
  command -v npm >/dev/null 2>&1 || die "npm 安装失败。"

  local major
  major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  [[ "$major" =~ ^[0-9]+$ && "$major" -ge 18 ]] || die "Node.js 版本仍低于 18：$(node -v)。请先安装 Node.js 18+。"

  log "Node.js：$(node -v)，npm：$(npm -v)"
}

install_codex_by_npm() {
  warn "standalone installer 失败，开始 fallback：npm install -g @openai/codex@latest"
  ensure_node_for_npm_fallback
  npm install -g @openai/codex@latest
}

install_or_update_codex() {
  if ! install_codex_by_official_installer; then
    install_codex_by_npm
  fi

  inspect_codex

  [[ "$CODEX_INSTALLED" == "yes" ]] || die "Codex 安装/更新后仍未找到 codex 命令。"
  log "Codex 当前版本：$CODEX_VERSION"
  log "Codex 命令路径：$CODEX_CMD"
}

ask_execution_policy() {
  APPROVAL_POLICY="on-request"
  SANDBOX_MODE="workspace-write"
  EXECUTION_PROFILE_DESC="默认安全模式：workspace-write + on-request"

TELEGRAM_DIR=""
TELEGRAM_ENV_FILE=""
TELEGRAM_SERVICE_FILE="/etc/systemd/system/codex-telegram-bot.service"
TELEGRAM_SERVICE_NAME="codex-telegram-bot.service"
TELEGRAM_REPO_URL="https://github.com/woosungchoi/codex-telegram-bot.git"

TELEGRAM_INSTALLED="no"
TELEGRAM_ENV_EXISTS="no"
TELEGRAM_SERVICE_EXISTS="no"
TELEGRAM_SERVICE_ENABLED="unknown"
TELEGRAM_SERVICE_ACTIVE="unknown"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ALLOWED_USER_IDS=""
TELEGRAM_ALLOWED_CHAT_IDS=""
TELEGRAM_ALLOWED_THREAD_IDS=""
TELEGRAM_WORKDIR=""
TELEGRAM_LANGUAGE="en"
TELEGRAM_TIME_ZONE="Asia/Shanghai"
TELEGRAM_LOCALE="zh-CN"
TELEGRAM_SKIP_GIT_REPO_CHECK="false"

  echo
  warn "Codex 默认将使用安全模式：允许写工作区，但执行敏感命令会询问。"
  read -r -p "是否启用“全部允许 Codex 执行、不再询问用户”的高风险配置？[y/N]: " full_auto
  full_auto="${full_auto:-N}"

  if [[ "$full_auto" =~ ^[Yy]$ ]]; then
    echo
    warn "高风险提醒：启用后 Codex 将使用 danger-full-access + never。"
    warn "这意味着 Codex 可在本机执行命令、改文件、访问网络，且不再向你确认。"
    warn "建议只在一次性测试机、隔离容器、无重要数据的环境使用。"
    read -r -p "请输入 ALLOW 确认启用： " final_confirm

    if [[ "$final_confirm" == "ALLOW" ]]; then
      APPROVAL_POLICY="never"
      SANDBOX_MODE="danger-full-access"
      EXECUTION_PROFILE_DESC="完全自动模式：danger-full-access + never"
      log "已选择完全自动执行模式。"
    else
      warn "未输入 ALLOW，保持默认安全模式。"
    fi
  else
    log "保持默认安全模式。"
  fi
}

ask_reconfigure_after_update() {
  echo
  if [[ "$CONFIG_EXISTS" == "yes" ]]; then
    read -r -p "是否重写中转和执行策略配置？默认保留现有配置。[y/N]: " reconfig
    reconfig="${reconfig:-N}"
  else
    warn "未检测到 ~/.codex/config.toml，建议补充中转配置。"
    read -r -p "是否现在写入中转和执行策略配置？[Y/n]: " reconfig
    reconfig="${reconfig:-Y}"
  fi

  if [[ "$reconfig" =~ ^[Yy]$ ]]; then
    SHOULD_WRITE_CONFIG="yes"
  else
    SHOULD_WRITE_CONFIG="no"
  fi
}

write_codex_config() {
  log "写入 Codex 配置"

  local codex_dir="$TARGET_HOME/.codex"
  local backup_dir="$codex_dir/backup-$(date +%Y%m%d-%H%M%S)"

  install -d -m 700 "$codex_dir"

  if [[ -f "$CONFIG_FILE" || -f "$ENV_FILE" ]]; then
    install -d -m 700 "$backup_dir"
    [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$backup_dir/config.toml.bak"
    [[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "$backup_dir/proxy.env.bak"
    log "已备份旧配置到：$backup_dir"
  fi

  local model_toml base_toml api_shell approval_toml sandbox_toml
  model_toml="$(toml_escape "$MODEL_NAME")"
  base_toml="$(toml_escape "$BASE_URL")"
  api_shell="$(shell_single_quote "$API_KEY")"
  approval_toml="$(toml_escape "$APPROVAL_POLICY")"
  sandbox_toml="$(toml_escape "$SANDBOX_MODE")"

  local tmp_config tmp_env
  tmp_config="$(mktemp)"
  tmp_env="$(mktemp)"

  cat > "$tmp_config" <<EOF
# Generated by codex-cli-manager.sh
# Codex user config: ~/.codex/config.toml
#
# 注意：
# - 当前 Codex 自定义 provider 使用 Responses API。
# - 你的中转必须支持 ${BASE_URL}/responses。
# - API Key 不在本文件中，见 ~/.codex/proxy.env。
# - 当前执行策略：${EXECUTION_PROFILE_DESC}

model = "$model_toml"
model_provider = "proxy"

approval_policy = "$approval_toml"
sandbox_mode = "$sandbox_toml"

[model_providers.proxy]
name = "OpenAI-compatible proxy"
base_url = "$base_toml"
env_key = "CODEX_PROXY_API_KEY"
wire_api = "responses"
request_max_retries = 4
stream_max_retries = 5
stream_idle_timeout_ms = 300000
EOF

  cat > "$tmp_env" <<EOF
# Generated by codex-cli-manager.sh
# chmod 600. Do not share this file.
export CODEX_PROXY_API_KEY=$api_shell
export CODEX_HOME="\$HOME/.codex"
EOF

  install -m 600 "$tmp_config" "$CONFIG_FILE"
  install -m 600 "$tmp_env" "$ENV_FILE"

  rm -f "$tmp_config" "$tmp_env"

  log "已写入：$CONFIG_FILE"
  log "已写入：$ENV_FILE"
  log "执行策略：$EXECUTION_PROFILE_DESC"
}

ensure_shell_profile() {
  log "写入 shell 环境加载配置"

  local block_start="# >>> codex proxy env >>>"
  local block_end="# <<< codex proxy env <<<"
  local block
  block="$(cat <<'EOF'
# >>> codex proxy env >>>
export CODEX_HOME="$HOME/.codex"
if [ -f "$CODEX_HOME/proxy.env" ]; then
  . "$CODEX_HOME/proxy.env"
fi
if [ -d "$HOME/.codex/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.codex/bin:"*) ;;
    *) export PATH="$HOME/.codex/bin:$PATH" ;;
  esac
fi
if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
fi
# <<< codex proxy env <<<
EOF
)"

  local file tmp
  for file in "$TARGET_HOME/.bashrc" "$TARGET_HOME/.profile"; do
    touch "$file"

    tmp="$(mktemp)"
    awk -v start="$block_start" -v end="$block_end" '
      $0 == start {skip=1; next}
      $0 == end {skip=0; next}
      skip != 1 {print}
    ' "$file" > "$tmp"

    {
      cat "$tmp"
      echo
      echo "$block"
    } > "${tmp}.new"

    install -m 644 "${tmp}.new" "$file"
    rm -f "$tmp" "${tmp}.new"
  done
}

install_wrapper() {
  log "安装 codex-proxy 启动包装器到 /usr/local/bin/codex-proxy"

  local tmp
  tmp="$(mktemp)"

  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

if [[ -f "$CODEX_HOME/proxy.env" ]]; then
  # shellcheck disable=SC1090
  source "$CODEX_HOME/proxy.env"
fi

if [[ -d "$HOME/.codex/bin" ]]; then
  export PATH="$HOME/.codex/bin:$PATH"
fi
if [[ -d "$HOME/.local/bin" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

if [[ -x "$HOME/.codex/bin/codex" ]]; then
  exec "$HOME/.codex/bin/codex" "$@"
fi

if [[ -x "$HOME/.local/bin/codex" ]]; then
  exec "$HOME/.local/bin/codex" "$@"
fi

exec codex "$@"
EOF

  install -m 755 "$tmp" /usr/local/bin/codex-proxy
  rm -f "$tmp"
}

optional_smoke_test() {
  echo
  read -r -p "是否执行一次 Codex 命令检查？只检查版本，不调用模型。[Y/n]: " check
  check="${check:-Y}"
  if [[ "$check" =~ ^[Yy]$ ]]; then
    export CODEX_HOME="$TARGET_HOME/.codex"
    # shellcheck disable=SC1090
    [[ -f "$CODEX_HOME/proxy.env" ]] && source "$CODEX_HOME/proxy.env"
    export PATH="$TARGET_HOME/.codex/bin:$TARGET_HOME/.local/bin:/usr/local/bin:$PATH"

    codex --version
  fi
}


update_execution_policy_only() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    warn "未检测到 $CONFIG_FILE，无法仅修改执行策略。"
    warn "将进入完整中转配置流程。"
    read_config
    ask_execution_policy
    write_codex_config
    return 0
  fi

  ask_execution_policy

  local backup_dir tmp
  backup_dir="$TARGET_HOME/.codex/backup-$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$backup_dir"
  cp -a "$CONFIG_FILE" "$backup_dir/config.toml.bak"
  log "已备份旧配置到：$backup_dir/config.toml.bak"

  tmp="$(mktemp)"
  awk -v approval="$APPROVAL_POLICY" -v sandbox="$SANDBOX_MODE" '
    BEGIN {
      in_top=1
      wrote_approval=0
      wrote_sandbox=0
    }

    /^[[:space:]]*\[/ {
      if (in_top == 1) {
        if (wrote_approval == 0) {
          print "approval_policy = \"" approval "\""
          wrote_approval=1
        }
        if (wrote_sandbox == 0) {
          print "sandbox_mode = \"" sandbox "\""
          wrote_sandbox=1
        }
      }
      in_top=0
      print
      next
    }

    in_top == 1 && /^[[:space:]]*approval_policy[[:space:]]*=/ {
      print "approval_policy = \"" approval "\""
      wrote_approval=1
      next
    }

    in_top == 1 && /^[[:space:]]*sandbox_mode[[:space:]]*=/ {
      print "sandbox_mode = \"" sandbox "\""
      wrote_sandbox=1
      next
    }

    { print }

    END {
      if (in_top == 1) {
        if (wrote_approval == 0) print "approval_policy = \"" approval "\""
        if (wrote_sandbox == 0) print "sandbox_mode = \"" sandbox "\""
      }
    }
  ' "$CONFIG_FILE" > "$tmp"

  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"

  log "已更新执行策略：approval_policy=$APPROVAL_POLICY, sandbox_mode=$SANDBOX_MODE"
}

load_existing_proxy_key() {
  EXISTING_PROXY_KEY=""
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
    EXISTING_PROXY_KEY="${CODEX_PROXY_API_KEY:-}"
  fi
}

telegram_status() {
  inspect_telegram
  echo
  echo "================ Telegram 集成状态 ================"
  echo "项目目录：$TELEGRAM_DIR"
  echo "安装状态：$TELEGRAM_INSTALLED"
  echo "配置文件：$TELEGRAM_ENV_FILE"
  echo "配置状态：$TELEGRAM_ENV_EXISTS"
  echo "服务文件：$TELEGRAM_SERVICE_FILE"
  echo "服务状态：$TELEGRAM_SERVICE_EXISTS"
  echo "是否启用：$TELEGRAM_SERVICE_ENABLED"
  echo "是否运行：$TELEGRAM_SERVICE_ACTIVE"
  if command -v node >/dev/null 2>&1; then
    echo "Node.js ：$(node -v)"
  else
    echo "Node.js ：未安装"
  fi
  if command -v npm >/dev/null 2>&1; then
    echo "npm     ：$(npm -v)"
  else
    echo "npm     ：未安装"
  fi
  echo "==================================================="
  echo
}

telegram_choose_action() {
  echo "Telegram 聊天通道子菜单："
  echo "  1) 安装/更新 Telegram Bot，并写入配置"
  echo "  2) 启动/重启 Telegram Bot 服务"
  echo "  3) 停止 Telegram Bot 服务"
  echo "  4) 查看 Telegram Bot 日志"
  echo "  5) 只查看 Telegram 集成状态"
  echo "  6) 返回主菜单/退出"
  echo
  read -r -p "请输入选项 [1]: " TELEGRAM_ACTION
  TELEGRAM_ACTION="${TELEGRAM_ACTION:-1}"

  case "$TELEGRAM_ACTION" in
    1|2|3|4|5|6) ;;
    *) die "无效选项：$TELEGRAM_ACTION" ;;
  esac
}

read_telegram_config() {
  echo
  warn "Telegram Bot 会成为这台机器的远程命令入口，请务必限制 ALLOWED_USER_IDS。"

  read -r -s -p "请输入 Telegram Bot Token（从 @BotFather 获取，不会回显）: " TELEGRAM_BOT_TOKEN
  echo
  [[ -n "$TELEGRAM_BOT_TOKEN" ]] || die "Telegram Bot Token 不能为空。"

  read -r -p "请输入允许访问的 Telegram 用户数字 ID，多个用英文逗号分隔: " TELEGRAM_ALLOWED_USER_IDS
  TELEGRAM_ALLOWED_USER_IDS="$(printf '%s' "$TELEGRAM_ALLOWED_USER_IDS" | sed 's/[[:space:]]//g')"
  [[ "$TELEGRAM_ALLOWED_USER_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "ALLOWED_USER_IDS 格式不正确，必须是数字 ID，多个用英文逗号分隔。"

  read -r -p "可选：限制 Chat ID，多个用英文逗号分隔，群/超级群通常是负数 [留空]: " TELEGRAM_ALLOWED_CHAT_IDS
  TELEGRAM_ALLOWED_CHAT_IDS="$(printf '%s' "$TELEGRAM_ALLOWED_CHAT_IDS" | sed 's/[[:space:]]//g')"
  if [[ -n "$TELEGRAM_ALLOWED_CHAT_IDS" && ! "$TELEGRAM_ALLOWED_CHAT_IDS" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]]; then
    die "ALLOWED_CHAT_IDS 格式不正确。"
  fi

  read -r -p "可选：限制 Forum Thread ID，多个用英文逗号分隔 [留空]: " TELEGRAM_ALLOWED_THREAD_IDS
  TELEGRAM_ALLOWED_THREAD_IDS="$(printf '%s' "$TELEGRAM_ALLOWED_THREAD_IDS" | sed 's/[[:space:]]//g')"
  if [[ -n "$TELEGRAM_ALLOWED_THREAD_IDS" && ! "$TELEGRAM_ALLOWED_THREAD_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    die "ALLOWED_THREAD_IDS 格式不正确。"
  fi

  local default_workdir
  default_workdir="${CONFIG_WORKDIR:-$TARGET_HOME}"
  read -r -p "请输入 Codex 工作目录 [${default_workdir}]: " TELEGRAM_WORKDIR
  TELEGRAM_WORKDIR="${TELEGRAM_WORKDIR:-$default_workdir}"
  TELEGRAM_WORKDIR="$(realpath -m "$TELEGRAM_WORKDIR")"
  install -d -m 700 "$TELEGRAM_WORKDIR"

  read -r -p "Telegram 菜单语言 [en]: " TELEGRAM_LANGUAGE
  TELEGRAM_LANGUAGE="${TELEGRAM_LANGUAGE:-en}"

  read -r -p "Telegram 时区 [Asia/Shanghai]: " TELEGRAM_TIME_ZONE
  TELEGRAM_TIME_ZONE="${TELEGRAM_TIME_ZONE:-Asia/Shanghai}"

  read -r -p "Telegram Locale [zh-CN]: " TELEGRAM_LOCALE
  TELEGRAM_LOCALE="${TELEGRAM_LOCALE:-zh-CN}"

  read -r -p "是否允许 Codex 在非 Git 仓库目录运行？[y/N]: " skip_git
  skip_git="${skip_git:-N}"
  if [[ "$skip_git" =~ ^[Yy]$ ]]; then
    TELEGRAM_SKIP_GIT_REPO_CHECK="true"
  else
    TELEGRAM_SKIP_GIT_REPO_CHECK="false"
  fi

  echo
  log "Telegram 配置将使用："
  echo "  Bot Token          : 已隐藏"
  echo "  ALLOWED_USER_IDS   : $TELEGRAM_ALLOWED_USER_IDS"
  echo "  ALLOWED_CHAT_IDS   : ${TELEGRAM_ALLOWED_CHAT_IDS:-未限制}"
  echo "  ALLOWED_THREAD_IDS : ${TELEGRAM_ALLOWED_THREAD_IDS:-未限制}"
  echo "  CODEX_WORKDIR      : $TELEGRAM_WORKDIR"
  echo "  TELEGRAM_LANGUAGE  : $TELEGRAM_LANGUAGE"
  echo "  TELEGRAM_TIME_ZONE : $TELEGRAM_TIME_ZONE"
  echo "  TELEGRAM_LOCALE    : $TELEGRAM_LOCALE"
  echo "  SKIP_GIT_CHECK     : $TELEGRAM_SKIP_GIT_REPO_CHECK"
  echo
  read -r -p "确认安装/更新 Telegram Bot 并写入配置？[Y/n]: " confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]] || die "用户取消。"
}

validate_telegram_token() {
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi

  log "尝试校验 Telegram Bot Token（调用 getMe）"
  local http_body
  http_body="$(curl -fsS --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || true)"
  if [[ -z "$http_body" ]]; then
    warn "无法连接 Telegram API 或校验失败。可能是网络问题，继续安装。"
    return 0
  fi

  if echo "$http_body" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    log "Telegram Bot Token 校验通过。"
  else
    warn "Telegram Bot Token 返回异常：$http_body"
    read -r -p "是否仍继续安装？[y/N]: " continue_anyway
    continue_anyway="${continue_anyway:-N}"
    [[ "$continue_anyway" =~ ^[Yy]$ ]] || die "用户取消。"
  fi
}

install_telegram_bot_files() {
  install_deps
  ensure_node_for_npm_fallback

  log "安装/更新 codex-telegram-bot 项目"
  if [[ -d "$TELEGRAM_DIR/.git" ]]; then
    local backup_env=""
    if [[ -f "$TELEGRAM_ENV_FILE" ]]; then
      backup_env="$(mktemp)"
      cp -a "$TELEGRAM_ENV_FILE" "$backup_env"
    fi

    if ! git -C "$TELEGRAM_DIR" pull --ff-only; then
      warn "git pull --ff-only 失败，可能存在本地修改。"
      read -r -p "是否强制重置到 origin/main？会覆盖项目目录内除 .env 备份外的本地修改。[y/N]: " reset_git
      reset_git="${reset_git:-N}"
      if [[ "$reset_git" =~ ^[Yy]$ ]]; then
        git -C "$TELEGRAM_DIR" fetch origin main
        git -C "$TELEGRAM_DIR" reset --hard origin/main
      else
        warn "跳过代码更新，仅继续 npm install 和配置写入。"
      fi
    fi

    if [[ -n "$backup_env" && -f "$backup_env" ]]; then
      cp -a "$backup_env" "$TELEGRAM_ENV_FILE"
      rm -f "$backup_env"
    fi
  else
    if [[ -e "$TELEGRAM_DIR" ]]; then
      local moved="${TELEGRAM_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
      warn "$TELEGRAM_DIR 已存在但不是 git 仓库，将移动到：$moved"
      mv "$TELEGRAM_DIR" "$moved"
    fi
    git clone "$TELEGRAM_REPO_URL" "$TELEGRAM_DIR"
  fi

  log "执行 npm install"
  npm --prefix "$TELEGRAM_DIR" install
}

write_telegram_env() {
  log "写入 Telegram Bot .env 配置"

  local backup_dir
  backup_dir="$TELEGRAM_DIR/backup-$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$TELEGRAM_ENV_FILE" ]]; then
    install -d -m 700 "$backup_dir"
    cp -a "$TELEGRAM_ENV_FILE" "$backup_dir/.env.bak"
    log "已备份旧 Telegram .env 到：$backup_dir/.env.bak"
  fi

  local codex_path_for_bot
  if [[ -x "/usr/local/bin/codex-proxy" ]]; then
    codex_path_for_bot="/usr/local/bin/codex-proxy"
  elif [[ -n "$CODEX_CMD" ]]; then
    codex_path_for_bot="$CODEX_CMD"
  else
    codex_path_for_bot="codex"
  fi

  local codex_model_for_bot codex_base_url_for_bot codex_approval_for_bot codex_sandbox_for_bot
  codex_model_for_bot="${CONFIG_MODEL:-${MODEL_NAME:-}}"
  codex_base_url_for_bot="${CONFIG_BASE_URL:-${BASE_URL:-}}"
  codex_approval_for_bot="${CONFIG_APPROVAL:-${APPROVAL_POLICY:-on-request}}"
  codex_sandbox_for_bot="${CONFIG_SANDBOX:-${SANDBOX_MODE:-workspace-write}}"

  load_existing_proxy_key

  if [[ -z "${EXISTING_PROXY_KEY:-}" ]]; then
    warn "没有在 $ENV_FILE 中读到 CODEX_PROXY_API_KEY。"
    read -r -s -p "请输入给 Telegram Bot 使用的 Codex API Key（不会回显；可与中转 API Key 相同）: " EXISTING_PROXY_KEY
    echo
    [[ -n "$EXISTING_PROXY_KEY" ]] || die "Codex API Key 不能为空。"
  fi

  install -d -m 700 "$TELEGRAM_DIR/state" "$TELEGRAM_DIR/state/uploads" "$TELEGRAM_DIR/state/backups"

  local q_bot_token q_allowed_users q_allowed_chats q_allowed_threads
  local q_codex_path q_workdir q_model q_approval q_sandbox q_base_url q_api_key
  local q_codex_home q_sessions_dir q_language q_tz q_locale q_state_file q_upload_dir q_backup_dir

  q_bot_token="$(shell_single_quote "$TELEGRAM_BOT_TOKEN")"
  q_allowed_users="$(shell_single_quote "$TELEGRAM_ALLOWED_USER_IDS")"
  q_allowed_chats="$(shell_single_quote "$TELEGRAM_ALLOWED_CHAT_IDS")"
  q_allowed_threads="$(shell_single_quote "$TELEGRAM_ALLOWED_THREAD_IDS")"
  q_codex_path="$(shell_single_quote "$codex_path_for_bot")"
  q_workdir="$(shell_single_quote "$TELEGRAM_WORKDIR")"
  q_model="$(shell_single_quote "$codex_model_for_bot")"
  q_approval="$(shell_single_quote "$codex_approval_for_bot")"
  q_sandbox="$(shell_single_quote "$codex_sandbox_for_bot")"
  q_base_url="$(shell_single_quote "$codex_base_url_for_bot")"
  q_api_key="$(shell_single_quote "$EXISTING_PROXY_KEY")"
  q_codex_home="$(shell_single_quote "$TARGET_HOME/.codex")"
  q_sessions_dir="$(shell_single_quote "$TARGET_HOME/.codex/sessions")"
  q_language="$(shell_single_quote "$TELEGRAM_LANGUAGE")"
  q_tz="$(shell_single_quote "$TELEGRAM_TIME_ZONE")"
  q_locale="$(shell_single_quote "$TELEGRAM_LOCALE")"
  q_state_file="$(shell_single_quote "$TELEGRAM_DIR/state/state.json")"
  q_upload_dir="$(shell_single_quote "$TELEGRAM_DIR/state/uploads")"
  q_backup_dir="$(shell_single_quote "$TELEGRAM_DIR/state/backups")"

  cat > "$TELEGRAM_ENV_FILE" <<EOF
# Generated by codex-cli-manager.sh
# Do not share this file.

TELEGRAM_BOT_TOKEN=${q_bot_token}
ALLOWED_USER_IDS=${q_allowed_users}
ALLOWED_CHAT_IDS=${q_allowed_chats}
ALLOWED_THREAD_IDS=${q_allowed_threads}

CODEX_PATH=${q_codex_path}
CODEX_WORKDIR=${q_workdir}
CODEX_MODEL=${q_model}
CODEX_APPROVAL_POLICY=${q_approval}
CODEX_SANDBOX_MODE=${q_sandbox}
CODEX_SKIP_GIT_REPO_CHECK=${TELEGRAM_SKIP_GIT_REPO_CHECK}

# 让 Telegram Bot 直接拿到与 Codex CLI 相同的中转配置。
CODEX_BASE_URL=${q_base_url}
CODEX_API_KEY=${q_api_key}
CODEX_HOME=${q_codex_home}
CODEX_SESSIONS_DIR=${q_sessions_dir}

TELEGRAM_LANGUAGE=${q_language}
TELEGRAM_TIME_ZONE=${q_tz}
TELEGRAM_LOCALE=${q_locale}
TELEGRAM_FORMAT_CODEX_ANSWERS=markdown
TELEGRAM_LIVE_PROGRESS_ENABLED=true
TELEGRAM_LIVE_PROGRESS_INTERVAL_SECONDS=30

STATE_FILE=${q_state_file}
UPLOAD_DIR=${q_upload_dir}
UPLOAD_RETENTION_DAYS=7
UPLOAD_MAX_BYTES=1073741824
UPLOAD_CLEANUP_ENABLED=true
BACKUP_DIR=${q_backup_dir}

CLEANUP_ENABLED=true
SNAPSHOT_ENABLED=true
LOGS_MAX_LINES=120
EOF

  chmod 600 "$TELEGRAM_ENV_FILE"
  log "已写入：$TELEGRAM_ENV_FILE"
}

write_telegram_service() {
  log "写入 systemd 服务：$TELEGRAM_SERVICE_FILE"

  cat > "$TELEGRAM_SERVICE_FILE" <<EOF
[Unit]
Description=Codex Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_GROUP}
WorkingDirectory=${TELEGRAM_DIR}
EnvironmentFile=${TELEGRAM_ENV_FILE}
Environment=HOME=${TARGET_HOME}
Environment=CODEX_HOME=${TARGET_HOME}/.codex
Environment=PATH=${TARGET_HOME}/.codex/bin:${TARGET_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/env node ${TELEGRAM_DIR}/src/bot.js
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$TELEGRAM_SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "$TELEGRAM_SERVICE_NAME"
  systemctl restart "$TELEGRAM_SERVICE_NAME"

  sleep 2
  systemctl --no-pager --full status "$TELEGRAM_SERVICE_NAME" || true
}

install_or_update_telegram_bot() {
  inspect_codex
  if [[ "$CODEX_INSTALLED" != "yes" ]]; then
    die "未检测到 Codex CLI。请先选择 1 安装 Codex，或确认 codex 在 PATH 中。"
  fi

  read_telegram_config
  validate_telegram_token
  install_telegram_bot_files
  inspect_codex
  write_telegram_env
  write_telegram_service

  log "Telegram Bot 集成完成。打开 Telegram 给你的 Bot 发送 /start 或 /menu。"
  warn "首次建议发送 /whoami，确认 user/chat/thread id 后再收紧 ALLOWED_CHAT_IDS/ALLOWED_THREAD_IDS。"
}

restart_telegram_service() {
  [[ -f "$TELEGRAM_SERVICE_FILE" ]] || die "未找到服务文件：$TELEGRAM_SERVICE_FILE。请先安装 Telegram 集成。"
  systemctl daemon-reload
  systemctl restart "$TELEGRAM_SERVICE_NAME"
  systemctl --no-pager --full status "$TELEGRAM_SERVICE_NAME" || true
}

stop_telegram_service() {
  if systemctl list-unit-files "$TELEGRAM_SERVICE_NAME" >/dev/null 2>&1; then
    systemctl stop "$TELEGRAM_SERVICE_NAME" || true
    log "已停止 $TELEGRAM_SERVICE_NAME"
  else
    warn "未找到 $TELEGRAM_SERVICE_NAME"
  fi
}

show_telegram_logs() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$TELEGRAM_SERVICE_NAME" -n 120 --no-pager || true
  else
    warn "当前系统没有 journalctl。"
  fi
}

telegram_menu() {
  telegram_status
  telegram_choose_action

  case "$TELEGRAM_ACTION" in
    1)
      install_or_update_telegram_bot
      telegram_status
      ;;
    2)
      restart_telegram_service
      telegram_status
      ;;
    3)
      stop_telegram_service
      telegram_status
      ;;
    4)
      show_telegram_logs
      ;;
    5)
      telegram_status
      ;;
    6)
      log "退出 Telegram 子菜单。"
      ;;
  esac
}

print_done() {
  inspect_codex

  cat <<EOF

============================================================
Codex CLI 管理操作完成。

当前用户：
  $TARGET_USER

Codex状态：
  $CODEX_INSTALLED

Codex版本：
  ${CODEX_VERSION:-unknown}

Codex路径：
  ${CODEX_CMD:-not found}

配置文件：
  $CONFIG_FILE

密钥文件：
  $ENV_FILE

启动方式：

  方式 1：重新登录 SSH 后直接运行
    codex

  方式 2：当前 shell 立即生效
    source "$ENV_FILE"
    export PATH="$TARGET_HOME/.codex/bin:$TARGET_HOME/.local/bin:/usr/local/bin:\$PATH"
    codex

  方式 3：使用包装器，自动加载中转 API Key
    codex-proxy

常用命令：

  查看版本：
    codex --version

  指定模型临时启动：
    codex --model "${MODEL_NAME:-${CONFIG_MODEL:-模型名}}"

  非交互执行：
    codex exec "帮我检查这个项目的安全风险"

重要提醒：
  1. 当前自定义 provider 使用 Responses API。
     你的中转需要支持：
       ${BASE_URL:-${CONFIG_BASE_URL:-你的BaseURL}}/responses

  2. 如果你的中转只支持 /v1/chat/completions，Codex 可能会报 404、405、400 或 provider/request 相关错误。

  3. 如果你启用了完全自动执行模式：
       approval_policy = "never"
       sandbox_mode = "danger-full-access"
     这属于高风险组合，建议只在隔离测试机使用。

============================================================
EOF
}

main() {
  check_root
  detect_os
  detect_arch

  inspect_codex
  inspect_telegram
  print_status
  choose_action

  case "$ACTION" in
    1)
      install_deps
      read_config
      install_or_update_codex
      ask_execution_policy
      write_codex_config
      ensure_shell_profile
      install_wrapper
      optional_smoke_test
      print_done
      ;;
    2)
      install_deps
      install_or_update_codex
      inspect_codex
      ask_reconfigure_after_update
      if [[ "$SHOULD_WRITE_CONFIG" == "yes" ]]; then
        read_config
        ask_execution_policy
        write_codex_config
      else
        log "保留现有中转和执行策略配置。"
      fi
      ensure_shell_profile
      install_wrapper
      optional_smoke_test
      print_done
      ;;
    3)
      log "仅查看安装情况，不做修改。"
      ;;
    4)
      read_config
      ask_execution_policy
      write_codex_config
      ensure_shell_profile
      install_wrapper
      optional_smoke_test
      print_done
      ;;
    5)
      update_execution_policy_only
      inspect_codex
      print_status
      ;;
    6)
      telegram_menu
      ;;
  esac
}

main "$@"

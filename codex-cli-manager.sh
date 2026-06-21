#!/usr/bin/env bash
# codex-cli-manager.sh
# Debian/Ubuntu Codex CLI 管理脚本：查看状态、安装、更新、配置 OpenAI-compatible 中转。
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
  echo "  4) 仅重写中转和执行策略配置"
  echo
  echo "根据当前检测结果，默认推荐：$default_action"
  read -r -p "请输入选项 [${default_action}]: " ACTION
  ACTION="${ACTION:-$default_action}"

  case "$ACTION" in
    1|2|3|4) ;;
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
  esac
}

main "$@"

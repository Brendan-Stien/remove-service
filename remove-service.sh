#!/usr/bin/env bash
set -o pipefail
# 小心模式：不 set -e，这样出错时能继续清理并写日志

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS] <service-name>
安全卸载 systemd 服务（默认备份 unit 文件而非直接删除）

Options:
  -y, --yes             不交互，直接按选项执行（小心）
  --dry-run             仅显示将做的操作，不执行
  --backup-dir=PATH     备份目录（默认 /var/backups/remove-service）
  --remove-files        尝试备份并移除 ExecStart 指向的可执行文件（需谨慎）
  --remove-timers       同时处理 <name>.timer
  --force               即使被识别为 distro-managed 也继续
  --verbose             输出更详细信息
  --help                显示此帮助
EOF
}

# defaults
DRY_RUN=0
YES=0
BACKUP_BASE="/var/backups/remove-service"
REMOVE_FILES=0
REMOVE_TIMERS=0
FORCE=0
VERBOSE=0

# parse args (simple)
SERVICE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --backup-dir=*) BACKUP_BASE="${1#*=}"; shift;;
    --backup-dir) BACKUP_BASE="$2"; shift 2;;
    --remove-files) REMOVE_FILES=1; shift;;
    --remove-timers) REMOVE_TIMERS=1; shift;;
    --force) FORCE=1; shift;;
    --verbose) VERBOSE=1; shift;;
    --help) usage; exit 0;;
    -*)
      echo "未知选项: $1"; usage; exit 1;;
    *)
      if [ -z "$SERVICE" ]; then SERVICE="$1"; shift; else echo "多余参数: $1"; usage; exit 1; fi
      ;;
  esac
done

if [ -z "$SERVICE" ]; then
  echo "❌ 必须指定服务名，例如： sudo $0 serverstatus"
  usage
  exit 1
fi

# ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 或 sudo 运行此脚本"
  exit 1
fi

# normalize unit
UNIT="$SERVICE"
case "$UNIT" in
  *.service) :;;
  *) UNIT="${UNIT}.service";;
esac

# prepare logging
TS=$(date +%Y%m%dT%H%M%S)
LOGDIR="/var/log"
LOGFILE="${LOGDIR}/remove-service-${SERVICE}-${TS}.log"
if ! touch "$LOGFILE" 2>/dev/null; then
  LOGDIR="/tmp"
  LOGFILE="${LOGDIR}/remove-service-${SERVICE}-${TS}.log"
fi
# tee all output to log
exec > >(tee -a "$LOGFILE") 2>&1

info() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*"; }
err()  { echo -e "[ERROR] $*"; }

if [ "$VERBOSE" -eq 1 ]; then
  info "日志: $LOGFILE"
fi

# helpers
confirm() {
  if [ "$YES" -eq 1 ]; then
    return 0
  fi
  echo -n "$1 [y/N]: "
  read -r ans
  case "$ans" in
    y|Y|yes|Yes) return 0;;
    *) return 1;;
  esac
}

plan_action() {
  echo "---- 计划 (dry-run=$DRY_RUN) ----"
  echo "服务 unit: $UNIT"
  echo "默认备份目录: $BACKUP_BASE"
  echo "remove-files: $REMOVE_FILES , remove-timers: $REMOVE_TIMERS , force: $FORCE"
  echo "-------------------------------"
}

# gather info
FRAGMENT_PATH=$(systemctl show -p FragmentPath --value "$UNIT" 2>/dev/null || true)
IS_ACTIVE=0
if systemctl is-active --quiet "$UNIT" 2>/dev/null; then IS_ACTIVE=1; fi
IS_ENABLED=0
if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then IS_ENABLED=1; fi

info "检查 unit..."
if [ -n "$FRAGMENT_PATH" ]; then
  info "找到 unit 文件: $FRAGMENT_PATH"
else
  warn "systemd 未报告 FragmentPath（unit 可能不存在或是 transient）"
fi

# detect vendor-managed (conservative)
VENDOR_MANAGED=0
if [[ "$FRAGMENT_PATH" == /lib/* ]] || [[ "$FRAGMENT_PATH" == /usr/lib/* ]] || [[ "$FRAGMENT_PATH" == /usr/lib64/* ]]; then
  VENDOR_MANAGED=1
  warn "检测到 unit 似乎位于发行版目录（$FRAGMENT_PATH），可能由包管理器维护。建议优先使用包管理器卸载服务。"
fi

# plan
plan_action

if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry-run 模式，退出（不做任何改动）"
  exit 0
fi

if [ "$VENDOR_MANAGED" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  warn "此 unit 可能由系统包管理（/lib 或 /usr/lib）。继续可能在下次包升级时被还原。"
  if ! confirm "仍要继续？（建议先用包管理器移除）"; then
    info "已取消。若你确实要强制删除，请使用 --force"
    exit 0
  fi
fi

# create backup dir
BACKUP_DIR="${BACKUP_BASE%/}/${SERVICE}-${TS}"
mkdir -p "$BACKUP_DIR"
info "备份目录: $BACKUP_DIR"

# stop & disable
if [ "$IS_ACTIVE" -eq 1 ]; then
  info "停止服务: systemctl stop $UNIT"
  systemctl stop "$UNIT" || warn "停止服务时出错（可忽略）"
else
  info "服务当前未运行"
fi

if [ "$IS_ENABLED" -eq 1 ]; then
  info "禁用并取消开机启动: systemctl disable $UNIT --now"
  systemctl disable "$UNIT" --now || warn "disable 返回非0（可忽略）"
else
  info "服务已非启用状态"
fi

# mask to prevent restarts during op
info "临时 mask 服务以防被重启"
systemctl mask "$UNIT" || warn "mask 失败（可忽略）"

# handle timer with same base name
BASENAME="${UNIT%.service}"
TIMER_UNIT="${BASENAME}.timer"
if [ "$REMOVE_TIMERS" -eq 1 ]; then
  if systemctl list-unit-files | grep -q "^${TIMER_UNIT}"; then
    info "检测到 timer 单元: $TIMER_UNIT -> 停止、禁用并备份"
    systemctl stop "$TIMER_UNIT" 2>/dev/null || true
    systemctl disable "$TIMER_UNIT" 2>/dev/null || true
    TIMER_PATH=$(systemctl show -p FragmentPath --value "$TIMER_UNIT" 2>/dev/null || true)
    if [ -n "$TIMER_PATH" ] && [ -f "$TIMER_PATH" ]; then
      info "备份 timer 文件到 $BACKUP_DIR"
      mv -v "$TIMER_PATH" "$BACKUP_DIR/" || warn "无法移动 $TIMER_PATH"
    fi
  else
    info "未检测到 ${TIMER_UNIT}"
  fi
fi

# backup and remove unit file(s)
move_unit_file() {
  local path="$1"
  if [ -z "$path" ]; then return 0; fi
  if [ -f "$path" ]; then
    info "备份 unit 文件: $path -> $BACKUP_DIR/"
    mv -v "$path" "$BACKUP_DIR/" || warn "无法移动 $path（可能权限/已被删除）"
  fi
}

# preferred: use FragmentPath if present, else search common locations
if [ -n "$FRAGMENT_PATH" ] && [ -f "$FRAGMENT_PATH" ]; then
  move_unit_file "$FRAGMENT_PATH"
else
  # search common places
  for p in "/etc/systemd/system/$UNIT" "/run/systemd/system/$UNIT" "/lib/systemd/system/$UNIT" "/usr/lib/systemd/system/$UNIT"; do
    if [ -f "$p" ]; then
      move_unit_file "$p"
    fi
  done
fi

# drop-in dir
DROPIN_DIR="/etc/systemd/system/${UNIT}.d"
if [ -d "$DROPIN_DIR" ]; then
  info "备份 drop-in 目录: $DROPIN_DIR -> $BACKUP_DIR/"
  mv -v "$DROPIN_DIR" "$BACKUP_DIR/" || warn "无法移动 $DROPIN_DIR"
fi

# try to remove symlinks in multi-user.target.wants
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"
if [ -L "${WANTS_DIR}/${UNIT}" ]; then
  info "删除 multi-user.target.wants 的 symlink: ${WANTS_DIR}/${UNIT}"
  mv -v "${WANTS_DIR}/${UNIT}" "$BACKUP_DIR/" || warn "无法移动 symlink"
fi

# attempt to identify ExecStart executable (very conservative)
EXEC_RAW=$(systemctl show -p ExecStart --value "$UNIT" 2>/dev/null || true)
if [ -n "$EXEC_RAW" ]; then
  # extract something that looks like an absolute path
  EXEC_PATH=$(echo "$EXEC_RAW" | grep -oE '(/[[:alnum:]_./\-\+]+)' | head -n1 || true)
  if [ -n "$EXEC_PATH" ]; then
    info "检测到 ExecStart 可执行文件: $EXEC_PATH"
    if [ "$REMOVE_FILES" -eq 1 ]; then
      if [ -f "$EXEC_PATH" ]; then
        if [ "$FORCE" -eq 0 ]; then
          if ! confirm "将备份并移除可执行文件 $EXEC_PATH？（非常谨慎）"; then
            warn "跳过可执行文件删除"
            REMOVE_FILES=0
          fi
        fi
        if [ "$REMOVE_FILES" -eq 1 ]; then
          info "备份并移除可执行: $EXEC_PATH -> $BACKUP_DIR/"
          mv -v "$EXEC_PATH" "$BACKUP_DIR/" || warn "无法移动 $EXEC_PATH"
        fi
      else
        warn "ExecStart 指向的文件不存在：$EXEC_PATH"
      fi
    fi
  else
    info "无法从 ExecStart 中解析出可执行路径（内容: $EXEC_RAW）"
  fi
else
  info "unit 未报告 ExecStart"
fi

# final systemd reload + reset
info "重新加载 systemd 守护进程并重置状态"
systemctl daemon-reload || warn "daemon-reload 失败"
systemctl reset-failed || true

# unmask （如果你真正要删除/备份完毕可以保留 mask；我们这里解除 mask）
info "解除 mask（如果之前 mask 成功）"
systemctl unmask "$UNIT" 2>/dev/null || true

# final checks
info "最终检查："
if systemctl list-unit-files | grep -q "^${UNIT}"; then
  warn "仍检测到 unit 文件条目（可能已移除但仍残留），请检查： systemctl status $UNIT"
else
  info "systemctl 中未检测到 unit 条目，或已被移除（请用 systemctl status 确认）"
fi

info "完成。已将备份/删除的文件移至： $BACKUP_DIR"
info "日志路径: $LOGFILE"
info "提示：若该服务是通过发行版包安装的，建议使用包管理器卸载（apt, yum, dnf, pacman 等），否则包更新/重装可能会恢复 unit 文件。"

exit 0

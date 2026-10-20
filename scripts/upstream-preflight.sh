#!/usr/bin/env bash
# 上游一致性校验：在构建前断言"我们依赖的上游事实"仍然成立。
# 任何一项 FAIL 都意味着构建可能"成功但功能静默失效"。
#
# 用法：
#   bash scripts/upstream-preflight.sh                        # 用 config/upstream.env 的默认组合
#   bash scripts/upstream-preflight.sh --android android15 --kernel 6.6
#   bash scripts/upstream-preflight.sh --print-pins           # 打印当前上游 pin 值（升级用）
#   bash scripts/upstream-preflight.sh --soft                 # FAIL 不改变退出码（仅提示）
#
# 退出码：0 通过（可能有 WARN）；1 存在 FAIL。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT/config/upstream.env"
ANDROID_OVERRIDE=""
KERNEL_OVERRIDE=""
SOFT=0
PRINT_PINS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --android) ANDROID_OVERRIDE="$2"; shift 2 ;;
    --kernel)  KERNEL_OVERRIDE="$2"; shift 2 ;;
    --soft)    SOFT=1; shift ;;
    --print-pins) PRINT_PINS=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
else
  echo "[FAIL] 缺少 $CONFIG_FILE" >&2
  exit 1
fi

ANDROID="${ANDROID_OVERRIDE:-${PREFLIGHT_ANDROID:-android16}}"
KERNEL="${KERNEL_OVERRIDE:-${PREFLIGHT_KERNEL:-6.12}}"
# 显式指定 android/kernel 时，分支名必须跟着推导，否则会和补丁名对不上
if [ -n "$ANDROID_OVERRIDE" ] || [ -n "$KERNEL_OVERRIDE" ]; then
  SUSFS_REF="gki-${ANDROID}-${KERNEL}"
else
  SUSFS_REF="${SUSFS_REF:-gki-${ANDROID}-${KERNEL}}"
fi

PASS=0; WARN=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t preflight)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# Git Bash 的 sha256sum 会给含反斜杠的文件名行首加 '\'，统一剥掉
sha_of() { sha256sum "$1" | sed 's/^\\//' | awk '{print $1}'; }

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ---------- 1. KSU 分支 / pin ----------
say "SukiSU 分支与 pin"
KSU_TIP="$(git ls-remote --heads "$KSU_REPO" "$KSU_REF" 2>/dev/null | awk '{print $1}' | head -n1)"
if [ -z "$KSU_TIP" ]; then
  fail "分支 '$KSU_REF' 在上游不存在——workflow 里的 checkout 会静默退回默认分支，SUSFS 集成随之消失"
  KSU_SHA=""
else
  pass "分支 '$KSU_REF' 存在：$KSU_TIP"
  if [ -z "${KSU_PIN:-}" ]; then
    KSU_SHA="$KSU_TIP"
    warn "未固定版本（KSU_PIN 为空），每次构建都会跟随上游 HEAD，行为不可复现"
  else
    KSU_SHA="$KSU_PIN"
    if [ "$KSU_PIN" = "$KSU_TIP" ]; then
      pass "KSU_PIN 与上游 HEAD 一致"
    else
      warn "上游已前进：pin=${KSU_PIN:0:12} 远端=${KSU_TIP:0:12}（未升级，属预期；需要时按 README 流程升级）"
    fi
    if ! git ls-remote "$KSU_REPO" 2>/dev/null | grep -q "^$KSU_PIN"; then
      warn "KSU_PIN 不是上游任何分支的 tip，无法在此确认其仍可检出"
    fi
  fi
fi

if [ "$PRINT_PINS" = "1" ]; then
  say "当前可写入 config/upstream.env 的值"
  echo "KSU_REF=\"$KSU_REF\""
  echo "KSU_PIN=\"$KSU_TIP\""
  SUSFS_COMMIT="$(git ls-remote --heads "$SUSFS_REPO" "$SUSFS_REF" 2>/dev/null | awk '{print $1}' | head -n1)"
  echo "SUSFS_REF=\"$SUSFS_REF\""
  echo "SUSFS_PIN=\"$SUSFS_COMMIT\""
  curl -fsSL "$PATCH_LINUX_URL" -o "$TMP/patch_linux" 2>/dev/null \
    && echo "PATCH_LINUX_SHA256=\"$(sha_of "$TMP/patch_linux")\"" \
    || echo "PATCH_LINUX_SHA256=\"<下载失败>\""
  exit 0
fi

# ---------- 2. Kconfig 符号 ----------
say "上游 Kconfig 符号（$KSU_REF@${KSU_SHA:0:12}）"
KCONFIG_SYMS=""
if [ -n "$KSU_SHA" ]; then
  RAW_BASE="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra"
  if curl -fsSL "$RAW_BASE/$KSU_SHA/kernel/Kconfig" -o "$TMP/Kconfig" 2>/dev/null; then
    KCONFIG_SYMS="$(grep -E '^[[:space:]]*config[[:space:]]+' "$TMP/Kconfig" | awk '{print $2}' | sort -u)"
    echo "发现 $(echo "$KCONFIG_SYMS" | grep -c . ) 个配置项"
  else
    fail "无法获取上游 kernel/Kconfig，后续符号校验跳过"
  fi
fi

REQUIRED="KSU KPM KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP"

if [ -n "$KCONFIG_SYMS" ]; then
  MISSING_REQ=""
  for s in $REQUIRED; do
    echo "$KCONFIG_SYMS" | grep -qx "$s" || MISSING_REQ="$MISSING_REQ $s"
  done
  if [ -z "$MISSING_REQ" ]; then
    pass "内核侧必需符号齐全（KSU / KPM / SUSFS 全套）"
  else
    fail "上游缺少必需符号:$MISSING_REQ"
  fi

  # 工作流里实际写入、但上游 Kconfig 已经不存在 = 死配置（功能静默失效）
  WF_SYMS="$(grep -rhoE 'CONFIG_KSU[A-Z0-9_]*' "$ROOT"/.github/workflows/*.yml 2>/dev/null \
    | sed 's/^CONFIG_//' | grep -v '_$' | sort -u)"
  if [ -n "$WF_SYMS" ]; then
    DEAD=""
    for s in $WF_SYMS; do
      echo "$KCONFIG_SYMS" | grep -qx "$s" || DEAD="$DEAD CONFIG_$s"
    done
    if [ -z "$DEAD" ]; then
      pass "workflow 写入的 CONFIG_KSU* 全部存在于上游 Kconfig"
    else
      fail "workflow 写入了上游已不存在的配置项（不会生效）:$DEAD"
    fi
  fi
fi

# ---------- 3. SUSFS 分支 / 补丁 ----------
say "SUSFS 补丁（$SUSFS_REF）"
SUSFS_COMMIT="$(git ls-remote --heads "$SUSFS_REPO" "$SUSFS_REF" 2>/dev/null | awk '{print $1}' | head -n1)"
if [ -z "$SUSFS_COMMIT" ]; then
  fail "susfs 分支 '$SUSFS_REF' 不存在，git clone 会直接失败"
  AVAI="$(git ls-remote --heads "$SUSFS_REPO" 2>/dev/null | sed 's#.*refs/heads/##' | grep '^gki-' | sort | tr '\n' ' ')"
  echo "       可用分支: $AVAI"
else
  pass "susfs 分支存在：$SUSFS_COMMIT"
  [ -n "${SUSFS_PIN:-}" ] && [ "${SUSFS_PIN}" != "$SUSFS_COMMIT" ] \
    && warn "SUSFS 分支已前进：pin=${SUSFS_PIN:0:12} 远端=${SUSFS_COMMIT:0:12}"
fi

EFFECTIVE_SUSFS_REF="${SUSFS_PIN:-$SUSFS_REF}"
PATCH_NAME="50_add_susfs_in_gki-${ANDROID}-${KERNEL}.patch"
PATCH_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/${EFFECTIVE_SUSFS_REF}/kernel_patches/${PATCH_NAME}"
if curl -fsSL "$PATCH_URL" -o "$TMP/susfs.patch" 2>/dev/null; then
  pass "补丁可获取：$PATCH_NAME（$(wc -l < "$TMP/susfs.patch") 行）"

  # ---------- 4. 补丁 -> KSU 源码耦合 ----------
  say "补丁与 KSU 源码的耦合符号"
  KSU_SYMS="$(grep -oE '\b(__)?ksu_[a-z0-9_]+' "$TMP/susfs.patch" | sort -u)"
  if [ -z "$KSU_SYMS" ]; then
    warn "补丁中未发现 ksu_* 符号，跳过耦合校验"
  elif [ -z "$KSU_SHA" ]; then
    warn "无法解析 KSU 源码，跳过耦合校验"
  else
    if git clone --quiet --filter=blob:none --no-checkout --depth=1 --branch "$KSU_REF" "$KSU_REPO" "$TMP/ksu" 2>/dev/null; then
      (
        cd "$TMP/ksu" || exit 1
        git sparse-checkout init --cone >/dev/null 2>&1
        git sparse-checkout set kernel >/dev/null 2>&1
        if [ "${KSU_SHA}" != "${KSU_TIP:-}" ]; then
          git fetch --quiet --depth=1 origin "$KSU_SHA" >/dev/null 2>&1 && git checkout --quiet FETCH_HEAD >/dev/null 2>&1
        else
          git checkout --quiet >/dev/null 2>&1
        fi
      )
      BROKEN=""
      for s in $KSU_SYMS; do
        grep -rqE "\\b${s}\\b" "$TMP/ksu/kernel" 2>/dev/null || BROKEN="$BROKEN $s"
      done
      if [ -z "$BROKEN" ]; then
        pass "补丁引用的 $(echo "$KSU_SYMS" | grep -c .) 个 KSU 符号在源码中均存在"
      else
        fail "补丁依赖的符号在 KSU 源码中不存在（SUSFS 功能会静默失效）:$BROKEN"
      fi
    else
      warn "KSU 源码检出失败，跳过耦合校验"
    fi
  fi
else
  fail "补丁不存在：$PATCH_NAME（该 android/kernel 组合没有对应补丁）"
  echo "       可用组合: android12-5.10 / android13-5.10 / android13-5.15 / android14-5.15 / android14-6.1 / android15-6.6 / android16-6.12"
fi

# ---------- 5. patch_linux 完整性 ----------
say "KPM 补丁工具"
if curl -fsSL "$PATCH_LINUX_URL" -o "$TMP/patch_linux" 2>/dev/null; then
  ACTUAL="$(sha_of "$TMP/patch_linux")"
  if [ -z "${PATCH_LINUX_SHA256:-}" ]; then
    warn "未记录期望哈希，请把 PATCH_LINUX_SHA256=\"$ACTUAL\" 写入 config/upstream.env"
  elif [ "$ACTUAL" = "$PATCH_LINUX_SHA256" ]; then
    pass "patch_linux 哈希匹配（$ACTUAL）"
  else
    fail "patch_linux 内容已变化！期望 ${PATCH_LINUX_SHA256:0:12} 实际 ${ACTUAL:0:12}（供应链风险，确认来源后再更新）"
  fi
else
  fail "patch_linux 下载失败：$PATCH_LINUX_URL"
fi

# ---------- 汇总 ----------
printf '\n\033[1m== 结果：%d PASS / %d WARN / %d FAIL ==\033[0m\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  if [ "$SOFT" = "1" ]; then
    echo "存在 FAIL，但已指定 --soft，退出码视为 0"
    exit 0
  fi
  echo "存在 FAIL：构建可能产出缺少 root 或 SUSFS 的内核而不报错，请先修复。"
  exit 1
fi
echo "上游依赖与 workflow 一致。"

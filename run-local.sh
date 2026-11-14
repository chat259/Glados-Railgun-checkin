#!/usr/bin/env bash
# ============================================================================
# GLaDOS 自动签到 - Linux 服务器一键运行脚本 (run-local.sh)
#
# 功能: 检查 Python -> 安装依赖 -> 加载/创建 .env -> 执行 checkin.py
#
# 用法:
#   ./run-local.sh                       # 完整流程
#   ./run-local.sh --skip-deps          # 跳过依赖安装 (已装过可加速)
#   ./run-local.sh --env-file /path/.env
#   GLADOS_ENV_FILE=/path/.env SKIP_DEPS=1 ./run-local.sh
#
# 说明:
#   - .env 已被 .gitignore 忽略, cookie 不会泄露到 Git
#   - 非交互环境 (如 cron) 下不会提示粘贴 cookie, 请提前编辑 .env
#   - cron 示例:
#       30 8 * * * cd /opt/glados && /usr/bin/env bash ./run-local.sh --skip-deps >> /var/log/glados.log 2>&1
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKIN_PY="$SCRIPT_DIR/checkin.py"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

# ---------- 参数解析 ----------
ENV_FILE=""
SKIP_DEPS="${SKIP_DEPS:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-deps)
            SKIP_DEPS=1
            shift
            ;;
        --env-file)
            if [ $# -lt 2 ]; then
                echo "错误: --env-file 需要一个路径参数" >&2
                exit 1
            fi
            ENV_FILE="$2"
            shift 2
            ;;
        --env-file=*)
            ENV_FILE="${1#--env-file=}"
            shift
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $1 (可用: --skip-deps / --env-file <path>)" >&2
            exit 1
            ;;
    esac
done

# 环境变量 GLADOS_ENV_FILE 优先级低于命令行参数
if [ -z "$ENV_FILE" ]; then
    ENV_FILE="${GLADOS_ENV_FILE:-$SCRIPT_DIR/.env}"
fi
case "$ENV_FILE" in
    /*) ;;                      # 已是绝对路径
    *)  ENV_FILE="$PWD/$ENV_FILE" ;;
esac

# ---------- 输出辅助 ----------
if [ -t 1 ]; then
    C_STEP="\033[36m"; C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_DIM="\033[90m"; C_RESET="\033[0m"
else
    C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RESET=""
fi

write_step()  { printf "${C_STEP}▶ %s${C_RESET}\n" "$1"; }
write_ok()    { printf "${C_OK}✔ %s${C_RESET}\n" "$1"; }
write_warn()  { printf "${C_WARN}⚠ %s${C_RESET}\n" "$1"; }
write_err()   { printf "${C_ERR}❌ %s${C_RESET}\n" "$1"; }

show_banner() {
    echo ""
    printf "${C_DIM}========================================${C_RESET}\n"
    printf "      GLaDOS 自动签到 - Linux 一键运行      \n"
    printf "${C_DIM}========================================${C_RESET}\n"
    echo ""
}

# ---------- 1. 检查 Python ----------
PYTHON_CMD=""

find_python() {
    write_step "步骤 1/4: 检查 Python 环境"
    local c
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1; then
            # import 自检 + 版本检查 (需 3.9+)
            if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
                local ver
                ver=$("$c" --version 2>&1 | head -n 1)
                write_ok "找到 Python: $ver (命令: $c)"
                PYTHON_CMD="$c"
                return 0
            fi
        fi
    done
    write_warn "未找到可用的 Python 3.9+。"
    echo "    Debian/Ubuntu: sudo apt install python3 python3-pip"
    echo "    CentOS/RHEL:   sudo yum install python3 python3-pip"
    echo "    或手动安装:    https://www.python.org/downloads/"
    return 1
}

# ---------- 2. 安装依赖 ----------
install_deps() {
    if [ "$SKIP_DEPS" = "1" ]; then
        write_warn "已跳过依赖安装 (--skip-deps)"
        return 0
    fi
    write_step "步骤 2/4: 安装 Python 依赖 (requests / pypushdeer / serverchan-sdk)"
    if ! "$PYTHON_CMD" -m pip install --quiet --disable-pip-version-check requests pypushdeer serverchan-sdk; then
        write_warn "pip 安装失败, 尝试升级 pip 后重试..."
        "$PYTHON_CMD" -m pip install --quiet --disable-pip-version-check --upgrade pip
        if ! "$PYTHON_CMD" -m pip install --quiet --disable-pip-version-check requests pypushdeer serverchan-sdk; then
            write_err "依赖安装失败。请检查网络, 或手动执行: $PYTHON_CMD -m pip install requests pypushdeer serverchan-sdk"
            return 1
        fi
    fi
    write_ok "依赖安装完成"
}

# ---------- 3. 加载 / 创建 .env ----------
# 解析 .env: 支持 KEY=VALUE; GLADOS_COOKIES 允许其后若干续行 (每行一个 cookie)
declare -A ENV_VARS=()

read_env_file() {
    ENV_VARS=()
    [ -f "$ENV_FILE" ] || return 0
    local in_cookies=0 raw line key val
    local cookie_lines=()
    while IFS= read -r raw || [ -n "$raw" ]; do
        line="${raw#"${raw%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]*}"}"
        if [ -z "$line" ] || [ "${line:0:1}" = "#" ]; then
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [ "$key" = "GLADOS_COOKIES" ]; then
                in_cookies=1
                cookie_lines=()
                [ -n "$val" ] && cookie_lines+=("$val")
            else
                in_cookies=0
                ENV_VARS["$key"]="$val"
            fi
        elif [ "$in_cookies" -eq 1 ]; then
            # 无 KEY= 前缀的行: 视为 GLADOS_COOKIES 的续行
            cookie_lines+=("$line")
        fi
    done < "$ENV_FILE"
    if [ "${#cookie_lines[@]}" -gt 0 ]; then
        local first="${cookie_lines[0]}"
        first="${first#"${first%%[![:space:]]*}"}"
        local nl=$'\n' out=""
        if [ "${first:0:1}" = "[" ] || [ "${first:0:1}" = "{" ]; then
            # JSON: 用换行拼接 (各行缩进会被去掉, json.loads 不依赖缩进)
            for line in "${cookie_lines[@]}"; do
                out="${out:+$out$nl}$line"
            done
        else
            # 旧 & 分隔格式: 每行一个 cookie
            for line in "${cookie_lines[@]}"; do
                out="${out:+$out&}$line"
            done
        fi
        ENV_VARS["GLADOS_COOKIES"]="$out"
    fi
}


save_env_file() {
    local order=("GLADOS_COOKIES" "GLADOS_EXCHANGE_PLAN" "PUSHDEER_SENDKEY" "SERVERCHAN_SENDKEY" "GLADOS_VERBOSE")
    local k v part pretty
    {
        echo "# GLaDOS 本地配置 (由 run-local.sh 生成, 已被 .gitignore 忽略, 请勿提交)"
        echo "# 修改后保存即可, 再次运行 ./run-local.sh 自动生效"
        echo "# GLADOS_COOKIES 支持 JSON 数组 (可多行缩进); 旧 & 分隔格式仍兼容"
        echo ""
        for k in "${order[@]}"; do
            v="${ENV_VARS[$k]:-}"
            if [ "$k" = "GLADOS_COOKIES" ] && [ -n "$v" ] && { [ "${v:0:1}" = "[" ] || [ "${v:0:1}" = "{" ]; }; then
                # JSON: 用 python 美化为多行缩进; 失败则原样单行
                pretty=$(printf '%s' "$v" | "$PYTHON_CMD" -m json.tool 2>/dev/null)
                if [ -n "$pretty" ]; then
                    printf 'GLADOS_COOKIES=%s\n' "$(printf '%s' "$pretty" | head -n1)"
                    printf '%s\n' "$pretty" | tail -n +2
                else
                    echo "GLADOS_COOKIES=$v"
                fi
            elif [ "$k" = "GLADOS_COOKIES" ] && [ -n "$v" ]; then
                # 旧 & 分隔格式: 每行一个 cookie
                echo "GLADOS_COOKIES="
                local old_ifs="$IFS"
                IFS='&'
                for part in $v; do
                    [ -n "$part" ] && echo "$part"
                done
                IFS="$old_ifs"
            else
                echo "$k=$v"
            fi
            echo ""
        done
    } > "$ENV_FILE"
    write_ok "已生成本地配置: $ENV_FILE"
}

load_or_create_env() {
    write_step "步骤 3/4: 加载本地配置 (.env)"
    local have_cookies=0
    read_env_file

    if [ -f "$ENV_FILE" ]; then
        if [ -n "${ENV_VARS[GLADOS_COOKIES]:-}" ]; then
            have_cookies=1
            write_ok "已从 $ENV_FILE 读取配置"
        else
            write_warn "$ENV_FILE 缺少 GLADOS_COOKIES, 需要补充"
        fi
    fi

    if [ "$have_cookies" -eq 0 ]; then
        if [ -t 0 ]; then
            # 交互模式: 提示粘贴 cookie
            echo ""
            printf "${C_WARN}首次运行: 请在下方粘贴 GLADOS_COOKIES。${C_RESET}\n"
            printf "${C_WARN}获取方式: GLaDOS 签到页面 F12 -> Network -> 刷新 ->${C_RESET}\n"
            printf "${C_WARN}         点第一个请求 -> Request Headers -> 复制 Cookie 的值。${C_RESET}\n"
            printf "${C_WARN}(推荐 JSON 数组, 单行; 旧 & 分隔格式仍兼容。也可直接留空, 稍后手动编辑 .env)${C_RESET}\n"
            echo ""

            local input ex pk sc verb
            read -r -p "粘贴 GLADOS_COOKIES (留空跳过): " input
            input="${input#"${input%%[![:space:]]*}"}"
            input="${input%"${input##*[![:space:]]}"}"
            if [ -n "$input" ]; then
                ENV_VARS["GLADOS_COOKIES"]="$input"
                have_cookies=1

                read -r -p "GLADOS_EXCHANGE_PLAN (plan100/plan200/plan500, 留空=不兑换): " ex
                [ -n "${ex:-}" ] && ENV_VARS["GLADOS_EXCHANGE_PLAN"]="$ex"

                read -r -p "PUSHDEER_SENDKEY (留空=不推送): " pk
                [ -n "${pk:-}" ] && ENV_VARS["PUSHDEER_SENDKEY"]="$pk"

                read -r -p "SERVERCHAN_SENDKEY (留空=不推送): " sc
                [ -n "${sc:-}" ] && ENV_VARS["SERVERCHAN_SENDKEY"]="$sc"

                read -r -p "GLADOS_VERBOSE (true/false, 直接回车默认 false): " verb
                [ -n "${verb:-}" ] && ENV_VARS["GLADOS_VERBOSE"]="$verb"
            fi
            save_env_file
        else
            # 非交互 (cron / CI 等): 无法粘贴 cookie
            write_warn "非交互环境, 无法粘贴 cookie。请手动编辑: $ENV_FILE"
            if [ -f "$ENV_EXAMPLE" ]; then
                echo "    参考模板: $ENV_EXAMPLE"
                echo "    快速生成: cp \"$ENV_EXAMPLE\" \"$ENV_FILE\" && vi \"$ENV_FILE\""
            fi
        fi
    fi

    # 把 .env 中的值导入当前进程环境变量 (仅设置非空值)
    local k
    for k in "${!ENV_VARS[@]}"; do
        if [ -n "${ENV_VARS[$k]}" ]; then
            export "$k=${ENV_VARS[$k]}"
        fi
    done

    if [ "$have_cookies" -eq 0 ]; then
        write_warn "未提供 GLADOS_COOKIES, 签到将不会执行。请编辑 $ENV_FILE 填入后重新运行。"
    fi
}

# ---------- 4. 执行签到 ----------
run_checkin() {
    write_step "步骤 4/4: 执行签到 (checkin.py)"
    echo ""
    "$PYTHON_CMD" "$CHECKIN_PY"
    local code=$?
    echo ""
    if [ "$code" -eq 0 ]; then
        write_ok "签到流程执行完成, 请查看上方日志确认结果。"
    else
        write_warn "checkin.py 退出码 $code, 请查看上方日志定位问题。"
    fi
}

# ---------- 主流程 ----------
show_banner

if [ ! -f "$CHECKIN_PY" ]; then
    write_err "未找到 $CHECKIN_PY, 请在项目根目录运行本脚本。"
    exit 1
fi

find_python || exit 1
install_deps || exit 1
load_or_create_env
run_checkin
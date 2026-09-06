#!/bin/bash
# Keep the entry in a function so an incomplete pipeline download cannot run it.
gemini_main() (
    set -eu
    umask 077

    country=us
    user_data_dir="${HOME}/Library/Application Support/Google/Chrome"
    uninstall=false
    what_if=false
    workspace=''
    temporary=''
    manifest_temporary=''
    cyan='' green='' yellow='' red='' reset=''
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
        cyan=$'\033[36m' green=$'\033[32m' yellow=$'\033[33m' red=$'\033[31m' reset=$'\033[0m'
    fi

    status() { printf '%s%s%s\n' "$1" "$2" "$reset"; }
    fail() { status "$red" "[失败] $*" >&2; exit 1; }
    cleanup() {
        if [ -n "$temporary" ]; then rm -f -- "$temporary"; fi
        if [ -n "$manifest_temporary" ]; then rm -f -- "$manifest_temporary"; fi
        if [ -n "$workspace" ]; then
            rm -f -- "$workspace/configure-macos.js"
            rmdir -- "$workspace"
        fi
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --country|--user-data-dir)
                option=$1
                [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$option 需要提供参数值。"
                if [ "$option" = --country ]; then country=$2; else user_data_dir=$2; fi
                shift 2 ;;
            --uninstall) uninstall=true; shift ;;
            --what-if) what_if=true; shift ;;
            --help|-h)
                printf '%s\n' 'Gemini in Chrome：macOS 持久化设置' \
                    '用法：bash install.sh [参数]' \
                    '  --country us          永久实验地区，默认 us' \
                    '  --user-data-dir PATH  包含 Local State 的 Chrome 数据目录' \
                    '  --what-if             仅预览，不修改配置或建立备份' \
                    '  --uninstall           按首次备份恢复修改字段' \
                    '  --help                显示此帮助'
                exit 0 ;;
            *) fail "未知参数：$1。请运行 bash install.sh --help 查看用法。" ;;
        esac
    done

    status "$cyan" '[检查] 正在识别系统和 Chrome 配置。'
    case "$(uname -s)" in
        Darwin) status "$cyan" "[检查] 已识别 macOS（$(uname -m)），使用 Mac 配置实现。" ;;
        MINGW*|MSYS*|CYGWIN*) fail '当前为 Windows，请在 PowerShell 中运行本仓库的 install.ps1 安装命令。' ;;
        *) fail '此入口支持 macOS；Windows 请使用 PowerShell 安装命令，其他系统暂不支持。' ;;
    esac
    [ "$(id -u)" -ne 0 ] || fail '请以当前登录用户运行，不要使用 sudo，以免修改错误的 Chrome 配置。'
    case "$country" in
        [a-zA-Z][a-zA-Z]) country=$(printf '%s' "$country" | tr '[:upper:]' '[:lower:]') ;;
        *) fail '地区代码必须是两个英文字母，例如 us。' ;;
    esac

    state_path="$user_data_dir/Local State"
    backup_dir="$user_data_dir/GeminiInChromeBackup"
    manifest_path="$backup_dir/restore.json"
    if $uninstall && [ ! -e "$manifest_path" ]; then
        if $what_if; then
            status "$cyan" '[预览] 没有本脚本的恢复记录，无需修改配置。'
        else
            status "$green" '[完成] 未发现本脚本的持久化回退记录，Chrome 配置未修改。'
        fi
        exit 0
    fi
    [ -f "$state_path" ] || fail "未找到 Chrome 配置：$state_path。请先运行一次 Chrome，或用 --user-data-dir 指定数据目录。"
    [ ! -L "$state_path" ] || fail 'Local State 是符号链接，请使用原始配置文件所在的数据目录。'
    user_data_dir=$(cd -- "$user_data_dir" && pwd -P)
    state_path="$user_data_dir/Local State"
    backup_dir="$user_data_dir/GeminiInChromeBackup"
    manifest_path="$backup_dir/restore.json"
    if $what_if; then
        if $uninstall; then action='按首次备份恢复地区和 Gemini 开关'; else action="设置永久地区 $country 并启用 Gemini 开关"; fi
        status "$cyan" "[预览] 将$action：$state_path"
        status "$cyan" '[预览] 未修改配置、未建立备份，无需关闭 Chrome。'
        exit 0
    fi

    chrome_running() {
        if pgrep -u "$(id -u)" -f '/Contents/MacOS/Google Chrome([[:space:]]|$)' >/dev/null; then
            return 0
        else
            result=$?
            [ "$result" -eq 1 ] || fail '无法检查 Chrome 进程，请检查系统权限后重试。'
            return 1
        fi
    }
    if chrome_running; then
        status "$yellow" '[等待] 请保存工作，用“退出 Google Chrome”或 Command+Q 完全退出 Chrome，仅关闭窗口不够。'
        status "$yellow" '[等待] 关闭后按回车继续；脚本不会强制关闭浏览器。'
        if ! { IFS= read -r reply </dev/tty; } 2>/dev/null; then
            fail '当前无法读取交互终端。请完全退出 Chrome 后重新运行安装命令。'
        fi
        if chrome_running; then fail '仍检测到 Chrome 运行，尚未修改配置。请完全退出后重新运行。'; fi
    fi

    workspace=$(mktemp -d "${TMPDIR:-/tmp}/gemini-installer.XXXXXXXX") || fail '无法创建临时目录，请检查磁盘空间和权限。'
    entry_path=${BASH_SOURCE[0]:-}
    if [ -n "$entry_path" ] && [ -f "$entry_path" ]; then
        entry_dir=$(cd -- "$(dirname -- "$entry_path")" && pwd -P)
        implementation="$entry_dir/src/configure-macos.js"
        [ -f "$implementation" ] || fail '缺少 src/configure-macos.js。请下载完整仓库，或使用在线安装命令。'
    else
        implementation="$workspace/configure-macos.js"
        status "$cyan" '[下载] 正在获取本仓库的 Mac 配置实现。'
        if ! curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 \
            'https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/src/configure-macos.js' -o "$implementation"; then
            fail '下载失败，Chrome 配置未修改。请检查网络能否访问 raw.githubusercontent.com 后重试。'
        fi
        [ -s "$implementation" ] || fail '下载内容为空，Chrome 配置未修改。请稍后重试。'
    fi
    json() { osascript -l JavaScript "$implementation" "$@"; }
    file_hash() {
        local digest
        digest=$(shasum -a 256 < "$1") || fail "无法校验文件：$1。请检查读取权限。"
        printf '%s\n' "${digest%% *}"
    }
    original_hash=$(file_hash "$state_path")
    json validate "$state_path" || fail 'Chrome 配置无法解析或字段格式不正确，请保留原文件并检查其完整性。'
    if [ -e "$manifest_path" ]; then
        [ -f "$manifest_path" ] || fail '回退记录不是文件，请保留 GeminiInChromeBackup 目录并检查。'
        manifest=$(json manifest-read "$manifest_path") || fail '回退记录损坏，请保留 GeminiInChromeBackup 目录。'
        backup_name=${manifest%%$'\n'*}
        backup_hash=${manifest#*$'\n'}
        backup_path="$backup_dir/$backup_name"
        [ -f "$backup_path" ] || fail '原始配置备份缺失，已停止操作。请保留回退记录。'
        actual_backup_hash=$(file_hash "$backup_path")
        [ "$actual_backup_hash" = "$(printf '%s' "$backup_hash" | tr '[:upper:]' '[:lower:]')" ] || fail '原始备份校验失败，已停止操作，未修改配置。'
        json validate "$backup_path" || fail '原始备份的配置格式不正确，未修改配置。'
        status "$cyan" '[备份] 原始备份已存在，将继续保留，不会被本次操作覆盖。'
    fi

    temporary=$(mktemp "$user_data_dir/.gemini-XXXXXXXX") || fail '无法创建配置临时文件，请检查数据目录的写入权限。'
    if $uninstall; then
        json uninstall "$state_path" "$backup_path" "$temporary" || fail '无法生成恢复配置，原文件未修改。'
    else
        json install "$state_path" "$temporary" "$country" || fail '无法生成新配置，原文件未修改。'
    fi
    json validate "$temporary" || fail '新配置校验失败，原文件未修改。'
    expected_hash=$(file_hash "$temporary")
    original_mode=$(stat -f '%Lp' "$state_path") || fail '无法读取原文件权限，原文件未修改。'
    chmod "$original_mode" "$temporary" || fail '无法保留原文件权限，原文件未修改。'

    if [ ! -e "$manifest_path" ]; then
        status "$cyan" '[备份] 保存本次安装前的原始配置。'
        mkdir -p -- "$backup_dir" || fail '无法创建备份目录，请检查目录权限和磁盘空间。'
        backup_name="Local State.$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]').bak"
        backup_path="$backup_dir/$backup_name"
        cp -p -- "$state_path" "$backup_path" || fail '无法保存原始备份，配置未写入。'
        [ "$(file_hash "$backup_path")" = "$original_hash" ] || fail '备份校验失败，配置未写入。请关闭 Chrome 后重试。'
        # Publish the manifest on the same filesystem without replacing a first backup.
        manifest_temporary=$(mktemp "$backup_dir/.restore-XXXXXXXX") || fail '无法创建回退记录临时文件，配置未写入。'
        json manifest-create "$manifest_temporary" "$backup_name" "$original_hash" || fail '无法生成回退记录，配置未写入。'
        if ! ln -- "$manifest_temporary" "$manifest_path"; then
            fail '无法保存首次回退记录，或另一个安装正在进行。配置未写入，请稍后重试。'
        fi
        rm -f -- "$manifest_temporary"
        manifest_temporary=''
    fi

    status "$cyan" '[应用] 正在写入并校验 Chrome 配置。'
    if chrome_running; then fail '写入前检测到 Chrome 又已启动。请完全退出后重新运行；原始备份已保留。'; fi
    [ "$(file_hash "$state_path")" = "$original_hash" ] || fail '配置在检查后发生变化，已停止覆盖。请关闭 Chrome 后重新运行。'
    mv -f -- "$temporary" "$state_path" || fail '无法替换配置文件，请检查目录权限和磁盘空间；原始备份已保留。'
    temporary=''
    [ "$(file_hash "$state_path")" = "$expected_hash" ] || fail '写入后校验失败，请保留备份并检查 Local State 文件。'
    json validate "$state_path" || fail '写入后配置无法解析，请保留备份并检查 Local State 文件。'
    if $uninstall; then
        archive="$backup_dir/restored-$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]').json"
        mv -- "$manifest_path" "$archive" || fail '配置已恢复，但回退记录未能归档，请保留备份并检查目录权限。'
        status "$green" '[完成] 已还原原有地区和 Gemini 开关，其他 Chrome 设置保持不变。'
    else
        status "$green" "[完成] 永久实验地区已设为 $country，Gemini 开关已启用。"
    fi
    status "$cyan" "[备份] 原始配置保留在：$backup_dir"
    status "$green" '[下一步] 设置已写入，请从原来的 Chrome 图标重新启动并验证侧栏。'
    status "$yellow" '[说明] 本地设置不会改变实际网络出口；侧栏能否使用仍需打开后验证。'
)

gemini_main "$@"

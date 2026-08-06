#!/bin/zsh
# 编译检查门：对全部源文件做类型检查，不产出产物
# 用法：bash ChargeMonitor/scripts/check.sh（任意目录均可）
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/ChargeMonitor"

# bash/zsh 通用写法收集源文件
SOURCES=()
while IFS= read -r f; do
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)
if [ ${#SOURCES[@]} -eq 0 ]; then
	echo "错误：未在 $SRC 找到任何 Swift 源文件" >&2
	exit 1
fi

echo "==> 类型检查 ${#SOURCES[@]} 个源文件..."
swiftc -typecheck \
	-parse-as-library \
	-swift-version 5 \
	-default-isolation MainActor \
	-target arm64-apple-macosx26.0 \
	"${SOURCES[@]}"

echo "==> 检查通过"

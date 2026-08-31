#!/bin/zsh
# 妙电 单元测试：与主程序共用同一批源文件编译，测的是真代码
# 用法：bash 测试/run_tests.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ChargeMonitor/ChargeMonitor"
OUT="/tmp/chargemonitor_tests"
# 测试跑在当前机器上（arm64），部署目标与主程序保持一致，可用性检查同源
DEPLOYMENT_TARGET="15.0"

mkdir -p "$OUT"

# 收集除 @main 入口外的全部源文件（入口与测试的 main.swift 冲突）
SOURCES=()
while IFS= read -r f; do
	[ "$(basename "$f")" = "ChargeMonitorApp.swift" ] && continue
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

echo "==> 编译测试（源文件 ${#SOURCES[@]} 个 + 测试用例）..."
swiftc \
	-swift-version 5 \
	-default-isolation MainActor \
	-target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
	"${SOURCES[@]}" \
	"$ROOT/测试/main.swift" \
	-o "$OUT/tests"

echo "==> 运行测试..."
"$OUT/tests"

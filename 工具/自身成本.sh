#!/bin/bash
# 妙电自身成本量具（目标模式 §1 能量悖论的可复跑判据）
# 能验：某窗口内 /Applications 里那个妙电进程的 CPU 秒与 RSS、逐段增量（看是稳态还是脉冲）、
#       以及同窗口内 sample 采到的"真在 CPU 上"的叶子函数（区分"记账时间在涨"与"确实在跑"）
# 不能验：真实瓦特/毫安时（powermetrics 要 root）；充电动画与面板展开态的成本需人工配合切换状态
# 用法：bash 工具/自身成本.sh [窗口秒数，默认 60]
set -u

window="${1:-60}"
pid="$(pgrep -x ChargeMonitor | head -1)"
if [ -z "$pid" ]; then
	echo "妙电未在运行，无可测对象"
	exit 1
fi

secs() { # "H:MM:SS.cc" → 秒
	python3 -c "
p='$1'.split(':')
v=0.0
for x in p: v = v*60 + float(x)
print(v)"
}

echo "进程：pid=$pid 版本=$(plutil -extract CFBundleShortVersionString raw -o - "/Applications/妙电.app/Contents/Info.plist" 2>/dev/null)"
echo "电源：$(pmset -g batt 2>/dev/null | sed -n '1p')"
echo "菜单栏模式：$(defaults read fun.crashsystem.ChargeMonitor menuBarContent 2>/dev/null || echo '（未设置＝默认图标+百分比）')"

# 逐段 CPU 增量：稳态负载各段相近，脉冲负载（轮询/备份写盘）会有明显尖峰
steps=4
per=$((window / steps))
echo "窗口 ${window}s，每 ${per}s 采一次累计 CPU 时间："
declare -a marks
for i in $(seq 0 "$steps"); do
	marks[$i]="$(ps -o time= -p "$pid" | tr -d ' ')"
	[ "$i" -lt "$steps" ] && sleep "$per"
done

prev="$(secs "${marks[0]}")"
peak=0
total=0
for i in $(seq 1 "$steps"); do
	cur="$(secs "${marks[$i]}")"
	delta=$(python3 -c "print('%.3f' % ($cur - $prev))")
	pct=$(python3 -c "print('%.2f' % (($delta / $per) * 100))")
	echo "  段$i（${per}s）：CPU ${delta}s → ${pct}% 单核"
	prev="$cur"
	peak=$(python3 -c "print(max($peak, $pct))")
done
first="$(secs "${marks[0]}")"
last="$(secs "${marks[$steps]}")"
total=$(python3 -c "print('%.2f' % (($last - $first) / $window * 100))")
echo "整窗均值：${total}% 单核   最大单段：${peak}%   RSS=$(ps -o rss= -p "$pid" | tr -d ' ')KB"

# 第二把尺：同窗口内 sample 的在栈叶子。若这里几乎全是内核等待叶子，
# 说明 ps 的累计时间来自零散 syscall 而非持续计算
sample "$pid" "$per" -f /tmp/miaodian_sample.txt >/dev/null 2>&1
echo "最近一段 ${per}s 的 sample 叶子（按样本数，前 8）："
sed -n '/Sort by top of stack/,/^$/p' /tmp/miaodian_sample.txt | sed 's/^ *//' | tail -n +2 | head -8
echo "（叶子为 mach_msg2_trap/workq_kernreturn 等＝线程在等待，不烧 CPU；出现 ChargeMonitor 自家符号＝真在算）"

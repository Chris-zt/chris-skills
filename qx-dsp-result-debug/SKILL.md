---
name: qx-dsp-result-debug
description: 分析QX DSP内核测试的result.txt对比日志并判断责任归因。用于解析PC/寄存器/value比较表、DEADLY ERROR汇总、CR/flag mismatch、FPU特殊值差异和Write Back Value，对照本skill的references目录中的指令手册与特殊值表，判断问题属于芯片前仿/RTL、模拟器、trace问题还是证据不足。
---

# QX DSP Result Debug

用于分析 QX DSP 内核测试同事反馈的对比结果文件。日志中 `reg1/value1` 是芯片前仿结果，`reg2/value2` 是模拟器结果；目标是参照指令手册判断每个不一致是芯片错误、模拟器错误，还是证据不足。

默认只使用本 skill 自带的参考文件。

## 本地参考资料

按需读取 skill 目录下的参考文件，不要一次性加载全部资料：

- `references/manuals/Instruction_Set.doc`：指令手册（扩展名虽为 `.doc`，实为 `.docx`/zip，抽取方法见工作流程步骤 3）。
- `references/tables/C2000指令编码_v2.0_202412.xlsx`：指令编码表。
- `references/tables/FPUsepcial.xlsx`：FPU单精度特殊值行为表。
- `references/tables/FPU64sepcial.xlsx`：FPU64双精度特殊值行为表；分析双精度浮点特殊值时优先查看。
- `references/examples/tmp.s`：汇编示例，可用于确认语法和指令写法。

## 工作流程

### 0. 前置检查（结果是否可信）

逐条归因前先做几项快速检查，避免把“设置层错位 / 陈旧二进制 / trace 截断”误判成单条指令的芯片或模拟器 bug：

- **trace 完整性（先做这条）**：比对芯片 trace（`core0_gr_trace.dat`）行数与 ISS 参照（`gr_trace_instr.txt`）行数，并检查芯片 trace 末行是否完整（以换行结尾、末尾值不是半截）。若芯片 trace 行数**远少于** ISS（不是跳 GR30/31、BAR/MR 造成的小差额），或末行被写到一半（如 `...0x000293b8\t0xd` 这种残行），说明芯片 trace 被**截断**——多半是测试脚本轮询早取（trace 未写完就拉）或仿真被提前 `$stop` 打断。此时 result.txt **作废**，那条"末行 mismatch"是截断假象，**不要**逐条归因；先让 harness 等仿真真正结束再拉 trace、让芯片跑完整个程序，重跑后再判。
- **trace 新鲜度**：result.txt / core0_gr_trace.dat 若来自预编译的 `simv_verdi`（例如 run_p65_test.sh 直接跑 `./simv_verdi` 不重编），其结果反映的是编译该 simv 时的旧 RTL，可能与当前 RTL 不符。若不确定 simv 是否由当前 RTL 重编、或编译是否完好（磁盘满会静默产出坏 simv），先按 `dsp-kernel-auto-verification` 的门禁重编再分析，否则归因无意义。
- **系统性错位判据**：若写回寄存器号 `reg1`(芯片) 与 `reg2`(模拟器) 在多数行都不一致（不只是 value 不同），说明是整段错位，优先排查 BASE_PC / 镜像加载地址 / 对齐同步点 / simv 版本，**不要**进入逐条 chip/sim 归因。只有当 reg1==reg2 基本对齐、仅个别行 value 不同时，下面的逐条归因才成立。

1. 先解析 result 日志：

```powershell
python .\plugins\qx-dsp-result-debug\scripts\parse_result.py C:\path\to\result.txt --context 5 --out C:\path\to\analysis.json
```

若当前安装缺少 `scripts/parse_result.py`（部分安装只带 `references/`），不要卡住：直接用 Grep 定位 `DEADLY ERROR`、`false`、`set CR at line`、`Write Back Value` 等关键行，读小窗口上下文手工解析即可（result.txt 可能很大，先定位再读，勿整读）。

2. 阅读生成的 JSON 或终端摘要。重点看：
- 表格总行数和 mismatch 汇总
- 每个 `DEADLY ERROR` block
- `Write Back Value` 中 chip/sim 的最终写回值
- `target_rows` 和 `context` 中的原始比较表上下文
- CR mismatch 的 bit 名称，以及按时间顺序排列的 `set CR at line ...` 候选指令
- `movigl`、`movigh`、`moviglz` 等简单立即数搬移指令的自动期望值推导

3. 查本 skill 的指令手册。优先使用 `references/manuals/Instruction_Set.doc`，不要默认改用其他位置的手册版本，除非用户明确指定。

必须先把 `references/manuals/Instruction_Set.doc` 抽取成文本，再用本次日志中的指令名搜索命中——不要直接读二进制，也不要对它硬抽 ASCII。

**重要**：该文件扩展名虽为 `.doc`，实际是 `.docx`（Office Open XML = zip 打包的 XML，文件头为 `PK`）。用本 skill 自带的 `scripts/extract_manual_text.py`（纯 Python 标准库 `zipfile`/`re`，自动按 docx 解析，无需 antiword/catdoc/libreoffice；非 zip 的旧 OLE .doc 会自动退回 ASCII 兜底）：

```bash
# 在 WSL 里执行；skill 目录的盘符路径在 WSL 中为 /mnt/c/...
# 用 MSYS_NO_PATHCONV=1 防止 Git Bash 改写路径
SK="/mnt/c/Users/zhoumaozhen/.claude/skills/qx-dsp-result-debug"
python3 "$SK/scripts/extract_manual_text.py" "$SK/references/manuals/Instruction_Set.doc" /tmp/manual.txt
rg -n -i "MOVIGH|MOVIGL|EALLOW|MOVG2C|FDSUB|FDMIN|LUF|CON" /tmp/manual.txt
```

抽取后必须用本次日志中的关键指令名做命中验证（正常应能搜到 MOVIGH / EALLOW 等）。若搜不到相关 DSP 指令，说明抽取内容不对，报告为证据不足，不要自行改用其他手册版本。

3.1 如果是FPU双精度浮点的指令，还需要参考本 skill 的 `references/tables/FPU64sepcial.xlsx`，里面是特殊值的期望行为。

4. 按手册行为分类：
- `模拟器错误`：手册期望值等于 chip，且不同于 sim。
- `芯片错误`：手册期望值等于 sim，且不同于 chip。
- `两边或 trace 问题`：chip/sim 都不等于手册期望值，或日志上下文自相矛盾。
- `证据不足`：缺手册文本、缺操作数、缺内存内容、缺 flag/CR 前态，无法确定。

## CR 错误分析

CR 的打印有延迟：`movc2g` 行只是把之前的 CR 状态搬到 GR，真正修改 CR 的指令会在后续 block 中以 `set CR at line ...` 列出。

分析 CR mismatch 时：
1. 使用解析结果里的 `cr_setters`，按 line 从小到大分析。
2. 从最近一次已知 CR 值开始，逐条根据手册重建 CR。
3. 对报告的 bit 单独检查，例如 `bit1 LUF mismatch`、`bit4 CON mismatch`。
4. 比较重建出的最终 CR 与 `Write Back Value (Chip: ..., Sim: ...)`。
5. 如果 setter 是浮点、访存、饱和或比较类指令，需要结合操作数解释该 bit 为什么置位或保持。

不要只看最后的 `movc2g` 就下结论；`movc2g` 本身通常只是暴露先前 CR 状态。

## 输出格式

报告保持简洁，按错误行或共同根因分组：

```text
line 167 movigl GR4 0x53d5: 芯片错误
证据：手册说明 MOVIGL 将 imm16 写入低 16 位，高 16 位保持不变。前态 GR4=0x00000004，期望 0x000053d5，chip=0x000253d5，sim=0x000053d5。
手册依据：<章节/页码/搜索命中>
```

重复根因要合并，尤其是多个 `movigh` 行表现为同一类立即数移位/掩码错误时。

---
name: random_test
description: 手动触发的 QX DSP (qx_c2000/P65) 内核随机指令测试流程。用于用户明确要求"跑随机测试""random_test""run_p65_test.sh""随机指令生成器对比前仿与模拟器"时，驱动 D:\workplace\QX_Workplace\random_test 完成"本地随机生成汇编 → 远程 VCS 芯片前仿 → 本地 ISS 模拟器 → compare.py 逐条写回对比 → result.txt"的端到端回归，并按已知坑点清单排除伪阳性。不要在普通编译、单点 debug、CLA BG 测试或 result.txt 事后分析中自动触发。
---

# QX DSP 内核随机测试 (random_test)

## 触发方式

仅在用户**明确**手动触发本 skill，或明确说"跑随机测试""random test""run_p65_test.sh""随机指令生成器""生成 N 条随机指令跑前仿对比"之类请求时使用。

不要自动触发的场景：
- 只是让你看 `result.txt` 分析某条指令 mismatch → 那是 `qx-dsp-result-debug` 的活。
- CLA 协处理器 BG task 测试 → 用 `cla-test`。
- 定向汇编用例、core0 trace 插探针、RTL 根因定位 → 用 `dsp-kernel-auto-verification`。
- 只改 RTL 想编译/lint → 用 `dsp-spyglass-lint` 或直接编译。

## 定位与职责边界

本 skill 的定位是**跑通并守住整条随机回归流水线，产出可信的数据**。它既可以被用户直接触发，也会**被 `dsp-kernel-auto-verification` 调用**来执行随机回归。

**只管三件事**：

1. 生成随机用例、跑完 `run_p65_test.sh` 全流程
2. **数据完整性检查**：覆盖率（按写回数算）、是否跑飞、X 态截断、仿真结束原因
3. 排除流水线自身的伪阳性（旧 simv / 坏 simv / 地址伪阳性 / 流错位等）

**不做的事**：不判定某条差异是硬件 bug 还是模拟器 bug。容差标准、特殊值规格、缺陷归因**全部交给 `dsp-kernel-auto-verification`**（它维护 `references/knowledge.md` 判定知识库）。

**交接物**：`results/YYYYMMDD_HHMM/` 结果目录 + 数据完整性结论 + `result.txt` 里的 `DEADLY ERROR` **原文**（`grep 'DEADLY ERROR' result.txt` 原样摘录，**不要改写、节选或只留自认为重要的字段**；`movc2g` 那种多行结构要连同 `set CR at line …` 上下文一起带上）。被调用时把这些交回调用方，由它做逐条判定；用户直接触发时，如实报告数据完整性并**贴出 DEADLY ERROR 原文**，说明"缺陷归因需转 `dsp-kernel-auto-verification`"。

原文必须完整交出的原因：判定方要靠它核对字段。历史上出现过把 `movc2g` 首行的内部追踪变量当成结果而误判的情况，只有原文在场才能发现。

这样分工的原因：判定标准必须单点维护。历史上判定规则分散在两处，导致 TMU 容差规则没能作用到随机测试上，白白多排查了好几轮。

## 项目与执行环境

- 项目根目录：`D:\workplace\QX_Workplace\random_test`（WSL 内路径 `/mnt/d/workplace/QX_Workplace/random_test`）
- **必须在 WSL 内执行**：本地 ISS `simulator/simulator_step13` 是 Linux ELF，且脚本要 ssh 远程。Windows 上直接跑必然失败。
- **必须先连 VPN**：WSL 内执行 `qx-on`；用 `wsl.exe -u zhaotao -- bash -lc "ip route get 10.18.30.200"` 确认路由走 `cnem_vnic`。
- 远程服务器 `zhaotao@10.18.30.200`（ssh 别名 `lx5`，已免密）。远程登录 shell 是 **tcsh**，任何复杂远程命令都必须走 `ssh lx5 bash -s <<'EOF' ... EOF` 管道，**不能**用 `ssh lx5 "bash -lc '...'"`——tcsh 会重新拆分参数把命令拆坏。

从 Windows 侧发起的标准包裹形式：

```bash
wsl.exe -u zhaotao -- bash -lc 'cd /mnt/d/workplace/QX_Workplace/random_test && bash run_p65_test.sh 5000'
```

## 一、执行前的门禁检查（不要跳过）

历史上绝大多数"芯片 bug"最后都被证明是这一步没做。按顺序确认：

1. **VPN 通不通** —— `ip route get 10.18.30.200` 走 `cnem_vnic`。
2. **P65 TB 时间是否准确** —— 每次测试前必须 `grep` 检查 `~/Desktop/p65/fpga/c2000_tb.v`，有效仿真超时必须是 `#80000000`（80ms）且超时分支最终执行 `$finish`。不一致时先改为该值、再次核对并重新编译；不得使用按其它超时值编译的 `simv_verdi`。
3. **RTL 有没有改过** —— `run_p65_test.sh` 用的是**预编译好的** `~/Desktop/p65/vcs/simv_verdi`，脚本**不会重编译**。只要动过 RTL，必须先：
   ```bash
   wsl.exe -u zhaotao -- ssh lx5 bash -s <<'EOF'
   bash ~/Desktop/p65/vcs/agent_compile.sh
   EOF
   ```
   （该脚本会设 `PRJ_P65` + setup 宏。）编译完确认 `DONE_RC=0`，日志里没有 `corrupted` / `No space left`。

   **回归请关掉波形 dump**：Makefile 每个 target 都带 `$(dump_all) = +define+DUMP_ALL+VERDI_SIM`，会打开 `$vcdpluson` + `$fsdbDumpvars(0)` 全芯片 dump。随机回归只要写回 trace，不需要波形。加 `dump_all=""` 覆盖：

   ```bash
   make comp_verdi PRJ_P65=$PRJ_P65 setup="$setup" dump_all="" >comp_nodump.agent.log 2>&1
   ```

   实测同样 400ms 仿真：带 dump 563s CPU，关掉 258s（约 **2.2×** 提速），并省掉约 230MB 的 vpd+fsdb I/O，trace md5 不变。要看波形时再单独编一版带 dump 的。
4. **远程磁盘余量** —— `ssh lx5 'df -h ~'`。磁盘满会**静默**编出一个坏 simv：trace 中途截断、末行半截、寄存器值变成 `0x0d` 这种残值。历史上连续三次误判成"movig 芯片 bug"都是这个原因。至少留 10G 以上。如果 lx5 的 `/lx5data` 满盘或剩余空间不足，不要直接清理不确定文件；先检查备用服务器是否有空间：`lx4`(`10.18.30.199`) 和 `lx6`(`10.18.30.202`)。
5. **`instr_generate/config/config.py` 的开关** —— 见下方"生成器配置"，确认 `BASE_PC` 与目标芯片一致。

## 一·五、改动前必须先有对照实验（硬门禁）

在修改 **TB（`c2000_tb.v`）、`instr_generate/config/config.py`、编译选项** 之前，必须先完成一个 **"改变 X → 观测 Y 是否变化"** 的对照实验，并把结果写进报告。没有对照实验证据，不要动这些文件。唯一例外是把 P65 TB 超时纠正为强制标准 `#80000000`：这属于测试前门禁，不需要先做对照实验，但修改后必须重新编译。

理由是这类改动都很贵：改 TB 或编译选项要重编（约 3 分钟）+ 重跑（2–10 分钟），改 `config.py` 还会动到用户的工程配置。而**从间接指标推断出的原因，实测推翻率很高**——2026-07-21 那次会话里，"超时太小"和"数据区盖住 core1 内存"两个推断都是先改后验、事后全被推翻，合计浪费约 30 分钟。

对照实验长这样：

| 你的推断 | 对照实验 | 推断成立的判据 |
|---|---|---|
| TB 超时太小、trace 被截断 | 只把超时翻倍，重跑**同一份镜像**（`md5sum` 核对） | trace 变长；**md5 不变 = 推断错误** |
| 某项配置导致芯片行为异常 | 只改该项，其余不动，重跑 | 目标现象消失；否则立即回退 |
| 编译选项拖慢仿真 | 同一镜像编两版，比日志里的 `CPU Time:` 行 | 有可量化差值 |

两条附加要求：

- **复用镜像做对照时先核 md5**（`dat/1.dat` 与 `outer_insn_mem_core0.dat`），否则比的是两个不同程序，结论无效。
- **改用户工程文件（`config.py` 等）前先备份或记下原值；验证不通过立即回退**，不要把未验证的改动留在用户仓库里。

## 二、标准执行

```bash
bash run_p65_test.sh [指令条数]     # 默认 5000
```

### 指令数上限受"执行窗口"约束

芯片可用的执行时间是一段固定窗口：**boot 结束（约 60 ms）→ 约 123.5 ms 的一次复位**，中间只有约 **64 ms**。用例必须在这个窗口内跑完。

| 指令数 | 实测结果 |
|---|---|
| 2000 / 5000 | 100% 跑完 ✓（5000 为当前默认） |
| 10000 | ✗ 复位打在测试中途，trace 损坏，`compare.py` 崩溃 |

指令内存（代码装 `0x28000`，下一区 `0xa0000`，可用 480 KB，约 5 万条）和生成器数据区都**不是**瓶颈，唯一的瓶颈是这段时间窗口。

**要往 5000 以上调，必须重新实测**（照第一·五节做对照实验），不能凭感觉加。真正想大幅提高单轮指令数，得先解决那次约 123.5 ms 的复位。

脚本七步（详见 `run_p65_test.sh` 顶部注释）：

| 步 | 位置 | 动作 | 产物 |
|---|---|---|---|
| 1 | 本地 | `instr_generate/main.py random N` 随机生成，失败自动重试 8 次 | `random.s`(芯片版) / `random_sim.s`(sim版) |
| 2 | 本地 | 套 `instr_generate/txt/start2.s` 前仿头，统一 LF，scp 上传 | 远程 `1.s`(芯片) / `2.s`(ISS) |
| 3 | 远程 | `all_assember.py` 汇编 | `dat/1.dat` / `datFileSim/2` / `dis/1.dis` |
| 4 | 远程 | `1.dat` → `outer_insn_mem_core0.dat`，`nohup simv_verdi` 跑前仿 | `core0_gr_trace.dat` |
| 5 | 本地 | scp 拉回三份产物 | `sim.bin` / `core0_gr_trace.dat` / `random.dis` |
| 6 | 本地 | `bin2issdat.py` → `simulator_step13 -c qx320f034 -l` → `log_level3.py` → `log_process.py` | `gr_trace_instr.txt`（标准答案） |
| 7 | 本地 | `script/compare.py` 两份 trace 1:1 对比 | `result.txt` |

结果落在 `results/YYYYMMDD_HHMM/`，脚本末尾自动打印 `Total comparisons / Total mismatches / correct / within tolerance`。

**为什么能 1:1 对齐**：VCS 与 ISS 跑的是同一份镜像的两个地址版本，写回顺序天然一致，所以不需要 QXIDE 工具链——远程 objcopy 出裸二进制，本地 `bin2issdat.py` 转成 ISS 的 `32'h<addr>,\t128'h<w0>_<w1>_<w2>_<w3>` 格式即可。

### 脚本关键配置（`run_p65_test.sh` 第 20–41 行）

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHIP` | `qx320f034` | 本地 ISS 芯片型号（`-c`） |
| `IMEM_BASE` | `0x200000` | **sim 版**镜像在 ISS 中的加载基址 |
| `TARGET_MEM` | `insn` | 镜像目标内存：`insn`→`outer_insn_mem_core0.dat`，`data`→`outer_data_mem_core0.dat` |
| `SIMV` | `./simv_verdi` | 预编译仿真器（**不重编**） |
| `SIM_WAIT_MAX` | 120 | 轮询上限，×15s ≈ 30 分钟 |
| `GEN_RETRY` | 8 | 生成器随机失败重试次数 |

### 仿真完成判据（改动前请先理解）

- **主判据**：远程 `simv_verdi` 进程已退出(DONE) 且 trace 非空 —— **实际只有这一条可靠**。
- **兜底**：trace 行数连续 3 次（≈45s）不增长。

**重要：trace 行数不能当进度用。** TB 的 `$fwrite` 是缓冲的，可能整轮仿真 trace 都是 0 行，直到 `$fclose`（`$finish` 那一刻）才一次性落盘。实测见过"轮询 250s 全是 0 行 → 最后一跳到 137 行"。所以兜底判据在这种情况下形同虚设，而且**绝不能从行数少推断"被截断/时间不够"**——见下面第五节。

## 三、生成器配置

> **总则：本 skill 里的芯片侧数值一律是"上次实测值"，不是常量。**
>
> `BASE_PC`、内存映射（各 `.dat` 的装载地址）、复位时刻、执行窗口、指令数上限这类数字，都会随 boot 流程、TB 激励和 RTL 演进而变化。每次使用前必须用本 skill 给出的判据**现场确认**；**判据与数值不一致时，以判据为准，并顺手更新这里的数值**。
>
> 这条不是形式主义：2026-07-21 那次，`BASE_PC` 就是照搬了项目记忆里 2026-07-01 的结论（`0x00280000`），当时是对的，在新 boot 流程下已经错了，导致首轮测试完全无效且极难察觉（初始化段仍与 ISS 逐条对齐）。**现场验证一次约 10 秒，误信一次要花一小时。**

`instr_generate/config/config.py`，改开关就能调测试面：

- `TestConfig`：`PACKED_INSTR`(VLIW 打包)、`TEST_JMP_CALL`(跳转/调用)、`TEST_CLA`、`FPU_TEST`、`TMU_TEST`、`VCU_TEST`、`FINTDIV_TEST`、`DOUBLE_WB_PACK`(双写回打包)、`INCREASE_BYPASS_TEST`(加强 bypass)、`WEIGHT_MODE`(权重模式)、`TEST_MODE`。
- **`BASE_PC` 要用测试码的实际起始 PC，当前实测是 `0x00028400`**。不要用 chip trace 的**首行** PC —— trace 开头几十行是 bootloader（装载在 `0x280000`）的写回，测试镜像装在别处。正确的判定方法是找 **PC 区段切换点**：

  ```bash
  awk '{pc=strtonum($2); r=(pc>=0x280000)?"BOOT":"TEST"; if(r!=p){printf "行%-5d %s %s\n",NR,$2,r; p=r}}' core0_gr_trace.dat
  ```

  切到 TEST 的那一行的 PC 就是 `BASE_PC`。交叉验证：哨兵 `0xDEADBEEF` 应落在 `BASE_PC + 0x13c`，紧接生成器标注的 `initial addr` 偏移 `0x140`。

  曾误设为 `0x00280000`（把 bootloader 首写回当成测试码起点）：初始化因顺序执行仍然正常、且与 ISS 逐条对齐，**看不出异常**；但函数/跳转目标被算成 `0x280000+offset` 落进 bootloader 区，核跳错地址后挂死，chip trace 停在 137 行。这个失效模式很隐蔽——前 126 行完美对齐会让人以为只是"跑得不够久"。

  数据区也由 `BASE_PC` 推导（`tool/ram.py:81`），改它会连带改变随机 store 的落点。
- `JmpConfig`：函数划分比例、call 频率、函数名列表。

`instr_generate/txt/start.py` 在测试体前插入 GR0~GR29 + CR 初始化，末尾写哨兵 `GR0=0xDEADBEEF`（`CR_INIT_VALUE=0x00004000`，即复位默认值，避开 EALLOW）。`script/compare.py` 会跳到哨兵之后才开始比较——`SENTINEL_VALUE` 两边必须一致（`start.py` 与 `compare.py:11`）。

## 四、读 result.txt

`result.txt` 结构：逐条写回对比表 → 按指令归类的错误汇总 → `DEADLY ERROR` 列表。

### 覆盖率怎么算（**别用行数**）

这是个踩过的坑：`core0_gr_trace.dat` **每行都是一次写回**，而 `gr_trace_instr.txt` 里**包含不产生写回的指令行**（`nop`、`movg2c`、跳转、只写 CR 的比较等，这些行前面几列是空的）。两者口径不同，直接比行数会算出一个严重偏低的假覆盖率。

正确算法——只数 ISS 侧真正有写回的行：

```bash
D=results/<最新>
ch=$(wc -l < $D/core0_gr_trace.dat)
cs=$(grep -in deadbeef $D/core0_gr_trace.dat | head -1 | cut -d: -f1)
is=$(grep -n  deadbeef $D/gr_trace_instr.txt | head -1 | cut -d: -f1)
ib=$(awk -v s="$is" 'NR>s && /^0x[0-9a-f]{2}\(GR/ {c++} END{print c+0}' $D/gr_trace_instr.txt)
echo "chip 测试体写回=$((ch-cs))  ISS 测试体写回=$ib"
```

两者相等即 100% 覆盖。实测正常情况下就该相等（949/949、633/633、278/278）。

同理，`compare.py` 的 `Total comparisons made` 也是按 ISS **行数**计的，把不写回的行当成"正确"计入，所以那个百分比偏乐观——判断"有没有真实差异"要看 `DEADLY ERROR` 和错误归类，不要看百分比。

**先看汇总数字，别一上来整读文件**（大日志用 Grep 定位再读小窗口）：

```bash
grep -nE 'Total comparisons|Total mismatches|correct \(|within tolerance' result.txt
grep -n 'DEADLY ERROR' result.txt | head -40
grep -nE '^[a-z0-9_]+ error at lines' result.txt
```

对比容差（`script/compare.py`）：
- `ERROR_PRECISION_THRESHOLD = 1.0`：误差百分比超过记 `false`，非零但低于阈值记 `warning`。
- `FPU_ULP_TOLERANCE = 2`：超越函数类 FPU 指令允许 2 ULP 误差。

**已知固有伪阳性：地址类寄存器。** `compare.py` 直接比较寄存器裸值，不做地址归一化。凡是寄存器装载代码地址（间接跳转/调用目标）的地方，芯片版是 `BASE_PC+offset`、sim 版是 `SIM_BASE_PC+offset`，**两边都对但值不同**，必然报 mismatch；一旦跳过去，后续 PC 全部错开，级联成片报错。识别方法：两侧值相减为常数 `BASE_PC - SIM_BASE_PC`，且 offset 部分相同。

这类用例的对齐率会断崖式下跌（实测同样配置下，无间接跳转的用例 1 个 mismatch，有的那轮 696 个）。看到成片 `movigl/movigh` 报错时先算这个差值，不要当成芯片 bug。

## 五、发现 mismatch 时的判定顺序

**先排伪阳性，再谈芯片 bug。** 按这个顺序走，因为历史上四次"芯片 bug"全部是流水线问题：

0. **先查仿真到底是怎么结束的** —— 这是第 0 步，别跳过：

   ```bash
   grep -nE 'time out|\$finish at|\$stop|STATUS: failed|CPU Time' $R_VCS/simv_run.agent.log | tail
   ```

   可能的结束方式差别巨大：`simulate completed due to time out`（TB 超时）、`c2000_jtag.v` 的 `$stop`（JTAG BFM 主动停仿真）、或自然跑完。**永远不要从 trace 行数去猜结束原因**——行数受 `$fwrite` 缓冲影响，而且"短"可能是核跑飞、可能是 BFM 停仿真、可能是超时，三者处置完全不同。

   区分"核跑飞"和"时间不够"的可靠判据：
   - **核跑飞**：PC 区段切换回 BOOT 区；**加大超时后 trace 的 md5 完全不变**。
   - **时间不够**：全程在测试码区，尾部 PC 正常推进，加大超时后 trace 变长。

   加超时之前先做这个 md5 对照实验，否则会像 2026-07-21 那次一样，白白改 TB + 重编 + 多跑一轮。

1. **simv 是不是旧的？** RTL 改过但没重编 → 跑的是旧 RTL。
2. **simv 是不是坏的？** 磁盘满/编译中断会产坏 simv：确认编译 `DONE_RC=0`、无 `corrupted`/`No space`、`df -h` 有余量。
3. **trace 是不是残缺？** 用第四节的**写回数**算覆盖率（**不要比行数**）。若 chip 写回数明显少于 ISS，看 trace 末行：
   - 末行形如 `0xxX  0x00280000  0x00000000` → **复位打在测试中途**（`0xxX` 是 Verilog `%h` 打印 X 态，`0x280000` 是复位向量）。绝大多数情况是**指令数超出执行窗口**，减少指令数即可，不是芯片 bug。`compare.py` 会因解析 `0xxX` 直接崩溃。
   - 末行正常但偏短 → 回到第 0 步确认结束原因。
4. **JTAG `$stop` 通常无害，别被它带偏。** 日志尾部的 `STATUS: failed (Read ID = 0xffffffff)` + `$stop`（`c2000_jtag.v:179`）在正常情况下发生在**测试跑完之后**——测试结束 → core0 空闲 → `c2000_tb.v:100` 的 `always` 块延时 20 ms → core0 复位 → BFM 的 reset-test 块醒来 → 读 IDCODE 失败。它是日志里最显眼的结束事件，但只是最后发生的那件事，**不代表数据不完整**。先用写回数确认覆盖率，再决定要不要管它。把 TB 超时设在复位之前（见第二节）就能完全绕开。
5. **是不是对齐问题？** 用第三节的 PC 区段切换点判据现场确认 `BASE_PC`（当前实测 `0x00028400`，**不要直接照抄**）；核对反汇编 `random.dis` 里函数标签的 `pc == addr`。
6. 以上都排除，再把具体指令交给 `qx-dsp-result-debug` 做归因，或用 `dsp-kernel-auto-verification` 插探针定位 RTL。

详细的历史误判复盘见 `references/pitfalls.md`——出现"某条指令读到 `0x0d` 这种半截值""chip trace 远短于 ISS""大面积 PC 错位"这类现象时，先去那里对照，多半已经有定论。

## 六、脚本中途失败时

不要整条重跑（5000 条一轮约 3–5 分钟，改 TB/编译选项还要多花约 3 分钟重编）。读 `references/manual-steps.md`，里面有目录/远程路径速查和七个步骤各自的独立命令，可以从断点继续。最常见的是"只改了 compare.py 容差，想在已有 trace 上重看结果"——直接从步骤 7 开始即可。

## 七、备选：Makefile 老流程

`run_p65_test.sh` 之外还有一套 Makefile 流程（只跑到本地 ISS，上传靠 ftp，需要 QXIDE 工具链）。除非用户明确要用，否则默认走脚本。

| 命令 | 作用 |
|---|---|
| `make` / `make random` | 随机生成并测试，条数由 `INSTR_TIME`(默认 100000) 定义 |
| `make run` | 对已有 `test/random.s` 重跑 |
| `make all` | 交互输入指令名和次数（基本没维护） |
| `make remote` | ftp 上传 `remote/` 内容 |
| `make error` | 按时间戳把当前用例+结果归档到 `ERROR/` |
| `make clean` | 清理 |

## 八、报告格式

跑完后向用户汇报，用这个结构：

**先报数据完整性，再报差异。** 顺序不能颠倒——数据不完整时，任何"正确率"都没有意义。

```
## 随机测试结果
- 用例：N 条随机指令，结果目录 results/YYYYMMDD_HHMM/
- 门禁：VPN ✓ / P65 TB `#80000000` ✓ / simv 已按该 TB 重编 ✓ / 远程磁盘 <XXG>

### 数据完整性（先看这里）
- 覆盖率：chip 测试体写回 <A> / ISS 测试体写回 <B> = <P%>   ← 必须按写回数算
- 是否跑飞：PC 区段切换 <仅 1 次 BOOT→TEST ✓ / 中途切回 BOOT ✗>
- 结束原因：<time out→$finish ✓ / $stop / STATUS: failed>

### 差异
- DEADLY ERROR <n> 条，错误归类 <m> 项
- <指令名> ×<次数>：<现象>，判定=<地址伪阳性/级联错位/待归因/疑似 RTL>，依据=<...>

## 建议
- <下一步：重编 simv / 交 qx-dsp-result-debug 归因 / 插探针 / 无需处理>
```

**不要用 `compare.py` 的 `correct (P%)` 当结论**。它按 ISS 行数计、把不写回的行算作正确，口径偏乐观；芯片跑飞时它照样能给出 `99.77% correct`（2026-07-21 实测，当时芯片只执行了 1754 条中的 11 条）。要引用就标注"此为 compare.py 口径，仅供参考"。

没有 mismatch 时不要编造问题；有 mismatch 但证据不足以定性时，明确写"证据不足"并说明还需要什么。

**报告里必须体现结论的边界**：单轮随机用例不构成完备验证；说明哪些测试面是关闭的（如 `TEST_CLA`、`FINTDIV_TEST`）；已知的 harness 伪阳性（地址类寄存器）本轮是否触发。

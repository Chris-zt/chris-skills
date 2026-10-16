---
name: dsp-kernel-auto-verification
description: 为QX DSP/MCU项目执行端到端RTL验证和远程调试。用于运行或修复项目025、034、039p、049、137、377、core、p65的VCS仿真、汇编测试生成与编译、core0寄存器跟踪分析、受限SystemVerilog探针插入、Verilog/SystemVerilog根因定位、RTL补丁上传和最终回归验证；指令手册、编码表、FPU特殊值表和示例汇编仅使用本skill的references目录。
---

# DSP内核自动验证

## 范围

作为DSP内核设计和验证代理，完整驱动整个流程：创建或上传汇编测试、构建并运行远程VCS模拟、分析日志/跟踪、在需要时添加精确受限的探针、定位RTL漏洞、修复本地RTL、将修复上传到远程服务器、重新运行模拟并报告结果。

假设本地RTL与远程RTL在开始时相匹配。本地项目工作区可以直接编辑。将代理创建的临时文件放在项目的`agent/`目录下。

## 执行环境（重要）

本机能连通远程服务器的网络与凭证（VPN、`~/.ssh/config`、免密密钥、别名 `lx5`）都在 **WSL**（发行版 `Ubuntu-22.04`，用户 `zhaotao`）里；Windows 上直接访问内网 SSH/Git 不可靠。因此**所有访问远程服务器或内网 Git 远端的命令都必须在 WSL 内执行**：

- 先确保 WSL 内 VPN 已连：在 WSL 里执行 `qx-on`，并用 `wsl.exe -u zhaotao -- bash -lc "ip route get 10.18.30.200"` 确认路由走 `cnem_vnic`。
- 远程命令统一用别名 `lx5`（= `zhaotao@10.18.30.200`，已配好免密），并用 `wsl.exe` 包裹：
  - 执行远程命令：`wsl.exe -u zhaotao -- ssh lx5 "<远程shell命令>"`
  - 上传文件：`wsl.exe -u zhaotao -- scp <WSL路径> lx5:<远程路径>`。Windows 盘符路径在 WSL 中是 `/mnt/<盘符小写>/...`，例如本项目 `D:\workplace\QX_Workplace\p65` → `/mnt/d/workplace/QX_Workplace/p65`。
  - 内网 Git 操作：访问 `10.18.30.*` 等内网 remote 的 `fetch`、`pull`、`push`、`ls-remote` 必须通过 WSL 执行，例如 `wsl.exe -u zhaotao -- git -C /mnt/d/workplace/QX_Workplace/p65 push origin <branch>`；不要先在 Windows 侧尝试同一网络操作。本地 `status`、`diff`、`log`、`commit` 仍可在 Windows 执行。
- 本地分析（读参考资料、直接编辑本地 RTL）仍在 Windows 正常进行，**无需**走 WSL。
- 注意多层引号链：PowerShell → wsl → ssh → 远程 bash。复杂远程脚本优先用单引号包裹、分步执行，或用 here-doc 先落到远程再运行，避免引号被层层吞掉。
- **远程登录 shell 是 tcsh，不是 bash**。凡含重定向(`>log 2>&1`)、`&&`、`for`/变量、here-doc 等 bash 语法的远程命令，必须强制在 bash 里跑，否则 tcsh 会报 `Ambiguous output redirect` 之类错误。统一用：
  - `ssh lx5 bash -s <<'EOF' … EOF`（推荐，多行脚本一次落地执行），或
  - `ssh lx5 bash -lc '单行命令'`。
  只有最简单、无重定向/无 bash 语法的命令才可 `ssh lx5 "cmd"` 直接跑。实测 `wsl -e bash -lc 'ssh lx5 …'`（默认用户）可用；若 `wsl.exe -u zhaotao -- ssh lx5 …` 空输出/不通，改用前者。
- **临时开关一律改本地文件后整体上传，不要只在远端 `sed`**。两种改法混用时，下一次整体上传会静默覆盖掉远端的 `sed` 结果。危险之处在于症状极具迷惑性——被打回原状的开关会让统计量全为 0，与"通路不通""激励没到"等真实故障长得一模一样，容易误判为设计问题（本 skill 因此浪费过一整轮约 57 分钟的仿真）。若确需临时切换，在脚本里加一行开关状态的 `grep` 回显，让每轮日志自证跑的是哪一版。

## 芯片型号、编译器选项与 Git 分支

来源：用户于 2026-09-12 确认的对应表。查询芯片版本对应分支时优先使用本表；实际运行测试前仍需核对工作区当前分支和提交。

| 芯片型号 | `-mcpu=` | `qx_c2000` 分支 |
|---|---|---|
| QX320F280{049,377}RevA | `qx320f` | 待确认 |
| QX320F280{049,377}RevB | `qx320f049v2` | `T55_049_NTO` |
| QX320F2800137 | `qx320f137` | `U110_137_NTO_V3` |
| QX320F28034 | `qx320f034` | `U110_034_NTO_V2` |
| QX320F28377D | `qx320f377d` | `377D_SIMC55` |
| QX320F28P650 | `qx320fp650` | `P65_NTO_SMIC55` |
| QX320F280025 | 未提供 | `U110_025_NTO` |
| QX320F280039 | `qx320f039` | `T55_039_NTO` |

RevA 分支和 025 的 `-mcpu` 值尚未确认，不得按名称猜填。`377D_SIMC55` 保留仓库实际拼写；不要将 QX320F280{049,377} 与 QX320F28377D 混为同一版本。

## 项目和远程环境

- 有效的`{project}`值：`025`、`034`、`039p`、`049`、`137`、`377`、`core`、`p65`。
- 远程服务器：通过 WSL 访问，统一用别名 `ssh lx5`（= `zhaotao@10.18.30.200`）；具体调用方式见上方“执行环境”。
- 远程验证工作区：`~/Desktop/{project}/vcs/`。
- 远程汇编临时目录：`~/Desktop/test/tmp/`。
- 远程测试源路径：`~/Desktop/test/tmp/1.s`。
- P65远程批量汇编器脚本：`~/Desktop/test/assember_linux/all_assember.py`。
- P65远程汇编器命令：从`~/Desktop/test/assember_linux/`运行`python3 all_assember.py`。该脚本批量处理脚本中配置的目录（包括`../tmp`），并调用`tr3.py`为目录内`.s`生成`dat/`、`out/`和`dis/`产物。
- 生成的二进制文件：`~/Desktop/test/tmp/dat/1.dat`。
- 验证数据目标：`~/Desktop/{project}/vcs/outer_data_mem_core0.dat`。
- P65 core0指令测试目标：`~/Desktop/p65/vcs/outer_insn_mem_core0.dat`。当测试用例是要由core0执行的指令流时，汇编产物应进入指令存储镜像，不要误复制到`outer_data_mem_core0.dat`。
- 寄存器跟踪：`~/Desktop/{project}/vcs/core0_gr_trace.dat`。
- 测试台跟踪定义：`~/Desktop/{project}/fpga/c2000_tb.v`。
- 指令示例：`references/examples/tmp.s`。
- 指令手册：`references/manuals/Instruction_Set.doc`。

## 本地参考资料

**分析任何差异之前，第一步先读 `references/knowledge.md`（判定知识库）。**

那里存放已经确认过的判定规则——容差标准、特殊值规格、已知设计特性。很多"看起来像 bug"的现象在那里已有定论，查一次几秒钟，能省掉整轮排查。典型例子：TMU 指令允许 1e-7 的误差，芯片对极小输入返回 0 而模拟器返回 3e-10 属于**正常**，不是缺陷——不查知识库就会把它当成 bug 上报。

**知识库要持续维护**：每当用户确认了一条新的判定标准（新的容差、某类指令的规格、某个已知差异的定性结论），立即写进 `references/knowledge.md`，注明来源与确认日期，并写成可执行的形式（"什么情况判什么"），而不是泛泛的经验总结。判定完一个问题后回头想一下：这次的结论是否值得沉淀成规则？是就写进去。

按需读取 skill 目录下的其它参考文件，不要一次性加载全部资料：

- `references/knowledge.md`：**判定知识库（先读这个）**。
- `references/manuals/Instruction_Set.doc`：指令手册（扩展名虽为 `.doc`，实为 `.docx`/zip）。
- `references/tables/C2000指令编码_v2.0_202412.xlsx`：指令编码表。
- `references/tables/FPUsepcial.xlsx`：FPU单精度特殊值行为表。
- `references/tables/FPU64sepcial.xlsx`：FPU64双精度特殊值行为表。
- `references/tables/049-finalTMU_sepcial.xlsx`：**TMU 指令特殊值对照表（含 TI 参考结果）**。比对 TMU 指令（`SINPUF32`/`COSPUF32`/`ATANPUF32`/`QUADF`/`MPY2PIF32`/`DIV2PIF32`/`FSSQRT`）结果时优先查这张。
- `references/examples/tmp.s`：汇编测试示例。

### TMU 特殊值表怎么用（`049-finalTMU_sepcial.xlsx`）

列结构：`指令 | 数据 | 数据表示 | 结果 | LUF | LVF | ti理论结果 | ti实际结果 | ti_LUF | ti_LVF`。
左半是 QX(049) 实测，右半是 TI 参考——**判定"芯片对还是模拟器对"时以本表为准**，不要拿通用 IEEE-754 行为套。

表中体现的 TMU 统一规格（多条指令重复标注，可作通用规则）：

- **输入 denorm 视为 0** —— `SINPUF32`/`COSPUF32`/`ATANPUF32`/`MPY2PIF32`/`DIV2PIF32`/`FSSQRT` 全部如此，结果按输入=0 计算，且 **LUF/LVF 均不置位**。
- **输入 NaN 视为 Inf** —— TMU 不生成 NaN 值（与手册 `LOGPUF32` 说明一致）。
- **下溢才置 LUF** —— 例：`DIV2PIF32` 输入最小规格化数 `0x00800000`(1.175e-38)，结果 0 且 **LUF=1**；而 denorm 输入结果也是 0 但 **LUF=0**。所以"结果为 0"本身不代表下溢，要看 LUF。
- `ATANPUF32`：`Inf→0.125`、`-Inf→-0.125`、`±0→0`、`±1→±0.125`、`denorm→0`；Inf/NaN 输入置 **LVF=1**。

**已知覆盖盲区**：该表只列举特殊值（Inf/NaN/±0/±1/denorm），**不覆盖"极小但已规格化"的正常数**（如 1e-9 量级）。随机测试中若遇到这类输入下 QX 结果为 0 而模拟器给出非零精确值，本表**不足以定性**，需另找 TMU 内部定点精度规格；此时应判"无法确定"，不要据此断言芯片或模拟器有 bug。

指令手册抽取：`Instruction_Set.doc` 实际是 `.docx`（zip+XML，文件头 `PK`），不要当二进制 OLE .doc 硬抽 ASCII（抽不到中文正文）。用本 skill 的 `scripts/extract_manual_text.py`（纯 Python 标准库 `zipfile`/`re`，无需 antiword/catdoc/libreoffice）抽成文本再搜：

```bash
SK="/mnt/c/Users/zhoumaozhen/.claude/skills/dsp-kernel-auto-verification"
python3 "$SK/scripts/extract_manual_text.py" "$SK/references/manuals/Instruction_Set.doc" /tmp/manual.txt
rg -n -i "MOVIGH|MOVIGL|EALLOW|MOVG2C|FDSUB" /tmp/manual.txt
```

抽取后用本次相关指令名做命中验证（应能搜到 MOVIGH/EALLOW 等）；搜不到则判证据不足，不要改用其它手册版本。

## 工作流

### 第0阶段：准备测试用例

**先分流——用例从哪来，决定走哪条路：**

| 情形 | 走法 |
|---|---|
| **随机回归测试**：用户要"跑随机测试""跑一轮回归"，或没有指定具体用例 | **调用 `random_test` skill** 执行，不要自己复刻生成器 / `run_p65_test.sh` 那套流程 |
| **定向测试**：用户给了汇编用例、指名测某条指令、要复现某个 bug | 走本节以下的原有流程 |
| **要在 CPU1(core1) 上跑程序**：用户要"在 CPU1 上测""core1 跑不起来""core1 没有 trace"、LCM/lockstep 相关 | **调用 `dsp-cpu1-test` skill** 准备 CPU1 的启动与镜像；编译、探针、判定、报告仍回本 skill 流程 |

调用 `random_test` 时的分工：它负责跑出**可信数据**（生成用例、跑完整流程、做数据完整性检查——覆盖率/跑飞/X态/结束原因、排除流水线伪阳性），交回 `results/YYYYMMDD_HHMM/` 结果目录和 `DEADLY ERROR` 原始清单。**它不做缺陷归因**——拿到结果后由本 skill 从第2阶段接手判定（见下）。

不要绕过 `random_test` 自己拼随机测试流程：那套流水线有大量踩过坑的判据（`BASE_PC` 现场校验、执行窗口上限、trace 缓冲特性、覆盖率算法），重新实现必然重蹈覆辙。

**以下为定向测试流程：**

如果用户提供了测试用例，使用它。否则，按照远程示例和指令手册精确编写最小化的汇编测试。将语法兼容性视为关键，因为这是专有ISA。对于64位结果，使用两个连续的32位寄存器作为连接的结果。

将测试上传到`~/Desktop/test/tmp/1.s`，远程汇编，确认`dat/1.dat`存在。**P65 定向测试必须先把待测汇编替换到 `/home/zhaotao/Desktop/test/tmp/1.s`，再从 `~/Desktop/test/assember_linux/` 执行 `python3 all_assember.py`；除非用户明确授权，不得用项目私有 `assember_linux`、直接调用 `tr3.py` 或其它临时汇编路径替代标准入口。** 对P65 core0指令执行测试，必须确认实际指令镜像被写入或复制到`~/Desktop/p65/vcs/outer_insn_mem_core0.dat`；`outer_data_mem_core0.dat`只用于数据存储初始化，不能作为指令流目标。对其它项目或纯数据初始化用例，按项目原有加载规则复制到对应目标文件。

**汇编用例收尾规则：**执行 RTL/ISS 对比前，检查用例末尾是否包含用于驻留的死循环（例如 `end: jmp end` 或同等形式）。测试版本必须删除该死循环，并在原位置保留 **10 条 `nop`** 作为收尾；不要以死循环中的 trace 作为“程序跑完”的证据。这样仿真可自然到达 testbench 的结束条件，报告时必须区分“目标指令已执行”和“程序已自然结束”。仅当用户明确要求保留死循环以观察长期状态时才例外，并在报告中说明该例外。

**测试初始化规则：**每次 RTL/ISS 测试开始前，测试用例必须显式完成初始化，不能依赖上一次仿真、旧镜像或寄存器复位后的偶然状态。对于涉及 FPU、CR 或 flag 的用例，程序开头必须先将 CR 清零（使用 `movigl`/`movigh` 设置一个通用寄存器为 `0x00000000`，再执行 `movg2c` 写入 CR），并插入足够的 `nop` 使写入提交；随后再设置操作数、舍入模式和其他测试状态。RTL 与 ISS 必须使用同一份初始化后的测试程序，并在报告中说明初始化内容。

**舍入模式验证规则：**如果结论依赖 FPU/TMU/转换指令的舍入模式，不能只用 SPR/CR 写后读回证明“配置生效”；写后读回只证明目标地址可读写。还必须给出消费者侧证据：要么静态追踪 RTL 路径到目标执行单元的 `RND`/`RND32`/`RND64` 输入，要么插入受限临时探针，在目标指令执行窗口打印执行单元实际看到的舍入信号。报告中要区分“寄存器写入成功”和“目标指令实际使用该舍入模式”。

**FPU/FVCU 舍入分流规则：**判定 FPU 差异前，先确认指令实际进入的执行模块和活跃宏路径，再按 `references/knowledge.md` 的“FPU/FVCU 默认舍入模式”规则选择默认模式：FPU 中非 FVCU 指令默认 RNE；FVCU 中 `FCVTDS` 默认 RNE；FVCU 其它指令默认 RTZ。不得仅凭“属于转换指令”推断 RTZ，也不得把整个 FVCU 或整个 FPU 统一套用同一种舍入模式。报告必须列出“指令 → 执行模块 → 消费者舍入信号 → 实际/默认模式 → 期望结果”；若有明确配置且消费者侧证据证明模式已覆盖，再按实际模式判定。

P65默认必须使用`~/Desktop/test/assember_linux/all_assember.py`作为批量汇编入口。从`~/Desktop/test/assember_linux/`运行`python3 all_assember.py`，不要把该脚本当成单文件命令调用。若脚本缺失或不可执行，不要静默改用其它流程并声称完成；先在`~/Desktop/test/assember_linux/`和用户指定路径中查找同名脚本或备份。若仍不可用，报告缺失事实，并按以下顺序修复：1）从项目备份、版本库或用户提供位置恢复`all_assember.py`到`~/Desktop/test/assember_linux/`；2）确认脚本能批量处理`../tmp`并为`1.s`生成`~/Desktop/test/tmp/dat/1.dat`、`~/Desktop/test/tmp/out/1.out`和`~/Desktop/test/tmp/dis/1.dis`；3）若必须临时验证单个用例，可说明原因后使用同目录下的`tr3.py`交叉检查语法和objdump，但最终批量流程仍需恢复并验证`all_assember.py`。

### 第1阶段：编译和运行

通过 WSL 用 `ssh lx5` 连接远程服务器（见“执行环境”）。在每次 P65 测试前先检查`~/Desktop/p65/fpga/c2000_tb.v`，有效仿真超时必须是`#80000000`（80ms）且最终执行`$finish`。数值不一致时先改为`#80000000`，再次`grep`核对，并在运行测试前重新编译；不得沿用按其它超时值编译的`simv`。**注意别多写/少写 0**：本规则要求的准确值是八千万。其它项目仍需确认测试台具有有限且合适的超时和`$finish`。保留已有的`$fclose(...)`收尾代码，例如：

```systemverilog
initial begin
        #80000000

        $fclose(fp_gr_core_0);
        $fclose(fp_dm_core_0);
        $fclose(fp_peri_core_0);
        $fclose(fp_sprs_core_0);
        $fclose(fp_cla_gr_bgtask);
        $fclose(fp_gr_core_1);
        $fclose(fp_dm_core_1);
        $fclose(fp_peri_core_1);
        $fclose(fp_sprs_core_1);
        $display("simulate completed due to time out\n");
        $finish;
end
```

进入`~/Desktop/{project}/vcs/`运行编译。注意 `make comp_verdi` 依赖 `PRJ_P65` 等变量与 setup 宏——**裸跑 `make comp_verdi` 会因 `filelist` 路径变成 `/filelist/...` 而编译失败**。

P65 优先用服务器上现成的编译封装 `~/Desktop/p65/vcs/agent_compile.sh`（内含 `export PRJ_P65=~/Desktop/p65` 与 `setup="+define+CORE0 +define+CORE1 +define+CLA0 +define+CLA_BGTASK_REG2DAT"`）。

**成功判据要用日志里真实存在的标志**：`agent_compile.sh` 的写法是 `make ... >comp_verdi.agent.log 2>&1` 后再 `echo "DONE_RC=$?"`——那个 `echo` **没有重定向**，`DONE_RC=0` 只出现在 **stdout**，日志里根本没有这一行。因此 `grep DONE_RC comp_verdi.agent.log` 必然落空、把成功的编译误判成失败。改用日志中确实存在的 `successfully generated: 0 error`。

按“执行环境”里的 `ssh lx5 bash -s` 方式执行下面这段远程脚本：

```bash
cd ~/Desktop/p65/vcs
df -h . | tail -1                       # 编译前先看磁盘余量：/lx5data 是共享盘，满盘会静默产出坏 simv
bash agent_compile.sh
# 判据：日志里有 elaboration 成功行，且无 corrupted / No space left（满盘/损坏会静默出坏 simv）
if grep -q "successfully generated: 0 error" comp_verdi.agent.log && ! grep -qiE "corrupted|No space left" comp_verdi.agent.log; then
    echo COMP_OK
else
    echo COMP_FAIL; grep -iE "corrupted|No space left|Error-\[" comp_verdi.agent.log | tail
fi
# 关键：编译流程会重置指令镜像，务必"先编译、再放镜像、再跑仿真"，否则会跑成别的程序
cp ~/Desktop/test/tmp/dat/1.dat outer_insn_mem_core0.dat
# 必须用 printf 'exit\n' 管道喂给仿真：tb 里可能有 $stop（如 cmsdk_uart_capture_ard.v
# 的 UART 测试结束点），一旦触发就进入 ucli 交互模式，会把脚本剩余命令当成 ucli 输入
# 吃掉（报 "invalid command name grep"），整轮结果静默丢失，而退出码仍是 0。
printf 'exit\n' | ./simv_verdi >/tmp/simrun.log 2>&1; echo "SIM_RC=$?"
```

若 `agent_compile.sh` 缺失，退回裸 make 并显式带上变量：`make comp_verdi PRJ_P65=~/Desktop/p65 setup="+define+CORE0 +define+CORE1 +define+CLA0 +define+CLA_BGTASK_REG2DAT"`。

**编译鲁棒性（磁盘满 / 中间库损坏）**：`/lx5data` 是团队共享盘，满盘时 VCS 会静默把中间库写坏，报 `VCS database file access error ... corrupted` 或 `No space left on device`，且 mtime 看起来仍是新的（骗过新鲜度判断）。处理：
1. 如果 lx5 的 `/lx5data` 满盘或剩余空间不足，不要直接清理不确定文件；先检查备用服务器是否有空间：`lx4`(`10.18.30.199`) 和 `lx6`(`10.18.30.202`)。
2. 若仍需在当前工程继续，满盘时只清**明确可再生**的构建产物（如 `urgReport`、`vcdplus.vpd`、`*.fsdb`、`AN.DB`、`csrc`、`simv_verdi.daidir`、`partitionlib`）再编；共享盘属破坏性操作，不确定的大文件（coverage 数据库、来历不明的大文件）先问用户，不要擅删。
3. 遇 `corrupted .sdb`：`rm -rf AN.DB csrc simv_verdi.daidir partitionlib` 后 `agent_compile.sh` 全量重编（partition 库会重建，稍久）。
4. VCS 分区编译产物是一个整体：复制或建立并行运行目录时，不能只复制 `simv`/`simv_verdi`，必须保证对应 `.daidir`、`partitionlib` 等组件完整、自包含且时间戳一致；若副本共享或引用原目录组件，应在副本内重新编译。长测前先做启动检查，日志出现 `Simv is Obsolete` 时立即停止，不得消费该次 trace。

编译和模拟需要时间。运行后读取`core0_gr_trace.dat`，并使用`~/Desktop/{project}/fpga/c2000_tb.v`解释跟踪字段。

### 第2阶段：分析失败

**本阶段是两条分支的汇合点——无论用例来自 `random_test` 还是定向测试，结果判定都在这里做。**

**若结果来自 `random_test`**：数据完整性（覆盖率、跑飞、X 态截断、结束原因、流水线伪阳性）已由它检查并保证，**不要重复做**。直接从它交回的 `results/YYYYMMDD_HHMM/` 目录取 `result.txt`，对末尾的 `DEADLY ERROR` 清单逐条判定。若它报告数据不完整（覆盖率异常、跑飞、被截断），则结果不可用，先解决数据问题再判定。

**先查 `references/knowledge.md`，再动手排查。** 拿到一条差异（尤其是 `DEADLY ERROR`），先对照知识库里已确认的容差与规格：符合的直接判"正确"结案，不要再往下走探针流程。这一步能挡掉大量伪缺陷——例如 TMU 指令的 1e-7 容差、FPU 特殊值以 QX 表为准这两条，历史上就误判过多轮。

**判定前先确认取证正确**：DEADLY ERROR 的实际结果一律取 `Write Back Value (Chip: …, Sim: …)`，**不要拿上下文行当结果**——`movc2g` 那种报告里，首行的 `CR (Chip: …, Sim: …)` 是 `compare.py` 的内部追踪变量，中段的 `set CR at line X` 是前序指令记录，两者都可能"看起来两边一致"而实际结果并不一致。完整格式释义见 `references/knowledge.md` 第四节。读错字段会让后面整条判定链失效。

**trace compare 前先确认格式和起点一致**：如果 mismatch 从第 1 行、表头（如 `GR0`）或启动初始化区就开始，先判定为 trace 过滤/对齐问题，不能把全量 mismatch 当成 RTL 缺陷。复现既有 log 时必须复用原测试脚本的 compare/filter 逻辑（例如是否丢弃 sim 前若干行、是否把三列 trace 转成两列、参考文件是否带表头），并在报告中说明使用的比较入口。**禁止直接复用历史固定跳过行数**：Bootloader 写回数可能随构建变化，必须用反汇编中的首个测试 PC、显式初始化产生的写回序列和 golden 首个寄存器序列共同确定偏移，并抽查对齐后的前几条记录；只有格式和起点对齐后，后续 mismatch 才进入指令级根因分析。

**逐条判定，结论必须落在三选一**：

**判定前还要先看源操作数**：如果这条指令的源操作数两侧就不一致，那它是被上游传导过来的，**不是独立缺陷**——先回溯根因再判。回溯方法与容差误差的放大效应见 `references/knowledge.md` 第五节。

| 判定 | 含义 |
|---|---|
| **正确** | 符合知识库的容差或特殊值规格，不是缺陷 |
| **级联（根因见 #N）** | 本指令按规格正确执行，差异由上游指令传导而来；**必须写明根因编号，不单独计入缺陷数** |
| **硬件 bug** | 芯片行为违反手册/表格的明确规定 |
| **模拟器 bug** | 模拟器行为违反手册/表格的明确规定（QX 表是黄金参考，不是 TI/IEEE） |
| **无法确定** | 手册、表格、知识库都不覆盖 —— 如实这么写，并说明还缺什么证据，不要臆断 |

报告缺陷总数时**排除级联条目**，避免同一根因被重复计数（例如"1 个根因 + 1 个级联"不应报成"2 条待查差异"）。

#### 结论必须同时给出「原文」和「判定表」

**每次测试结束后的结论，必须包含两部分，缺一不可**：

1. **`DEADLY ERROR` 原文** —— 从 `result.txt` **原样摘录**（`grep 'DEADLY ERROR' result.txt`），不要改写、不要节选、不要只留自己认为重要的字段。`movc2g` 那种多行结构要连同 `set CR at line …` 上下文一起贴。
2. **判定表** —— 每条对应原文中的一条，编号一致，列出 PC/指令、芯片值、模拟器值、判定、依据。

**为什么两者都要**：判定表是结论，原文是证据。只给表格，用户无法核对是否读错字段、判错结论——本会话就发生过把 `movc2g` 首行的内部追踪变量当成结果从而误判的情况，正是靠原文才发现。原文让结论可复核。

格式示例：

```
### DEADLY ERROR 原文（results/YYYYMMDD_HHMM/result.txt）

DEADLY ERROR :58 (sinpuf32 GR26 GR12)  ... Write Back Value (Chip: 0x00000000, Sim: 0xa8fa34c5)
DEADLY ERROR :375 (movc2g GR14)  CR (Chip: ..., Sim: ...) last line 360  bit4 CON mismatch
        set CR at line 364 : movg2c GR0
        ...
Write Back Value (Chip: 0x00004010, Sim: 0x00004000)

### 判定表

| # | PC/行 | 指令 | 芯片 | 模拟器 | 判定 | 依据 |
|---|---|---|---|---|---|---|
| 1 | 58 | sinpuf32 GR26 GR12 | 0x00000000 | 0xa8fa34c5 | 正确 | 误差 2.78e-14 ≤ 1e-7 |
| 2 | 375 | movc2g GR14 | CR 0x4010 | CR 0x4000 | 级联（根因 #1） | 两边均按 FDGE 正确置位 |
```

没有 `DEADLY ERROR` 时也要写明"`DEADLY ERROR` 清单为空"，不要省略这一节。

知识库判不了的，再识别第一个失败的时间戳、指令PC、寄存器、信号、断言或不匹配。如果日志直接识别了失败的状态机或信号，则移至根本原因分析。如果症状是静默的错误结果，继续进行受限探测。

**trace 只反映 GR 写回**：跳转（`jmp`/`jnc`）、比较（`ltu`）、`store` 等不写 GR 的指令**本就不产生 trace**。因此判定"core 停止/挂死"前必须用 PC 序列或反汇编对照确认，不能仅凭 trace 停止增长下结论——否则会把"循环未继续""程序正常跑完"误判成"core 挂死"，导致整条归因链失效。

**结案后回写**：如果这次差异得出了新的通用判定结论（新容差、某类指令的规格、某个反复出现现象的定性），把它补进 `references/knowledge.md`，下次就不用重新排查。

### 第3阶段：智能探测循环

探测前，读取相关RTL并形成2-3个具体假设，例如取指/PC错误、解码错误、旁路失败、写回时序、位宽截断或握手死锁。

仅使用强触发条件将临时SystemVerilog`$display`探针插入测试台或顶级RTL。始终通过时间窗口和/或特定PC/指令状态约束探针，以避免日志爆炸。保持探针输出低于1000行。

当用户要求打印CR、flag或control register变化时，必须先在实际RTL中确认目标信号，不要仅凭名称猜测。P65 core0的CR默认指`rtl/swift_core/core_cpu_scale.v`中的`cpu_ctrlReg`；只有当用户明确要求SPR CR或`core_sprs`控制寄存器时，才打印`core_sprs.cr_reg`/`spr_ctrlReg`。报告中要写明探针读取的完整层级路径。

使用此格式：

```systemverilog
if ($time > 10000 && pc == 32'h08000104) begin
  $display("[AGENT_PROBE] Time: %0t, SigA: %h", $time, sigA);
end
```

重新编译和重新运行，然后仅检查`[AGENT_PROBE]`输出和附近的失败日志。如果上游信号已经错误，将下一个探针移动到生产者逻辑更接近的位置。如果上游信号正确，向消费者/写回逻辑方向移动。

最多运行3次探测迭代。如果3次迭代后仍未解决，停止并报告收集的信号状态、假设和用户需要的本地波形或FSDB/VCD区域。

### 第4阶段：定位根本原因

通过编译使用的实际RTL追踪失败的逻辑圆锥。检查由``ifdef`` / ``else``保护的条件实现，并在决定哪个代码路径重要之前确认`include/core_defines.v`或项目编译定义中的活跃宏。

精确命名真正的RTL缺陷：缺少分支、错误的条件、不正确的宽度/符号扩展、陈旧的旁路选择、无效的流水线使能、握手违规、复位/初始化问题或类似情况。

### 第5阶段：修复和验证

修补修复漏洞所需的最小RTL。在最终运行前删除所有临时探针。根据需要将本地RTL更改上传到远程工作区，然后运行最终编译和模拟。

对于FPU、定点/浮点转换、CR/flag、舍入模式或特殊值相关修复，最终验证必须包含定向测试。测试至少覆盖相关舍入模式、正负号、边界输入、overflow/underflow、`+inf`、`-inf`、`+NaN`、`-NaN`中与本次缺陷相关的组合；不能只因为原随机失败消失就判定修复完成。

如果本次修改需要提交 git，在执行 `git commit` 之前必须调用 `dsp-spyglass-lint` skill，对本次准备提交的 RTL/相关设计文件运行 SpyGlass `lint/lint_rtl` 检查。报告中必须写明检查文件、prj/日志/报告路径、error/warning 数量，以及是否有消息落在本次修改文件或修改行附近。

除非最终回归通过或相关失败消失且剩余问题显然无关，否则不要声称成功。

## 报告

已完成调试工作的最终报告必须使用此结构：

- **失败症状**：总结原始失败命令、日志、跟踪不匹配、时间戳和PC（如果已知）。
- **调试过程**：总结关键探针或跟踪检查以及每个所揭示的内容。
- **根本原因**：识别RTL文件和行、相关的活跃宏路径以及确切的逻辑错误。
- **修复和结果**：显示基本代码更改并说明最终编译/模拟结果；若涉及FPU/转换/flag/舍入/特殊值，列出定向测试覆盖点和实际结果。
- **提交前检查**：如果进行了 git 提交，说明 `dsp-spyglass-lint` 的 SpyGlass lint 结果、报告路径，以及是否存在本次修改相关消息。

## 硬规则

- **消费任何 `core0_gr_trace.dat` / result 前，必须确认 `simv_verdi` 是由当前 RTL 完好重编的产物。** `run_p65_test.sh` 等脚本直接跑预编译 `./simv_verdi` 不重编；改过 RTL 后必须先重编（`agent_compile.sh`）再跑，否则跟踪反映的是编译 simv 时的旧 RTL，归因会完全跑偏（典型坑：明明当前 RTL 已修复，却因旧 simv 复现出“bug”）。判据（**仅 mtime 不够**，磁盘满会静默产出坏 simv 且 mtime 仍是新的）：① `simv_verdi` 修改时间晚于相关 RTL（尤其 `rtl/swift_core/*.v`）；② `comp_verdi.agent.log` 有 `DONE_RC=0` 且无 `corrupted` / `No space left`；③ `df` 显示磁盘仍有余量。任一不满足、或不确定，就重编。**A/B 对照时这三条仍不够**：VCS 见源文件内容与上次编译相同就不重编，会让两版跑出完全一样的结果、得出"两版无差异"的反向结论（本会话踩过）。对照实验必须让探针自带版本指纹——打印被改信号的实际取值或脉宽（如 `spr_write_o` 是 3 拍还是 1 拍），用输出本身确认跑的是哪一版。
- 除非凭证、缺少的文件、破坏性操作或未解决的歧义阻止进展，否则不要在阶段之间要求确认。
- 每次提交 git 代码之前，必须先完成 `dsp-spyglass-lint` 的 SpyGlass lint 检查；如果 SpyGlass 无法运行或结果仍有本次修改相关 error/warning，必须说明阻塞原因并暂停提交，除非用户明确要求强制提交。
- 每次 P65 测试前都必须 `grep` 出`~/Desktop/p65/fpga/c2000_tb.v`的有效仿真超时行并确认其准确为`#80000000`（80ms），同时确认超时分支最终调用`$finish`。不一致时先修正、再次核对并重新编译，之后才能运行测试；不得复用由其它超时值编译出的`simv`。其它项目则检查有限且合适的超时。
- 从不在最终RTL中留下临时探针。
- CPU1(core1) 测试不得直接套用 core0 的装载路径与跳转写法（core0 的 `outer_insn_mem_core0.dat` + `.=1024` + `jmp` 三点对 CPU1 全部不适用）；走 `dsp-cpu1-test` skill。判定"CPU1 没跑起来"前先确认 `cpu1_sysrsn` 是否已由 core0 释放。
- 依赖 `posedge clk` 的计数探针，在目标核/协处理器时钟未运行时会全为 0，产生假阴性（CLA 侧曾因此连续 5 轮误判）。存疑时补一个不依赖时钟的采样兜底：`initial begin forever begin #200; if (sig) cnt = cnt + 1; end end`。
- 如果为临时探针重编了远程 `simv`/`simv_verdi`，任务结束前必须恢复原 RTL 和原仿真产物（至少包括 `simv`/`simv_verdi` 及其 `.daidir`），或明确说明保留探针版产物的位置和原因；恢复后用 `grep` 等方式确认临时探针标记已从最终 RTL 中移除。
- 从不添加无限制的`$display`或`$monitor`。
- 保持探针日志低于1000行。
- 不要修改不相关的RTL。
- 不要还原用户更改。
- 3次不成功的探测迭代后停止，并请求人工波形支持。

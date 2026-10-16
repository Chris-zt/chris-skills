---
name: dsp-cpu1-test
description: >-
  QX DSP P65 在 CPU1(core1) 上跑测试程序的方法论。用于让 CPU1 启动、执行指定汇编、稳定循环运行，
  以及配套的 tb trace 打印准备。**只要用户提到"在 CPU1 上跑""测 core1""CPU1 跑不起来"
  "core1 没有 trace""LCM/lockstep 测试""cpu1_sysrsn""CPU2RESCTL""core1.iram_image.bootloader"
  "autotest_lcm.py"，或需要构造 core1 的测试镜像，就使用本 skill**——即使用户没有明说"skill"。
  不要与偏 core0 的 dsp-kernel-auto-verification 混淆：本 skill 只负责 CPU1 侧的启动与程序装载；
  编译、探针、判定、报告仍走主 skill 的流程。
---

# P65 CPU1(core1) 测试方法论

在 P65 上让 **CPU1 跑起指定测试程序**。环境、编译、探针、判定、报告沿用
`dsp-kernel-auto-verification`；本 skill 只覆盖 CPU1 特有的启动与装载部分。

**证据分级**：本文标注 ✅ 的为实测验证过；标注 ⚠️ 的为绕过方案；标注 ❌ 的为已知不通/未解决。
不要把绕过方案当成标准做法传播。

## 三个必要条件（缺一不可，均已实测 ✅）

### 1. CPU0 必须先释放 CPU1 的芯片级复位

CPU1 的复位由 `CPU2RESCTL` 寄存器控制，**复位默认值为 1（保持 CPU1 复位）**，必须由 core0
主动写寄存器放开。不做这一步，`cpu1_sysrsn` 恒为 0，CPU1 一条指令都不会执行。

RTL 依据（`rtl/sys_ctrl/p659_dev_reg.v`）：

```verilog
assign CPU1RESCTL = CPU2RESCTL[0];                    // 904 行
CPU2RESCTL[0] <= 'b1;                                 // 1833 行：复位默认 = 保持复位
if(cpu0_write & CPU2RESCTL_EN & (cpu0_pwdata[31:16] == 16'ha5a5))
    if(&cpu0_pstrb)  CPU2RESCTL[0] <= cpu0_pwdata[0]; // 1838 行：需 a5a5 密钥 + 全字节使能
```

core0 侧固定模板（写 `0x010700F4 = 0xa5a5_0000`）：

```asm
.global start
_begin:
start:
.text
boot:
.=1024

movigh GR0 0x0107||
movigl GR0 0x00F4||
movigh GR1 0xa5a5||
movigl GR1 0x0000||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
||store32 GR1 GR0 0x00
nop||
nop||
nop||
nop||
nop||

loop1:
nop||
jnc loop1||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||
```

汇编后放到 `~/Desktop/p65/vcs/outer_insn_mem_core0.dat`。

验证方法：在 `c2000_tb.v` 加临时探针采样，应看到 `cpu1_sysrsn` 由 0 变 1：

```systemverilog
$display("[AGENT_PROBE] cpu0_sysrsn=%b cpu1_sysrsn=%b",
         tb.dsp_c2000.u_c2000_digital.cpu0_sysrsn,
         tb.dsp_c2000.u_c2000_digital.cpu1_sysrsn);
```

### 2. CPU1 程序装到启动地址 `0x282000`，用 `.=0` ⚠️

把 CPU1 的程序镜像写入 `~/Desktop/p65/vcs/core1.iram_image.bootloader.dat`
（`c2000_jtag.v` 用 `init_bootmem_fast(..., 32'h0028_2000)` 加载到 `0x282000`）。

汇编源必须用 **`.=0`**（无偏移）：

- `.=1024` 会让文件前 1024 字节全为 0，CPU1 从 `0x282000` 取指时执行非法指令直接挂死
  （实测 trace = 0 行）
- `.=0` 时代码从文件首字节开始，CPU1 上电即执行（实测 PC 从 `0x282000` 起连续推进）

**这是绕过方案**，见下方"未解决项"。

### 3. 循环必须用 `ltu` + `jnc`，不能用 `jmp` ✅

`jmp` 与 `jnc` 的语义完全不同，这是 CPU1 程序无法持续运行的最常见原因。

| 指令 | 语义 | 能否回跳 |
|---|---|---|
| `jmp X` | 相对跳转，目标 = `PC + 4 + X×4`，**只能向前** | ❌ |
| `jnc label` | 条件跳转，支持负偏移（补码），可向后 | ✅ 但需先设条件 |

反汇编实证（`./assember/objdump -D xxx.o`）：

```
jmp 0x8    源 0x960 → 目标 0x984     偏移 0x24
jmp 0x10   源 0x960 → 目标 0x9a4     偏移 0x44
jmp 0x100  源 0x960 → 目标 0xd64     偏移 0x404
jmp 0x400  源 0x960 → 目标 0x1964    偏移 0x1004
jmp 0x0    源 0xc80 → 目标 0xc84     ← 立即数 0 = 跳到下一条，等于 nop
jnc loopstart   c80: 83 ff 9b e9   jnc 0 <start>   ← 0xff 为负偏移补码，正确回跳
```

**关键坑**：`jnc` 是条件跳转（jump if no carry）。`movigh`/`movigl` 会改变 carry，
导致条件不满足、跳转不发生（实测：`jnc` 编码正确指向循环起点，但运行时不跳，程序跑完一遍即停）。
必须在 `jnc` 前用 `ltu` 显式设置条件：

```asm
movigh GR26 0x0000||
movigl GR26 0x0002||        ; GR26 = 2
movigh GR27 0x0000||
movigl GR27 0x0001||        ; GR27 = 1
loopstart:
    <循环体：任意指令>
ltu GR26 GR27||             ; 2 < 1 为假 → carry=0 → 条件满足
jnc loopstart||
nop||
nop||
```

core0 模板里 `loop1: nop×6; jnc loop1` 能裸跳，是因为循环体是纯 `nop` 不改标志；
一旦循环体含运算指令就必须显式设条件。`autotest_lcm.py` 的 LCM 前导代码同样是
`sub` → `ltu` → `jnc` 的写法，可作旁证。

## 跑之前先查数据镜像大小 ⚠️

`outer_data_mem_core0.dat` / `outer_data_mem_core1.dat` 若过大，会**覆盖掉指令区**，
让两个 core 都去执行数据。地址图（`vcs/ldscript_Memory.vh`）：

| 区域 | 地址 |
|---|---|
| `SRAM_CORE0_DATA` / `SRAM_CORE0_INST` | `0x00010000` / `0x00028000` |
| `SRAM_CORE1_DATA` / `SRAM_CORE1_INST` | `0x000A0000` / `0x000B8000` |
| `BOOT_RAM_CORE0` / `BOOT_RAM_CORE1` | `0x00280000` / `0x00282000` |

data 与 inst 只隔 `0x18000`（98304 字节 = 12288 行），**data 镜像超过约 12000 行就会盖到指令区**。
实测踩过：遗留的 50128 行镜像（≈`0x61E80`）把 core0 的 `0x28000` 和 core1 的 `0xB8000` 全盖掉，
表现为 core0 的 PC 在 `0x15000`~`0x31000` 乱窜、trace 涨到 46639 行（在执行数据），
换成 26 行的版本后 trace 降到 47 行、PC 立刻稳定。

参考基线：`/lx5data/projectdata/dspproject/lixiang/zhaotao_time/vcs/outer_data_mem_core0.dat` 只有 26 行。
不需要数据初始化的用例，直接用这个小文件即可。

## 汇编约束（踩过的坑）

- **访存指令的槽位由竖线位置决定**，写错槽汇编器就报错：
  - `||op` = s2 槽，如 `||store32 GR1 GR0 0x00`
  - `|op|` = s1 槽，如 `|load32 GR8 GR6 0x0|` ← **`load32` 必须这样写**
  - `op||` = s0 槽
- **`load32` 可用**（曾被误记为"汇编器拒绝"，实为槽位写法不对）。`load32`/`loado32`/
  `load16`/`load8`/`loadi32` 等在 lixiang 的 `load_store/` 用例里大量出现（`load32` 226 次、
  `store32` 674 次），CLA 侧同样可用。core 侧要读 SPR（构造读冲突用例）就靠它
  （`syntax error`）。需要制造 SPR 访问时用"写 SPR"而非"读 SPR"
- **标签跳转在 `.=0` 下会跳飞**：`jnc <label>` 的 label 地址是相对文件开头的小值，
  而实际 PC 在 `0x282xxx`。用上面的 `ltu`+`jnc` 写法（同一程序内回跳）才正确
- 避免使用 GR30/GR31

## tb 侧准备：core1 的 trace 打印

`fpga/c2000_tb.v` 里 core1 的 trace **默认不完整**：只有 4 条 `$fwrite`（缺 `wen1_s0`）
且**不带 PC**，而 core0 有 5 条且带 PC。需要补齐才能做 PC 级分析。

需要新增的信号（对照 core0 的 `_core_0` 版本）：

```systemverilog
`ifdef DCG
       wire rfgr_wen1_s0_core_1 = ...cpu1.core.core_cpu_scale.rfgr.wen1_s0_BAR;
`else
       wire rfgr_wen1_s0_core_1 = ...cpu1.core.core_cpu_scale.rfgr.wen1_s0;
`endif
wire [4:0]rfgr_waddr1_s0_core_1 = rfgr_waddr_s0_core_1 + 1'b1;
wire [31:0]rfgr_din1_s0_core_1  = ...cpu1.core.core_cpu_scale.rfgr.din1_s0;
```

PC 层次路径应与 core0 对称：`cpu1.core.core_cpu_scale.core_m3_scale.me3_current_pc`

`$fwrite` 补齐为 5 条、统一带 PC（格式 `"0x%h\t0x%h\t0x%h\n"` = addr / pc / data）。

**注意**：原生 `P65_NTO` 环境的 tb 同样没做这个同步（core1 trace 只有两列），
所以这是本地改进，不是从上游继承的。

## 完整可用示例（实测 ✅）

CPU1 上稳定循环运行 800 条指令：

```bash
# 1) core0：释放 CPU1 复位（用上面的固定模板）
cd ~/Desktop/p65/assember_linux
python3 tr3.py core0_release_cpu1.s

# 2) core1：生成长程序 + ltu/jnc 循环
{
echo ".global start"; echo "_begin:"; echo "start:"; echo ".text"; echo "boot:"; echo ".=0"
echo "movigh GR26 0x0000||"; echo "movigl GR26 0x0002||"
echo "movigh GR27 0x0000||"; echo "movigl GR27 0x0001||"
echo "loopstart:"
i=1
while [ $i -le 400 ]; do
  r=$(( (i % 24) + 1 ))
  printf "movigh GR%d 0x%04x||\n" $r $(( (i*7919) % 65536 ))
  printf "movigl GR%d 0x%04x||\n" $r $(( (i*10729) % 65536 ))
  i=$((i+1))
done
echo "ltu GR26 GR27||"; echo "jnc loopstart||"; echo "nop||"; echo "nop||"
} > cpu1_loop.s
python3 tr3.py cpu1_loop.s

# 3) 先编译，再装镜像（编译会重置镜像！）
cd ~/Desktop/p65/vcs && bash agent_compile.sh
cp ~/Desktop/p65/assember_linux/core0_release_cpu1.dat outer_insn_mem_core0.dat
cp ~/Desktop/p65/assember_linux/cpu1_loop.dat          core1.iram_image.bootloader.dat

# 4) 跑
./simv_verdi </dev/null > run.log 2>&1

# 5) 验证：trace 行数 >> 指令数，且 PC 唯一值 = 指令数，即为稳定循环
wc -l core1_gr_trace.dat
awk '{print $2}' core1_gr_trace.dat | sort -u | wc -l
```

实测结果：`trace 41111 行 / PC 唯一值 804`（800 循环体 + 4 初始化）→ 约 51 轮循环，
仿真未结束时仍在增长。

## 未解决项 ❌（不要当成已解决）

### 标准两级加载流程不通

按 `autotest_lcm.py` 的正规流程，core1 程序应装 `outer_insn_mem_core1.dat`，由 bootloader
跳到 `SRAM_CORE1_INST = 0x000B8000` 执行。实测 **CPU1 从不跳过去**，PC 恒在 `0x282xxx`：

- 装我写的程序 → trace 12862 行
- 装加了 LCM 前导的程序 → trace 12862 行（完全相同）
- 装 **P65_NTO 官方 12580 字节镜像** → trace 12862 行（完全相同）

trace 行数与镜像内容**完全无关**，说明执行的是固定 bootloader 流程。

**原因已定位（2026-08-16）**：现有 core1 bootloader（540 字节，md5 `c06dbb14eff8b50b7705701123ea112e`，
`/lx5data/.../zhaotao_time/vcs`、`~/Desktop/p65_nto_full`、`p65_nto_test` 四处副本完全相同）
是按**另一套内存布局**编的，与当前 `ldscript_Memory.vh` 不符：

- 它构造的跳转目标是 `0x000F8400`，而当前地址图是 `SRAM_CORE1_INST = 0x000B8000`（程序体在 `0xB8400`）
- 它设的栈是 `0x0008fbe0`，而当前 `SRAM_CORE1_DATA = 0x000A0000`

PC 探针显示它执行到 `0x2820d0` 的 `jalr GR4`（`GR4=0x000f8400`、`GR31=0x002820d8`）后
**取指失败、PC 就此卡死不动**，从未跳到用户程序 —— 这正是"trace 与镜像内容无关"的原因。
对照 core0 bootloader 的 GR30 序列 `0x00020000 → 0x00028000 → 0x00027fc0`，与地址图严丝合缝。
两者日期也差 9 天（core1 是 7/4，core0 是 7/13）。

因此"装到 `0x282000`"仍是**绕过**，但已不是盲目绕过：标准流程要通，需要一份与当前
地址图匹配的 core1 bootloader，而现存四份副本都不满足。

### 原生环境的基线

曾怀疑是 `zhaotao_time` 分支缺 CPU1 支持。已完整复制 `/lx4data/lixiang/P65_NTO`
（分支 `P65_NTO_SMIC55`）并**重新编译**验证（注意：直接复制 `simv` 不可用，内含 34 处
`/lx4data` 硬编码路径，必须在副本内重编）—— 原生环境下 CPU1 **同样只跑 26 行**。

**结论：假设被证伪**。这套 tb 里 CPU1 可能本就不承担独立长程序运行的角色（LCM 模式下
它做 lockstep 一致性比较）。排查同类问题时，**先在原生/参考环境确认基线行为**，
不要默认"参考流程能直接移植到当前分支"。

## 参考资料位置

- LCM 自动测试脚本：`/lx5data/projectdata/dspproject/lixiang/TMU_testcase/core_testp65/autotest_lcm.py`
  - 内含 `LCM_CORE0_ASM`（core0 固定模板）与 `LCM_CORE1_INJECT`（core1 前导：延时等待 +
    写 `0x01098000` 启动 lockstep 比较）
  - 流程：core0 模板 → `outer_insn_mem_core0.dat`；用户程序注入前导 → `outer_insn_mem_core1.dat`
  - 该脚本的实际验证环境是 `/lx4data/lixiang/P65_NTO`、分支 `P65_NTO_SMIC55`
    （见其 `running.log` 的 `QX_PATH` 记录）
- 参考 vcs 环境：`/lx5data/projectdata/dspproject/lixiang/zhaotao_time/vcs`
  （含非空的 `core1.iram_image.bootloader.dat`，540 字节）

## 硬规则

- **不得把 core0 的装载路径和跳转写法直接套用到 CPU1**：core0 用 `outer_insn_mem_core0.dat`
  + `.=1024` + `jmp 0x400` 可循环；CPU1 这三点全都不适用
- **先编译、再装镜像、再跑仿真**：`agent_compile.sh` 会重置 `outer_insn_mem_*.dat`
- **判定"CPU1 没跑起来"前，先确认 `cpu1_sysrsn` 是否为 1**：绝大多数"CPU1 不工作"
  都是 core0 没做复位释放，而不是程序或 RTL 的问题
- **依赖 `posedge clk` 的计数探针在目标核时钟未运行时全为 0**，这会产生假阴性
  （CLA 侧曾因此连续 5 轮误判）。存疑时补一个不依赖时钟的采样兜底：
  `initial begin forever begin #200; if (sig) cnt = cnt + 1; end end`
- 判定 CPU1 行为异常前，先在原生/参考环境跑同一批镜像确认基线，不要默认参考流程可移植

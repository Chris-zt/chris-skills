# 判定知识库

本文件是**判定标准的唯一来源**。分析任何 RTL vs 模拟器差异之前，**先来这里查**——很多"看起来像 bug"的现象，这里已经有定论，不需要重新排查。

**所有结果判定都在本 skill 完成**，无论用例来自定向测试还是 `random_test` 的随机回归（`random_test` 只负责跑出可信数据和数据完整性检查，不做缺陷归因）。因此判定规则**只写在这里**，不要散落到 SKILL.md 正文或其它 skill 里——历史上规则分散在两处，导致 TMU 容差没能作用到随机测试上，白白多排查了好几轮。

**维护规则**：每当用户确认了一条新的判定标准（容差、特殊值规格、已知设计特性），立刻写进本文件，并注明来源和确认日期。规则要可执行——写清楚"什么情况下判什么"，而不是泛泛的经验。

---

## 〇、判定优先级（按顺序查，命中即结案）

一条差异摆在面前，按这个顺序走，不要跳步也不要三个来源轮流试：

| 顺序 | 查什么 | 命中后 |
|---|---|---|
| **①** | **容差规则**（本文件第一节等） | 数值差异先按容差判。在容差内 → **判"正确"，直接结案**，不再查表、不再排查 |
| **②** | **特殊值表**（`references/tables/`） | 输入是 ±0 / ±Inf / NaN / denorm 这类特定值时查表。表里有明确条目 → 按表判"硬件 bug"或"模拟器 bug" |
| **③** | **指令手册**（`references/manuals/Instruction_Set.doc`） | 查功能定义、限制条件、异常规定。手册有明文 → 按手册判 |
| **④** | 以上都不覆盖 | **判"无法确定"**，写清楚缺什么证据（例如"需要 TMU 内部定点位宽规格"），不要臆断，也不要因为"看起来不合理"就报成 bug |

**为什么容差排第一**：绝大多数数值差异是精度问题而非功能错误。先按容差筛一遍，能直接结案的就不必再查表查手册。反面教材：曾对同一个 `atanpuf32` 现象依次查了手册（异常栏空白）、FPU 表（无该指令）、TMU 表（无极小规格化数档）三处仍判不了，最后发现只是 1e-7 容差内的正常误差。

---

## 一、TMU 指令：允许误差，绝对误差 ≤ 1e-7 判为正确

**来源**：用户确认（2026-07-22）

TMU 是近似计算单元（定点/查表实现），**不保证与浮点精确计算逐位一致**。判定标准：

> **|芯片结果 − 模拟器结果| ≤ 1e-7 → 判为正确，不是 bug。**

适用指令（手册 3.7 节 TMU 指令）：
`SINPUF32`、`COSPUF32`、`ATANPUF32`、`QUADF`、`MPY2PIF32`、`DIV2PIF32`、`EXPPUF32`、`LOGPUF32`、`FSSQRT`、`FSEINV`、`FSEISQRT`

**为什么是 1e-7**：float32 的机器精度 ε≈1.19e-7，TMU per-unit 函数结果落在 [-1,1]，所以 1e-7 相当于结果满量程下的最后一位精度。

### 典型表现：芯片返回 0，模拟器返回极小非零值

这是最常见的形态，**全部属于正常**：

| 指令 | 芯片 | 模拟器 | 绝对误差 | 判定 |
|---|---|---|---|---|
| `atanpuf32` | 0 | 3.64e-10 | 3.64e-10 | ✓ 正确 |
| `atanpuf32` | 0 | 2.72e-10 | 2.72e-10 | ✓ 正确 |
| `atanpuf32` | -5.0172e-07 | -5.0176e-07 | 3.71e-11 | ✓ 正确 |
| `sinpuf32` | 0 | 1.04e-37 | 1.04e-37 | ✓ 正确 |
| `sinpuf32` | -2.2212e-07 | -2.2295e-07 | 8.28e-10 | ✓ 正确 |
| `sinpuf32` | 8.758106e-04 | 8.758108e-04 | 1.75e-10 | ✓ 正确 |

芯片对极小输入做量化归零，与 TMU「输入 denorm 视为 0」的设计一致，方向正确。

### 判定脚本

```python
import struct
def f32(h): return struct.unpack(">f", struct.pack(">I", h))[0]
def tmu_ok(chip_hex, sim_hex, tol=1e-7):
    return abs(f32(chip_hex) - f32(sim_hex)) <= tol
```

### 注意

- `compare.py` 的 `FPU_ULP_TOLERANCE = 2`（2 ULP）对 TMU **过严**，会把正常结果误报成 `DEADLY ERROR`。看到 TMU 指令的 mismatch，先按 1e-7 绝对误差复核，不要直接当缺陷上报。
- 超过 1e-7 才需要进一步排查。

---

## 二、TMU 特殊值规格（来源：`references/tables/049-finalTMU_sepcial.xlsx`）

判定 TMU 特殊值行为时**以该表为准**，不要套通用 IEEE-754。表中贯穿多条指令的统一规格：

- **输入 denorm 视为 0** —— 结果按输入=0 计算，且 **LUF/LVF 均不置位**。
- **输入 NaN 视为 Inf** —— TMU 不生成 NaN 值。
- **只有真下溢才置 LUF** —— 例：`DIV2PIF32` 输入最小规格化数 `0x00800000` 结果 0 且 LUF=1；denorm 输入结果也是 0 但 LUF=0。**"结果为 0"本身不代表下溢，要看 LUF。**
- `ATANPUF32`：`Inf→0.125`、`-Inf→-0.125`、`±0→0`、`±1→±0.125`、`denorm→0`；Inf/NaN 输入置 **LVF=1**。

表的列结构：`指令 | 数据 | 数据表示 | 结果 | LUF | LVF | ti理论结果 | ti实际结果 | ti_LUF | ti_LVF`（左半 QX 实测，右半 TI 参考）。

---

## 三、FPU 特殊值：以 QX 表为准，不以 TI/IEEE 为准

**来源**：`references/tables/FPUsepcial.xlsx`、`FPU64sepcial.xlsx`

两表结构均为 `QX结果` / `TI结果` / `是否一致` 逐值对照，**明确接受 QX 与 TI 不一致**。这意味着**特殊值行为以 QX 芯片为黄金参考**。

- ±0 的符号位、±inf/NaN 的符号，在 QX 与 TI 之间存在**系统性差异**，是记录在案的设计特性，不是 bug。
- 因此模拟器(ISS)在这些点上与芯片不一致时，**优先怀疑模拟器未按 QX 规格实现**。
- 注意：单精度表中 `fsmul`/`fsdiv`/`fseinv`/`fseisqrt`/`fssqrt` 的 `qx结果` 列**尚未填写**（只有 TI 值），这些行的 `是否一致=False` 是待填占位，**不能当成"已确认不一致"**。

---

## 四、`result.txt` 的 DEADLY ERROR 怎么读（取证规则）

**判定之前先确认取证正确——读错字段，后面的判定全错。**

### 铁律：`Write Back Value` 才是被判定指令的实际结果

一条 DEADLY ERROR 可能有好几行，但**只有 `Write Back Value (Chip: …, Sim: …)` 是这条指令的执行结果**。其余各行都是辅助上下文，**不能拿来下结论**。

### `movc2g` 的三段式结构（最容易读错，逐段释义）

```
DEADLY ERROR :375 (movc2g GR14)    CR (Chip: 0x00004000, Sim: 0x00004000) last line 360   bit4 CON mismatch
        set CR at line 364 : movg2c GR0
        GR0 (Chip: 0x00004000,  Sim: 0x00004000)

        set CR at line 367 : fdge GR20 GR12
        GR20 (Chip: 0xfffffc3e, Sim: 0xfffffc3e)   GR12 (Chip: 0xe39579de, Sim: 0xe39579de)
Write Back Value (Chip: 0x00004010,  Sim: 0x00004000)
```

| 段 | 内容 | 含义 | 能不能当结果 |
|---|---|---|---|
| **首行** | `CR (Chip: …, Sim: …) last line N` | `compare.py` 的**内部追踪变量** `CHIP_CR`/`SIMULATION_CR`，`N` 是上次 CR 被写的行号 | ❌ **不是本条结果**。它可能两边相同而实际结果不同 |
| **中段** | `set CR at line X : <指令>` + 各操作数两侧值 | 本条之前**所有可能改动 CR 的指令**及其两侧操作数，用于**追溯谁改错了 CR** | ❌ 是线索，不是结果 |
| **末行** | `Write Back Value (Chip: …, Sim: …)` | `movc2g` 读回的 CR 实际值 | ✅ **判定依据** |

上例中首行两侧都是 `0x4000` 看着"一致"，但末行 `Chip=0x4010 / Sim=0x4000` 才是真相——**确有 CON 位差异**。曾据首行误判成"两边一致、无法确定"，属于取证错误而非判定错误。

**中段的用法**：找操作数两侧完全一致、却导致 CR 结果不同的那条指令——嫌疑直接锁定它的标志置位逻辑。上例中 `movg2c GR0` 和 `fdge GR20 GR12` 两侧输入全部相同，而其后 CON 不同，故嫌疑指向 `fdge` 的 CON 置位。

### `bitN XXX mismatch` 的来源

由 `compare_cr_bits(写回值1, 写回值2)` 对**两侧写回值**做 XOR 得出（`compare.py:146`），**只扫低 16 位**。所以 `bit4 CON mismatch` ⇔ 两个 `Write Back Value` 的 bit4 不同。

### CR 位含义表（来源 `compare.py:70` `CR_DIRCT`）

| bit | 名称 | | bit | 名称 |
|---|---|---|---|---|
| 0 | CF | | 7 | OF |
| 1 | LUF（下溢） | | 8–13 | OVC |
| 2 | LVF（上溢） | | 14 | EALLOW |
| 4 | CON | | 3/6/15/16 | 未定义 |
| 5 | OVM | | | |

---

## 五、差异传导与级联识别

### 铁律：判定任何差异前，先检查该指令的**源操作数两侧是否一致**

源操作数不同 → **这是级联差异，必须回溯根因，不得当独立缺陷判定**。逐条独立判定对传导来的差异必然给出错误结论（要么误报成 bug，要么判成"无法确定"）。

### 回溯方法

在 `result.txt` 里往前找源寄存器最后一次写回，逐级追到两侧首次分叉的那条指令：

```bash
# 找 GR21 在第 367 行之前的最后一次写回
awk -v pat="0x15(GR21)" 'NR<367 && index($0,pat)>0 {last=NR": "$0} END{print last}' result.txt
```

双精度指令要连高 32 位一起查（`{GR[Rs+1], GR[Rs]}`，即 `fdge GR20` 要同时查 GR20 和 GR21）。

### ⚠️ 容差误差的放大效应（反直觉，最容易漏）

**"某条差异在容差内判正确"不等于"它不会在下游制造 DEADLY ERROR"。** 容差内的合法误差落到下列位置会被放大成质变：

| 落点 | 后果 |
|---|---|
| **双精度数的高 32 位** | 改变符号位/指数 —— 误差从 1e-14 量级直接变成 1e+200 量级，甚至正负反号 |
| **比较指令的操作数** | 布尔量翻转（CON / ZF / NF） |
| **分支条件** | 控制流分叉，后续全部错开 |

### 实例（2026-07-22 实测，完整数据流）

```
line 58   sinpuf32 GR26 GR12      GR26: chip=0x00000000  sim=0xa8fa34c5
                                   ↑ TMU 容差内的合法差异（误差 2.78e-14 ≤ 1e-7）
             │ （58→304 之间 GR26 未被改写）
             ▼
line 304  mulu32 GR21 GR26 GR28   GR21: chip=0x00000000  sim=0xa8fa34c5
             │ 差异传导到双精度高 32 位
             ▼
line 367  fdge GR20 GR12          比较 {GR21,GR20} >= {GR13,GR12}
             │ 芯片侧 = +2.122e-314（正）  模拟器侧 = -2.724e-111（负！符号位被改）
             ▼
line 375  movc2g GR14             CR: chip=0x4010(CON=1)  sim=0x4000(CON=0)
```

两边都严格符合手册 `FDGE` 规定，**都没错**。这条 CR 差异的正确判定是「级联，根因 = line 58」，而不是缺陷。

---

## 六、浮点比较指令与 CON 标志

**来源**：指令手册（`FDGE` 见手册 3083–3090 行，`CR[4] CON` 定义见 359 行），2026-07-22 查证。

- `FDGE Rs, Rt`：`IF {GR[Rs+1],GR[Rs]} >= {GR[Rt+1],GR[Rt]} → CON = 1；ELSE CON = 0`。同类还有 `FSLE`/`FSGT`/`FSEQ`/`FSGE`/`FSLT` 等。
- `CR[4] CON`：**标量比较指令的结果**，比较成立置 1、否则置 0；**当前不是比较指令时该位保持不变**。CR[4] 对应 slot0。

**判定 CON 差异的正确顺序**：先回溯比较指令的源操作数（双精度要查寄存器对）——**两侧操作数一致，才谈得上 CON 置位逻辑有问题**；操作数不一致就是级联，去查上游。

---

## 七、FPU/FVCU 默认舍入模式

**来源**：用户确认（2026-07-31）

- FPU 中除 FVCU 模块以外的指令默认使用 **RNE（舍入到最近偶数）**。
- FVCU 模块中的 `FCVTDS` 是例外，默认使用 **RNE**。
- FVCU 模块中除 `FCVTDS` 外的其它指令默认使用 **RTZ（向 0 舍入）**。
- 判定 `FCVTDS` 的有限正常大数转单精度溢出时，默认 RNE 的期望结果是同符号无穷大（`+Inf=0x7f800000`、`-Inf=0xff800000`）；芯片返回 ±Inf、模拟器返回同符号最大有限单精度数（`+FLT_MAX=0x7f7fffff`、`-FLT_MAX=0xff7fffff`）时，判为**模拟器 bug**。
- 只有用例明确修改舍入配置，并且已有执行单元消费者侧的 `RND`/`RND32`/`RND64` 证据时，才覆盖上述默认值；仅凭配置寄存器写入或读回不能覆盖默认判定。

## 八、P65 `QUADF` 会错误清除 CR.CON（RTL bug）

**来源**：P65 RTL 静态分析与定向 VCS 复现（2026-07-31）

若 `result.txt` 中出现 `movc2g` 的 bit4 CON mismatch，且其前序是成立的比较指令、随后执行了 `QUADF`，优先检查该已知 RTL bug：

- 指令手册只规定 `QUADF` 计算 ratio/quadrant，不定义 CON；根据 CR.CON 规则，非比较指令必须保持 CON。
- P65 `core_id_dcdOp100_s0.v` 用 `funct[7:6] == 2'b00` 生成 `tst`，误把功能码 `8'b0000_1111` 的 `QUADF` 也标记为比较指令。
- `core_ex2.v` 在 `ex1_tst=1` 时选择 ALU 的 `CON_s0`；`QUADF32` 不在标量 ALU 的 CON case 中，因此走 default 输出 0，最终清除原有 CON。
- 定向用例：CR 清零后执行恒成立的 `eqi GR18, 0x004b`，首次 `movc2g` 读到 `0x00004010`；再执行有限数 `quadf GR12, GR27, GR7`（1.0、2.0），第二次 `movc2g` 读到 `0x00004000`。这证明 EQI 正确置位，而 CON 在 QUADF 后被硬件错误清零。

判定：输入和控制流满足上述条件时，判为**芯片/RTL bug，模拟器保持 CON 的行为正确**。修复方向是让 `QUADF` 的 `tst=0`，即 `tst` 只覆盖真正的比较/TEST 类功能码，不能仅按 `funct[7:6]` 粗分。

## 九、P65 `COSPUF32` 对 biased exponent 149 的输入错误归零（RTL bug）

**来源**：随机测试与 RTL 静态分析（2026-07-31）

若 `COSPUF32` 输入是正常有限 float32、biased exponent 为 149，且输入仍带 `0.5` 小数，P65 可能错误返回 `+1.0`：

- 实例：输入 `0xcac23317 = -6363531.5`，小数部分为 `-0.5`。按手册 `COS(2π·Rs)`，期望严格为 `-1.0 (0xbf800000)`；芯片返回 `+1.0 (0x3f800000)`，模拟器返回 `-1.0`。
- 根因：`core_ex1_sin_s0.v` 的 `zero_flag` 使用 `exp>=149`，把 exp=149 的输入提前当成 0；但 float32 在该指数仍有 0.5 ULP，不能统一按整数处理。
- 同文件下一行的移位逻辑明确支持 `exp<150`，进一步证明边界应覆盖 exp=149。

判定：该模式属于**芯片/RTL bug，模拟器正确**，且绝对误差 2 远超 TMU 的 1e-7 容差。修复方向是把大指数归零门限由 `exp>=149` 改为 `exp>=150`，并用整数和半整数边界用例回归。

## 十、共享 RAM 波形取证：`ram_bank.addr` 命中 ≠ 有写动作

**来源**：SysCtl_isPLLValid / `fclk1_0ratio(0x805c)` “写不进去” 复核（2026-09-01，判定为**不存在该缺陷**）

排查“某地址写不进去”类波形问题前，先套用下面三条，能挡掉大部分伪缺陷：

1. **`ram_bank` 的 `addr` 是 fetch/load/store 三者共享的单一端口**（`rtl/ram_ctrl/ram_bank.v` 只有一个 `addr`，靠 `fetch_en`/`load_en`/`store_en` 区分）。
   因此波形上看到 `addr == 目标地址` 而 `store_en` 为低，**只说明这是一次读访问**，不能作为“写被丢掉”的证据。程序里凡是把该变量读回来用的（如 `dccCounterSeed1 = window * fclk1_0ratio`）都会产生这种地址命中。
2. **bank 索引 = `addr[19:15]`**（`BANK_ADR_HIGH=19` / `BANK_ADR_LOW=15`，见 `include/core_define.v`）。
   `core0_swap_cfg` 只对 **bank 8~15** 生效（`inst_data_share_ram.v` 的 `core0_store_en_f` / `core0_store_en_f1` 两个 generate 段）；**bank 0~5 是硬解码**，不会被 swap 搬走。所以 `0x8000~0xFFFF` 恒定落在 `ram_bank_x[1]`，“写去了别的 bank”这一假设可以直接排除。
3. **`store_data_i[39:0]` = {data[31:0], ecc[7:0]}**。波形上的 `41_a000_0000` 就是写 `0x41A00000`，末尾两位十六进制是 ECC 不是数据。
   实测 `addr` / `store_en` / `store_data_i` 在 bank 输入端**同拍对齐**；若截图里数据段看着比地址段晚一拍，多半是波形标签渲染位置的错觉，需用光标对齐重新确认归属。

**另一条通用规则：先看编译产物再怀疑硬件。** 静态变量“没写进内存”的第一嫌疑是编译器把它提升进寄存器/消除死存储（file-static 且只在单个函数内使用时完全合法）。
先在 `.dis` 里 `grep` 目标地址，确认 `movigl/movigh` 常量 + `store32` 确实存在，再谈 RTL。本例中存储指令真实存在（`ec 41 40 02  store32 gr4 gr5 0`，基址 `gr5=0x805c`），所以排除了编译器优化。

**复现结论（版本相关，必须按版本分开看）**

把驱动里 `41f54~41f64` 的指令包逐字节复刻（`fsdiv gr4 gr2 gr3` → 两拍后 `fsdiv gr2 gr3 gr2 || store32 gr4 gr5 0`，机器码 `04 20 c2 6e` / `ec 41 40 02`）后跑 VCS：

| 版本 | 第二条 fsdiv 结果 | 同包 store | 判定 |
|---|---|---|---|
| `fbf30c269`（P65_NTO_SMIC55, 2026-07-15） | **`0x00000000`**（应为 `0x3d4ccccd`） | **丢失**，`store_en` 从未拉高 | **真实 RTL 缺陷** |
| `a8f6c21f9` + zhaotao_time 工作区未提交改动 | `0x3d4ccccd` ✓ | 正常，回读 `0x41A00000` | 已修复 |

**触发条件：两条 `fsdiv` 背靠背（第二条在第一条后第 3 拍发射）**。此时第二条 fsdiv 返回 0，且与它同包的 `store32` 整个被杀。
store 的数据与地址寄存器都与第二条 fsdiv 无数据依赖，所以**不是等操作数的停顿，是 slot 被丢弃**。
孤立一条 fsdiv（后插满 nop）则正常。实测：背靠背 2/2 失败，孤立 1/1 成功。

**端到端验证**：在 `fbf30c269` 上跑真实驱动 `F28P6x_driver_core0`（0x805c 只有启动 .bss 清零那一笔），驱动在 PLL 检查处报 **TEST FAIL，错误码 `0x00000103`**；同一驱动镜像在 `a8f6c21f9` 工作区上则正常写入 `0x41a00000`×2 + `0x41400000`×1，且 0x8060 与之互为倒数。

**修复候选提交**（两版之间 swift_core 相关，未做 bisect 定位）：`b0e51681c Fix FDIV flushed zero result handling`、`f73dd4d6a Optimize bypass timing`、`42330106b Simplify dead bypass logic`、`a8f6c21f9 Fix radix-4 divide step`。浮点除法器本体（`core_fdiv_*.v`）两版一致，`core_m1.v` 差异只是格式，所以修复应在发射/旁路逻辑。

**经验**：“丢写”类报告必须先问清对方的 RTL commit。同一个用例在两个版本上结论相反，只拿手边工作区测一遍就下“不存在”会直接误判。

**另一个坑**：`P65_NTO_SMIC55` 系列版本的 `c2000_tb.v` 超时是 `#80000000000`（比规程要求多 3 个 0，相当于 80 秒仿真时间），且多了一个 `Result_Check` 块（写 0x900000 报 TEST SUCCESS/FAIL）。跨版本测试前必须重新 grep 超时行，不能假定各版本 tb 一致。

## 十一、背靠背 `fsdiv` 会让第二条返回 0 且同包 store 丢失（P65_NTO_SMIC55 系列）

**来源**：定向用例 + 真实驱动实测（2026-09-05）

**现象**：两条 `fsdiv` 背靠背（第二条在第一条后第 3 拍发射）时，第二条 `fsdiv` 返回 `0x00000000`，**且与它同包的 `store32` 被丢弃**（`store_en` 从未拉高）。
store 的数据与地址寄存器都与第二条 fsdiv 无数据依赖，所以不是等操作数停顿，是 slot 被杀。孤立一条 fsdiv（后插满 nop）正常。

**版本矩阵**：

| 版本 | 结果 |
|---|---|
| `fbf30c269`（NTO, 7/15） | ❌ 失败 |
| `27081e0d4`（NTO 最新, 9/3） | ❌ 失败，与上行逐位一致 |
| `zhaotao_time` 工作区（a8f6c21f9+未提交） | ✅ 通过 |
| `27081e0d4` + 整个 `rtl/swift_core` 换成通过版 | ✅ 通过 |

**端到端影响**：真实驱动 `F28P6x_driver_core0` 在 PLL 检查处 **TEST FAIL，错误码 `0x00000103`**（`SysCtl_isPLLValid()` 的 `fclk1_0ratio`(0x805c) 写不进去）。

**已排除的单文件候选**（各做过完整重编+实测）：
- `core_id_bypass.v`（`d887086d6` rt_s2 旁路扩到 30 路）—— 无效
- `core_fdiv_post.v`（139→292 行）—— 无效

**已确认无关**：`include/core_define.v` 与 `rtl/ram_ctrl/` 两版完全一致。

**根因已定位（单提交 cherry-pick 验证）**：

```
f73dd4d6a  Optimize bypass timing
作者 zhaotao <taozhao@mail.ustc.edu.cn>，2026-07-18
在 zhaotao_time（同内容副本 723858765 在 zhaotao_p65fm）
未合入 P65_NTO_SMIC55
改动 8 文件：core_cpu_scale/core_id/core_id_bypass/core_m1/core_ex1/
        core_ex1_falu_s0/core_fdiv_post/core_me1_ein_s0
```

单独 cherry-pick 到 `27081e0d4`（干净应用，无冲突）后，定向用例全部转正：GR2=`0x3d4ccccd`、GR10=`0x41a00000`、GR13=`0x41a00000`、探针 16→20 次。

**定位技巧：编译报错比二分更快。** 单独换 `core_cpu_scale.v` 时 VCS 报
`Port "r_rx_bar_s1_reg_patch_en" is not defined in module 'core_id'`，
`git log -S"<信号名>" --all` 直接命中引入它的提交。**遇到跨分支定位先试这招**：找一个只存在于“通过版”的信号名，用 `-S` 搜历史，比逐文件重编快一个数量级。

**已排除的候选**：`b71164926 Fix FDIV flushed zero result handling`、`2da49046d Fix radix-4 divide step`（二者已在 NTO，不对症）；`d887086d6` 的 `core_id_bypass.v`、通过版 `core_fdiv_post.v`（单独无效）。`42330106b Simplify dead bypass logic` 同系列但非必需。

**重要保留项**：打上 `f73dd4d6a` 后，0x805c 写入恢复正常（`41a00000`，且 0x8060 写 `3d4ccccd` 成倒数），但驱动测试套**仍报 TEST FAIL，错误码从 `0x103` 变为 `0x102`**，结束时刻从 63465865ns 提前到 63377950ns。说明**还有另一个独立故障未解决**。注意：`zhaotao_time` 的 tb 没有 `Result_Check` 块，无法直接对比驱动判定，不能据此假定“在通过版上驱动就能 PASS”。

## 十二、驱动 `F28P6x_driver_core0` 的 0x900000 状态码含义

驱动把测试状态写到 `0x900000`，tb 的 `Result_Check` 块监视该地址：`0xCCCCCCCC`=SUCCESS，`0xEEEEEEEE`=FAIL，其余值当进度/错误码打印。

| 码 | 位置 | 含义 |
|---|---|---|
| `0x101` | `sysctl.c:304` | — |
| **`0x102`** | `sysctl.c:542` | `SysCtl_setClock()` 中 `SysCtl_isPLLValid()` 返回 false → `ESTOP0` |
| **`0x103`** | `sysctl.c:714` | 另一调用点的 `SysCtl_isPLLValid()` 返回 false → `ESTOP0` |
| `0x104` | `sysctl.c:753` | 同上，再一个调用点 |

**实测结论（2026-09-05）**：

| 配置 | 定向用例 | 驱动 |
|---|---|---|
| `27081e0d4`（NTO 最新） | ❌ | TEST FAIL `0x103` |
| `27081e0d4` + `f73dd4d6a` | ✅ | TEST FAIL `0x102` |
| `babb4e7c5`（zhaotao_time 最新提交） | ✅ | TEST FAIL `0x102` |

**后两行逐位一致**（同样 63377950000000 fs 结束、3572 行 trace、同样 0x805c/0x8060 写入时刻）。
所以 **`0x102` 是两条分支共有的独立问题**，与 fsdiv 缺陷无关：`fclk1_0ratio` 已正确写入（`41a00000`，0x8060 写 `3d4ccccd` 成倒数），但 `SysCtl_isPLLValid()` 仍判 false——卡在 **DCC 频率测量**而非比值计算。属于 DCC/PLL 子系统，需单独排查（看 DCC 计数器实际值与仿真里 pll_clk 真实频率），尚未区分是 RTL 缺陷、PLL 模型局限还是驱动配置问题。

**坑：不同分支的 tb 能力不一样。** `P65_NTO_SMIC55` 的 `c2000_tb.v` 带 `Result_Check`，`zhaotao_time` 的**没有**（跑驱动只会超时，不给判定）。跨分支对比驱动结果时，必须先把判定块移植过去（纯监视逻辑，读 `cpu_top_u.core0_axi_store_en/core0_store_addr/core0_store_data`），否则会把“看不到失败”误当成“没有失败”。

## 十三、跨版本/跨配置测试的两个硬坑

**坑 1：VCS 缓存要删四样，少一样就会跑到旧配置。**
`rm -rf AN.DB csrc simv_verdi.daidir partitionlib` —— **`partitionlib` 最容易漏**。实测：只删前三样时，`vcs/ldscript_Memory.vh` 源文件明明是 `SRAM_CORE0_INST=0x28000`，编出的 simv 里仍是上一轮的 `0x40000`，镜像被灌到错地址，core0 跳进空内存在 bootloader 里空转。

**坑 2：版本指纹必须来自仿真输出，不能 grep 源文件。**
“grep 源文件里的信号位宽”只能证明源文件对，证明不了 simv 里编进去什么（坑 1 就是这样漏过去的）。
可用的三项自证：① 仿真日志里的 `Set write addr: 0x...` 实际加载地址；② trace 行数是否符合预期；③ 探针命中数。三项都对才能看结果。

**坑 3：镜像必须整组切换。**
`bootloader` / `outer_*_mem_*` / `ldscript_Memory.vh` 是一套。只换其中一部分会造成 map 错配（例如驱动 bootloader 跳 `0x40400`、而用例装在 `0x28000`），现象是“程序跑不起来”，极易误判为被测代码有问题。

**坑 4：`P65_NTO_SMIC55` 系列早期版本的 tb 超时是 `#80000000000`**（多 3 个 0），且多了 `Result_Check` 块（写 0x900000 报 TEST SUCCESS/FAIL，这个块很有用）。`27081e0d4` 已修正为 `#80000000`。跨版本测试前必须重新 grep。

## 十四、`SAT64` 紧跟 `ADD/SUB` 系列时读到旧 OVC（P65_NTO_SMIC55，RTL 旁路缺失）

**来源**：外部报告《Sat64指令.docx》+ 定向用例在 `27081e0d4` 复现（2026-09-12）

**OVC 更新规则（RTL 实测，`core_ex_alu_s01.v:83-96`）**：`ADD/ADDI/ADDC/ADDIC/SUB/SUBI/SUBC/SUBIC` 在 **OVM=0** 时，33 位双符号位结果 `[32:31]==01`（正溢出）→ `ovc_step=+1`，`==10`（负溢出）→ `-1`；OVM=1 时结果直接饱和到 `0x7fffffff/0x80000000`、OVC 不动。OVC 只在指令到达 **ME3** 才写进 `cpu_ctrlReg[13:8]`（`core_cpu_scale.v:1381-1391`）。`SAT64` 不改 OVC。

**缺陷**：`SAT64` 在 EX1 读的 `ovc`（`core_ex1.v:330-335`）只旁路 `*_wCtrlReg`（movg2c 类整写），**不含在飞的 `ovc_step`**；对比同文件 `cf0`/`OF` 的旁路链都带 `*_genCF_s0`/`*_genOF_s0` 项，OVC 这条链漏了同类项。`ovc_step` 的走法：EX1 组合产生 → `ex1_ovc_step`(EX2) → `ex2_`(ME1) → `me1_`(ME2) → `me2_`(ME3) → `me3_`(WB) → `ovc_new` 在 WB 末拍写入 `cpu_ctrlReg`。**窗口 = 溢出指令之后的 5 条指令**（探针实测，2026-09-12，时钟 400ns/拍）：N=0..4 条 nop 时 `sat64` 的 `core_ex1.ovc` 都是 0（N=4 时 commit 与 sat64 的 EX1 同一 posedge，仍读旧值），N=5 才读到 1。`movc2g` 同样直读 `cpu_ctrlReg`（`core_ex1.v:551`），无旁路。**对照**：`movg2c` 写 OVC=1 后紧跟 `sat64` 能立即饱和（`ex1_wCtrlReg` 旁路命中），证明缺的只是 `ovc_step` 这一路。ADD(op 0x80)/SUB(0x82)/SUBC(0x83) 同样触发；负溢出 `ovc_step=11`→OVC=-1（movc2g 读 0x7f80）→提交后 `sat64` 得 0x8000_0000_0000_0000。

**引入版本（二分结论，2026-09-12 仿真验证）**：缺陷由 **`07c81c0b6`（2025-10-31，034 分支，"修改ovc更新逻辑"）** 首创、**`d146fba5a`/`d059dac4b`（2026-01-19，039 `T55_039_NTO`/`zhaotao_core`，"修改溢出计数器ovc"）** 移植：把旧的"OVC 值随 ctrlReg 流水传递 + `*_genOF_s0` 旁路"改成"`ovc_step` 延迟到 WB 提交"，同时删掉了旁路项。P65 主线通过 **`b548fb911`（2026-04-17，合入 `intergrate_zqf` 换核 `fb85b7847`）** 引入，此后 OVC 代码未再变。039 同项目相邻提交 A/B：`510122aa8`(父) N=0 即饱和 ✅，`d146fba5a` N=0..4 不饱和 ❌。**P65 换核前（≤`04de126a2`）的 swift_core 是 377D/lcm 血统、且 4 月份芯片环境跑不了当前镜像**（trace 只有 82 行、写回错位），不能用同一镜像当"好版本"对照——要验证旧设计只能去 039 环境。

**各芯片版本矩阵（2026-09-13，各分支 tip 各自 worktree 全量重编 + `agent/sat64_scan.s` 实测，trace 存 `agent/ovc_<proj>_tip.dat`）**：

| 芯片（Bug List 文档） | 分支 @ tip | OVC 设计 | 结果 |
|---|---|---|---|
| QX320F280025 | `U110_025_NTO` @ 7e50db592 | 旧（2 位 + genOF 旁路） | ✅ N=0 即饱和 |
| QX320F280{049,377}RevB / qx320f049v2 | `T55_049_NTO` @ 7d39571fe | 旧 | ✅ |
| QX320F2800137 | `U110_137_NTO_V3` @ 6c941635f | 旧 | ✅ |
| QX320F28377D | `377D_SIMC55` @ 48daeb7a1 | 旧 | ✅ |
| QX320F28034 | `U110_034_NTO_V2` @ bdf08c08d | 新（ovc_step，无旁路） | ❌ N=0..4 透传 |
| QX320F280039 | `T55_039_NTO` @ cae5cade4 | 新 | ❌ |
| QX320F28P650 | `P65_NTO_SMIC55` @ 27081e0d4 / 768e96f30 | 新 | ❌（CPU0、CPU1 均复现） |
| RevA qx320f | 文档"待确认"，无分支 | — | 未测 |

旧设计版本 `movc2g` 读到的是 2 位 OVC（`0x6081`=正溢出标志 bit13:12=10，`0x7080`=负溢出 11），`movg2c` 写 bit8 不算 OVC，所以旧版最后一组"movg2c 写 OVC=1 后 sat64"不饱和是编码差异、不是缺陷。**软件绕过**：受影响版本上 `SAT64` 与其前最近一条可能改 OVC 的指令（ADD/ADDI/ADDC/ADDIC/SUB/SUBI/SUBC/SUBIC，以及走同一 `me1_ovc_step` 通路的 MAC32/MACU32）之间至少隔 **5 个发射拍**（5 条单槽 `nop||`，或 5 个不改 OVC 的 VLIW 包）；已有 k 条则补 5−k 条。

**判定**：`result.txt` 中 `sat64` 差异、芯片"原样透传"而模拟器饱和、且前 **≤5** 条指令内有 ADD/SUB 系列溢出 → 归入本条（RTL 旁路缺失），不是模拟器问题；模拟器按"OVC 立即生效"算是对的。是"改 RTL 加旁路"还是"规定软件插 nop"由设计方定，未定前报告里写明两种口径。

**复现用例**：`agent/sat64_test.s`（文档原用例，trace `agent/sat64_test_trace_27081e0d4.dat`）、`agent/sat64_scan.s`（距离扫描 N=0..5 + ADD/SUB/MOVG2C 对照，trace `agent/sat64_scan_trace_clean.dat`，探针日志 `agent/sat64_scan_trace_probe.dat.simlog`）。探针写法：`core_cpu_scale.v` 末尾 `always @(posedge clk)` 在 `id_op_s0==\`SAT64` 时打印 `core_ex1.ovc`、`cpu_ctrlReg[13:8]`、五级 `*_ovc_step`/`*_wCtrlReg`；注意探针的 `id_pc` 比 trace 的 `rfgr_pc` 大 4。

## 十五、待补充

以下问题尚无定论，遇到时如实标"无法确定"，不要臆断：

- CR 的 **bit5 OVM / bit7 OF** 置位规则（bit4 CON 见第六节；bit8-13 OVC 见第十四节）。
- **访存地址落入指令区或他核内存区**（模式已识别，待对照实验证实）：
  实测内存映射 —— CLA0 指令 `0x00000000` / CLA0 数据 `0x00008000` / core0 数据 `0x00010000` / **core0 指令 `0x00028000`** / **core1 数据 `0x000a0000`** / core1 指令 `0x000b8000`。
  而随机测试数据区常配成 `0x30000~0xbffff`，**与 core0 指令区、core1 内存区大幅重叠**。实测多例访存差异（`loado32` 基址 `0x51e38`、`load8` 目标 `0x88581`、`loadu8` 目标 `0xab88c`）都落在这些区内：芯片读代码段/他核内存与 ISS（单核模拟、整块当 RAM）行为不同。
  **判定前先算访存地址落在哪个区**；落在指令区或他核内存区的，倾向测试用例配置问题，但需做"收窄数据区 → 差异是否消失"的对照实验才能定性。

## 十六、P65 FCVTFD 对 INT32_MIN 错误返回 0（RTL 位宽缺陷）

**来源**：2026-10-07 新随机用例整芯 VCS/ISS 对比，以及当前原始 FVCU 模块六组边界复现；分支 `zhaotao_p65 @ 083569bfde9337ffc562419b7ab5b5ae8f1bc4a8`。结果目录 `D:/workplace/QX_Workplace/random_test/results/20261007_2316/`。

- 现象：`FCVTFD GR12 GR23`，PC `0x2C764`，两侧 `GR23=0x80000000`（有符号整数 -2147483648），芯片 `{GR13,GR12}=0`，ISS 为 `0xC1E0000000000000`（-2147483648.0）。依据指令手册 FCVTFD 定义，ISS 正确、芯片错误；必须检查双写回高字，低字两侧均为0。
- 活跃路径：`FPU_Type_0` 未定义的64位 FPU 分支，`core_ex1_fvcu_s0` → `core_ex2_fvcu_s0.Shift_F2D`。
- 根因：`core_ex1_fvcu_s0.v:192` 使用 `{temp_a[31],~temp_a[30:0]+1}`。未定宽常量1使运算子表达式扩展为32位，拼接变为33位后赋给32位时丢弃符号位；INT32_MIN 在 EX1 的 `Trueform_F32` 实测变成0。EX2在 `core_ex2_fvcu_s0.v:400` 的零输入分支输出0，:401的INT32_MIN特判无法命中。
- 六组原模块复现：0、+1、-1、INT32_MAX、INT32_MIN+1均正确，只有INT32_MIN失败；日志 `fcvtfd_unit/unit.log`。没有修改DUT，不依赖流水线旁路推断。
- 本例整数转双精度能精确表示；`Shift_F2D`没有舍入输入，不因 RND_FVCU 默认RTZ而改变期望。
- 判定规则：相同输入且出现上述模式，归为此独立RTL缺陷；后续 `MOVIGL` 保留错误高16位引起的差异归为级联。
- 修复方向：将取反加一明确约束到31位再拼接符号，或使用明确32位的两补转换并覆盖INT32_MIN。该逻辑同时服务FCVTFS，修复回归应覆盖两类转换；本次只确认FCVTFD，没有宣称FCVTFS已做定向复现。

## 十七、P65 FCVTFS 把潜在舍入进位当实际进位，部分正数转换指数多加1（既有RTL缺陷）

**来源**：2026-10-08 FCVTFD 位宽修复验证；`zhaotao_p65 @ 083569bfde9337ffc562419b7ab5b5ae8f1bc4a8` 原RTL与仅修改EX1加一为`31'd1`的版本做同一组246个整数、1230项模块测试，随后整芯定向测试。证据目录 `D:/workplace/QX_Workplace/p65/agent/fcvtf_fix_20261007/`。

- 此问题独立于第十六节的EX1位宽缺陷。模块对照：原版23项失败，EX1修复版18项失败，减少的5项均为INT32_MIN（FCVTFD一次、FCVTFS四种舍入模式）；其余18项的输入、模式及错误结果完全相同，无新增失败。
- 确定实例：FCVTFS输入`0x00FFFFFF`（16777215），应精确转换为`0x4B7FFFFF`，RTL却为`0x4BFFFFFF`（33554430）。此整数可以被float32精确表示，不存在容差或舍入模式争议；RNE/RTZ/RDN/RUP四种模式都复现。
- 活跃路径：64位FPU分支，`core_ex2_fvcu_s0.M_Shifted_FS`（`Shift_F2S`）。`core_ex2_fvcu_s0.v:379`用`overflow_rounding`决定指数加1。
- 原模块信号实证：该输入的`u_round.din=25'h0FFFFFF`、`din_frac=0`、`need_rounding=0`、`r_tmp=25'h0FFFFFF`；实际没有舍入进位。但`core_fvcu_rounding.v`的`overflow`基于无条件`din+1`产生，`overflow_rounding=1`，从而EX2错误使用指数`0x97`而不是`0x96`。
- 默认RTZ整芯测试：1722/1722测试体写回完整，8个正数FCVTFS失败与8个后续ADDI复制的级联，共16条差异；ISS均与整数参考结果一致。输入为`0x00FFFFFF`、`0x01FFFFFF`、`0x03FFFFFF`、`0x07FFFFFF`、`0x0FFFFFFF`、`0x1FFFFFFF`、`0x3FFFFFFF`、`0x7FFFFFFF`。它们属于同一根因，不能计为8个独立缺陷。
- 判定：上述满足相同输入、潜在进位为1而实际结果没有进位的模式属于RTL缺陷，ISS正确；仅EX1位宽修复不会消除它。
- 修复方向（尚未实施）：在`Shift_F2S`中按实际舍入输出的进位决定指数变化，保留负数及INT32_MIN边界分支；不要直接修改共享rounding模块的全局语义。回归需覆盖四种已实现舍入模式及正负边界。

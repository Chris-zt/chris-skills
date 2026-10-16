# 编写 CLA 定向汇编测试

CLA 用专有 C2000 类 VLIW ISA，语法敏感。以下写法已在 p65 用探针实测验证槽位与行为。

## 槽位（slot）与打包

- `||op ...`（**行首** `||`）→ 指令进 slot **s2**（并入上一条指令所在 bundle 的第二槽）。
- `|op ...|`（**两侧单竖线**）→ 指令进 slot **s1**。`load32` 系列必须这样写。
- `op ... ||`（**行尾** `||`）→ 指令进 slot **s0**（bundle 首槽）。
- 单独的 `nop||` 作填充；bundle 间用它拉开间隔（间隔 N 就是 N 个 `nop||`）。

要构造"s2 指令 → 若干 nop → s0 指令"，就写 `||fsmul ...`（s2）、N 个 `nop||`、再 `fsadd ...||`（s0）。

## 访存与循环（CLA 同样支持）

CLA 不只能做 `movc2g`/FP 运算，**`load32`/`store32` 与 `jnc` 条件跳转都可用**，已实测编译通过。
需要长时间运行、或要产生 **SPR 总线访问**（`movc2g` 走内部通路，产生不了）时靠这两类指令。

- 访存：`|load32 gr8 gr6 0x0|`（s1 槽）、`||store32 gr7 gr6 0x00`（s2 槽）。
  lixiang 的 `load_store/` 用例里 `load32` 出现 226 次、`store32` 674 次，另有
  `loado32`/`load16`/`load8`/`loadi32` 等变体。
- 跳转：`jnc` 可**向后**跳（负偏移补码），但**必须先用 `ltu` 设条件**；`jmp` 只能向前。
  现有用例里还有 `call`/`callr`/`ret`。

循环骨架（GR9 计数、GR10 步长 1、GR11 阈值 1）：

```
movigh gr9 0x0003||     ; 循环次数 0x30000
movigl gr9 0x0000||
movigh gr10 0x0000||    ; 步长 1
movigl gr10 0x0001||
movigh gr11 0x0000||    ; 阈值 1
movigl gr11 0x0001||
nop||
loop1:
|load32 gr8 gr6 0x0|
||store32 gr7 gr6 0x00
sub gr9 gr9 gr10||
ltu gr9 gr11||
jnc loop1||
```

**`.cla.text` 有大小上限**：约 3KB 就接近极限（`random_init_all_gr.s` 那种 6335 次 `movc2g`
的用例链接直接失败，报 `section '.cla.text' will not fit in region 'SRAM_CORE0_CLA_INST'`）。
所以**要拉长执行时间应当加循环次数，而不是展开指令** —— 循环体是常数大小，次数存在寄存器里不占代码空间。

## 读/写 CR

- `movg2c GRx` —— 把 GRx 写进 CR（清 CR 用 GRx=0）。
- `movc2g GRy` —— 读 CR 到 GRy（trace 里就是对 GRy 的一次写回）。**注意流水冒险**：`movc2g` 在 EX1 级
  读架构 CR，而 FP 标志在 ME3 级才提交；紧跟 FP 指令时需在 `movc2g` 前垫**≥5 个 nop**，否则读到提交前旧值
  （详见 `trace-and-probe.md`）。要单独考察"标志是否被覆盖/累积"，就在 `movc2g` 前放足够 nop 排除这个冒险。

## 立即数与寄存器装载

- `movigl GRn 0xLLLL` 写低 16 位，`movigh GRn 0xHHHH` 写高 16 位。合起来装一个 32 位常量。

## 触发标志的操作数配方（单精度 float）

| 目的 | 值 | 说明 |
|---|---|---|
| 溢出源 | `0x7F000000` = 2^127 | `fsmul` 自乘 → 2^254 → **+inf，置 LVF** |
| 下溢源 | `0x00800000` = 2^-126 | `fsmul` 自乘 → 2^-252 → **0，置 LUF** |
| 常数 1.0 | `0x3F800000` | `fsadd 1.0+1.0=2.0`(`0x40000000`)，**不置任何标志** |

装载示例：`movigl GR4 0x0000 || ; movigh GR4 0x7F00 ||` → GR4=0x7F000000。

## 序言（preamble）

沿用工具随机用例的头部：`.data / mydata: .byte 0x00 / .text / .globl main / .type main,@function / main:`，
随后 `movigl/movigh` 装载各常量与 GR3=0（清 CR 用），再进入各测试组。

## 组结构范式（一组 = 一次 movc2g 读数）

```
movg2c GR3||            ; 清 CR（可与下一条 ||fsmul 同 bundle）
||fsmul GR6 GR4 GR4     ; instr1: s2, 2^127² → +inf → 置 LVF
[N × nop||]             ; instr1↔instr2 间隔
fsadd GR8 GR10 GR11||   ; instr2: s0, 1.0+1.0 → 无标志
[10 × nop||]            ; movc2g 前垫 nop，排除 EX1 读冒险
movc2g GR20||           ; 读 CR → GR20（trace 中 reg=0x14）
```

## 多组扫描 + 用脚本生成

扫参数（如 instr1↔instr2 间隔 N=0..10）时用脚本按上面范式循环拼接，避免手写出错。可在 WSL/Anaconda
python 里生成，写到 `cla_bg_<proj>\custom_random\<名字>.s`。**注意 BG task trace 末尾会截断**——在真正
要观察的最后一组后再追加 1~2 个 padding 组，保证最后一组的 `movc2g` 落入捕获窗口。

生成后务必抽查：`||fsmul` 后是否紧跟/隔 N 个 nop 再 `fsadd||`，各组是否以 `movg2c GR3||` 起、`movc2g GR20||` 止。

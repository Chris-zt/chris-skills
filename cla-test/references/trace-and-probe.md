# Trace 解析、RTL 探针与已知 CR 流水行为

## Trace 文件

- `cla_bgtask_sprs_trace.dat`（CLA BG task 的 SPRS/GR 写回 trace）。含 NUL 字节——用 `grep`/
  `tr -d '\000'` 处理，**别整读为文本**（大文件更要先 `grep` 定位）。
- 行格式：`reg\tvalue\tpc\t[time ns]`。常见 reg：`0x14`=GR20、`0x06`=GR6、`0x08`=GR8、
  `0x01..0x0b`=对应 GRn、`0x1e/0x1f`=GR30/31（栈/帧）。
- `movc2g GR20` 每次产生一行 `0x14`，按程序顺序对应各测试组；`grep '0x14' trace | tr -d '\000'` 即得
  各组 CR 读数序列。fsmul/fsadd 的结果（GR6/GR8）也在 trace 里，可用来核对 instr1 确实溢出（GR6=+inf=
  `0x7f800000`）、instr2 确实无标志。

## CR 位定义（来自 RTL `include/core_define.v`）

- `bit1 = LUF`（Latched Underflow，锁存下溢）
- `bit2 = LVF`（Latched Overflow，锁存溢出）
- `bit14 = EALLOW`（常置位）
- 常见值：`0x4000`=都清、`0x4004`=LVF、`0x4002`=LUF、`0x4006`=LVF+LUF。
- LUF/LVF 是"Latched"=**sticky**：一旦置位保持到软件显式写 CR 清除。参考模拟器是原子模型，会正确累积。

## 已知 CR 流水行为（p65 实测结论，039 同 ISA 可类比）

1. **`movc2g` 读 CR 的 read-after-write 冒险（真实缺陷）**：`movc2g` 在 **EX1** 级读架构寄存器
   `cpu_ctrlReg_s0`（见 `rtl/CLA/cla_ex1.v` 的 `id_rCtrlReg_s0 ? cpu_ctrlReg_s0 : ...`），
   **无 ME3→EX1 转发**；而 FP 的 LVF/LUF 在 **ME3** 级才提交。若 `movc2g` 紧跟 FP 指令，其 EX1 读与
   ME3 提交撞在同一时钟沿（非阻塞赋值），读到提交前旧值——**丢掉刚置的标志**。经验阈值：`movc2g` 前垫
   **≥5 个 nop** 即可读到正确值（4 个正好差一拍）。
2. **s0/s2 的 LVF/LUF sticky 合并与累积（实测正确）**：`rtl/CLA/cla_m2.v` 的
   `lvf_updata = lvf_s0 ? 1'b1 : lvf_new`（从 me2/me3/cpu 转发）正确保持 sticky。一条 **s0 非标志指令**
   跟在 **s2 置标志指令** 后，在任意间隔（含 0 nop）下都**不会**清掉 s2 的 LVF——这是正确行为。
   `rtl/CLA/cla_scale.v` 的 me3 最终提交（约 1242~1253 行，含 `me3_ctrlReg_s0[1]/[2]` 的条件写）
   实测能使 `cpu_ctrlReg_s0` 累积到 `0x4006`。

> 教训：看到 `movc2g` 读数少了某个标志，先分清是 **读冒险**（读早一拍）还是 **累积/覆盖**（sticky 逻辑）。
> 用"改 movc2g 前 nop 数"与"改 instr1↔instr2 间隔"两组扫描分别隔离这两个因素。

## RTL 探针方法

- 受限 `$display`，强触发条件约束（时间窗 / PC / flag 信号），**输出 <1000 行**。CLA 只在 BG task 期间跑
  FP，故用 `if (me3_genLVF_s0|me3_genLVF_s2|me3_genLUF_s0|me3_genLUF_s2|me3_wCtrlReg_s0)` 之类条件即可自然限量。
- 有用的观测点：
  - 提交级（`cla_scale.v` cpu_ctrlReg 更新处）：`me3_ctrlReg_s0`、`me3_genLVF/LUF_s0/s2`、
    `me3_wCtrlReg_s0`、`cpu_ctrlReg_s0`（打印的是提交前旧值）。
  - 捕获级（`cla_m2.v` `ctrlReg_new_s0` 处）：`freeze`、`me1_valid_s0/s2`、`LVF_s0/LUF_s0`、
    `lvf_s0/luf_s0`、`lvf_updata_s0/luf_updata_s0`、`ctrlReg_new_s0`、`me1_ctrlReg_s0`。
  - movc2g 读级（`cla_ex1.v` `id_rCtrlReg_s0` 处）：`cpu_ctrlReg_s0`（看 movc2g 到底读到什么、何时读）。
- 流程：改本地 RTL 插桩 → 上传改动文件 → 远端 `agent_compile.sh` 重编 `simv_verdi` → 跑 →
  `grep '[AGENT_PROBE]'` 分析。**最终 RTL 不留探针**（改完删掉、重新上传+重编恢复干净二进制）。
- 用 `posedge clk` 的 `always` 块加 `$display` 是安全的（无驱动冲突）；`clk`/信号需在该模块作用域内。

## 结果报告要点

给每组一张表：间隔/nop 数 → 期望 CR → 实测 CR → 结论（保留/丢失/覆盖）。用 trace 里的 GR6/GR8 佐证
用例确实触发了预期行为。若定位到 RTL，给 **文件:行 + 活跃宏路径 + 确切机理 + 探针证据（时间戳对齐）**。

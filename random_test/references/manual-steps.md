# 分步手工执行与目录速查

`run_p65_test.sh` 在某一步失败时，用这份文档从断点继续，不必整条重跑（生成 2000 条 + 前仿一轮要十几分钟）。

## 目录速查

```
random_test/
├── run_p65_test.sh        # 一键脚本（七步）
├── Makefile               # 老流程（只到本地 ISS，ftp 上传）
├── instr_generate/        # 随机指令生成器
│   ├── main.py            # 入口：python3 main.py random N
│   ├── config/config.py   # BASE_PC / SIM_BASE_PC / TestConfig / JmpConfig / ClaConfig
│   ├── txt/start.py       # 生成寄存器初始化 + 0xDEADBEEF 哨兵
│   ├── txt/start2.s       # 前仿头模板（芯片版）
│   ├── generate/          # 产物：random.s(芯片版) / random_sim.s(sim版)
│   ├── slot1/ load_store/ fpu/ tmu/ vcu/ fintdiv/ jmp/   # 各功能单元指令生成
│   ├── tool/              # tool.py 立即数/寄存器工具、ram.py 数据区布局
│   └── global_state/      # 三个槽的指令队列、寄存器状态
├── script/
│   ├── bin2issdat.py      # 裸二进制 → ISS .dat 文本格式
│   ├── compare.py         # 两份 trace 1:1 对比 → result.txt
│   ├── log_process.py     # simulator.log → gr_trace.txt / gr_trace_instr.txt
│   ├── remote_start.sh    # 把 random.s 头换成前仿头
│   ├── upload.sh          # ftp 上传（老流程）
│   └── copy_with_timestamp.sh  # 错误用例归档
├── simulator/
│   ├── simulator_step13   # 本地 ISS（Linux ELF）
│   └── log_level3.py      # ISS 日志降噪到 level3
├── remote/                # 待上传内容
├── results/YYYYMMDD_HHMM/ # 每次运行的完整快照
└── ERROR/                 # make error 归档的出错用例
```

## 远程路径

| 用途 | 路径 |
|---|---|
| 上传暂存 | `/home/zhaotao/Desktop/test/tmp`（`1.s` 芯片版 / `2.s` sim 版） |
| 汇编器 | `/home/zhaotao/Desktop/test/assember_linux`（`all_assember.py`） |
| 汇编产物 | `$R_TMP/dat/1.dat`(芯片镜像) `$R_TMP/datFileSim/2`(ISS 二进制) `$R_TMP/dis/1.dis`(反汇编) |
| VCS 目录 | `/home/zhaotao/Desktop/p65/vcs`（`simv_verdi`、`core0_gr_trace.dat`、`simv_run.agent.log`） |
| testbench | `/home/zhaotao/Desktop/p65/fpga/c2000_tb.v` |
| 重编脚本 | `~/Desktop/p65/vcs/agent_compile.sh` |

## 分步命令

以下都在 WSL 内、`cd /mnt/d/workplace/QX_Workplace/random_test` 之后执行。`OUT=results/<你的时间戳>`。

### 步骤 1：只重新生成用例

```bash
(cd instr_generate && python3 main.py random 2000)
# 产物：instr_generate/generate/random.s 和 random_sim.s
```

生成器带随机性，偶发失败正常，脚本里重试 8 次。连续失败要看 `gen.log`——历史上 2000 条量级的失败是 `tool/tool.py` 移位越界（已修，见 pitfalls.md）。

### 步骤 2：拼头 + 上传

```bash
{ sed 's/\r$//' instr_generate/txt/start2.s; tail -n +12 instr_generate/generate/random.s     | sed 's/\r$//'; } > remote/random.s
{ sed 's/\r$//' instr_generate/txt/start2.s; tail -n +12 instr_generate/generate/random_sim.s | sed 's/\r$//'; } > remote/random_sim.s
scp -q remote/random.s     lx5:/home/zhaotao/Desktop/test/tmp/1.s
scp -q remote/random_sim.s lx5:/home/zhaotao/Desktop/test/tmp/2.s
```

`tail -n +12` 是跳过生成器自带的头部 11 行，换成前仿头。两边都必须转成 LF，CRLF 会让远程汇编器报错。

### 步骤 3：远程汇编

```bash
ssh -T lx5 bash -s <<'EOF'
set -e
cd /home/zhaotao/Desktop/test/assember_linux
python3 all_assember.py >/tmp/p65_asm.log 2>&1
ls -l /home/zhaotao/Desktop/test/tmp/dat/1.dat \
      /home/zhaotao/Desktop/test/tmp/datFileSim/2 \
      /home/zhaotao/Desktop/test/tmp/dis/1.dis
EOF
```

三个产物任一为空就看 `/tmp/p65_asm.log`。

### 步骤 4：远程前仿

```bash
ssh -T lx5 bash -s <<'EOF'
set -e
cp /home/zhaotao/Desktop/test/tmp/dat/1.dat /home/zhaotao/Desktop/p65/vcs/outer_insn_mem_core0.dat
cd /home/zhaotao/Desktop/p65/vcs
rm -f core0_gr_trace.dat
nohup ./simv_verdi -l simv_run.agent.log >simv_run.nohup 2>&1 &
echo "simv PID=$!"
EOF
```

轮询状态（**别一有行就往下走**，判据见 SKILL.md）：

```bash
ssh -T lx5 bash -s <<'EOF'
if pgrep -f 'simv_verdi -l simv_run.agent.log' >/dev/null; then echo RUN; else echo DONE; fi
wc -l < /home/zhaotao/Desktop/p65/vcs/core0_gr_trace.dat 2>/dev/null || echo 0
EOF
```

### 步骤 5：拉回产物

```bash
scp -q lx5:/home/zhaotao/Desktop/test/tmp/datFileSim/2       $OUT/sim.bin
scp -q lx5:/home/zhaotao/Desktop/p65/vcs/core0_gr_trace.dat  $OUT/core0_gr_trace.dat
scp -q lx5:/home/zhaotao/Desktop/test/tmp/dis/1.dis          $OUT/random.dis
```

### 步骤 6：本地 ISS

```bash
python3 script/bin2issdat.py $OUT/sim.bin $OUT/random_iss.dat 0x200000
(cd $OUT && ../../simulator/simulator_step13 -c qx320f034 random_iss.dat -l) >$OUT/iss.log 2>&1
cp $OUT/simulator.log ./simulator.log
python3 simulator/log_level3.py simulator.log
python3 script/log_process.py simulator.log gr_trace.txt
cp gr_trace.txt gr_trace_instr.txt $OUT/
```

`bin2issdat.py` 的第三个参数是二进制偏移 0 对应的内存地址：sim 版（`.data` 在低地址，从 0 平铺）用 `0`；chip 版（`start2.s` 头，objcopy 从 `.text` 起始）用 `0x200000`。ISS 的 `.dat` 格式是 `32'h<addr>,\t128'h<w0>_<w1>_<w2>_<w3>`，指令段（≥`0x200000`）四个字**正序**、数据段（<`0x200000`）**倒序**（ISS 源码 `set_Ram` 用 `address+12-i`）。

### 步骤 7：对比

```bash
python3 script/compare.py $OUT/core0_gr_trace.dat gr_trace_instr.txt
cp result.txt $OUT/
grep -nE 'Total comparisons|Total mismatches|correct \(|within tolerance' result.txt
```

## 只想复跑对比（用例和 trace 都已有）

最常见的场景：改了 `compare.py` 的容差或归类逻辑，想在已有 trace 上重看结果。直接从步骤 7 开始，不需要重跑前仿。

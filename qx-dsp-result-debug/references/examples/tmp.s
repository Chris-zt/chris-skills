.global start
_begin:
start:
.text
#.ent main

boot:
.=1024

# --------------------------初始化---------------------
movigl GR0 0x0000||
movigh GR0 0x0000||
movg2c GR0||
movigl GR1 0x0000||
movigh GR1 0x0000||
movigl GR2 0x0000||
movigh GR2 0x0000||
movigl GR3 0x0000||
movigh GR3 0x0000||
movigl GR4 0x0000||
movigh GR4 0x0000||
movigl GR5 0x0000||
movigh GR5 0x0000||
movigl GR6 0x0000||
movigh GR6 0x0000||
movigl GR7 0x0000||
movigh GR7 0x0000||
movigl GR8 0x0000||
movigh GR8 0x0000||
movigl GR9 0x0000||
movigh GR9 0x0000||
movigl GR10 0x0000||
movigh GR10 0x0000||
movigl GR11 0x0000||
movigh GR11 0x0000||
movigl GR12 0x0000||
movigh GR12 0x0000||
movigl GR13 0x0000||
movigh GR13 0x0000||
movigl GR14 0x0000||
movigh GR14 0x0000||
movigl GR15 0x0000||
movigh GR15 0x0000||
movigl GR16 0x0000||
movigh GR16 0x0000||
movigl GR17 0x0000||
movigh GR17 0x0000||
movigl GR18 0x0000||
movigh GR18 0x0000||
movigl GR19 0x0000||
movigh GR19 0x0000||
movigl GR20 0x0000||
movigh GR20 0x0000||
movigl GR21 0x0000||
movigh GR21 0x0000||
movigl GR22 0x0000||
movigh GR22 0x0000||
movigl GR23 0x0000||
movigh GR23 0x0000||
movigl GR24 0x0000||
movigh GR24 0x0000||
movigl GR25 0x0000||
movigh GR25 0x0000||
movigl GR26 0x0000||
movigh GR26 0x0000||
movigl GR27 0x0000||
movigh GR27 0x0000||
movigl GR28 0x0000||
movigh GR28 0x0000||
movigl GR29 0x0000||
movigh GR29 0x0000||

# 在此之前的代码不可以修改，需要严格复制
# --------------------------构造测试数据---------------------

movigl GR0 0x1111||
movigh GR0 0x1111||
movigl GR1 0x3333||
movigh GR1 0x3333||
movigl GR2 0xcccc||
movigh GR2 0xcccc||


# --------------------------测试--------------------------
movigl GR4 0x0000||
movigh GR4 0x0000||
addi GR4 GR0 0x400||
addi GR4 GR1 0x3ff||
addi GR4 GR2 0x111||
addi GR4 GR3 0x111||

# --------------------------其它示例--------------------------

movg2c GR0||store32 GR0 GR1 0x0000 # mov指令在slot0,store指令在slot2
max GR25 GR11 GR18|loadi16 GR22 0x74B3| # alu指令在slot0,load指令在slot1
fdadd GR4 GR0 GR2|| # 双精度浮点指令只需要用低位的寄存器序号表示。实际运行是低位的和高位的拼接 {GR1, GR0}和{GR3, GR2} 想加结果放在{GR5, GR4}中



# --------------------------末尾nop确认程序执行结束--------------------------
nop||
nop||
nop||
nop||
nop||
nop||
nop||
nop||

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把指令手册抽取成纯文本，供 grep/搜索指令语义。

重要事实：本项目的 references/manuals/Instruction_Set.doc 扩展名虽为 .doc，
实际是 .docx（Office Open XML = zip 打包的 XML，文件头为 "PK"）。因此不能当
旧版二进制 OLE .doc 直接抽 ASCII（那样几乎抽不到中文正文）。本脚本：
  1) 优先按 docx(zip) 解析 word/document.xml 等，去 XML 标签得到正文；
  2) 若不是 zip（真正的旧 OLE .doc），退回抽取可见 ASCII 作兜底。
只用 Python 标准库（zipfile / re / html），无需 antiword/catdoc/libreoffice。

用法：
  python3 extract_manual_text.py <手册.doc/.docx> [输出.txt]
  不给输出路径时打印到标准输出。
抽取后务必用本次日志中的指令名做命中验证，例如：
  rg -n -i "MOVIGH|MOVIGL|EALLOW|MOVG2C" manual.txt
"""
import sys, re, zipfile, html


def docx_to_text(path):
    """按 docx(zip+XML) 抽取正文。"""
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist()
                 if re.match(r"word/(document|header\d*|footer\d*)\.xml$", n)]
        # 保证正文优先、且一定包含 document.xml
        names = sorted(set(["word/document.xml"] + names),
                       key=lambda n: (n != "word/document.xml", n))
        chunks = []
        for n in names:
            try:
                xml = z.read(n).decode("utf-8", "replace")
            except KeyError:
                continue
            xml = re.sub(r"</w:p>", "\n", xml)     # 段落 -> 换行
            xml = re.sub(r"<w:tab/>", "\t", xml)    # 制表
            xml = re.sub(r"<[^>]+>", "", xml)       # 去所有 XML 标签
            chunks.append(xml)
        return "\n".join(chunks)


def ole_to_text(path):
    """兜底：真正的旧 OLE .doc，抽取可见 ASCII 片段（质量有限）。"""
    data = open(path, "rb").read()
    txt = data.decode("latin-1")
    txt = re.sub(r"[^\x09\x0a\x0d\x20-\x7e]", " ", txt)
    return re.sub(r" {3,}", "  ", txt)


def extract(path):
    if zipfile.is_zipfile(path):
        return docx_to_text(path)
    return ole_to_text(path)


def main():
    if len(sys.argv) < 2:
        print("用法: python3 extract_manual_text.py <手册.doc/.docx> [输出.txt]",
              file=sys.stderr)
        sys.exit(1)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    txt = html.unescape(extract(src))
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(txt)
        print(f"写出 {len(txt)} 字符 -> {out}")
    else:
        sys.stdout.write(txt)


if __name__ == "__main__":
    main()

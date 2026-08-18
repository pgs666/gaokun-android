#!/usr/bin/env python3
"""把 meson 文件里的反斜杠续行拼成单行（meson_to_hermetic 的 lark 语法不认 \\）。

语义等价变换；只处理行尾为 `\\` 的行。在 external/mesa3d 下运行，幂等。
"""
import os

changed = 0
for root, _dirs, files in os.walk('.'):
    if '/meson_to_hermetic' in root or '/.git' in root:
        continue
    for fn in files:
        if fn not in ('meson.build', 'meson.options', 'meson_options.txt'):
            continue
        p = os.path.join(root, fn)
        try:
            src = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        if '\\\n' not in src:
            continue
        out_lines = []
        buf = ''
        for line in src.split('\n'):
            if line.rstrip().endswith('\\'):
                buf += line.rstrip()[:-1].rstrip() + ' '
            else:
                out_lines.append(buf + line)
                buf = ''
        if buf:
            out_lines.append(buf)
        open(p, 'w').write('\n'.join(out_lines))
        changed += 1
print('已拼平 %d 个 meson 文件的续行' % changed)

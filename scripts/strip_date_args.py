"""VisitGrid が距離ベースになった際に残った、日時の引数と未使用の `now` を落とす。

使い方: scripts/strip_date_args.py [対象ディレクトリ...]

VisitGrid の減衰の時計は「歩いた総距離」になったので(docs/04)、
`recordVisit(at:date:)` / `familiarity(at:now:)` などから日時が消えた。
呼び出し側に残った引数を機械的に外す。判断を要する箇所は変更しない。
"""
import glob
import re
import sys

# 「, date: 何か)」「, now: 何か)」を落とす。引数が入れ子の括弧を含む場合は触らない
ARG = re.compile(r",\s*(?:date|now):\s*[^(),]*\)")
# 使われなくなった `let now = Date(...)`
UNUSED_NOW = re.compile(r"^\s*let now = Date\([^)]*\)\n", re.MULTILINE)

targets = sys.argv[1:] or ["Tests"]
changed = []
for directory in targets:
    for path in sorted(glob.glob(f"{directory}/**/*.swift", recursive=True)):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        new = ARG.sub(")", text)
        # `now` が他で使われていなければ宣言ごと落とす
        for block in re.findall(r"func [^\n]*\{(?:[^{}]|\{[^{}]*\})*\}", new):
            if "let now = Date(" in block and block.count("now") == 1:
                new = new.replace(block, UNUSED_NOW.sub("", block))
        if new != text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            changed.append(path)

for p in changed:
    print(p)
print(f"{len(changed)} ファイルを更新しました")

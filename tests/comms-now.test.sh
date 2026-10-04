#!/bin/bash
# comms-now.test.sh — RED TESTS for the live `now.md` builder (vdm-comms).
#
# `now.md` is the owner's state, rebuilt from the project's homes — the open
# items of the files in `comms.pending-paths` — without a model: what waits for
# the owner's move, what is due today and tomorrow, what others lead. The owner
# reads it in Obsidian and may write a reply (`>>@ai …`) straight under an item;
# a rebuild must not lose that line. Workitem: docs/tasks/vdm-comms-live-now.
#
# The fixture breaks correlations on purpose: the owner's item and a
# neighbour's overdue item sit in the same section, a neighbour's future item
# sits between them, and the item without an owner has no block id — so no
# assertion can pass by position alone.
#
# Run: bash tests/comms-now.test.sh   (exit 0 = all pass)

set -u

unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE GIT_EDITOR 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$REPO_ROOT/plugins/vdm-comms"
NOW="${COMMS_NOW_BIN:-$P/scripts/comms-now.py}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
expect_exit() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }
expect_says() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention: $3" ;; esac; }
expect_not_says() { [ -n "$2" ] || { bad "$1" "output is empty — absence proves nothing there; assert silence instead"; return; }; case "$2" in *"$3"*) bad "$1" "output should NOT mention: $3" ;; *) ok "$1" ;; esac; }
expect_before() { # expect_before <desc> <haystack> <first> <second> — both present, in that order
  local rest="${2#*"$3"}"
  if [ "$rest" = "$2" ]; then bad "$1" "output did not mention: $3"; return; fi
  case "$2" in *"$4"*) ;; *) bad "$1" "output did not mention: $4"; return ;; esac
  case "$rest" in *"$4"*) ok "$1" ;; *) bad "$1" "'$4' comes before '$3'" ;; esac
}
# block <file> <heading> — the lines of one `## heading` block, up to the next `## `
block() { awk -v h="## $2" 'index($0, h) == 1 { on = 1; next } on && /^## / { exit } on' "$1"; }

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t nowtest)
trap 'rm -rf "$TMP"' EXIT
export COMMS_TODAY=2026-09-30
# The homes alone first: an echelon that is not there. The echelon section
# below points this at a stub.
export ECHELON_BIN="$TMP/no-echelon-here"

FX="$TMP/proj"
mkdir -p "$FX/.claude" "$FX/tracks/alpha/comms" "$FX/tracks/beta" "$FX/docs" "$FX/signals"
cat > "$FX/tracks/alpha/index.md" <<'EOF'
# Alpha

## Наши действия

- [ ] **владелец** — решить, брать ли реестр подписок ⏰ 2026-10-06 ^a3f
- [ ] **product** — проверить выгрузку Z ⏰ 2026-10-10 ^m2p
- [ ] **product** — выкатить исправление Y ⏰ 2026-09-20 ^k7q
- [ ] Завести файл письма задним числом

## Ожидаем

- [ ] ⏰ 2026-09-30 — Accounting — выгрузка закупок ^t0d
EOF
cat > "$FX/tracks/beta/index.md" <<'EOF'
# Beta

## Наши действия

- [ ] **владелец** — ответить Котовой ^b1x
- [ ] **владелец** — брать ли реестр подписок источником I3 вместо зависшей выгрузки Accounting. Морозов 30.09 письмом `Подписки по AI` сверил по списку десять подписок своей группы, в ходу Codex Pro и Claude Max, к отключению ChatGPT Plus, Copilot Pro+ и JetBrains AI, и владелец ответил, что пусть пришлют подтверждение отписки, а имён в счёт не несём никогда ⏰ 2026-10-06 ^l0n
- [ ] **владелец** — спросить Белых лично: видела ли правку от группы ядра (ABC-1761, Смирнов В. 30.09: сверка встреч в 01:00 МСК). Остальное про mcp-chat и новую ABC-1852 в треке ^l2n
- [ ] **владелец** — ⏰ Отправлено 21.09. Ответ Ковальчук на комментарий в PROJ-619 — что выбирают: дефолт «Авто» с правкой критерия или пин на язык интерфейса. Дальше длинный разбор ветки ^l3n
- [ ] **владелец** — ⏰ Отправлено 22.09. Ответ Волкова и Бондаренко на письмо по вопросу Ивана — что из выбора модели уже доступно и кому и что задачи ядра делают с выбором, пришедшим от вызывающей системы — приоритет, отказ или игнор, и срок, которого в письме нет ^l4n
- [ ] **владелец** — сверить длинный хвост без точки: `подписки по группе и по направлению и по источнику и ещё по трём разрезам сразу для отчёта квартала` и ещё много слов после кода, чтобы отрезать пришлось посреди строки, а не на точке ^l1n
- [x] **владелец** — уже закрытое ^c9z
EOF
printf -- '---\ndraft: true\nchannel: email\n---\n\nТекст.\n' > "$FX/tracks/alpha/comms/2026-09-29-petrov-out.md"
printf '# Как работать с now.md\n' > "$FX/docs/how-to-work.md"

cfg() {  # cfg <now-object-json or empty>
  local now="${1:-}"
  {
    printf '{\n  "comms": {\n'
    printf '    "pending-paths": ["tracks/*/index.md"],\n'
    printf '    "pending-sections": {"waiting": ["Ожидаем"], "action": ["Наши действия"]},\n'
    printf '    "owners": ["владелец", "product", "штаб"],\n'
    printf '    "labels": "ru",\n    "link-style": "wikilink"'
    [ -n "$now" ] && printf ',\n    "now": %s' "$now"
    printf '\n  }\n}\n'
  } > "$FX/.claude/vdm-plugins.json"
}
build() { python3 "$NOW" --project-root "$FX" 2>&1; }
N="$FX/signals/now.md"

echo "== not configured: nothing is built =="
cfg ""
out="$(build)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "without comms.now the build refuses"; else bad "without comms.now the build refuses" "rc=$rc"; fi
expect_says "…and names the key to set" "$out" "comms.now"
[ ! -e "$N" ] && ok "…and writes no now.md" || bad "…and writes no now.md"

echo "== built from the homes =="
cfg '{"owner": ["владелец"], "instructions": "docs/how-to-work.md"}'
out="$(build)"; rc=$?
expect_exit "a configured project builds" 0 "$rc"
[ -f "$N" ] && ok "…signals/now.md is written" || { bad "…signals/now.md is written" "$out"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }
F="$(cat "$N")"
expect_says "frontmatter carries the moment of the build" "$F" "built: 2026-"
expect_says "…and the count for the hook line: own + lifted + draft + own-without-date + 5 long" "$F" "your-move: 9"
first="$(awk 'f == 2 && NF { print; exit } /^---$/ { f++ }' "$N")"
expect_says "the first line after the frontmatter is the instructions link" "$first" "[[../docs/how-to-work|"

MINE="$(block "$N" "Твой ход")"
expect_says "the owner's item is in «Твой ход», linked to its block" "$MINE" "[[../tracks/alpha/index#^a3f|a3f]]"
expect_says "…with its text, the block id stripped" "$MINE" "решить, брать ли реестр подписок"
expect_says "…and the home it lives in, so the line reads without a click" "$MINE" "a3f]] · alpha · "
expect_not_says "…the id is not left dangling in the text" "$MINE" "подписок ⏰ 2026-10-06 ^a3f"
expect_says "an owner's item with no date is there too" "$MINE" "b1x"
expect_says "a neighbour's overdue item is lifted" "$MINE" "k7q"
expect_says "…saying whose it was" "$MINE" "product"
expect_says "…and which date passed" "$MINE" "2026-09-20"
expect_not_says "a neighbour's future item is not lifted" "$MINE" "m2p"
expect_not_says "…nor one due today: its date has not passed yet" "$MINE" "t0d"
expect_says "an unsent draft — outgoing in the owner's name — is the owner's move" "$MINE" "2026-09-29-petrov-out"
expect_not_says "a closed item is nowhere" "$F" "c9z"
# The owner, 2026-09-30: the start of an item, not the paragraph — the sheet's
# first pain was "long, and nobody reads it to the end". The full text is one
# click away, in the home.
L0="$(printf '%s\n' "$MINE" | grep 'l0n')"
expect_says "a long item shows its first sentence" "$L0" "вместо зависшей выгрузки Accounting."
expect_not_says "…not the rest of the paragraph" "$L0" "имён в счёт не несём"
expect_says "…marked as cut" "$L0" "…"
expect_says "…keeping its date, which was in the part cut off" "$L0" "⏰ 2026-10-06"
L2="$(printf '%s\n' "$MINE" | grep 'l2n')"
expect_says "an initial is not the end of a sentence" "$L2" "Смирнов В. 30.09"
L3="$(printf '%s\n' "$MINE" | grep 'l3n')"
expect_says "a first sentence too short to say anything takes the next one too" "$L3" "Ответ Ковальчук на комментарий"
L4="$(printf '%s\n' "$MINE" | grep 'l4n')"
expect_says "…and when the next one runs past the limit, the cut is at a word near it, not back at the stub" "$L4" "Ответ Волкова и Бондаренко"
L1="$(printf '%s\n' "$MINE" | grep 'l1n')"
expect_not_says "a sentence too long is cut near 200 characters" "$L1" "а не на точке"
if [ "$(printf '%s' "$L1" | tr -cd '`' | wc -c | tr -d ' ')" -eq 2 ] || [ "$(printf '%s' "$L1" | tr -cd '`' | wc -c | tr -d ' ')" -eq 0 ]; then ok "…and a code span cut in half is closed"; else bad "…and a code span cut in half is closed" "$L1"; fi

SOON="$(block "$N" "Сегодня и завтра")"
expect_says "an item due today is in «Сегодня и завтра»" "$SOON" "t0d"

OTHERS="$(block "$N" "Ведут другие")"
expect_says "a neighbour's future item is under «Ведут другие»" "$OTHERS" "m2p"
expect_says "…under its owner" "$OTHERS" "product"
expect_says "an item with no block id is shown by its place" "$OTHERS" "tracks/alpha/index.md:"
expect_says "…with its text" "$OTHERS" "Завести файл письма задним числом"
expect_before "the blocks come in order: your move first" "$F" "## Твой ход" "## Сегодня и завтра"
expect_before "…then today, then the others" "$F" "## Сегодня и завтра" "## Ведут другие"

echo "== a rebuild follows the homes =="
sed -i.bak 's/^- \[ \] \*\*владелец\*\* — решить/- [x] **владелец** — решить/' "$FX/tracks/alpha/index.md" && rm -f "$FX/tracks/alpha/index.md.bak"
build >/dev/null
expect_not_says "an item closed in its home is gone after the rebuild" "$(cat "$N")" "a3f"
expect_says "…and the count follows" "$(cat "$N")" "your-move: 8"

echo "== the owner's replies survive the rebuild =="
# A reply written under b1x, and one under k7q whose item is then closed.
python3 - "$N" <<'EOF'
import sys
p = sys.argv[1]; out = []
for line in open(p, encoding="utf-8").read().splitlines():
    out.append(line)
    if "^b1x|b1x]]" in line:
        out.append(">>@ai а что Котова уже ответила?")
    if "^t0d|t0d]]" in line and not any("Accounting уже" in l for l in out):
        out.append(">>@ai Accounting уже прислали?")
    if "^k7q|k7q]]" in line:
        out.append(">>@AI это ещё актуально?")
        out += ["```", ">>@ai пример из кода, не реплика", "```"]
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
EOF
sed -i.bak 's/^- \[ \] \*\*product\*\* — выкатить/- [x] **product** — выкатить/' "$FX/tracks/alpha/index.md" && rm -f "$FX/tracks/alpha/index.md.bak"
build >/dev/null
F="$(cat "$N")"
expect_says "a reply under a live item is kept" "$F" ">>@ai а что Котова уже ответила?"
after_b1x="$(awk '/\^b1x\|b1x\]\]/ { getline; print; exit }' "$N")"
expect_says "…right under the same item" "$after_b1x" ">>@ai а что Котова уже ответила?"
expect_says "a reply whose item is gone is kept too, case and all" "$F" ">>@AI это ещё актуально?"
expect_before "…at the top, before «Твой ход»" "$F" ">>@AI это ещё актуально?" "## Твой ход"
expect_says "…under a heading that says its item is gone" "$F" "Реплики без пункта"
expect_not_says "a marker inside a code block is not a reply, and is not carried" "$F" "пример из кода"
build >/dev/null
expect_says "a second rebuild keeps them once, not twice" "$(grep -c 'Котова уже ответила' "$N")" "1"
# t0d stands in two blocks (due today, and under its owner): its reply goes
# under the first one only — a reply shown twice gets answered twice.
expect_says "a reply under an item shown in two blocks appears once" "$(grep -c 'Accounting уже прислали' "$N")" "1"

echo "== echelon: the owner's tasks and the calendar =="
# A stub with the shapes `echelon soon` / `echelon mine --json` return (measured
# live on hq 2026-09-30: 19 tasks, 18 on the owner's turn; 9 events, 3 of
# them the project's).
STUB="$TMP/echelon"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
case "$1" in
  soon) cat <<'J'
{"project": "proj", "generated_at": "2026-09-30T07:00:00+03:00", "days": ["2026-09-30", "2026-10-01"],
 "complete": true, "errors": [], "sources": {"outlook": {"complete": true}},
 "events": [
  {"start": "2026-09-30T18:00:00+03:00", "end": "2026-09-30T19:00:00+03:00", "title": "Weekly Пространство", "source": "outlook", "canceled": false, "relevant": true, "why": "слово словаря"},
  {"start": "2026-09-30T10:30:00+03:00", "end": "2026-09-30T11:00:00+03:00", "title": "Планерка SSO", "source": "outlook", "canceled": false, "relevant": false, "why": null},
  {"start": "2026-10-01T16:30:00+03:00", "end": "2026-10-01T17:00:00+03:00", "title": "Отменённая встреча", "source": "outlook", "canceled": true, "relevant": true, "why": "человек проекта"}
 ]}
J
  ;;
  mine) cat <<'J'
{"project": "proj", "generated_at": "2026-09-30T07:00:00+03:00", "complete": false,
 "errors": ["упоминания в Telegram ещё не отмечались сборщиком"], "covered": ["jira", "gitlab"], "counts": {},
 "items": [
  {"kind": "jira_mention", "ref": "PROJ-647", "title": "Котова: две проблемы на видео", "by": "Котова", "turn": "owner", "why": "упоминание без его ответа", "url": "https://jira.example/PROJ-647"},
  {"kind": "mr", "ref": "product!675", "title": "Draft: удаление карточки", "turn": "owner", "why": "черновик 4 дн.", "url": "https://gitlab.example/product/-/merge_requests/675"},
  {"kind": "task", "ref": "PROJ-598", "title": "Ждём ревью", "turn": "others", "why": "ждёт ревьюера", "url": "https://jira.example/PROJ-598"},
  {"kind": "task", "ref": "PROJ-700", "title": "Уже в доме", "turn": "owner", "why": "не закрыта при смерженном MR", "url": "https://jira.example/PROJ-700"},
  {"kind": "chat", "source": "telegram", "ref": "Команда", "title": "Telegram · Команда", "turn": "owner", "why": "упоминаний 2, твоего сообщения после нет", "by": ["Зайцев"], "count": 2, "mirror": "tg-komanda-2026-09-29#^m4"},
  {"kind": "mail", "ref": "Кластер dev: embeddings", "title": "Кластер dev: embeddings", "turn": "owner", "why": "ответ в ветке, где ты писал", "by": "Петров", "thread": "t-1"}
 ]}
J
  ;;
  *) exit 2 ;;
esac
STUBEOF
chmod +x "$STUB"
# PROJ-700 is also the subject of an owner's item in a home: the home's
# text wins, echelon's line is not doubled.
printf '\n- [ ] **владелец** — разобраться с PROJ-700 ^d4e\n' >> "$FX/tracks/beta/index.md"
export ECHELON_BIN="$STUB"
( export TZ=UTC; build >/dev/null )
F="$(cat "$N")"
MINE="$(block "$N" "Твой ход")"
expect_says "an echelon task on the owner's turn is in «Твой ход»" "$MINE" "PROJ-647"
expect_says "…as a link to where it lives" "$MINE" "https://jira.example/PROJ-647"
expect_says "…with echelon's reason" "$MINE" "упоминание без его ответа"
expect_says "an MR on the owner's turn too" "$MINE" "product!675"
expect_not_says "an echelon task waiting for others is not the owner's move" "$MINE" "PROJ-598"
expect_says "…it is under «Ведут другие»" "$(block "$N" "Ведут другие")" "PROJ-598"
expect_says "a task already carried by an owner's home item is not doubled" "$(grep -c 'PROJ-700' "$N")" "1"
expect_says "the count includes echelon's tasks: b1x + l0n..l4n + draft + d4e + 4 from echelon" "$F" "your-move: 12"
# echelon letter live-now-mine-chat-mail (2026-09-30): a chat has no url unless
# it is a Telegram supergroup, but a `mirror` anchor in the project's mirror; a
# letter's ref and title are the same subject.
expect_says "a chat with no url links to its place in the mirror" "$MINE" "[[tg-komanda-2026-09-29#^m4|Telegram · Команда]]"
expect_says "a letter shows its subject once" "$(printf '%s\n' "$MINE" | grep -c 'Кластер dev: embeddings')" "1"
expect_not_says "…not twice on one line" "$MINE" "embeddings · Кластер dev: embeddings"
expect_says "an incomplete echelon collection says so in the block" "$MINE" "упоминания в Telegram ещё не отмечались сборщиком"
SOON="$(block "$N" "Сегодня и завтра")"
expect_says "the project's meeting is in «Сегодня и завтра», bold" "$SOON" "**Weekly Пространство**"
expect_says "…at the machine's time, Moscow in brackets" "$SOON" "15:00–16:00 (МСК 18:00–19:00)"
expect_says "another meeting is there, dimmed" "$SOON" "_Планерка SSO_"
expect_says "a cancelled meeting is struck through" "$SOON" "~~Отменённая встреча~~"
expect_before "the meetings come in time order" "$SOON" "Планерка SSO" "Weekly Пространство"
expect_before "…today before tomorrow" "$SOON" "Weekly Пространство" "Отменённая встреча"
( export TZ=Europe/Moscow; build >/dev/null )
expect_not_says "on a Moscow machine there is no second time in brackets" "$(block "$N" "Сегодня и завтра")" "(МСК"

export ECHELON_BIN="$TMP/no-echelon-here"
out="$(build)"; rc=$?
expect_exit "without echelon the build still succeeds" 0 "$rc"
expect_says "…and the file says echelon was not reached" "$(cat "$N")" "echelon"
cfg '{"owner": ["владелец"], "instructions": "docs/how-to-work.md", "echelon": false}'
build >/dev/null
expect_not_says "echelon switched off for the project — not asked, not mentioned" "$(block "$N" "Твой ход")" "echelon"
export ECHELON_BIN="$TMP/no-echelon-here"

echo "== block ids: taken by the session, named by the linter, the backlog marked once =="
# Owner, 2026-09-30 (DL #2): the session that writes an item ends it with a block
# id; the linter names a new item without one; the items already open are marked
# once, by a command, on the owner's word — the diff shows what it did.
PEND="$P/scripts/comms-pending.py"
F2="$TMP/ids"; mkdir -p "$F2/.claude" "$F2/tracks/gamma"
git -C "$F2" init -q   # a project is a checkout: `--lint <file>` finds its root by .git
cat > "$F2/tracks/gamma/index.md" <<'EOF2'
# Gamma

Текст трека, не пункт.

## Наши действия

- [ ] **владелец** — первый пункт без метки ⏰ 2026-10-06
- [ ] **product** — второй пункт с меткой ⏰ 2026-10-07 ^q1w
- [x] **владелец** — закрытый пункт без метки
- [ ] **штаб** — третий пункт без метки ⏰ after: ответ product

| Кто | Что | Срок |
|---|---|---|
| product | строка таблицы ⏰ 2026-10-08 | — |
EOF2
printf '{"comms": {"pending-paths": ["tracks/*/index.md"], "pending-sections": {"action": ["Наши действия"]}, "owners": ["владелец", "product", "штаб"], "now": {"owner": ["владелец"]}}}\n' > "$F2/.claude/vdm-plugins.json"
cp "$F2/tracks/gamma/index.md" "$TMP/gamma.before"

id="$(python3 "$NOW" --project-root "$F2" --new-id 2>&1)"; rc=$?
expect_exit "--new-id answers" 0 "$rc"
case "$id" in [a-z][a-z0-9][a-z0-9]) ok "…a letter, then two letters or digits" ;; *) bad "…a letter, then two letters or digits" "got: $id" ;; esac
[ "$id" != "q1w" ] && ok "…not one the project already uses" || bad "…not one the project already uses"

# Uniqueness, deterministically: every id but one is taken — the one left is
# the only answer. Random ids would let a broken check pass by luck.
last="$(python3 - "$NOW" <<'EOF2'
import importlib.util, random, sys
spec = importlib.util.spec_from_file_location("comms_now", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
taken = {a + b + c for a in m.ID_FIRST for b in m.ID_REST for c in m.ID_REST} - {"z9x"}
print(m.new_id(taken, random.Random(1)))
EOF2
)"
expect_says "with every id but one taken, the one left is the answer" "$last" "z9x"
out="$(python3 "$NOW" --project-root "$F2" --assign-ids --dry-run 2>&1)"; rc=$?
expect_exit "--assign-ids --dry-run answers" 0 "$rc"
expect_says "…says how many items it would mark" "$out" "2"
cmp -s "$TMP/gamma.before" "$F2/tracks/gamma/index.md" && ok "…and writes nothing" || bad "…and writes nothing"

out="$(python3 "$NOW" --project-root "$F2" --assign-ids 2>&1)"; rc=$?
expect_exit "--assign-ids marks the backlog" 0 "$rc"
G="$(cat "$F2/tracks/gamma/index.md")"
expect_says "an open item without an id gets one" "$(grep 'первый пункт' "$F2/tracks/gamma/index.md")" "2026-10-06 ^"
expect_says "…so does one dated by an event" "$(grep 'третий пункт' "$F2/tracks/gamma/index.md")" "product ^"
expect_says "an item that has one keeps it" "$G" "2026-10-07 ^q1w"
expect_not_says "a closed item is left alone" "$(grep 'закрытый пункт' "$F2/tracks/gamma/index.md")" "^"
expect_not_says "a table row is left alone — a block id cannot mark one row" "$(grep 'строка таблицы' "$F2/tracks/gamma/index.md")" "^"
ids="$(grep -oE '\^[a-z][a-z0-9]{2}$' "$F2/tracks/gamma/index.md" | sort)"
[ "$(printf '%s\n' "$ids" | uniq -d)" = "" ] && ok "…every id in the project is unique" || bad "…every id in the project is unique" "$ids"
diff <(grep -v 'первый пункт\|третий пункт' "$TMP/gamma.before") <(grep -v 'первый пункт\|третий пункт' "$F2/tracks/gamma/index.md") >/dev/null \
  && ok "…and every other line is byte for byte as it was" || bad "…and every other line is byte for byte as it was"
out="$(python3 "$NOW" --project-root "$F2" --assign-ids 2>&1)"
expect_says "a second run has nothing to mark" "$out" "0"

# The linter, on a new line. A project with comms.now: an item without an id is
# named, with the command that gives one; a reused id is named too.
printf -- '- [ ] **владелец** — новый пункт без метки ⏰ 2026-10-09\n' >> "$F2/tracks/gamma/index.md"
out="$(python3 "$PEND" --lint "$F2/tracks/gamma/index.md" 2>&1)"; rc=$?
expect_exit "a new item without an id is outside the contract of a now.md project" 1 "$rc"
expect_says "…the linter says so" "$out" "block id"
expect_says "…and how to take one" "$out" "--new-id"
sed -i.bak 's/новый пункт без метки ⏰ 2026-10-09/новый пункт с чужой меткой ⏰ 2026-10-09 ^q1w/' "$F2/tracks/gamma/index.md" && rm -f "$F2/tracks/gamma/index.md.bak"
out="$(python3 "$PEND" --lint "$F2/tracks/gamma/index.md" 2>&1)"
expect_says "an id already used in the project is named" "$out" "q1w"
python3 - "$F2/.claude/vdm-plugins.json" <<'EOF2'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); del c["comms"]["now"]; json.dump(c, open(p, "w"))
EOF2
sed -i.bak 's/ ^q1w$//' "$F2/tracks/gamma/index.md" && rm -f "$F2/tracks/gamma/index.md.bak"
out="$(python3 "$PEND" --lint "$F2/tracks/gamma/index.md" 2>&1)"; rc=$?
expect_exit "a project without now.md is not asked for ids — the same file lints clean" 0 "$rc"

echo "== now.md behind the homes: said by the hook and at session start, never rebuilt by them =="
# DL #1, #9: the plugin's hooks write no project files. They compare what now.md
# was built from — a digest of the open items and drafts in its frontmatter —
# with the homes as they are, and say "behind" with the command that rebuilds.
# By content, not by time: a touch is not a change, an edit of prose is not one
# either, and a box ticked in Obsidian is.
F3="$TMP/stale"; mkdir -p "$F3/.claude" "$F3/tracks/delta/comms"
git -C "$F3" init -q
printf '# Delta\n\nПроза трека.\n\n## Наши действия\n\n- [ ] **владелец** — пункт один ⏰ 2026-10-06 ^s1a\n- [ ] **product** — пункт два ⏰ 2026-10-07 ^s2b\n' > "$F3/tracks/delta/index.md"
printf '{"comms": {"pending-paths": ["tracks/*/index.md"], "pending-sections": {"action": ["Наши действия"]}, "owners": ["владелец", "product"], "now": {"owner": ["владелец"], "echelon": false}}}\n' > "$F3/.claude/vdm-plugins.json"
chk() { python3 "$NOW" --project-root "$F3" --check "$@" 2>&1; }
out="$(chk)"; rc=$?
expect_exit "no now.md yet — the check says so" 1 "$rc"
expect_says "…with the command that builds it" "$out" "comms-now.sh"
python3 "$NOW" --project-root "$F3" >/dev/null 2>&1
expect_says "the build records what it was built from" "$(cat "$F3/signals/now.md")" "homes: "
out="$(chk)"; rc=$?
expect_exit "fresh — the check is silent, exit 0" 0 "$rc"
[ -z "$out" ] && ok "…and prints nothing" || bad "…and prints nothing" "$out"
touch "$F3/tracks/delta/index.md"
out="$(chk)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a touch without a change is not a change" || bad "a touch without a change is not a change" "rc=$rc $out"
sed -i.bak 's/Проза трека./Проза трека, поправленная./' "$F3/tracks/delta/index.md" && rm -f "$F3/tracks/delta/index.md.bak"
out="$(chk)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "an edit of prose, no item touched, is not behind" || bad "an edit of prose, no item touched, is not behind" "rc=$rc $out"
sed -i.bak 's/^- \[ \] \*\*владелец\*\* — пункт один/- [x] **владелец** — пункт один/' "$F3/tracks/delta/index.md" && rm -f "$F3/tracks/delta/index.md.bak"
out="$(chk)"; rc=$?
expect_exit "a box ticked in the home — now.md is behind" 1 "$rc"
expect_says "…the check says so" "$out" "behind"
expect_says "…with the command that rebuilds it" "$out" "comms-now.sh"
python3 "$NOW" --project-root "$F3" >/dev/null 2>&1
printf -- '---\ndraft: true\n---\n\nТекст.\n' > "$F3/tracks/delta/comms/2026-09-30-x-out.md"
out="$(chk)"; rc=$?
expect_exit "a new unsent draft — behind too: the owner's move changed" 1 "$rc"
# While now.md IS behind: a write to a file that feeds nothing must still be
# silent — otherwise every note in the tree would repeat the same line.
printf '# Notes\n' > "$F3/tracks/delta/notes.md"
out="$(chk --file "$F3/tracks/delta/notes.md")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "--file on a file that feeds no now.md is silent, even with now.md behind" || bad "--file on a file that feeds no now.md is silent, even with now.md behind" "rc=$rc $out"
python3 "$NOW" --project-root "$F3" >/dev/null 2>&1

HOOK="$P/scripts/comms-pending.sh"
payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1]}}))' "$1"; }
sed -i.bak 's/^- \[ \] \*\*product\*\* — пункт два/- [x] **product** — пункт два/' "$F3/tracks/delta/index.md" && rm -f "$F3/tracks/delta/index.md.bak"
out="$(payload "$F3/tracks/delta/index.md" | (cd "$F3" && bash "$HOOK" --hook) 2>/dev/null)"; rc=$?
expect_exit "the hook after an edit of a home does not block" 0 "$rc"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; sys.exit(0 if d["hookEventName"]=="PostToolUse" and "behind" in d["additionalContext"] else 1)' 2>/dev/null; then
  ok "…and tells the assistant now.md is behind, as additionalContext"
else
  bad "…and tells the assistant now.md is behind, as additionalContext" "stdout: ${out:-<empty>}"
fi
out="$(payload "$F3/tracks/delta/notes.md" | (cd "$F3" && bash "$HOOK" --hook) 2>&1)"
[ -z "$out" ] && ok "the hook on a file that feeds no now.md says nothing" || bad "the hook on a file that feeds no now.md says nothing" "$out"
out="$(cd "$F3" && printf '{}' | CLAUDE_PROJECT_DIR="$F3" bash "$P/scripts/comms-pending-check.sh" 2>&1)"
expect_says "session start names a now.md that fell behind outside the session" "$out" "behind"

echo "== english labels, markdown links =="
cfg '{"owner": ["владелец"]}'
python3 - "$FX/.claude/vdm-plugins.json" <<'EOF'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c["comms"]["labels"] = "en"; c["comms"]["link-style"] = "markdown"
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
EOF
rm -f "$N"; build >/dev/null
F="$(cat "$N")"
expect_says "english headings follow comms.labels" "$F" "## Your move"
expect_says "a markdown link keeps the block anchor" "$F" "(../tracks/beta/index.md#^b1x)"
expect_says "no instructions configured — the first line says so" "$F" "comms.now.instructions"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

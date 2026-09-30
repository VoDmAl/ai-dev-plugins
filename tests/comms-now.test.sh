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
      GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_INDEX_VERSION 2>/dev/null || true

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

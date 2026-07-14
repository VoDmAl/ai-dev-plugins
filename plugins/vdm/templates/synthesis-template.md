---
# Synthesis document — the layer that answers "how is this put together, as a whole".
#
# Fragments (feature docs, decision logs, tickets) accumulate on their own.
# Synthesis does not: it has to be REBUILT, and nothing rebuilds it unless
# something asks. This frontmatter is what makes the asking mechanical.

# `type` — human-facing label. No mechanical role; name it whatever fits the
# project (model / architecture / event-map / domain).
type: model

# `question` — REQUIRED by convention, and the most valuable line in the file.
# The identity rule: a synthesis document is defined by the question it answers,
# not by the files it happens to contain. If you cannot state the question, you
# do not have a synthesis — you have a pile.
# Real examples, found in the field rather than invented:
#   "Откуда событие берётся, куда уходит и что сломается, если тронуть"
#   "Какие конверсии у нас есть, куда они уезжают, и проверено ли это"
question: "<the one question a reader opens this file to get answered>"

# `covers` — REQUIRED. This is the machine contract: the discovery key AND the
# input of the drift signal. Globs/paths relative to the repo root. Anything
# listed here that grows newer than this file means this file has fallen behind.
# A document without `covers:` is invisible to the suite — by design, because
# without it drift cannot be computed at all.
covers:
  - docs/features/*.md
  - src/<the-subsystem>/

# `observed` — absolute date this was last verified against reality.
# ABSOLUTE DATES ONLY, everywhere in this file. "recently", "2 years ago",
# "last sprint" lie silently a year later, because nobody re-reads a document
# to re-anchor its relative dates.
observed: {{TODAY}}
---

# {{TITLE}}

> **Отвечает на вопрос:** <повтори `question:` человеческими словами>
> **Проверено:** {{TODAY}}

## Как это устроено сейчас

<!-- ТОЛЬКО ТЕКУЩЕЕ СОСТОЯНИЕ. Это закон всех долгоживущих документов суиты,
     а не стилевая придирка: документ, который начинается с «было», заставляет
     КАЖДОГО читателя проигрывать всю хронологию, чтобы добраться до правды.
     История — ниже, во врезке, и читать её необязательно. -->

Проза, а не список ссылок. Читатель пришёл за выводом об общности — за тем,
чего нельзя получить, прочитав десять фрагментов по очереди. Если этот раздел
можно собрать, склеив заголовки покрываемых документов, — синтеза не произошло.

## Единый источник истины

<!-- Идентификаторы, ключи, адреса — живут РОВНО В ОДНОМ месте, остальные на
     него ссылаются. Скопированный ID протухает молча: его никто не
     перепроверяет, потому что он «уже записан». -->

| Что | Значение | Где живёт |
|-----|----------|-----------|
|     |          |           |

## Чем это проверяется

<!-- Как читатель убеждается, что документ не врёт? Лестница детекторов, от
     лучшего к худшему:
       1. отпечаток (fingerprint/hash) внешней системы — совпал, значит актуально;
       2. диффабельный экспорт — перегенерировать и посмотреть `git diff`;
       3. дата наблюдения + жест обновления — эвристика, худший вариант.
     Возьмите самый высокий, доступный вашей системе, и назовите его здесь.
     Новый режим отказа → новый ассерт в скрипте, а не «запомнить на будущее». -->

## История

<!-- Археология: демонтированные схемы, отменённые решения. Читать
     необязательно — сюда идут только за ответом «а почему не сделали иначе».
     Ничего отсюда не должно требоваться, чтобы понять раздел «Как это устроено
     сейчас». -->

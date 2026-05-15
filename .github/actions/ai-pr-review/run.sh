#!/usr/bin/env bash
set -euo pipefail

echo "== AI PR Review Action =="

echo "Repository: ${INPUT_REPOSITORY}"
echo "PR number: ${INPUT_PR_NUMBER}"
echo "Base ref: ${INPUT_BASE_REF}"
echo "Head ref: ${INPUT_HEAD_REF}"
echo "Diff file: ${INPUT_DIFF_FILE}"
echo "Changed files file: ${INPUT_CHANGED_FILES_FILE}"
echo "Output file: ${INPUT_OUTPUT_FILE}"
echo "Run Go checks: ${INPUT_RUN_GO_CHECKS}"
echo "Post comment: ${INPUT_POST_COMMENT}"

if [ -z "${YANDEX_API_KEY:-}" ]; then
  echo "YANDEX_API_KEY is required. Add it to GitHub Secrets and pass it via env." >&2
  exit 1
fi

if [ ! -f "${INPUT_DIFF_FILE}" ]; then
  echo "Diff file not found: ${INPUT_DIFF_FILE}" >&2
  exit 1
fi

mkdir -p "$(dirname "${INPUT_OUTPUT_FILE}")"
mkdir -p .qwen

echo "== Create Qwen settings =="

python3 - <<'PY'
import json
import os
from pathlib import Path

model_id = os.environ["INPUT_MODEL_ID"]
base_url = os.environ["INPUT_BASE_URL"]

settings = {
    "modelProviders": {
        "openai": [
            {
                "id": model_id,
                "name": "Qwen3 235B Yandex AI Studio",
                "envKey": "YANDEX_API_KEY",
                "baseUrl": base_url,
                "generationConfig": {
                    "timeout": 120000,
                    "maxRetries": 2,
                    "contextWindowSize": 128000,
                    "samplingParams": {
                        "temperature": 0.3,
                        "max_tokens": 8192
                    }
                }
            }
        ]
    },
    "$version": 3,
    "model": {
        "name": model_id
    },
    "security": {
        "auth": {
            "selectedType": "openai"
        }
    }
}

Path(".qwen/settings.json").write_text(
    json.dumps(settings, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

echo "== Build Qwen prompt =="

python3 - <<'PY'
import os
from pathlib import Path

repository = os.environ.get("INPUT_REPOSITORY", "")
pr_number = os.environ.get("INPUT_PR_NUMBER", "")
base_ref = os.environ.get("INPUT_BASE_REF", "")
head_ref = os.environ.get("INPUT_HEAD_REF", "")
diff_file = os.environ["INPUT_DIFF_FILE"]
changed_files_file = os.environ.get("INPUT_CHANGED_FILES_FILE", "")
run_go_checks = os.environ.get("INPUT_RUN_GO_CHECKS", "false")
extra_prompt = os.environ.get("INPUT_EXTRA_PROMPT", "").strip()

diff = Path(diff_file).read_text(encoding="utf-8", errors="replace")

if changed_files_file and Path(changed_files_file).exists():
    changed_files = Path(changed_files_file).read_text(encoding="utf-8", errors="replace")
else:
    changed_files = "changed-files.txt not found."

if run_go_checks == "true":
    checks_text = """
6. Запусти проверки:
   - go test ./...
   - go vet ./...
   Если команда не может быть выполнена, объясни почему.
7. Сравни вывод CLI-команд с анализом diff.
"""
else:
    checks_text = """
6. Не запускай go test и go vet, если это не Go-проект или если проверки не нужны для анализа.
"""

prompt = f"""Ты — строгий, но прагматичный code reviewer.

Проверь Pull Request.

Repository: {repository}
PR: #{pr_number}
Base branch: {base_ref}
Head branch: {head_ref}

Ниже дан diff текущей ветки PR относительно целевой ветки PR.
Но НЕ ограничивайся только diff.

Используй доступные CLI tools, чтобы проверить изменения в контексте репозитория:

1. Посмотри структуру проекта.
2. Прочитай изменённые файлы из diff.
3. Прочитай связанные файлы, которые импортируются или используются изменённым кодом.
4. Найди определения вызываемых функций и типов, если это нужно для проверки.
5. Проверь, нет ли очевидных ошибок логики, безопасности, совместимости и обработки ошибок.
{checks_text}

Важно:
- Не изменяй файлы.
- Не делай commit.
- Не делай push.
- Не исправляй код автоматически.
- Твоя задача — только review.
- Не выдумывай проблемы, которых нет.
- Если серьёзных проблем нет, так и напиши.
- Если проблема подтверждается CLI-командой, явно напиши это.
- В разделе "Что проверил через CLI" не перечисляй внутренние tool names вроде read_file, grep_search, list_directory.
- Пиши человечески: "прочитал README", "проверил изменённый файл", "посмотрел структуру проекта".

{extra_prompt}

Ответь по-русски в формате:

## Краткое резюме

## Что проверил через CLI

## Найденные проблемы

Для каждой проблемы укажи:
- severity: low / medium / high
- file: путь к файлу
- line: примерная строка, если понятно
- issue: что не так
- evidence: чем подтверждается
- recommendation: что исправить

## Что проверить тестами

## Итоговый риск

low / medium / high

Changed files:

----- CHANGED FILES START -----
{changed_files}
----- CHANGED FILES END -----

Diff:

----- DIFF START -----
{diff}
----- DIFF END -----
"""

Path("qwen-prompt.md").write_text(prompt, encoding="utf-8")
PY

echo "Prompt size:"
wc -c qwen-prompt.md || true

echo "Prompt preview:"
sed -n '1,120p' qwen-prompt.md || true

echo "== Run Qwen Code =="

set +e

cat qwen-prompt.md | qwen \
  --prompt \
  --approval-mode=yolo \
  --append-system-prompt "You are running in GitHub Actions CI. Use CLI tools to inspect the repository, read files, run git commands, and run checks if requested. Do not modify files. Do not commit. Do not push." \
  > "${INPUT_OUTPUT_FILE}" \
  2> qwen-stderr.log

QWEN_EXIT_CODE=$?

set -e

if [ "${QWEN_EXIT_CODE}" -ne 0 ]; then
  echo "Qwen failed with exit code ${QWEN_EXIT_CODE}" >&2
  echo "== Qwen stderr =="
  cat qwen-stderr.log || true
  exit "${QWEN_EXIT_CODE}"
fi

echo "== Check whether Qwen modified tracked files =="

if ! git diff --quiet; then
  echo "::warning::Qwen modified tracked files. Reverting tracked changes."
  git diff --name-status || true
  git checkout -- .
fi

echo "== Qwen review =="
cat "${INPUT_OUTPUT_FILE}"

REVIEW_SUMMARY="$(head -n 20 "${INPUT_OUTPUT_FILE}" | tr '\n' ' ' | cut -c1-500)"

{
  echo "review_file=${INPUT_OUTPUT_FILE}"
  echo "review_summary=${REVIEW_SUMMARY}"
} >> "${GITHUB_OUTPUT}"

if [ "${INPUT_POST_COMMENT}" = "true" ]; then
  echo "== Post review comment to GitHub PR =="

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN is required when post_comment=true" >&2
    exit 1
  fi

  if [ -z "${INPUT_PR_NUMBER}" ]; then
    echo "pr_number is required when post_comment=true" >&2
    exit 1
  fi

  python3 - <<'PY'
import json
import os
from pathlib import Path

review_file = os.environ["INPUT_OUTPUT_FILE"]
body = Path(review_file).read_text(encoding="utf-8", errors="replace")

Path("comment.json").write_text(
    json.dumps({"body": body}, ensure_ascii=False),
    encoding="utf-8",
)
PY

  curl -fsS -X POST \
    "https://api.github.com/repos/${INPUT_REPOSITORY}/issues/${INPUT_PR_NUMBER}/comments" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data @comment.json

  echo "Comment posted."
fi

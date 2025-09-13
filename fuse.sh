#!/usr/bin/env bash

set -euo pipefail

VERSION="0.1"
MODE="consensus"
CONFIG="providers.txt"
TIMEOUT=0
JUDGE=""
MAX_CHARS=6000
OUTPUT_WORD_CAP=0
DEFAULT_WORD_CAP=350
MD=0
COLOR_MODE="auto"

usage() {
  cat <<EOF
FUSE v$VERSION — Parallel Multi-Model Judge & Merge
Usage: $0 [-c providers.txt] [-m raw|consensus|judgeonly] [-t timeout] [-j judge_name] [-x max_chars] [-w words] [-C] "your prompt"
  -c file       Providers config (default: providers.txt)
  -m mode       raw | consensus | judgeonly  (default: consensus)
  -t timeout    Per-provider timeout in seconds (0 = no timeout)
  -j judge      Force judge provider name
  -x max_chars  Max chars per candidate included in judge prompt (default: $MAX_CHARS)
  -w words      Hard-cap judge output to N words (0 = unlimited)
  -C            Disable colored output (same as NO_COLOR=1)
  -h            Help

Environment variables (optional):
  NVM_DIR                Override nvm directory (default: $HOME/.nvm)
  FUSE_NODE_VERSION      If set, attempt 'nvm use <version>' (e.g. 20, v20.11.1, lts/*)
  FUSE_SKIP_NODE_SETUP   If '1', skip any nvm/node detection
EOF
}

# Portable Node environment loader (replaces hardcoded path)
load_node_env() {
  if [ "${FUSE_SKIP_NODE_SETUP:-0}" = "1" ]; then
    return
  fi

  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$nvm_dir/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$nvm_dir/nvm.sh" || {
      echo "[FUSE] Warning: Failed sourcing nvm at $nvm_dir/nvm.sh" >&2
      return
    }
    if [ -n "${FUSE_NODE_VERSION:-}" ]; then
      if ! nvm use "${FUSE_NODE_VERSION}" >/dev/null 2>&1; then
        echo "[FUSE] Warning: nvm use ${FUSE_NODE_VERSION} failed; continuing with default node ($(command -v node || echo 'none'))" >&2
      fi
    fi
  else
    :
  fi
}

while getopts ":c:m:t:j:x:w:Cdh" opt; do
  case $opt in
    c) CONFIG="$OPTARG" ;; 
    m) MODE="$OPTARG" ;; 
    t) TIMEOUT="$OPTARG" ;; 
    j) JUDGE="$OPTARG" ;; 
    x) MAX_CHARS="$OPTARG" ;; 
    w) OUTPUT_WORD_CAP="$OPTARG" ;; 
    C) COLOR_MODE="never" ;; 
    h) usage; exit 0 ;; 
    \?) echo "Unknown option -$OPTARG" >&2; usage; exit 1 ;; 
  esac
done
shift $((OPTIND -1))

PROMPT_INPUT="${1:-}"
[ -z "$PROMPT_INPUT" ] && { echo "Error: prompt required."; usage; exit 1; }

[ -f "$CONFIG" ] || { echo "Error: config file not found: $CONFIG"; exit 1; }

SCRATCH="")(mktemp -d 2>/dev/null || mktemp -d -t fuse)"
cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
trap cleanup EXIT

infer_word_cap() {
  awk 'BEGIN{IGNORECASE=1}
    {gsub(/\n/," "); txt=$0;
     m=0;
     while (match(txt,/(under|max(imum)?|no more than|less than|limit(ed)? to|up to)[[:space:]]+([0-9]{1,5})[[:space:]]+words/)) {
       n=substr(txt, RSTART, RLENGTH);
       gsub(/[^0-9]/, "", n);
       if (n+0>0 && (m==0 || n+0<m)) m=n+0;
       txt=substr(txt, RSTART+RLENGTH);
     }
     print m;
    }' <<< "$PROMPT_INPUT"
}

cap_words() {
  local limit="$1"
  awk -v limit="$limit" '
    {
      if (count + NF <= limit) {
        print $0;
        count += NF;
      } else {
        need = limit - count;
        if (need > 0) {
          for (i=1; i<=need; i++) {
            printf("%s%s", $i, (i<need?OFS:""));
          }
          printf("\n");
        }
        exit;
      }
    }
  '
}

prompt_forbids_fences() {
  echo "$PROMPT_INPUT" | grep -Eiq "no code fence|no code fences|no code blocks"
}

PROVIDERS=()
COMMANDS=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "${line// }" ] && continue
  case "$line" in #*) continue;; esac
  IFS='|' read -r name cmd <<<"$line"
  if [ -n "${name:-}" ] && [ -n "${cmd:-}" ]; then
    PROVIDERS+=("$name")
    COMMANDS+=("$cmd")
  fi
done < "$CONFIG"

[ "
${#PROVIDERS[@]}" -gt 0 ] || { echo "No valid providers in $CONFIG. Format: name|command_with_$PROMPT" >&2; exit 1; }

printf "FUSE — Parallel Multi-Model Judge & Merge\n"
printf "Providers: %s\n" "$(IFS=, ; echo "${PROVIDERS[*]}")"
printf "─────────────────────────────────────────\n"

use_colors=false
case "$COLOR_MODE" in
  always) use_colors=true ;; 
  never)  use_colors=false ;; 
  *)
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${CLICOLOR:-1}" != "0" ]; then
      use_colors=true
    fi
    ;;
esac
if $use_colors; then
  GREEN="\033[32m"; RED="\033[31m"; NC="\033[0m"
else
  GREEN=""; RED=""; NC=""
fi

PIDS=()
OUTFILES=()
ERRFILES=()
TIMES=()
WORDS=()
STATUSES=()

i=0
global_start=$(date +%s)
for name in "${PROVIDERS[@]}"; do
  outfile="$SCRATCH/${name}.out"
  errfile="$SCRATCH/${name}.err"
  OUTFILES+=("$outfile")
  ERRFILES+=("$errfile")

  (
    load_node_env

    echo "Subshell PATH: $PATH" >> "$errfile"
    echo "Node check: $(command -v node || echo 'node MIA')" >> "$errfile"
    echo "Gemini check: $(command -v gemini || echo 'gemini MIA')" >> "$errfile"
    echo "Qwen check: $(command -v qwen || echo 'qwen MIA')" >> "$errfile"

    s=$(date +%s)
    ( PROMPT="$PROMPT_INPUT" bash -c "${COMMANDS[$i]}" ) >"$outfile" 2>"$errfile" &
    cpid=$!
    waited=0
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 1
      waited=$((waited+1))
      if [ "$TIMEOUT" -gt 0 ] && [ "$waited" -ge "$TIMEOUT" ]; then
        kill "$cpid" 2>/dev/null || true
        echo "[FUSE] Timeout after ${TIMEOUT}s" >>"$errfile"
        exit 124
      fi
    done
    wait "$cpid"
    rc=$?
    e=$(date +%s)
    echo "$rc $s $e" > "$SCRATCH/${name}.meta"
    exit "$rc"
  ) &
  PIDS+=($!)
  i=$((i+1))
done

FASTEST_NAME=""
FASTEST_TIME=999999
for idx in "${!PIDS[@]}"; do
  name="${PROVIDERS[$idx]}"
  pid="${PIDS[$idx]}"
  if wait "$pid"; then
    read rc s e < "$SCRATCH/${name}.meta"
    dur=$((e - s))
    [ "$dur" -lt "$FASTEST_TIME" ] && { FASTEST_TIME="$dur"; FASTEST_NAME="$name"; }
    wc_out=$(wc -w < "${OUTFILES[$idx]}" 2>/dev/null || echo 0)
    TIMES[$idx]="$dur"
    WORDS[$idx]="$wc_out"
    STATUSES[$idx]="ok"
  else
    if [ -f "$SCRATCH/${name}.meta" ]; then
      read rc s e < "$SCRATCH/${name}.meta"
      dur=$((e - s))
    else
      dur=0
    fi
    TIMES[$idx]="$dur"
    WORDS[$idx]="0"
    STATUSES[$idx]="fail"
  fi
done

for idx in "${!PROVIDERS[@]}"; do
  name="${PROVIDERS[$idx]}"
  status="${STATUSES[$idx]}"
  dur="${TIMES[$idx]}"
  words="${WORDS[$idx]}"
  status_sym=$([ "$status" = "ok" ] && echo "${GREEN}✓${NC}" || echo "${RED}✗${NC}")
  if [ "$status" = "ok" ]; then
    printf "%s %-7s %5.2fs   %s words\n" "$status_sym" "$name" "$dur" "$words"
  else
    printf "%s %-7s %5.2fs   (failed)\n" "$status_sym" "$name" "$dur"
    if [ -s "${ERRFILES[$idx]}" ]; then
      echo "ERR DEBUG for $name:" >&2
      cat "${ERRFILES[$idx]}" >&2
      echo "" >&2
    fi
  fi
done

total_dur=$(( $(date +%s) - global_start ))
printf "\nTotal runtime: %.2fs\n" "$total_dur"

if [ "$MODE" = "raw" ]; then
  for idx in "${!PROVIDERS[@]}"; do
    name="${PROVIDERS[$idx]}"
    if [ "$MD" = 1 ]; then
      echo "## [$name]"
    else
      echo "----- [$name] -----"
    fi
    if [ "${STATUSES[$idx]}" = "ok" ]; then
      if [ "$MD" = 1 ]; then
        sed 's/^/| /' "${OUTFILES[$idx]}" | sed '$s/|$/|/'
      else
        cat "${OUTFILES[$idx]}"
      fi
    else
      echo "(failed)"
      [ -s "${ERRFILES[$idx]}" ] && cat "${ERRFILES[$idx]}"
    fi
    if [ "$MD" != 1 ]; then echo; fi
  done
  exit 0
fi

if [ -z "$JUDGE" ]; then
  JUDGE="$FASTEST_NAME"
fi

JUDGE_IDX=-1
for idx in "${!PROVIDERS[@]}"; do
  if [ "${PROVIDERS[$idx]}" = "$JUDGE" ]; then JUDGE_IDX="$idx"; break; fi
done
if [ "$JUDGE_IDX" -lt 0 ]; then
  for idx in "${!PROVIDERS[@]}"; do
    if [ "${STATUSES[$idx]}" = "ok" ]; then
      JUDGE_IDX="$idx"; JUDGE="${PROVIDERS[$idx]}"; break; fi
    fi
  done
fi

if [ "$JUDGE_IDX" -lt 0 ]; then
  echo "— JUDGE: none —" >&2
  echo "(No successful providers available to judge. Showing raw outputs.)" >&2
  for idx in "${!PROVIDERS[@]}"; do
    name="${PROVIDERS[$idx]}"
    echo "----- [$name] -----"
    if [ "${STATUSES[$idx]}" = "ok" ]; then
      cat "${OUTFILES[$idx]}"
    else
      echo "(failed)"; [ -s "${ERRFILES[$idx]}" ] && cat "${ERRFILES[$idx]}"
    fi
    echo
  done
  exit 0
fi

trim() {
  awk -v max="$MAX_CHARS" 'BEGIN{cnt=0} {len=length($0)+1; if (cnt+len<=max){print; cnt+=len} }'
}

JUDGE_PROMPT_FILE="$SCRATCH/judge_prompt.txt"
{
  echo "You are an impartial expert judge."
  echo "Task: Read multiple model answers to the SAME prompt and produce a single, concise final answer that:"
  echo " - is factually careful"
  echo " - merges complementary content and removes duplication"
  echo " - resolves conflicts explicitly with rationale"
  echo " - respects any constraints in ORIGINAL PROMPT (length, format)"
  echo " - if none specified, keep it under ${DEFAULT_WORD_CAP} words"
  echo " - use bullet points only if they add clarity"
  echo " - avoid code fences if ORIGINAL PROMPT forbids them"
  echo
  echo "ORIGINAL PROMPT:"
  echo "$PROMPT_INPUT"
  echo
  echo "CANDIDATE ANSWERS:"
  for idx in "${!PROVIDERS[@]}"; do
    name="${PROVIDERS[$idx]}"
    echo "----- BEGIN $name -----"
    if [ "${STATUSES[$idx]}" = "ok" ]; then
      cat "${OUTFILES[$idx]}" | trim
    else
      echo "(failed)"
      [ -s "${ERRFILES[$idx]}" ] && cat "${ERRFILES[$idx]}" | trim
    fi
    echo "----- END $name -----"
    echo
  done
  echo "GRADING RUBRIC FOR MERGE: Prioritize helpfulness (actionable steps), verifiability (when applicable), brevity. Resolve disagreements by majority or strongest evidence."
  echo
  echo "Now write the FINAL MERGED ANSWER."
} > "$JUDGE_PROMPT_FILE"

if [ "$MODE" = "judgeonly" ]; then
  cat "$JUDGE_PROMPT_FILE"
  exit 0
fi

run_provider() {
  local idx=$1
  local prompt=$2
  load_node_env
  PROMPT="$prompt" bash -c "${COMMANDS[$idx]}" 2>&1
}

echo "— JUDGE: $JUDGE —"
PROMPT="$(cat "$JUDGE_PROMPT_FILE")"

INFERRED_CAP=$(infer_word_cap)
EFFECTIVE_WORD_CAP="$OUTPUT_WORD_CAP"
if [ "${EFFECTIVE_WORD_CAP:-0}" -eq 0 ] && [ "${INFERRED_CAP:-0}" -gt 0 ]; then
  EFFECTIVE_WORD_CAP="$INFERRED_CAP"
fi

NO_FENCES_FLAG=0
if prompt_forbids_fences; then NO_FENCES_FLAG=1; fi

postprocess_and_print() {
  local content="$1"
  local out="$content"
  if [ "$NO_FENCES_FLAG" -eq 1 ]; then
    out=$(printf "%s" "$out" | sed '/^```/d')
  fi
  if [ "${EFFECTIVE_WORD_CAP:-0}" -gt 0 ]; then
    out=$(printf "%s\n" "$out" | cap_words "$EFFECTIVE_WORD_CAP")
  fi
  printf "%s\n" "$out"
}

if ! JUDGE_OUT=$(run_provider "$JUDGE_IDX" "$PROMPT"); then
  echo "(Judge '$JUDGE' failed)." >&2
  [ -n "$JUDGE_OUT" ] && { echo "Judge error/output:" >&2; printf "%s\n" "$JUDGE_OUT" | sed -n '1,120p' >&2; }

  FALLBACK_IDXES=()
  while IFS= read -r line; do
    set -- $line
    [ "$2" = "$JUDGE_IDX" ] && continue
    FALLBACK_IDXES+=("$2")
  done < <(
    {
      for idx in "${!PROVIDERS[@]}"; do
        if [ "${STATUSES[$idx]}" = "ok" ]; then
          echo "${TIMES[$idx]} $idx"
        fi
      done
    } | sort -n -k1,1
  )

  for fb_idx in "${FALLBACK_IDXES[@]}"; do
    fb_name="${PROVIDERS[$fb_idx]}"
    echo "— JUDGE FALLBACK: $fb_name —" >&2
    if JUDGE_OUT=$(run_provider "$fb_idx" "$PROMPT"); then
      postprocess_and_print "$JUDGE_OUT"
      exit 0
    else
      [ -n "$JUDGE_OUT" ] && { echo "Fallback judge '$fb_name' failed:" >&2; printf "%s\n" "$JUDGE_OUT" | sed -n '1,120p' >&2; }
    fi
  done

  echo "(All judges failed). Showing raw outputs instead." >&2
  for idx in "${!PROVIDERS[@]}"; do
    name="${PROVIDERS[$idx]}"
    echo "----- [$name] -----"
    if [ "${STATUSES[$idx]}" = "ok" ]; then
      cat "${OUTFILES[$idx]}"
    else
      echo "(failed)"; [ -s "${ERRFILES[$idx]}" ] && cat "${ERRFILES[$idx]}"
    fi
    echo
  done
  exit 0
fi

postprocess_and_print "$JUDGE_OUT"

# End of file

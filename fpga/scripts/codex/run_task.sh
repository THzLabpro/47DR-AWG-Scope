#!/usr/bin/env bash
# Usage: bash scripts/codex/run_task.sh <TASK>
# Runs codex/<TASK>.md with Codex; retries on capacity / rate-limit errors, stops on quota or other failures.
T=$1; W=D:/ClaudeProject/47DR_DAAD/rf_awg_eth_v1; cd $W
for attempt in $(seq 1 20); do
  codex exec --skip-git-repo-check -C $W -m "${CODEX_MODEL:-gpt-6.1-sol}" -c model_reasoning_effort="${CODEX_EFFORT:-max}" --color never \
    -o codex/logs/$T.out.md \
    "Read AGENTS.md, then read and execute codex/$T.md in $W. If earlier partial work for this task exists in your owned files, inspect it and continue rather than redo. Follow the fixed acceptance list exactly. Never edit AGENTS.md, doc/00_ETH_PLAN.md, codex/ or scripts/codex/. Final message must start with CODEX_TASK_DONE $T <status>. Do NOT end your turn while any run is pending or any acceptance item is unfinished: wait for background runs with one blocking command (e.g. a PowerShell loop with Wait-Process or polling a result file every 60 s inside a single tool call), then continue. ${EXTRA_PROMPT}" \
    < /dev/null > codex/logs/$T.attempt$attempt.log 2>&1
  if [ -s codex/logs/$T.out.md ] && grep -q CODEX_TASK_DONE codex/logs/$T.out.md; then echo "DONE attempt=$attempt"; exit 0; fi
  if grep -qiE "^ERROR:.*quota exceeded" codex/logs/$T.attempt$attempt.log; then echo "QUOTA attempt=$attempt"; exit 3; fi
  if grep -qiE "^ERROR:.*rate limit" codex/logs/$T.attempt$attempt.log; then echo "rate limit, retry $attempt"; rm -f codex/logs/$T.out.md; sleep 120; continue; fi
  if grep -qiE "^ERROR:.*capacity" codex/logs/$T.attempt$attempt.log; then echo "capacity, retry $attempt"; rm -f codex/logs/$T.out.md; sleep 180; continue; fi
  if ! grep -qE "^ERROR:" codex/logs/$T.attempt$attempt.log && [ $attempt -lt 6 ]; then echo "ended without DONE, resume $attempt"; mv codex/logs/$T.attempt$attempt.log codex/logs/$T.resume$attempt.log; rm -f codex/logs/$T.out.md; sleep 20; continue; fi
  echo "FAILED attempt=$attempt (no capacity msg)"; exit 1
done
echo "GAVE_UP"; exit 2

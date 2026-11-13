#!/usr/bin/env bash
# GitHub Actions 배포 키가 할 수 있는 일을 deploy.sh 한 가지로 묶는다.
# 서버 배포 계정의 ~/.ssh/authorized_keys에 이렇게 등록한다(README 참고):
#   command="/home/aiot3/<학번>/lolog-infra/scripts/ssh-deploy-gate.sh",restrict ssh-ed25519 AAAA... github-actions
# Actions는 `ssh ... deploy api <SHA>`처럼 부른다.
set -euo pipefail

read -r -a args <<< "${SSH_ORIGINAL_COMMAND:-}"

if [[ "${#args[@]}" -ne 3 || "${args[0]}" != "deploy" ]]; then
  echo "허용된 명령은 'deploy <api|auth> <SHA>' 하나입니다." >&2
  exit 2
fi

exec "$(dirname "$0")/deploy.sh" "${args[1]}" "${args[2]}"

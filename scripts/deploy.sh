#!/usr/bin/env bash
# 서비스 하나를 지정한 이미지 태그로 바꿔 띄운다(deployment.md 8장).
#   사용: scripts/deploy.sh <api|auth> <커밋 SHA>
# GitHub Actions가 SSH로 부르고, 되돌릴 때는 사람이 이전 SHA로 직접 부른다.
# 헬스체크가 2분 안에 200을 못 받으면 이전 태그로 되돌리고 실패로 끝난다.
set -euo pipefail

cd "$(dirname "$0")/.."

service="${1:-}"
tag="${2:-}"

case "$service" in
  api)  var=API_TAG;  health=http://api:8080/api/health ;;
  auth) var=AUTH_TAG; health=http://auth:8081/auth/health ;;
  *) echo "서비스는 api 또는 auth만 됩니다: '$service'" >&2; exit 2 ;;
esac

if [[ ! "$tag" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "태그는 커밋 SHA(16진수 7~40자)여야 합니다: '$tag'" >&2
  exit 2
fi

# 한 번에 하나만 배포한다(api와 auth가 동시에 머지돼도 .env를 같이 고치지 않게).
exec 9>.deploy.lock
flock 9

prev="$(grep -E "^${var}=" .env | cut -d= -f2- || true)"

set_tag() {
  if grep -qE "^${var}=" .env; then
    sed -i "s/^${var}=.*/${var}=$1/" .env
  else
    echo "${var}=$1" >> .env
  fi
}

wait_healthy() {
  for _ in $(seq 1 24); do
    if docker compose exec -T nginx wget -q -O /dev/null "$health" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

echo "[$service] ${prev:-없음} -> $tag"
set_tag "$tag"

if docker compose pull "$service" && docker compose up -d --no-deps "$service" && wait_healthy; then
  echo "[$service] 배포 완료: $tag"
  exit 0
fi

echo "[$service] 헬스체크 실패. 이전 태그로 되돌립니다." >&2
docker compose logs --tail 50 "$service" >&2 || true
if [[ -n "$prev" ]]; then
  set_tag "$prev"
  docker compose up -d --no-deps "$service"
fi
exit 1

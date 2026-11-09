# LOLog-infra

교육기관 서버(s2.java21.net)에 인증, 메인 백엔드, PostgreSQL, Redis를 Docker Compose로 띄우는 설정이에요. 만화 이미지는 교육기관 MinIO에 둬요. 주소·포트·환경 변수의 기준은 LOLog-docs의 [배포 설정](https://github.com/LOLog-2026/LOLog-docs/blob/main/spec/deployment.md)이에요.

이미지를 만드는 `Dockerfile`과 배포 워크플로(`.github/workflows/deploy.yml`)는 각 서비스 레포(lolog-api, lolog-auth)에 있고, 이 레포에는 서버에서 띄우는 설정만 둬요.

## 구조

```
앱 ──https──▶ 학교 Nginx(80·443, 공용, Let's Encrypt)
                 │ lolog.java21.net
                 ▼
   host.docker.internal:NGINX_PORT ─ nginx(우리 Nginx 컨테이너, 0.0.0.0에 엶)
                                     ├─ /auth/**          → auth:8081
                                     ├─ /api/**           → api:8080
                                     ├─ /lolog-comics/**  → 교육기관 MinIO(S3_ENDPOINT) (GET만)
                                     └─ /internal/**      → 404
Jetson ──SSH 터널(8822)──▶ 127.0.0.1:TUNNEL_API_PORT   → api:8080   (/internal)
                          127.0.0.1:TUNNEL_REDIS_PORT → redis:6379 (작업 큐)
```

- 서버는 여러 학생이 같이 써요. 80·443은 학교 Nginx가 쓰고, 우리는 개인 포트 범위 안의 포트 3개만 열어요. nginx(8450)는 학교 Nginx 컨테이너가 닿도록 `0.0.0.0`에, Jetson 터널(8451, 8452)은 `127.0.0.1`에만 열어요. 8450으로 바로 들어와도 `/internal`은 막혀 있고 공개 주소와 같은 것만 보여요.
- 도메인과 HTTPS(Let's Encrypt)는 학교 Nginx가 맡고, 우리 nginx 컨테이너로는 HTTP로 넘겨요. 공개 주소는 `https://lolog.java21.net`이에요. 우리 nginx는 경로 나누기, `/internal` 막기, 로그인·가입 횟수 제한(IP마다 1분에 10번)을 해요.
- 데이터는 Docker 볼륨(`lolog_pgdata`, `lolog_redisdata`)에만 있고 백업하지 않아요. `docker compose down -v`는 쓰지 않아요.

| 파일 | 하는 일 |
| --- | --- |
| `compose.yaml` | 서버 스택 전체 |
| `.env.example` | 서버 `.env`의 틀(포트, 이미지 태그, 비밀값) |
| `nginx/` | 우리 nginx 컨테이너 설정. `lolog.conf.template`은 뜰 때 `S3_ENDPOINT`, `S3_BUCKET`이 채워져요 |
| `scripts/deploy.sh` | 서비스 하나를 새 태그로 바꾸고 헬스체크, 실패하면 이전 태그로 되돌림 |
| `scripts/ssh-deploy-gate.sh` | GitHub Actions 키가 `deploy.sh`만 부르도록 묶음 |
| (lolog-api, lolog-auth) `.github/workflows/deploy.yml` | main push → 테스트 → GHCR 이미지 → 서버의 `scripts/deploy.sh` |

## 처음 한 번 준비

서버에 접속해요(학교 안은 `10.116.64.12`, 밖은 `s2.java21.net`, 포트는 둘 다 8822).

```bash
ssh -p 8822 <학번>@s2.java21.net
```

### 1. 설정 받기와 .env 채우기

```bash
cd ~
git clone https://github.com/LOLog-2026/LOLog-infra.git lolog-infra
cd lolog-infra
cp .env.example .env
chmod 600 .env
vi .env
```

- `NGINX_PORT=8450`, `TUNNEL_API_PORT=8451`, `TUNNEL_REDIS_PORT=8452`: 개인 포트 범위 8450~8459에서 골랐어요(8456, 8457은 이미 사용 중). Jetson 터널 설정도 이 값을 써요. 비어 있는지는 `ss -ltn | grep 845`로 확인해요.
- 비밀값은 `openssl rand -hex 32`로 만들어요. `JWT_SECRET`, `INTERNAL_TOKEN`, `REDIS_PASSWORD`는 Jetson 워커와 같은 값이어야 해서 팀에 따로 전해요(레포·채팅에 올리지 않아요).
- `S3_*`: 교육기관 MinIO에 팀 계정으로 로그인해 버킷(`S3_BUCKET`, 기본 `lolog-comics`)과 접근 키를 만들어 넣어요. `S3_ENDPOINT`는 서버 안에서 MinIO S3 API에 바로 닿는 주소예요(교육기관 MinIO는 서버의 8000 포트라 `http://host.docker.internal:8000`). 학교 Nginx를 거치는 `https://storage.java21.net`은 안 돼요. imageUrl은 `https://lolog.java21.net/<버킷>/...`로 서명되고 우리 nginx가 Host를 그대로 둔 채 MinIO로 넘겨야 서명이 맞는데, 학교 Nginx는 그 Host를 다시 우리에게 보내요.
- `API_TAG`, `AUTH_TAG`는 GHCR에 올라간 이미지의 커밋 SHA예요. 처음에는 Actions 첫 배포가 끝난 뒤 그 SHA를 넣거나, Actions가 넣게 둬요.

### 1-1. FCM 키 넣기

Firebase 콘솔에서 받은 서비스 계정 키(JSON)를 서버의 `~/lolog-infra/secrets/fcm.json`에 둬요. 내 컴퓨터에서:

```bash
ssh -p 8822 <학번>@s2.java21.net 'mkdir -m 700 -p ~/lolog-infra/secrets'
scp -P 8822 <받은 키 파일>.json <학번>@s2.java21.net:~/lolog-infra/secrets/fcm.json
ssh -p 8822 <학번>@s2.java21.net 'chmod 644 ~/lolog-infra/secrets/fcm.json'
```

api 컨테이너는 root가 아닌 사용자로 돌아서 파일은 644여야 읽혀요. 다른 사람은 폴더(700) 때문에 못 봐요. 파일이 없으면 `docker compose up`이 멈춰요.

### 2. GHCR 이미지 받을 수 있게 하기

레포가 public이어도 GHCR 패키지는 처음에 비공개로 만들어져요. 둘 중 하나를 해요.

- (쉬움) 첫 배포 뒤 GitHub 조직 → Packages → `lolog-api`, `lolog-auth` → Package settings → Change visibility → Public
- 또는 서버에서 `read:packages` 권한 토큰으로 `docker login ghcr.io -u <GitHub 아이디>`

### 3. 띄우기

```bash
docker compose up -d
docker compose ps
curl -s http://127.0.0.1:8450/api/health    # {"status":"UP"}
curl -s http://127.0.0.1:8450/auth/health
```

### 4. 학교 Nginx에 도메인 연결

강사님이 알려 주신 Nginx 관리 웹사이트에 로그인해서 도메인을 등록해요.

- 도메인: `lolog.java21.net`
- 유형: 리버스 프록시
- 업스트림: `http://host.docker.internal:8450`

학교 Nginx는 컨테이너 안에서 돌아서 `127.0.0.1`을 적으면 서버가 아니라 그 컨테이너 자신을 가리켜요. 그래서 우리 nginx 포트는 `0.0.0.0`에 열어요(`.env`의 `NGINX_BIND`). Jetson 터널 포트(8451, 8452)는 그대로 `127.0.0.1`에만 열어요.

등록한 뒤 밖에서 `curl https://lolog.java21.net/api/health`가 `{"status":"UP"}`이면 돼요.

### 5. GitHub Actions 배포 키

```bash
ssh-keygen -t ed25519 -N '' -f lolog-deploy -C github-actions
```

`~/.ssh/authorized_keys`에 공개 키를 아래처럼 묶어서 한 줄로 넣어요. 이 키로는 `deploy.sh`만 부를 수 있어요.

```
command="/home/aiot3/<학번>/lolog-infra/scripts/ssh-deploy-gate.sh",restrict ssh-ed25519 AAAA... github-actions
```

lolog-api, lolog-auth 레포(또는 조직)의 Actions secrets에 넣어요. 넣은 뒤 서버의 개인 키 파일은 지워요.

| secret | 값 |
| --- | --- |
| `DEPLOY_HOST` | `s2.java21.net` |
| `DEPLOY_PORT` | `8822` |
| `DEPLOY_USER` | 학번 |
| `DEPLOY_SSH_KEY` | `lolog-deploy` 개인 키 내용 |
| `DEPLOY_KNOWN_HOSTS` | `ssh-keyscan -p 8822 s2.java21.net` 결과 |

배포 job은 `production` environment로 돌아요. 레포 Settings → Environments에서 승인자를 걸면 사람이 누른 뒤에만 배포돼요.

## 배포와 되돌리기

- `main`에 머지하면 Actions가 테스트 → `ghcr.io/lolog-2026/lolog-api:<SHA>` 빌드 → `ssh ... deploy api <SHA>`를 해요.
- `deploy.sh`는 `.env`의 태그를 바꾸고 그 서비스만 다시 띄운 뒤 `/api/health`(또는 `/auth/health`)를 2분까지 기다려요. 안 뜨면 이전 태그로 되돌리고 Actions를 실패로 끝내요.
- 손으로 되돌릴 때: `cd ~/lolog-infra && scripts/deploy.sh api <이전 SHA>`
- 이 레포(compose, nginx 설정)가 바뀌면 서버에서 `git pull` 뒤 `docker compose up -d --force-recreate nginx`(nginx 설정만 바뀐 때) 또는 `docker compose up -d`를 해요. 자동으로 따라가지 않아요. nginx 설정 파일은 바인드 마운트라 `git pull`이나 `vi`로 파일이 새로 써지면 `nginx -s reload`로는 안 읽혀요. 컨테이너를 다시 만들어야 해요.
- 새 환경 변수가 필요하면 머지 전에 서버 `.env`에 먼저 넣어요.

## Jetson 터널

Jetson 워커는 `localhost:6379`(Redis)와 `localhost:18080`(api)로 부르고(deployment.md 7장), 터널이 그 둘을 서버의 터널 포트로 이어요.

서버 `~/.ssh/authorized_keys`에 Jetson 키를 터널만 되게 묶어 넣어요(Jetson마다 한 줄).

```
restrict,port-forwarding,permitopen="127.0.0.1:8452",permitopen="127.0.0.1:8451" ssh-ed25519 AAAA... jetson-1
```

Jetson에서는 autossh를 systemd로 띄워요. 서비스 파일과 설치 순서는 [jetson/README.md](jetson/README.md)에 있어요.

```bash
autossh -M 0 -N -p 8822 \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
  -L 6379:127.0.0.1:8452 \
  -L 18080:127.0.0.1:8451 \
  <학번>@s2.java21.net
```

확인: Jetson에서 `redis-cli -a <REDIS_PASSWORD> ping`이 `PONG`, `curl -s localhost:18080/api/health`가 `{"status":"UP"}`이면 돼요.

## 공용 서버라서 조심할 것


- docker 그룹에 있는 다른 학생은 `docker inspect`로 우리 컨테이너의 환경 변수(비밀번호, JWT 비밀값)를 볼 수 있어요. 시연용 데이터만 두고, 다른 곳에서 쓰는 비밀번호를 재사용하지 않아요.
- `127.0.0.1` 포트도 같은 서버의 다른 계정에서는 보여요. Redis는 비밀번호, `/internal`은 `X-Internal-Token`으로 막혀 있어요.
- 다른 학생의 컨테이너·볼륨은 건드리지 않아요. 우리 것은 이름이 `lolog-`로 시작해요.

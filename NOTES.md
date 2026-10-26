# 포크 작업 노트 (self-host + 모바일 원격 제어)

> 목표: 집 서버(Tailscale 사설망 내)에서 Claude Code를 self-host Happy로 띄우고, 폰(Happy 모바일 앱)으로 타자 입력 원격 제어. 음성은 2순위.
>
> 아래 호스트명/IP는 예시로 치환돼 있음 — 실제 값은 로컬 Tailscale 설정에서 확인.

## 현재까지 한 것

- `slopus/happy` 포크 완료 (`broccoliInDB/happy`), 이 디렉토리가 로컬 클론
- Tailscale 네트워크 정리 (호스트마다 GUI 앱 vs Homebrew 데몬 중복 문제 → 재부팅으로 해결, self-host 서버 머신은 전용 ACL 태그로 분리)
- self-host 서버 머신에 Node, `happy`, `happy-server-self-host`, Claude Code CLI 설치
- `happy server --host <tailnet-ip> --port 3005` 로 self-host 서버 기동
- **버그 1 — 해결**: 모바일 앱의 서버 URL 저장 검증이 `Accept: text/plain`으로 `/`를 요청해 `"Welcome to Happy Server!"` 문자열을 기대하는데, self-host 모드는 `/`를 웹앱 HTML로 서빙해서 항상 실패 → `packages/happy-server/sources/app/api/api.ts`에 `onRequest` 훅 추가해서 그 특정 요청만 가로채 배너 응답 (이 브랜치 `fix/self-host-server-welcome-banner`에 반영)
- **버그 2 — 해결**: Android는 기본적으로 cleartext HTTP를 막아서 `http://`로는 앱이 영원히 "Failed to connect to server" → `tailscale cert`로 Let's Encrypt 인증서 발급 + Node로 직접 만든 HTTPS 리버스 프록시(`~/https-proxy.cjs`, 서버 머신 전용, repo 밖)로 `https://<tailnet-host>:8443` 노출. (`tailscale serve`는 왜인지 프록시 요청이 계속 hang — 원인 못 찾고 자체 프록시로 우회함, 나중에 재조사 여지 있음)
- **버그 3 — 미해결, 진짜 블로커**: `happy-server-self-host`가 쓰는 PGlite + `@prisma/client@6.19.2`(설치 시 `pglite-prisma-adapter@0.7.2`가 `>=7.1.0` 요구 경고 떴던 그 피어 디펜던시 불일치) 조합이 `Session.dataEncryptionKey`(Bytes 컬럼)를 읽을 때 깨짐:
  ```
  PrismaClientKnownRequestError: Inconsistent column data: Conversion failed:
  expected a string or an array in column 'dataEncryptionKey', found {0:.., 1:.., ...}
  ```
  - `prisma.session.findMany()`(복수 조회)에서만 발생 — 터미널이 자기 세션 하나 쓰고 쓰는 건 멀쩡
  - 모바일 앱이 `/v1/sessions`, `/v1/feed` 등 목록 조회할 때마다 500/이상 동작 → 앱에서 세션 목록이 영원히 안 뜸 (지금 이게 "폰으로 원격 조작" 핵심 기능을 막고 있음)
  - DB `--reset`으로 밀어도 재발 — 데이터 문제가 아니라 구조적 (버전 불일치) 문제로 보임

## 결정 — 버그 3 해결 방향

PGlite는 self-host 전용 호환 레이어일 뿐이고 공식 클라우드는 실제 Postgres로 돈다 → **PGlite 대신 외부 Postgres(Docker)로 전환**하는 쪽으로 결정 (Prisma 버전만 맞추는 임시방편은 기각 — 메이저 버전업 리스크 + PGlite 어댑터의 다른 타입에서도 재발할 구조적 위험).

- `happy-server`는 `DATABASE_URL` + `DB_PROVIDER=postgres` 환경변수로 외부 Postgres를 받을 수 있음 (`packages/happy-server/sources/standalone.ts`, `storage/db.ts`)
- 근데 `happy` CLI 래퍼(`packages/happy-cli/src/commands/server.ts`)가 자식 프로세스 환경변수에 `DB_PROVIDER: 'pglite'`를 **하드코딩**해버려서, 그냥 `DATABASE_URL=... happy server`로는 안 먹음 → 이 파일도 패치 필요 (DATABASE_URL이 설정돼 있으면 DB_PROVIDER 강제 오버라이드 안 하도록)

## 다음에 할 일 (우선순위)

1. **버그 3 — Postgres 전환**
   - self-host 서버 머신에 Docker 설치 (현재 없음, 확인됨)
   - Postgres 컨테이너 기동 (예: `docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=... postgres:16`)
   - `happy-cli/src/commands/server.ts`의 `DB_PROVIDER: 'pglite'` 하드코딩 패치 — `DATABASE_URL` 있으면 존중하도록
   - `DATABASE_URL=postgres://...@localhost:5432/happy happy server --host <tailnet-ip> ...`로 기동, 마이그레이션 확인
2. 버그 3 해결 후 → 모바일 앱에서 세션 목록·채팅 뜨는지 end-to-end 테스트 (타자 입력)
3. `tailscale serve`가 왜 hang했는지 재조사 (지금은 자체 Node 프록시로 우회 중 — 임시방편, 정식 해법으로 교체하면 좋음)
4. (보류) 음성 입력 — ElevenLabs Custom Agent ID + bypass 모드
5. (보류) TTS(응답 음성 출력) 추가 — 현재 Happy에 전혀 없는 기능
6. (보류) self-host 음성/HTTPS 설정 가이드를 upstream(`slopus/happy`)에 문서 PR로 기여 — Issue #472, #771 대응
7. (장기) Happy를 기반으로 더 쉬운 전용 모바일 경험(자체 앱)을 만드는 것도 고려 중 — 지금은 self-host 안정화가 선행

## 서버 머신 운영 메모 (일반화된 값, 실제 호스트명/IP는 자기 Tailscale 설정에서 확인)

- happy 서버: `nohup happy server --host <tailnet-ip> --port 3005 --i-understand-this-will-modify-default-happy-settings > /tmp/happy-server.log 2>&1 &`
- HTTPS 프록시: `nohup node ~/https-proxy.cjs > /tmp/https-proxy.log 2>&1 &` (레포 밖, 서버 머신 홈 디렉토리에 있음 — cert/key 경로가 그 머신 고유값으로 하드코딩돼 있으니 복사 시 수정 필요)
- 인증서: `tailscale cert`로 발급 (90일 주기로 재발급 필요)
- SSH: Tailscale SSH 사용, ACL에 클라이언트 태그 → 서버 태그로 포트 22/3005/8443 허용 규칙 필요

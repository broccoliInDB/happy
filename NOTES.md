# 포크 작업 노트 (self-host + 모바일 원격 제어)

> 목표: 집 맥미니(`ccoliui-macmini`, Tailscale)에서 Claude Code를 self-host Happy로 띄우고, 폰(Happy 모바일 앱)으로 타자 입력 원격 제어. 음성은 2순위.

## 현재까지 한 것

- `slopus/happy` 포크 완료 (`broccoliInDB/happy`), 이 디렉토리가 로컬 클론
- Tailscale 네트워크 정리 (노트북·맥미니 양쪽에 GUI 앱 vs Homebrew 데몬 중복 문제 → 재부팅으로 해결, 맥미니는 `tag:main-desktop`로 태그)
- 맥미니에 Node, `happy`, `happy-server-self-host`, Claude Code CLI 설치
- `happy server --host 100.114.63.85 --port 3005` 로 self-host 서버 기동
- **버그 1 — 해결**: 모바일 앱의 서버 URL 저장 검증이 `Accept: text/plain`으로 `/`를 요청해 `"Welcome to Happy Server!"` 문자열을 기대하는데, self-host 모드는 `/`를 웹앱 HTML로 서빙해서 항상 실패 → `packages/happy-server/sources/app/api/api.ts`에 `onRequest` 훅 추가해서 그 특정 요청만 가로채 배너 응답 (이 브랜치 `fix/self-host-server-welcome-banner`에 반영)
- **버그 2 — 해결**: Android는 기본적으로 cleartext HTTP를 막아서 `http://`로는 앱이 영원히 "Failed to connect to server" → `tailscale cert`로 Let's Encrypt 인증서 발급 + Node로 직접 만든 HTTPS 리버스 프록시(`~/https-proxy.cjs`, 맥미니 전용, repo 밖)로 `https://ccoliui-macmini.tail6eb2d2.ts.net:8443` 노출. (`tailscale serve`는 왜인지 프록시 요청이 계속 hang — 원인 못 찾고 자체 프록시로 우회함, 나중에 재조사 여지 있음)
- **버그 3 — 미해결, 진짜 블로커**: `happy-server-self-host`가 쓰는 PGlite + `@prisma/client@6.19.2`(설치 시 `pglite-prisma-adapter@0.7.2`가 `>=7.1.0` 요구 경고 떴던 그 피어 디펜던시 불일치) 조합이 `Session.dataEncryptionKey`(Bytes 컬럼)를 읽을 때 깨짐:
  ```
  PrismaClientKnownRequestError: Inconsistent column data: Conversion failed:
  expected a string or an array in column 'dataEncryptionKey', found {0:.., 1:.., ...}
  ```
  - `prisma.session.findMany()`(복수 조회)에서만 발생 — 터미널이 자기 세션 하나 쓰고 쓰는 건 멀쩡
  - 모바일 앱이 `/v1/sessions`, `/v1/feed` 등 목록 조회할 때마다 500/이상 동작 → 앱에서 세션 목록이 영원히 안 뜸 (지금 이게 "폰으로 원격 조작" 핵심 기능을 막고 있음)
  - DB `--reset`으로 밀어도 재발 — 데이터 문제가 아니라 구조적 (버전 불일치) 문제로 보임

## 다음에 할 일 (우선순위)

1. **버그 3 고치기** — 둘 중 하나:
   - (a) `happy-server-self-host`가 의존하는 `@prisma/client`를 `pglite-prisma-adapter`가 원하는 `>=7.1.0`으로 맞추기 (버전 충돌 재현 → 레포 쪽 `packages/happy-server`/`happy-server-self-host`의 package.json 의존성 고치고 재빌드)
   - (b) PGlite 대신 진짜 Postgres(Docker 등)로 self-host 백엔드 전환 — 더 손이 많이 가지만 PGlite 어댑터 버그 자체를 회피
2. 버그 3 해결 후 → 모바일 앱에서 세션 목록·채팅 뜨는지 end-to-end 테스트 (타자 입력)
3. `tailscale serve`가 왜 hang했는지 재조사 (지금은 자체 Node 프록시로 우회 중 — 임시방편, 정식 해법으로 교체하면 좋음)
4. (보류) 음성 입력 — ElevenLabs Custom Agent ID + bypass 모드
5. (보류) TTS(응답 음성 출력) 추가 — 현재 Happy에 전혀 없는 기능
6. (보류) self-host 음성/HTTPS 설정 가이드를 upstream(`slopus/happy`)에 문서 PR로 기여 — Issue #472, #771 대응

## 맥미니 운영 메모

- happy 서버: `nohup happy server --host 100.114.63.85 --port 3005 --i-understand-this-will-modify-default-happy-settings > /tmp/happy-server.log 2>&1 &`
- HTTPS 프록시: `nohup node ~/https-proxy.cjs > /tmp/https-proxy.log 2>&1 &` (레포 밖, `~/https-proxy.cjs`에 있음 — cert/key 경로 하드코딩돼 있으니 복사 필요하면 참고)
- 인증서: `~/ccoliui-macmini.tail6eb2d2.ts.net.{crt,key}` (`tailscale cert`로 발급, 90일 주기로 재발급 필요)
- SSH: `ssh ccoliui-macmini` (Tailscale SSH, ACL에 `tag:laptop`+`autogroup:member` → `tag:main-desktop`로 포트 22/3005/8443 허용)

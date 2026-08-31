# 백킹 서비스 운영 실습

기업 강의 「Redis · Kafka · MongoDB 운영」의 실습 저장소입니다.

돌려 보지 않은 상태입니다. 슬라이드 1차 완성 후 Azure 에서 검증합니다.

## 지금 담고 있는 것

| 경로 | 내용 |
|---|---|
| `terraform/modules` | 네트워크와 노드. 전 세션 공통 |
| `terraform/01-redis` | 세션 1 스택. Redis 3대 + ops 1대 |
| `ansible` | OS 튜닝, Redis, Sentinel, 관측 스택 |
| `loadgen` | 실습용 적재 스크립트 |

세션 2·3·4의 스택은 각 세션 자료를 만들 때 추가합니다.

## 쓰는 순서

```
cd terraform/01-redis
cp ../session.tfvars.example session.tfvars   # 값을 자기 것으로 고친다
terraform init
terraform apply -var-file=session.tfvars
terraform output
```

`ops_public_ip` 로 SSH 접속한 뒤 `ansible` 디렉터리에서 플레이북을 실행합니다.

```
ansible-playbook -i inventory/hosts.ini play-redis.yml
```

## 환경

| 항목 | 값 |
|---|---|
| 클라우드 | Azure, 한국 중부 (`koreacentral`) |
| OS | Ubuntu 24.04 LTS |
| Redis | 8.10.x |

**이 저장소에 고객사 정보나 계정 정보를 넣지 않습니다.** 공개 저장소입니다.

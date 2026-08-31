# 백킹 서비스 운영 실습

기업 강의 「Redis · Kafka · MongoDB 운영」의 실습 저장소입니다.

세션 1 과 세션 2 의 스택은 Azure 한국 중부에서 실제로 돌려 검증했습니다.
**세션 3 스택은 아직 돌려 보지 않았습니다.** 문법 검사까지만 마쳤습니다.
세션 4 의 스택은 그 세션 자료를 만들 때 추가합니다.

## 지금 담고 있는 것

| 경로 | 내용 |
|---|---|
| `terraform/modules` | 네트워크와 노드. 전 세션 공통 |
| `terraform/01-redis` | 세션 1 스택. Redis 3대 + ops 1대 |
| `terraform/02-mongodb` | 세션 2 스택. MongoDB 3대 + ops 1대. `sharding_enabled` 로 config server 3대와 shard2 3대를 더함 |
| `terraform/03-kafka` | 세션 3 스택. Kafka 3대 + ops 1대. KRaft combined 모드 |
| `ansible` | OS 튜닝, Redis, Sentinel, MongoDB, Kafka, 관측 스택 |
| `loadgen` | 실습용 적재와 부하 스크립트 |

## 쓰는 순서

세션 번호에 맞는 디렉터리에서 시작합니다. 아래는 세션 2 기준입니다.

```
cd terraform/02-mongodb
cp session.tfvars.example session.tfvars   # 값을 자기 것으로 고친다
terraform init
terraform apply -var-file=session.tfvars
terraform output
```

`ops_public_ip` 로 SSH 접속한 뒤 `ansible` 디렉터리에서 플레이북을 실행합니다.

```
ansible-playbook play-mongodb.yml
```

세션마다 플레이북이 다릅니다. 세션 1 은 `play-redis.yml`, 세션 3 은 `play-kafka.yml` 입니다.

세션이 끝나면 같은 디렉터리에서 `terraform destroy -var-file=session.tfvars` 로 지웁니다.
리소스 그룹째 사라지므로 자원이 다음 세션으로 넘어가지 않습니다.

## 환경

| 항목 | 값 |
|---|---|
| 클라우드 | Azure, 한국 중부 (`koreacentral`) |
| OS | Ubuntu 24.04 LTS |
| Redis | 8.10.x |
| MongoDB | 8.3.x |
| Apache Kafka | 4.3.x (KRaft 전용) |

**이 저장소에 고객사 정보나 계정 정보를 넣지 않습니다.** 공개 저장소입니다.

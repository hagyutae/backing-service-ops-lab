# 백킹 서비스 운영 실습

기업 강의 「Redis · Kafka · MongoDB 운영」의 실습 저장소입니다.

네 세션의 스택을 전부 Azure 한국 중부에서 실제로 돌려 검증했습니다.
슬라이드에 실린 명령과 출력은 그 실행에서 얻은 것입니다.

## 지금 담고 있는 것

| 경로 | 내용 |
|---|---|
| `terraform/modules` | 네트워크와 노드. 전 세션 공통 |
| `terraform/01-redis` | 세션 1 스택. Redis 3대 + ops 1대 |
| `terraform/02-mongodb` | 세션 2 스택. MongoDB 3대 + ops 1대. `sharding_enabled` 로 config server 3대와 shard2 3대를 더함 |
| `terraform/03-kafka` | 세션 3 스택. Kafka 3대 + ops 1대. KRaft combined 모드 |
| `terraform/04-operation` | 세션 4 스택. **단계마다 서비스 3대를 갈아 끼운다.** ops 1대는 계속 유지 |
| `ansible` | OS 튜닝, Redis, Sentinel, MongoDB, Kafka, 관측 스택 |
| `loadgen` | 실습용 적재와 부하 스크립트 |
| `scenarios` | 세션 4 장애 주입 스크립트. **전부 `--restore` 로 되돌린다** |

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

세션마다 플레이북이 다릅니다. 세션 1 은 `play-redis.yml`, 세션 3 은 `play-kafka.yml`,
세션 4 는 `play-operation.yml` 입니다.

세션이 끝나면 같은 디렉터리에서 `terraform destroy -var-file=session.tfvars` 로 지웁니다.
리소스 그룹째 사라지므로 자원이 다음 세션으로 넘어가지 않습니다.

## 세션 4 는 쓰는 순서가 다릅니다

서비스 하나를 끝까지 다룬 뒤 다음으로 넘어가므로, 그 구간의 서비스 노드만 띄웁니다.
동시에 존재하는 것은 **항상 4대**입니다.

| 단계 | 노드 |
|---:|---|
| 1 | `ops-1` + `redis-1`·`redis-2`·`redis-3` |
| 2 | `ops-1` + `mongo-1`·`mongo-2`·`mongo-3` |
| 3 | `ops-1` + `kafka-1`·`kafka-2`·`kafka-3` |
| 4 | `ops-1` 만 |

단계는 `session.tfvars` 의 `stage` 로 정합니다. **`-var stage=2` 로만 주지 않습니다.**
Terraform 의 `-var` 는 그 실행에만 적용되고 state 에 남지 않아, 다음 `apply` 에서
값을 다시 주지 않으면 앞 단계 노드가 되살아납니다.

```
# session.tfvars 에서 stage 를 2 로 고친 뒤
terraform apply -var-file=session.tfvars

# 인벤토리를 받아 ops 노드로 옮긴다
terraform output -raw inventory > hosts.ini
scp -i ~/.ssh/rkm hosts.ini azureuser@<ops 공인 IP>:~/ansible/inventory/hosts.ini
```

**인벤토리 갱신을 빠뜨리면 플레이북이 사라진 노드를 찾다가 멈춥니다.**
ops 노드의 인벤토리는 첫 부팅에 만들어지지 않습니다. `custom_data` 에 넣으면 단계를
바꿀 때마다 ops 노드가 새로 만들어져 그때까지 쓴 런북이 사라지기 때문입니다.

`scenarios` 의 주입 스크립트는 **재현과 부하 생성까지만** 합니다. 진단과 복구는
수강생이 손으로 합니다. 전부 `--restore` 로 되돌립니다.

`rb-k01.sh` 는 콘솔 Consumer 의 출력을 느리게 흘려 poll 간격을
넘기는 방식이고, 실습 검증에서 Rebalance 가 반복되는 것을 확인했습니다.
`max.poll.interval.ms` 를 20000 으로 둡니다. 이보다 짧으면 Rebalance 가 너무 잦아
`--describe` 가 표 대신 「is rebalancing」 한 줄만 내놓습니다.

## 환경

| 항목 | 값 |
|---|---|
| 클라우드 | Azure, 한국 중부 (`koreacentral`) |
| OS | Ubuntu 24.04 LTS |
| Redis | 8.10.x |
| MongoDB | 8.3.x |
| Apache Kafka | 4.3.x (KRaft 전용) |

**이 저장소에 고객사 정보나 계정 정보를 넣지 않습니다.** 공개 저장소입니다.

# 세션 2 · MongoDB 운영
#
#
# ── 노드 4대 ─────────────────────────────────────────────────
# mongo-1·mongo-2·mongo-3 : Replica Set 멤버. 3대여야 한 대가 정지해도
#                           과반 2가 남아 선출이 성립한다.
# ops-1                   : Ansible 을 돌리고 Prometheus·Grafana 를 올린다.
#                           mongosh 와 mongodb-database-tools 도 여기 깐다.
#                           이 세션의 모든 명령이 이 노드에서 나간다.
#
# ── 크기를 D2ds_v5 로 정한 이유 ──────────────────────────────
# MongoDB 는 working set 과 인덱스가 WiredTiger 캐시에 들어가는지가 성능을
# 가른다. 캐시 기본값이 (물리 메모리 - 1 GiB) x 0.5 라 메모리가 곧 캐시다.
# 8 GiB 노드에서는 약 3.4 GiB 가 잡히고, 실습 데이터가 20만 건에 storageSize
# 10.7 MB 라 인덱스를 더해도 캐시에 통째로 들어간다.
#
# vCPU 당 메모리가 큰 E 계열이 더 맞지만, 구독의 EBDSv5 패밀리 쿼타가
# 10 vCPU 라 세션 1 과 세션 2 스택이 겹치면 한도를 넘는다. DDSv5 는 100 이다.
#
# ── 디스크를 128 GiB 로 잡은 이유 ────────────────────────────
# 세션 1 은 64 GiB 였다. oplog 기본 크기가 데이터 디스크 여유 공간의 5% 라
# 128 GiB 에서 약 6.3 GiB 가 잡힌다. 하한 990 MB, 상한 50 GB 가 함께 걸린다. 챕터 06 의 oplog 윈도우 실습이 이 값을 쓴다.
# 덤프는 ops 노드의 홈 디렉터리에 쌓이므로 이 디스크와 무관하다.
#
# ── 사설 IP 를 고정하는 이유 ─────────────────────────────────
# 인벤토리를 이 코드가 채워 ops 노드에 배치한다. 동적 할당이면 apply 전에
# 값을 알 수 없어 파일을 만들지 못한다. 서브넷 앞 네 주소는 Azure 예약분이라
# ops-1 이 10.0.1.4, 서비스 노드가 10.0.1.5 부터다.
#
# ── replication 설정을 여기서 넣지 않는 이유 ─────────────────
# mongod.conf 에 replSetName 이 들어가면 그 노드는 rs.initiate() 전까지
# 사용자 데이터베이스에 쓰기도 조회도 받지 않는다. 챕터 03 과 05 의 확인
# 실습이 초기화 전에 오므로, 단독으로 올렸다가 챕터 06 에서 붙인다.
# 그 전환은 Ansible 변수 mongodb_replset_enabled 가 맡는다.

locals {
  prefix = "mongo"

  # 영역 하나가 통째로 사라져도 2대가 남아 과반을 유지한다.
  mongo_nodes = {
    "mongo-1" = { zone = "1", ip = "10.0.1.5" }
    "mongo-2" = { zone = "2", ip = "10.0.1.6" }
    "mongo-3" = { zone = "3", ip = "10.0.1.7" }
  }

  # 챕터 12 에서만 만든다.
  #
  # ── 추가 노드도 mongo 노드와 같은 크기인 이유 ────────────────
  # mongo-1·mongo-2·mongo-3 도 D2ds_v5 (2 vCPU / 8 GiB) 라 크기가 같다.
  #
  # 여기서 더하는 여섯 대는 캐시와 인덱스를 재는 실습을 받지 않는다. config server 는 Chunk 위치
  # 메타데이터만 담고, shard2 는 20만 건을 rs0 과 나눠 갖는다. D2ds_v5 의 기본
  # 캐시 약 3.4 GiB 로도 이 규모는 전부 들어간다.
  #
  # 쿼터는 계열별로 걸린다. 열 대를 전부 D2ds_v5 로 두면 DDSv5 가 20 이고
  # 한도 100 안이다. E 계열이면 EBDSv5 한도 10 을 첫 세 대로 이미 채운다.
  shard_nodes = var.sharding_enabled ? {
    "cfg-1"    = { zone = "1", ip = "10.0.1.8" }
    "cfg-2"    = { zone = "2", ip = "10.0.1.9" }
    "cfg-3"    = { zone = "3", ip = "10.0.1.10" }
    "shard2-1" = { zone = "1", ip = "10.0.1.11" }
    "shard2-2" = { zone = "2", ip = "10.0.1.12" }
    "shard2-3" = { zone = "3", ip = "10.0.1.13" }
  } : {}

  # ops 노드에 배치할 인벤토리.
  #
  # ── sharding_enabled 를 여기에 반영하지 않는 이유 ─────────────
  # 이 값은 ops 노드의 cloud-init(custom_data)에 들어간다. Azure 는
  # custom_data 가 바뀌면 VM 을 새로 만든다. 챕터 12 에서 sharding_enabled 를
  # 켜는 순간 ops 노드가 통째로 다시 만들어져, 수강생이 그때까지 만든 덤프
  # 파일과 explain() 출력이 전부 사라진다. 1회차 검증에서 실제로 그랬다.
  #
  # 그래서 인벤토리는 mongo 와 ops 만 담고 절대 바뀌지 않는다. 챕터 12 의
  # 새 노드 여섯 대는 수강생이 ops 노드에서 이 파일에 [configsvr] 과 [shard2]
  # 두 그룹을 직접 덧붙이는 것으로 처리한다.
  inventory = <<-INV
    # 세션 2 · MongoDB 운영 인벤토리
    # Terraform 이 배치했다. 노드를 늘리면 이 파일을 직접 고친다.

    [mongo]
    ${join("\n", [for name, n in local.mongo_nodes : "${name} ansible_host=${n.ip}"])}

    [ops]
    ops-1 ansible_connection=local

    [all:vars]
    ansible_user=azureuser
    ansible_ssh_private_key_file=~/.ssh/id_rsa

    mongodb_port=27017
    mongodb_replset_name=rs0

    # 챕터 06 에서 -e mongodb_replset_enabled=true 로 덮어써 복제를 켠다.
    mongodb_replset_enabled=false
  INV
}

# 세션이 끝나면 그룹째 사라져야 자원이 다음 세션으로 넘어가지 않는다.
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ops 노드가 서비스 노드에 붙을 때 쓰는 실습용 키 쌍.
# 수강생 키는 ops 접속에만 쓰고, ops 안쪽에서는 이 키를 쓴다.
resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

module "network" {
  source = "../modules/network"

  prefix              = local.prefix
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  allowed_cidrs       = var.allowed_cidrs
  public_ports        = [3000, 9090] # Grafana, Prometheus
  tags                = var.tags
}

module "mongo" {
  source   = "../modules/node"
  for_each = local.mongo_nodes

  name                 = each.key
  resource_group_name  = azurerm_resource_group.this.name
  location             = var.location
  subnet_id            = module.network.subnet_id
  size                 = "Standard_D2ds_v5"
  zone                 = each.value.zone
  private_ip           = each.value.ip
  data_disk_gb         = 128
  public_ip            = false
  ssh_public_key       = file(pathexpand(var.ssh_public_key_path))
  extra_ssh_public_key = tls_private_key.lab.public_key_openssh
  tags                 = var.tags
}

module "shard" {
  source   = "../modules/node"
  for_each = local.shard_nodes

  name                 = each.key
  resource_group_name  = azurerm_resource_group.this.name
  location             = var.location
  subnet_id            = module.network.subnet_id
  size                 = "Standard_D2ds_v5"
  zone                 = each.value.zone
  private_ip           = each.value.ip
  data_disk_gb         = 128
  public_ip            = false
  ssh_public_key       = file(pathexpand(var.ssh_public_key_path))
  extra_ssh_public_key = tls_private_key.lab.public_key_openssh
  tags                 = var.tags
}

module "ops" {
  source = "../modules/node"

  name                = "ops-1"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  subnet_id           = module.network.subnet_id
  size                = "Standard_D2ds_v5"
  zone                = "1"
  private_ip          = "10.0.1.4"
  data_disk_gb        = 64
  public_ip           = true
  ssh_public_key      = file(pathexpand(var.ssh_public_key_path))
  tags                = var.tags

  # ops 노드는 부팅이 끝난 시점에 Ansible control node 로 서 있어야 한다.
  # defer: true 가 없으면 azureuser 홈 디렉터리가 생기기 전에 돌아 실패한다.
  #
  # indent() 값은 6 이다. 10 이 아니다. 근거는 01-redis/main.tf 주석에 있다.
  custom_data = <<-EOT
    #cloud-config
    package_update: true
    packages:
      - ansible
      - git

    write_files:
      - path: /home/azureuser/.ssh/id_rsa
        owner: azureuser:azureuser
        permissions: "0600"
        defer: true
        content: |
          ${indent(6, tls_private_key.lab.private_key_openssh)}
      - path: /home/azureuser/hosts.ini
        owner: azureuser:azureuser
        permissions: "0644"
        defer: true
        content: |
          ${indent(6, local.inventory)}

    runcmd:
      - [su, azureuser, -c, "git clone --depth 1 ${var.lab_repo_url} /home/azureuser/lab"]
      - [su, azureuser, -c, "cp /home/azureuser/hosts.ini /home/azureuser/lab/ansible/inventory/hosts.ini"]
      - [su, azureuser, -c, "ln -sfn /home/azureuser/lab/ansible /home/azureuser/ansible"]
      - [su, azureuser, -c, "ln -sfn /home/azureuser/lab/loadgen /home/azureuser/loadgen"]
  EOT
}

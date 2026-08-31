# 세션 4 · 장애대응 · 모니터링
#
#
# ── 단계별로 서비스 노드를 갈아 끼운다 ───────────────────────
# 이 세션은 서비스 하나를 끝까지 다룬 뒤 다음 서비스로 넘어간다. 그 구간이
# 다루는 서비스의 노드만 있으면 되므로 세 서비스를 동시에 띄우지 않는다.
#
#   1단계  ops-1 + redis-1·2·3     관측 기초부터 Redis 까지
#   2단계  ops-1 + mongo-1·2·3     MongoDB
#   3단계  ops-1 + kafka-1·2·3     Kafka
#   4단계  ops-1                   런북 정리 후 전체 삭제
#
# 동시에 존재하는 노드는 항상 4대다. 세션 1·2·3 과 같은 규모이고,
# 20명 기준 1인 8 vCPU 다. 세 서비스를 함께 띄우면 20 vCPU 가 된다.
#
# ── 전환 한 번에 apply 를 두 번 한다 ────────────────────────
#   세 서비스가 10.0.1.5 부터를 돌려 쓴다. 앞 노드를 지우기 전에 새
#   노드를 만들면 사설 IP 가 겹쳐 그 자리에서 실패한다.
#
#   session.tfvars 에서 stage = 4 로 고친 뒤   terraform apply  (앞 서비스 삭제)
#   session.tfvars 에서 stage = 2 로 고친 뒤   terraform apply  (새 서비스 생성)
#
# 앞 서비스 노드를 지우고 새 노드를 만든다. destroy 를 따로 돌리지 않고
# -target 도 쓰지 않는다. 상태가 어긋난다.
#
# stage 를 -var 로만 주면 안 되는 이유는 variables.tf 주석에 있다.
#
# ── network 와 ops 는 조건 없이 만든다 ──────────────────────
# 단계가 바뀌어도 ops 노드와 공인 IP 가 유지돼야 한다. 그래야 수강생이
# ops 노드에 써 둔 런북과 기록이 살아남고, 접속 주소도 바뀌지 않는다.
#
# ── 사설 IP 를 세 서비스가 공유한다 ─────────────────────────
# 한 번에 한 서비스만 존재하므로 10.0.1.5 부터를 셋이 돌려 쓴다.
# 대역을 나누면 인벤토리와 실습 명령에 서비스마다 다른 주소가 나와
# 수강생이 외울 것이 늘어난다.
#
# ── 크기와 디스크는 세션 1·2·3 과 같다 ──────────────────────
# Redis 와 MongoDB 는 메모리 최적화 E 계열, Kafka 는 범용 D 계열이다.
# 세션 1·2·3 스택의 node 모듈 호출과 같은 값이다. 이 세션에서 바꾸지 않는다.

locals {
  prefix = "ops"

  # 영역 하나가 통째로 사라져도 2대가 남아 과반을 유지한다.
  redis_nodes = var.stage == 1 ? {
    "redis-1" = { zone = "1", ip = "10.0.1.5" }
    "redis-2" = { zone = "2", ip = "10.0.1.6" }
    "redis-3" = { zone = "3", ip = "10.0.1.7" }
  } : {}

  mongo_nodes = var.stage == 2 ? {
    "mongo-1" = { zone = "1", ip = "10.0.1.5" }
    "mongo-2" = { zone = "2", ip = "10.0.1.6" }
    "mongo-3" = { zone = "3", ip = "10.0.1.7" }
  } : {}

  # node_id 는 controller.quorum.voters 와 각 노드의 node.id 에 함께 들어간다.
  # 둘이 어긋나면 브로커가 기동 직후 종료한다.
  kafka_nodes = var.stage == 3 ? {
    "kafka-1" = { zone = "1", ip = "10.0.1.5", node_id = 1 }
    "kafka-2" = { zone = "2", ip = "10.0.1.6", node_id = 2 }
    "kafka-3" = { zone = "3", ip = "10.0.1.7", node_id = 3 }
  } : {}

  # ── 인벤토리는 활성 서비스의 그룹만 담는다 ─────────────────
  # 없는 그룹의 머리를 남기면 monitoring 롤이 빈 job 을 만든다.
  # 그 job 은 대상이 없어 Targets 화면에 아무것도 안 띄우고,
  # 수강생이 「수집이 안 된다」로 읽는다.
  #
  # join 을 쓰고 %{for~} 를 쓰지 않는다. <<-INV 의 들여쓰기 제거는
  # heredoc 리터럴에 직접 적힌 줄에만 걸린다. %{for~} 가 만들어 낸 줄에는
  # 걸리지 않아 앞 공백이 그대로 남고, cloud-init 이 그 파일을 쓸 때
  # YAML 블록의 들여쓰기가 어긋난다. 세션 3 2회차 검증에서 실제로 깨졌다.
  # redis_role 은 롤이 읽지 않지만 세션 1 인벤토리와 형태를 맞춘다.
  # 수강생이 어느 노드가 master 인지 인벤토리에서 바로 본다.
  redis_group = var.stage == 1 ? format("[redis]\n%s\n\n", join("\n",
    [for name, n in local.redis_nodes :
  "${name} ansible_host=${n.ip} redis_role=${name == "redis-1" ? "master" : "replica"}"])) : ""

  mongo_group = var.stage == 2 ? format("[mongo]\n%s\n\n", join("\n",
  [for name, n in local.mongo_nodes : "${name} ansible_host=${n.ip}"])) : ""

  kafka_group = var.stage == 3 ? format("[kafka]\n%s\n\n", join("\n",
  [for name, n in local.kafka_nodes : "${name} ansible_host=${n.ip} kafka_node_id=${n.node_id}"])) : ""

  inventory = <<-INV
    # 세션 4 · 장애대응 · 모니터링 인벤토리
    # Terraform 이 만들었다. 단계가 바뀌면 다시 받아 덮어쓴다.
    #
    #   terraform output -raw inventory
    #
    # 활성 서비스의 그룹만 들어 있다. 나머지 그룹은 아예 없다.

    ${local.redis_group}${local.mongo_group}${local.kafka_group}[ops]
    ops-1 ansible_connection=local

    [all:vars]
    ansible_user=azureuser
    ansible_ssh_private_key_file=~/.ssh/id_rsa

    redis_port=6379
    sentinel_port=26379

    # sentinel.conf.j2 가 이 둘을 읽는다. 없으면 Sentinel play 가 실패한다.
    # master 는 redis-1 이고, Sentinel 3대이므로 과반은 2다.
    redis_master_host=10.0.1.5
    sentinel_quorum=2
    mongodb_port=27017
    mongodb_replset_name=rs0
    mongodb_replset_enabled=true
    kafka_client_port=9092
    kafka_controller_port=9093
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

# 서비스 포트를 공인으로 열지 않는다. 서비스 노드에는 공인 IP 가 없고,
# 클라이언트 접속은 전부 ops 노드 안에서 사설 IP 로 나간다.
module "network" {
  source = "../modules/network"

  prefix              = local.prefix
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  allowed_cidrs       = var.allowed_cidrs
  public_ports        = [3000, 9090] # Grafana, Prometheus
  tags                = var.tags
}

module "redis" {
  source   = "../modules/node"
  for_each = local.redis_nodes

  name                 = each.key
  resource_group_name  = azurerm_resource_group.this.name
  location             = var.location
  subnet_id            = module.network.subnet_id
  size                 = "Standard_E2bds_v5"
  zone                 = each.value.zone
  private_ip           = each.value.ip
  data_disk_gb         = 64
  public_ip            = false
  ssh_public_key       = file(pathexpand(var.ssh_public_key_path))
  extra_ssh_public_key = tls_private_key.lab.public_key_openssh
  tags                 = var.tags
}

module "mongo" {
  source   = "../modules/node"
  for_each = local.mongo_nodes

  name                 = each.key
  resource_group_name  = azurerm_resource_group.this.name
  location             = var.location
  subnet_id            = module.network.subnet_id
  size                 = "Standard_E2bds_v5"
  zone                 = each.value.zone
  private_ip           = each.value.ip
  data_disk_gb         = 128
  public_ip            = false
  ssh_public_key       = file(pathexpand(var.ssh_public_key_path))
  extra_ssh_public_key = tls_private_key.lab.public_key_openssh
  tags                 = var.tags
}

module "kafka" {
  source   = "../modules/node"
  for_each = local.kafka_nodes

  name                 = each.key
  resource_group_name  = azurerm_resource_group.this.name
  location             = var.location
  subnet_id            = module.network.subnet_id
  size                 = "Standard_D2ds_v5"
  zone                 = each.value.zone
  private_ip           = each.value.ip
  data_disk_gb         = 256
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

  # ── cloud-init 에 인벤토리를 넣지 않는다 ────────────────────
  # Azure 는 custom_data 가 바뀌면 VM 을 새로 만든다. 인벤토리를 여기 넣으면
  # 단계를 전환하는 순간 ops 노드가 통째로 다시 만들어져, 수강생이 그때까지
  # 쓴 런북과 적어 둔 값이 전부 사라진다. 세션 2 1회차 검증에서 같은 이유로
  # 덤프 파일이 날아갔고, 그 스택은 인벤토리를 고정해 피했다.
  #
  # 이 세션은 단계가 세 번 바뀌므로 고정으로는 안 된다. 그래서 cloud-init 은
  # 빈 인벤토리 자리만 만들고, 실제 내용은 output 으로 받아 덮어쓴다.
  # 단계마다 있는 플레이북 실행 절차가 그 덮어쓰기부터 시작한다.
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

    runcmd:
      - [su, azureuser, -c, "git clone --depth 1 ${var.lab_repo_url} /home/azureuser/lab"]
      - [su, azureuser, -c, "ln -sfn /home/azureuser/lab/ansible /home/azureuser/ansible"]
      - [su, azureuser, -c, "ln -sfn /home/azureuser/lab/loadgen /home/azureuser/loadgen"]
      - [su, azureuser, -c, "ln -sfn /home/azureuser/lab/scenarios /home/azureuser/scenarios"]
  EOT
}

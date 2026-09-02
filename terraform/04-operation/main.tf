# 세션 4 · 장애대응 · 모니터링
#
#
# ── 열 대를 한 번에 올린다 ───────────────────────────────────
# 세 서비스를 함께 띄운다. 세션 2·3·4 의 실습을 이 스택 하나에서 모두
# 진행하므로, 서비스를 갈아 끼우느라 apply 를 다시 돌리지 않는다.
#
#   ops-1                   Ansible, Prometheus, Grafana, 부하 발생기
#   redis-1·2·3             Redis 와 Sentinel
#   mongo-1·2·3             MongoDB Replica Set
#   kafka-1·2·3             Kafka Broker
#
# 열 대 모두 Standard_D2ds_v5 다. 1인 20 vCPU 이고 20명이면 400 vCPU 다.
# 구독의 DDSv5 한도가 2000 이라 한도 안이다. E 계열을 쓰지 않는 이유는
# EBDSv5 한도가 10 vCPU 라 한 명분도 올리지 못하기 때문이다.
#
# ── 사설 IP 를 서비스마다 나눈다 ─────────────────────────────
# 세 서비스가 동시에 존재하므로 주소를 겹쳐 쓸 수 없다.
#
#   10.0.1.4        ops-1
#   10.0.1.5 .. 7   redis-1·2·3
#   10.0.1.8 .. 10  mongo-1·2·3
#   10.0.1.11 .. 13 kafka-1·2·3
#
# ── 인벤토리는 output 으로 낸다 ──────────────────────────────
# cloud-init 은 부팅할 때 한 번만 돈다. 인벤토리를 거기 넣으면 ops 노드가
# 다시 만들어질 때 수강생이 써 둔 런북과 기록이 사라진다.
#
locals {
  prefix = "ops"

  # 영역 하나가 통째로 사라져도 2대가 남아 과반을 유지한다.
  redis_nodes = {
    "redis-1" = { zone = "1", ip = "10.0.1.5" }
    "redis-2" = { zone = "2", ip = "10.0.1.6" }
    "redis-3" = { zone = "3", ip = "10.0.1.7" }
  }

  mongo_nodes = {
    "mongo-1" = { zone = "1", ip = "10.0.1.8" }
    "mongo-2" = { zone = "2", ip = "10.0.1.9" }
    "mongo-3" = { zone = "3", ip = "10.0.1.10" }
  }

  # node_id 는 controller.quorum.voters 와 각 노드의 node.id 에 함께 들어간다.
  # 둘이 어긋나면 브로커가 기동 직후 종료한다.
  kafka_nodes = {
    "kafka-1" = { zone = "1", ip = "10.0.1.11", node_id = 1 }
    "kafka-2" = { zone = "2", ip = "10.0.1.12", node_id = 2 }
    "kafka-3" = { zone = "3", ip = "10.0.1.13", node_id = 3 }
  }

  # ── 인벤토리에 세 그룹을 모두 담는다 ───────────────────────
  # 세 서비스가 함께 떠 있으므로 monitoring 롤이 job 세 벌과 대시보드 셋을
  # 만든다. 그 판정은 그룹이 비어 있는지로 하므로 그룹을 빠뜨리면 그 서비스가
  # Targets 화면에서 통째로 사라진다.
  #
  # join 을 쓰고 %{for~} 를 쓰지 않는다. <<-INV 의 들여쓰기 제거는
  # heredoc 리터럴에 직접 적힌 줄에만 걸린다. %{for~} 가 만들어 낸 줄에는
  # 걸리지 않아 앞 공백이 그대로 남고, cloud-init 이 그 파일을 쓸 때
  # YAML 블록의 들여쓰기가 어긋난다. 세션 3 2회차 검증에서 실제로 깨졌다.
  # redis_role 은 롤이 읽지 않지만 세션 1 인벤토리와 형태를 맞춘다.
  # 수강생이 어느 노드가 master 인지 인벤토리에서 바로 본다.
  redis_group = format("[redis]\n%s\n\n", join("\n",
    [for name, n in local.redis_nodes :
  "${name} ansible_host=${n.ip} redis_role=${name == "redis-1" ? "master" : "replica"}"]))

  mongo_group = format("[mongo]\n%s\n\n", join("\n",
  [for name, n in local.mongo_nodes : "${name} ansible_host=${n.ip}"]))

  kafka_group = format("[kafka]\n%s\n\n", join("\n",
  [for name, n in local.kafka_nodes : "${name} ansible_host=${n.ip} kafka_node_id=${n.node_id}"]))

  inventory = <<-INV
    # 세션 4 · 장애대응 · 모니터링 인벤토리
    # Terraform 이 만들었다. 스택을 만든 뒤 한 번 받아 배치한다.
    #
    #   terraform output -raw inventory
    #
    # Redis · MongoDB · Kafka 세 그룹이 모두 들어 있다.

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
  size                 = "Standard_D2ds_v5"
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
  size                 = "Standard_D2ds_v5"
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

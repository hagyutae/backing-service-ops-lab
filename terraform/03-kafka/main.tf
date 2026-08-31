# 세션 3 · Kafka 운영
#
#
# ── 노드 4대 ─────────────────────────────────────────────────
# kafka-1·kafka-2·kafka-3 : 브로커 겸 컨트롤러. KRaft combined 모드다.
#                           3대여야 한 대가 정지해도 컨트롤러 쿼럼의 과반 2가
#                           남고, min.insync.replicas=2 도 만족해 produce 가
#                           계속된다. 「1대 정지 후 관찰」 실습이 그 위에 선다.
# ops-1                   : Ansible 을 돌리고 Prometheus·Grafana 를 올린다.
#                           Kafka CLI 도구도 여기 깐다. 이 세션의 모든 명령이
#                           이 노드에서 나간다.
#
# ── 크기를 D2ds_v5 로 정한 이유 ──────────────────────────────
# Kafka 는 메시지를 JVM 힙에 캐싱하지 않고 OS page cache 에 의존한다.
# sendfile 로 커널에서 소켓으로 바로 보내므로 힙을 크게 잡을 이유가 없고,
# 오히려 힙이 크면 page cache 를 뺏는다. 힙 권장 상한이 6 GiB 라
# vCPU 당 8 GiB 인 E 계열은 과하다. 균형형 D 계열(4 GiB/vCPU)이 맞다.
# 세션 1·2 가 E2bds_v5 인 것과 갈리는 지점이고, 그 대비를 챕터 02 에서 다룬다.
#
# 8 GiB 배분: OS·exporter 1 GiB / JVM 힙 2 GiB / page cache 약 5 GiB
#
# ── 디스크를 256 GiB 로 잡은 이유 ────────────────────────────
# 세션 1 은 64 GiB, 세션 2 는 128 GiB 였다. 여기가 가장 큰 것은 retention
# 실습 때문이다. retention.ms 와 log.segment.bytes 를 조정해 세그먼트가 실제로
# 삭제되는 것을 보려면 세그먼트가 여러 개 쌓여 있어야 한다.
#
# Premium SSD v2 의 무료 최저값인 3,000 IOPS · 125 MB/s 를 쓴다. D2ds_v5 의
# 지속 처리량 상한이 85 MB/s 라 실제 처리량은 VM 이 정한다. 디스크를 더 키워도
# 이 실습에서는 달라지는 것이 없다.
#
# ── 사설 IP 를 고정하는 이유 ─────────────────────────────────
# 인벤토리를 이 코드가 채워 ops 노드에 배치한다. 동적 할당이면 apply 전에
# 값을 알 수 없어 파일을 만들지 못한다. 서브넷 앞 네 주소는 Azure 예약분이라
# ops-1 이 10.0.1.4, 브로커가 10.0.1.5 부터다.
#
# Kafka 는 여기에 이유가 하나 더 있다. controller.quorum.voters 와
# advertised.listeners 에 주소를 박아야 하는데, 기동 전에 값을 알아야 한다.

locals {
  prefix = "kafka"

  # 영역 하나가 통째로 사라져도 2대가 남아 컨트롤러 쿼럼의 과반을 유지한다.
  #
  # node_id 는 controller.quorum.voters 와 각 노드의 node.id 에 함께 들어간다.
  # 둘이 어긋나면 브로커가 기동 직후 종료한다.
  kafka_nodes = {
    "kafka-1" = { zone = "1", ip = "10.0.1.5", node_id = 1 }
    "kafka-2" = { zone = "2", ip = "10.0.1.6", node_id = 2 }
    "kafka-3" = { zone = "3", ip = "10.0.1.7", node_id = 3 }
  }

  # ops 노드에 배치할 인벤토리.
  #
  # ── join 을 쓰고 %{for~} 를 쓰지 않는 이유 ───────────────────
  # <<-INV 의 들여쓰기 제거는 heredoc 리터럴에 직접 적힌 줄에만 걸린다.
  # %{for~} 가 만들어 낸 줄에는 걸리지 않아 앞 공백 네 칸이 그대로 남고,
  # cloud-init 이 그 파일을 쓸 때 YAML 블록의 들여쓰기가 어긋난다.
  # 2회차 검증에서 실제로 hosts.ini 가 깨졌다. join 은 결과가 한 문자열이라
  # 리터럴 줄로 취급돼 제거가 걸린다.
  inventory = <<-INV
    # 세션 3 · Kafka 운영 인벤토리
    # Terraform 이 배치했다. 노드를 늘리면 이 파일을 직접 고친다.

    [kafka]
    ${join("\n", [for name, n in local.kafka_nodes : "${name} ansible_host=${n.ip} kafka_node_id=${n.node_id}"])}

    [ops]
    ops-1 ansible_connection=local

    [all:vars]
    ansible_user=azureuser
    ansible_ssh_private_key_file=~/.ssh/id_rsa

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

# ops 노드가 브로커에 붙을 때 쓰는 실습용 키 쌍.
# 수강생 키는 ops 접속에만 쓰고, ops 안쪽에서는 이 키를 쓴다.
resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 9092 와 9093 을 공인으로 열지 않는다. 브로커에는 공인 IP 가 없고,
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

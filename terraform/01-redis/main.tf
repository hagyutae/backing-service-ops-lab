# 세션 1 · Redis 운영
#
#
# ── 노드 4대 ─────────────────────────────────────────────────
# redis-1~3 : Redis 와 Sentinel 을 함께 올린다. 3대여야 마스터가 죽어도
#             Sentinel 과반(2)이 남아 자동 전환이 실행된다.
# ops-1     : Ansible 을 돌리고 Prometheus·Grafana 를 올린다.
#             관측 도구가 관측 대상과 함께 죽으면 장애 실습이 성립하지 않는다.
#
# ── 크기를 E2ds_v5 로 정한 이유 ──────────────────────────────
# Redis 는 명령을 단일 스레드로 처리한다. vCPU 를 늘려도 처리량이 비례하지
# 않으므로 코어보다 메모리가 중요하다. BGSAVE 와 AOF rewrite 가 fork 하고
# Copy-on-Write 로 메모리가 최대 2배까지 늘 수 있어 maxmemory 를 물리의 50%
# 로 잡는다. 그래서 vCPU 당 메모리가 큰 E 계열을 쓴다.
#
# ── 사설 IP 를 고정하는 이유 ─────────────────────────────────
# 인벤토리를 이 코드가 채워 ops 노드에 배치한다. 동적 할당이면 apply 전에
# 값을 알 수 없어 파일을 만들지 못한다. 서브넷 앞 네 주소는 Azure 예약분이라
# ops-1 이 10.0.1.4, 서비스 노드가 10.0.1.5 부터다.

locals {
  prefix = "redis"

  # 영역 하나가 통째로 사라져도 2대가 남아 과반을 유지한다.
  redis_nodes = {
    "redis-1" = { zone = "1", ip = "10.0.1.5", role = "master" }
    "redis-2" = { zone = "2", ip = "10.0.1.6", role = "replica" }
    "redis-3" = { zone = "3", ip = "10.0.1.7", role = "replica" }
  }

  master_ip = local.redis_nodes["redis-1"].ip

  # ops 노드에 배치할 인벤토리. 노드를 늘리는 실습에서는 수강생이 이 파일을 직접 고친다.
  inventory = <<-INV
    # 세션 1 · Redis 운영 인벤토리
    # Terraform 이 배치했다. 노드를 늘리면 이 파일을 직접 고친다.

    [redis]
    %{for name, n in local.redis_nodes~}
    ${name} ansible_host=${n.ip} redis_role=${n.role}
    %{endfor~}

    [ops]
    ops-1 ansible_connection=local

    [all:vars]
    ansible_user=azureuser
    ansible_ssh_private_key_file=~/.ssh/id_rsa

    redis_master_host=${local.master_ip}
    redis_port=6379
    sentinel_port=26379

    sentinel_quorum=2
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
# 세션이 끝나면 스택과 함께 사라진다.
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
  # 개인 키, 인벤토리, 도구, 플레이북이 전부 여기서 갖춰진다.
  # defer: true 가 없으면 azureuser 홈 디렉터리가 생기기 전에 돌아 실패한다.
  #
  # indent() 값은 6 이다. 10 이 아니다.
  # <<-EOT 는 블록 전체에서 공통으로 들어간 들여쓰기(여기서는 4칸)를 걷어낸다.
  # 그래서 소스에서 10칸인 보간 자리는 실제로 6칸으로 내려앉는다. 그런데
  # indent() 는 두 번째 줄부터 지정한 칸수를 그대로 넣으므로, 10 을 주면
  # 첫 줄만 6칸이고 나머지가 10칸이 된다. YAML 은 첫 줄로 기준을 잡으므로
  # 남는 4칸이 파일 내용으로 딸려 들어간다.
  # 개인 키는 PEM 본문이 어긋나 error in libcrypto 로 죽고,
  # 인벤토리는 [redis] 절 머리까지 들여쓰기돼 노드 간 SSH 가 전부 막힌다.
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

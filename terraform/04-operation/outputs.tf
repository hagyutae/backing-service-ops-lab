output "ops_public_ip" {
  description = "ops 노드 공인 IP. 여기로 SSH 접속한다. 단계가 바뀌어도 그대로다."
  value       = module.ops.public_ip
}

output "ssh_command" {
  description = "그대로 붙여 쓰는 접속 명령."
  value       = "ssh -i ~/.ssh/rkm azureuser@${module.ops.public_ip}"
}

# ── 단계가 바뀌면 이것을 받아 ops 노드에 덮어쓴다 ────────────
# cloud-init 은 부팅할 때 한 번만 돈다. 인벤토리를 거기 넣으면 단계를 바꿀
# 때마다 ops 노드가 새로 만들어져 그때까지 쓴 런북이 사라진다.
# 그래서 인벤토리를 output 으로 낸다.
#
#   terraform output -raw inventory > hosts.ini
#   scp -i ~/.ssh/rkm hosts.ini azureuser@<ops 공인 IP>:~/lab/ansible/inventory/hosts.ini
#
# 갱신하지 않으면 플레이북이 사라진 노드를 찾다가 그 자리에서 멈춘다.
output "inventory" {
  description = "ops 노드에 배치할 Ansible 인벤토리. 활성 서비스의 그룹만 들어 있다."
  value       = local.inventory
}

output "stage" {
  description = "지금 켜져 있는 단계."
  value = lookup({
    1 = "1단계 · ops-1 + redis-1·redis-2·redis-3"
    2 = "2단계 · ops-1 + mongo-1·mongo-2·mongo-3"
    3 = "3단계 · ops-1 + kafka-1·kafka-2·kafka-3"
    4 = "4단계 · ops-1 만"
  }, var.stage, "알 수 없음")
}

output "service_private_ips" {
  description = "활성 서비스 노드의 사설 IP. 실습 명령의 대상이다."
  value = merge(
    { for k, m in module.redis : k => m.private_ip },
    { for k, m in module.mongo : k => m.private_ip },
    { for k, m in module.kafka : k => m.private_ip },
  )
}

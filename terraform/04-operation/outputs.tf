output "ops_public_ip" {
  description = "ops 노드 공인 IP. 여기로 SSH 접속한다."
  value       = module.ops.public_ip
}

output "ssh_command" {
  description = "그대로 붙여 쓰는 접속 명령."
  value       = "ssh -i ~/.ssh/rkm azureuser@${module.ops.public_ip}"
}

# ── 스택을 만든 뒤 이것을 받아 ops 노드에 배치한다 ───────────
# cloud-init 은 부팅할 때 한 번만 돈다. 인벤토리를 거기 넣으면 ops 노드가
# 다시 만들어질 때 그때까지 쓴 런북이 사라진다.
# 그래서 인벤토리를 output 으로 낸다.
#
#   terraform output -raw inventory > hosts.ini
#   scp -i ~/.ssh/rkm hosts.ini azureuser@<ops 공인 IP>:~/lab/ansible/inventory/hosts.ini
#
# 갱신하지 않으면 플레이북이 사라진 노드를 찾다가 그 자리에서 멈춘다.
output "inventory" {
  description = "ops 노드에 배치할 Ansible 인벤토리. 세 서비스 그룹이 모두 들어 있다."
  value       = local.inventory
}

output "service_private_ips" {
  description = "서비스 노드 아홉 대의 사설 IP. 실습 명령의 대상이다."
  value = merge(
    { for k, m in module.redis : k => m.private_ip },
    { for k, m in module.mongo : k => m.private_ip },
    { for k, m in module.kafka : k => m.private_ip },
  )
}

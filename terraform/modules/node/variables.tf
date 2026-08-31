variable "name" {
  description = "노드 이름. redis-1, ops-1 처럼 화면에 그대로 보인다."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  description = "사설 IP. 인벤토리를 코드가 채우려면 apply 전에 정해져 있어야 한다."
  type        = string
  default     = null
}

variable "size" {
  description = "VM 크기. Redis 는 메모리 최적화 E 계열, ops 는 D 계열."
  type        = string
}

variable "zone" {
  description = "가용성 영역. 영역 하나가 사라져도 과반이 남게 나눈다."
  type        = string
  default     = null
}

variable "data_disk_gb" {
  description = "데이터 디스크 용량. 0 이면 붙이지 않는다."
  type        = number
  default     = 0
}

variable "public_ip" {
  description = "공인 IP 부여 여부. ops 노드에만 true 다."
  type        = bool
  default     = false
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key" {
  description = "수강생 공개 키. 이 과정은 RSA 4096 으로 통일한다."
  type        = string
}

variable "extra_ssh_public_key" {
  description = "덧붙일 공개 키. 서비스 노드에 ops 노드의 실습용 키를 함께 넣는다."
  type        = string
  default     = null
}

variable "custom_data" {
  description = "부팅 시 한 번 실행할 cloud-init. ops 노드에 개인 키를 배치할 때 쓴다."
  type        = string
  default     = null
}

variable "image" {
  description = "OS 이미지. 전 노드 Ubuntu 24.04 LTS."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

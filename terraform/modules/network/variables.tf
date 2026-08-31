variable "prefix" {
  description = "자원 이름 앞에 붙일 접두어. 스택마다 다르다."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  description = "VNet 대역."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_prefix" {
  description = "서브넷 대역. 노드는 전부 이 안에 들어간다."
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_cidrs" {
  description = "외부에서 들어올 수 있는 출발지. 수강생 PC 의 공인 IP 다."
  type        = list(string)
}

variable "public_ports" {
  description = "allowed_cidrs 에 열어 줄 포트. Grafana 3000, Prometheus 9090."
  type        = list(number)
  default     = [3000, 9090]
}

variable "tags" {
  type    = map(string)
  default = {}
}

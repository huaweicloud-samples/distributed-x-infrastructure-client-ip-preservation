output "elb_public_ip" {
  description = "负载均衡绑定的公网 EIP 地址，客户端通过该地址访问演示页。"
  value       = huaweicloud_vpc_eip.elb.address
}

output "elb_id" {
  description = "负载均衡实例 ID。"
  value       = huaweicloud_elb_loadbalancer.this.id
}

output "ecs_private_ip" {
  description = "后端 ECS 的私网 IP，即两个后端服务器组实际注册的后端地址。"
  value       = huaweicloud_compute_instance.this.network[0].fixed_ip_v4
}

output "demo_url_ppv2" {
  description = "入口 A：走 TLS 监听器 + Proxy Protocol v2，后端从 PPv2 头解析真实客户端 IP。"
  value       = "https://${huaweicloud_vpc_eip.elb.address}:${local.tls_listener_port}/index.php"
}

output "demo_url_plain" {
  description = "入口 B：走 TCP 监听器 + 源地址透传，后端从 TCP 连接源地址拿到真实客户端 IP。"
  value       = "http://${huaweicloud_vpc_eip.elb.address}:${local.tcp_listener_port}/index.php"
}

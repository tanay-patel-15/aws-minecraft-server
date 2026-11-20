output "public_ip" {
  description = "Address to enter in Minecraft's Multiplayer screen"
  value       = aws_eip.minecraft.public_ip
}

output "security_group_id" {
  description = "Security group that mc-start updates with your home IP"
  value       = aws_security_group.minecraft.id
}

output "instance_id" {
  description = "ID of the Minecraft server"
  value       = aws_instance.minecraft.id
}
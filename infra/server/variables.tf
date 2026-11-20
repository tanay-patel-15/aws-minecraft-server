variable "instance_type" {
  description = "EC2 instance type for the Minecraft server"
  type        = string
  default     = "c7i-flex.large"
}

variable "accept_minecraft_eula" {
  description = "Set to true only after reading https://aka.ms/MinecraftEULA"
  type        = bool
  validation {
    condition     = var.accept_minecraft_eula
    error_message = "Read https://aka.ms/MinecraftEULA, then set accept_minecraft_eula = true in terraform.tfvars."
  }
}
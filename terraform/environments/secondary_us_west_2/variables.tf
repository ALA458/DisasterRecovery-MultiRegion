variable "aws_region" {
  description = "Región secundaria de AWS (Warm Standby)"
  type        = string
  default     = "us-west-2"
}

variable "primary_aws_region" {
  description = "Región primaria de AWS donde reside el estado y recursos origen"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "dr-architecture"
}

variable "environment" {
  description = "Nombre del entorno secundario"
  type        = string
  default     = "secondary"
}

variable "state_bucket" {
  description = "Bucket S3 donde se almacena el estado remoto de Terraform"
  type        = string
  default     = "dr-tfstate-559050245919"
}

variable "primary_state_key" {
  description = "Ruta del archivo tfstate del entorno primario"
  type        = string
  default     = "primary/terraform.tfstate"
}

variable "db_username" {
  description = "Usuario administrador de RDS MySQL (usado por la API tras promoción)"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Contraseña de RDS (la MISMA de la primaria: la réplica la hereda). Pasarla con TF_VAR_db_password"
  type        = string
  sensitive   = true
}

variable "app_image_tag" {
  description = "Tag de la imagen de la API en el ECR réplica de us-west-2"
  type        = string
  default     = "latest"
}

variable "s3_bucket_prefix" {
  description = "Prefijo para el bucket S3 réplica de comprobantes en us-west-2"
  type        = string
  default     = "dr-invoices-utb-replica"
}


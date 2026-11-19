variable "aws_region" {
  description = "Región primaria de AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "dr-architecture"
}

variable "environment" {
  description = "Nombre del entorno"
  type        = string
  default     = "primary"
}

variable "db_username" {
  description = "Usuario administrador de RDS MySQL"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Contraseña de RDS MySQL. Sin default: pasarla con TF_VAR_db_password (8-41 caracteres, sin / @ \" ni espacios)"
  type        = string
  sensitive   = true
}

variable "s3_bucket_prefix" {
  description = "Prefijo para el bucket S3 de comprobantes"
  type        = string
  default     = "dr-invoices-utb"
}

variable "app_image_tag" {
  description = "Tag de la imagen de la API en ECR que despliegan las EC2"
  type        = string
  default     = "latest"
}

variable "dr_region" {
  description = "Región secundaria (destino de la replicación de ECR)"
  type        = string
  default     = "us-west-2"
}

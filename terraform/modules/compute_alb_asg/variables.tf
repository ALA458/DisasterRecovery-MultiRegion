variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "dr-architecture"
}

variable "environment" {
  description = "Entorno (primary, secondary)"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs de subredes públicas para el ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "IDs de subredes privadas para el Auto Scaling Group"
  type        = list(string)
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "min_size" {
  description = "Tamaño mínimo del ASG"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Tamaño máximo del ASG"
  type        = number
  default     = 4
}

variable "desired_capacity" {
  description = "Capacidad deseada del ASG (2 en primary, 0 en Warm Standby)"
  type        = number
  default     = 2
}

variable "app_port" {
  description = "Puerto de escucha de la aplicación en el contenedor"
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "Ruta de verificación de salud para ALB y Route 53"
  type        = string
  default     = "/health"
}

variable "db_host" {
  description = "Host de la base de datos MySQL"
  type        = string
}

variable "db_port" {
  description = "Puerto de la base de datos MySQL"
  type        = number
  default     = 3306
}

variable "db_user" {
  description = "Usuario de la base de datos MySQL"
  type        = string
  default     = "admin"
}

variable "db_pass_ssm_parameter" {
  description = "Nombre del parámetro SecureString de SSM con la contraseña de MySQL (las EC2 lo leen al arrancar)"
  type        = string
}

variable "app_image" {
  description = "URI completa de la imagen de la API en ECR de la región (ej. 123456789012.dkr.ecr.us-east-1.amazonaws.com/dr-api:latest)"
  type        = string
}

variable "db_name" {
  description = "Nombre de la base de datos MySQL"
  type        = string
  default     = "transactions_db"
}

variable "dynamo_table" {
  description = "Nombre de la tabla DynamoDB"
  type        = string
}

variable "s3_bucket" {
  description = "Nombre del bucket S3 de comprobantes"
  type        = string
}

variable "aws_region" {
  description = "Región de AWS de despliegue"
  type        = string
}

variable "tags" {
  description = "Etiquetas comunes"
  type        = map(string)
  default     = {}
}

# Guía de Pruebas Locales y Validación End-to-End en AWS

Este documento detalla el procedimiento reproducible para validar la API transaccional tanto en entorno local (sin costos de nube) como contra el Application Load Balancer desplegado en AWS.

---

## 1. Prerrequisitos

* **Para pruebas locales:**
  * Docker Engine / Docker Desktop y Docker Compose v2 (`docker compose`).
  * Python `3.11+` con la librería `requests` instalada (`pip install requests`), o cliente HTTP (`curl` / PowerShell `Invoke-RestMethod`).
* **Para despliegue y pruebas en AWS:**
  * Terraform `>= 1.10.0`.
  * AWS CLI v2 configurado con credenciales válidas (`aws sts get-caller-identity`).
  * Acceso de red HTTP al DNS público del ALB desplegado en `us-east-1`.

---

## 2. Escenario A: Entorno de Pruebas Local (`docker-compose.yml`)

El archivo [docker-compose.yml](file:///c:/Users/soulg/OneDrive/Desktop/Programaci%C3%B3n/aws-dr-architecture/docker-compose.yml) levanta dos contenedores interconectados:
1. `dr-local-mysql` (`mysql:8.0`): Expuesto en el host en el puerto **`3307:3306`** (evita colisiones con instancias locales de MySQL en Windows). Base de datos `transactions_db`, usuario `admin`, contraseña `password`.
2. `dr-api-service` (build de `./api/Dockerfile`): Expuesto en **`8000:8000`**, espera a que `dr-local-mysql` pase su `healthcheck` (`mysqladmin ping`) antes de iniciar.

### 2.1. Levantar el entorno local

```bash
docker compose up --build -d
```

Verificar estado de los contenedores:

```bash
docker compose ps
```

### 2.2. Alcance de las pruebas en modo local

En `docker-compose.yml`, las variables `AWS_ACCESS_KEY_ID=mock_key` y `AWS_SECRET_ACCESS_KEY=mock_secret` permiten arrancar los clientes Boto3 sin credenciales reales:
* **`/health`, `/transaction` y `/transactions/latest`:** Funcionan al 100% contra MySQL `8.0` real en contenedor.
* **`/readiness`:** Reportará `"rds_mysql": "connected"`, mientras que `"dynamodb"` y `"s3"` reportarán un mensaje `"error: ..."` al utilizar credenciales mock (a menos que inyectes credenciales reales o un emulador compatible).
* **`/cart` e `/invoice`:** Requieren credenciales AWS válidas con acceso a la tabla `user_sessions` y al bucket `S3_BUCKET` configurados.

### 2.3. Pruebas manuales de endpoints locales

**Swagger UI (navegador):** `http://localhost:8000/docs`

**Usando `curl` (Linux / macOS / Git Bash):**
```bash
# 1. Health check
curl -s http://localhost:8000/health

# 2. Readiness
curl -s http://localhost:8000/readiness

# 3. Registrar transacción financiera en MySQL
curl -s -X POST http://localhost:8000/transaction \
  -H "Content-Type: application/json" \
  -d '{"user_id":"usr-local-01","amount":125.50,"description":"Prueba local MySQL"}'

# 4. Consultar últimas transacciones
curl -s http://localhost:8000/transactions/latest?limit=5
```

**Usando PowerShell (`Invoke-RestMethod`):**
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/health" -Method Get

$body = @{
    user_id = "usr-local-01"
    amount = 125.50
    description = "Prueba local MySQL"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8000/transaction" -Method Post -ContentType "application/json" -Body $body
Invoke-RestMethod -Uri "http://localhost:8000/transactions/latest?limit=5" -Method Get
```

### 2.4. Detener y limpiar el entorno local

```bash
docker compose down -v
```
*(La bandera `-v` elimina el volumen `mysql_data` si se desea reiniciar la base de datos desde cero).*

---

## 3. Escenario B: Validación End-to-End en AWS (Fase 1)

Una vez desplegada la infraestructura en `us-east-1` mediante Terraform, el script [test_api_connection.py](file:///c:/Users/soulg/OneDrive/Desktop/Programaci%C3%B3n/aws-dr-architecture/tests/test_api_connection.py) valida secuencialmente la integración completa desde el ALB público hasta los tres servicios administrados de AWS.

### 3.1. Despliegue de la región primaria

```bash
terraform -chdir=terraform/environments/primary_us_east_1 init
terraform -chdir=terraform/environments/primary_us_east_1 validate
terraform -chdir=terraform/environments/primary_us_east_1 plan -out=tfplan
terraform -chdir=terraform/environments/primary_us_east_1 apply tfplan
```

Obtener el DNS público del ALB:

```bash
terraform -chdir=terraform/environments/primary_us_east_1 output -raw alb_dns_name
```

> **Tiempo de espera inicial:** Las instancias EC2 en el ASG ejecutan `dnf install`, `git clone` y `docker build` vía User Data al arrancar, lo cual puede tomar entre **3 y 5 minutos** adicionales después de que `terraform apply` finalice hasta que el Target Group marque las instancias como `healthy`.

### 3.2. Ejecución de la suite de pruebas (`test_api_connection.py`)

```bash
python tests/test_api_connection.py --url http://<ALB_DNS_NAME>
```

| Paso | Endpoint Evaluado | Validación Realizada | Criterio de Éxito |
| :--- | :--- | :--- | :--- |
| `[1/6]` | `GET /health` | Disponibilidad del ALB y contenedor FastAPI | HTTP `200` y `status == "healthy"` |
| `[2/6]` | `GET /readiness` | Conectividad física a RDS, DynamoDB y S3 | Los tres componentes en `"connected"` |
| `[3/6]` | `POST /transaction` | Escritura SQL transaccional en RDS Multi-AZ | HTTP `201` y generación de `transaction_id` |
| `[4/6]` | `GET /transactions/latest` | Lectura y ordenamiento cronológico en RDS | HTTP `200` y lista con `>= 1` registro |
| `[5/6]` | `POST /cart` + `GET /cart/usr-fase1` | Persistencia y lectura en DynamoDB (`user_sessions`) | Ambos retornan HTTP `200` |
| `[6/6]` | `POST /invoice` + `GET /invoice/{id}` | Subida de objeto a S3 y consulta de metadatos | HTTP `201` al subir y HTTP `200` en `head_object` |

Si todos los pasos finalizan correctamente, el script termina con código de salida `0` y el mensaje `>> TODOS LOS COMPONENTES DE LA FASE 1 ESTAN OPERACIONALES <<`.

### 3.3. Limpieza de recursos en AWS

Al finalizar la sesión de pruebas, destruir la infraestructura temporal para preservar créditos:

```bash
terraform -chdir=terraform/environments/primary_us_east_1 destroy -auto-approve
```

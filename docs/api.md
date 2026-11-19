# Especificación Técnica de la API Transaccional

**Archivo principal:** [main.py](file:///c:/Users/soulg/OneDrive/Desktop/Programaci%C3%B3n/aws-dr-architecture/api/main.py)  
**Empaquetado:** [Dockerfile](file:///c:/Users/soulg/OneDrive/Desktop/Programaci%C3%B3n/aws-dr-architecture/api/Dockerfile) | [requirements.txt](file:///c:/Users/soulg/OneDrive/Desktop/Programaci%C3%B3n/aws-dr-architecture/api/requirements.txt)  
**Framework:** FastAPI `1.0.0` sobre Uvicorn (Puerto `8000`)

---

## 1. Propósito de la API en la Arquitectura DR

La API REST (`DR Transactional API`) constituye la carga de trabajo de validación del proyecto. Su objetivo es ejercitar de forma conjunta las tres capas de persistencia exigidas por la arquitectura (RDS MySQL, DynamoDB y S3) y exponer endpoints de telemetría que permitan:

1. Detectar caídas regionales mediante Route 53 y el Application Load Balancer (`/health` y `/readiness`).
2. Generar transacciones reales con marca de tiempo UTC y región de origen (`/transaction`, `/cart`, `/invoice`).
3. Auditar los últimos registros escritos antes de un incidente para calcular el **RPO real** (`/transactions/latest`, `/cart/{user_id}`, `/invoice/{invoice_id}`).

---

## 2. Configuración, Variables de Entorno y Persistencia

### 2.1. Variables de Entorno

En AWS, estas variables son inyectadas por el script de *User Data* del Launch Template (`modules/compute_alb_asg/main.tf`). En local, son gestionadas por `docker-compose.yml`.

| Variable | Valor por Defecto (`main.py`) | Valor en `docker-compose.yml` | Origen en AWS (Fase 1) |
| :--- | :--- | :--- | :--- |
| `DB_HOST` | `localhost` | `db` | `module.database_rds.db_address` |
| `DB_PORT` | `3306` | `3306` | `module.database_rds.db_port` |
| `DB_USER` | `admin` | `admin` | `var.db_username` |
| `DB_PASS` | `password` | `password` | `var.db_password` o parámetro SSM `SecureString` en el entorno secundario |
| `DB_NAME` | `transactions_db` | `transactions_db` | `transactions_db` |
| `DYNAMO_TABLE` | `user_sessions` | `user_sessions` | `aws_dynamodb_table.user_sessions.name` |
| `S3_BUCKET` | `dr-invoice-bucket` | `dr-invoice-bucket` | `module.storage_s3.bucket_name` |
| `AWS_REGION` | `us-east-1` | `us-east-1` | `var.aws_region` |

### 2.2. Motor Relacional y Modelo de Datos (`SQLAlchemy`)

- **Cadena de conexión:** `mysql+pymysql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}`
- **Resiliencia de conexiones:**
  - `pool_pre_ping=True`: valida la vitalidad del socket antes de emitir consultas (evita errores con conexiones obsoletas tras conmutaciones Multi-AZ o promoción de RDS).
  - `pool_recycle=3600`: recicla conexiones cada hora.
  - `connect_args={"connect_timeout": 5}`: evita bloqueos prolongados cuando el endpoint relacional no responde.
- **Inicialización segura:** `init_db()` ejecuta `Base.metadata.create_all(bind=engine)` en el evento `startup` dentro de un bloque `try/except`, impidiendo que la API falle al arrancar si MySQL aún está terminando su inicialización.

#### Esquema de tabla `transactions` (`TransactionModel`)

| Columna | Tipo SQLAlchemy | Restricciones / Valor por Defecto |
| :--- | :--- | :--- |
| `id` | `String(36)` | Clave primaria, UUID v4 generado automáticamente |
| `user_id` | `String(64)` | `nullable=False`, indexado (`index=True`) |
| `amount` | `Float` | `nullable=False` |
| `description` | `String(255)` | Default `""` |
| `created_at` | `DateTime` | Timestamp UTC (`datetime.now(timezone.utc)`) |
| `region` | `String(32)` | Default `AWS_REGION` (permite identificar en qué región se escribió el registro) |

---

## 3. Contrato de Endpoints

La documentación OpenAPI interactiva generada por FastAPI está disponible en `GET /docs` (Swagger UI) y `GET /redoc`.

### 3.1. Observabilidad y Monitoreo

#### `GET /health`
Endpoint liviano utilizado por el Target Group del ALB (cada `10s`) y por los Health Checks de Route 53. No realiza consultas a bases de datos para responder de forma determinista sobre la salud del proceso API.

- **Respuesta `200 OK`:**
```json
{
  "status": "healthy",
  "region": "us-east-1",
  "timestamp": "2026-10-20T15:30:00.123456+00:00"
}
```

#### `GET /readiness`
Chequeo profundo que valida conectividad activa contra los tres motores:
1. **RDS MySQL:** Ejecuta `SELECT 1`.
2. **DynamoDB:** Ejecuta `dynamodb.describe_table(TableName=DYNAMO_TABLE)`.
3. **S3:** Ejecuta `s3.head_bucket(Bucket=S3_BUCKET)`.

- **Respuesta `200 OK` (entorno AWS saludable):**
```json
{
  "region": "us-east-1",
  "rds_mysql": "connected",
  "dynamodb": "connected",
  "s3": "connected"
}
```
> Si algún servicio falla, su clave devuelve `"error: <detalle>"` manteniendo el código HTTP `200` para inspección diagnóstica.

---

### 3.2. Capa Relacional (RDS MySQL)

#### `POST /transaction`
Inserta una transacción financiera en la tabla `transactions`.

- **Esquema `TransactionCreate`:**
  - `user_id` (`string`, default `"usr-1001"`)
  - `amount` (`float`, `> 0`, default `99.99`)
  - `description` (`string`, default `"Pago orden de compra"`)
- **Respuesta `201 Created`:**
```json
{
  "status": "Transacción financiera registrada",
  "transaction_id": "a3f1c2d4-5678-4abc-9def-0123456789ab",
  "user_id": "usr-1001",
  "amount": 99.99,
  "created_at": "2026-10-20T15:35:10.451200",
  "region": "us-east-1"
}
```
- **Errores:** `422 Unprocessable Entity` (si `amount <= 0`), `500 Internal Server Error` (fallo de SQLAlchemy con rollback automático).

#### `GET /transactions/latest?limit=10`
Retorna las últimas `limit` transacciones ordenadas descendentemente por `created_at`. Se utiliza como fuente de verdad para auditar qué transacciones sobrevivieron tras promover la Read Replica en `us-west-2`.

- **Respuesta `200 OK`:** Lista de objetos `{id, user_id, amount, description, created_at, region}`.

---

### 3.3. Capa NoSQL (DynamoDB)

#### `POST /cart`
Crea o sobreescribe (`put_item`) el carrito de un usuario en la tabla `user_sessions`.

- **Esquema `CartItem`:**
  - `user_id` (`string`, default `"usr-1001"`)
  - `item` (`string`, default `"SKU-994"`)
  - `quantity` (`integer`, `>= 1`, default `1`)
- **Respuesta `200 OK`:**
```json
{
  "status": "Carrito actualizado",
  "user_id": "usr-1001",
  "item": "SKU-994",
  "quantity": 1,
  "updated_at": "2026-10-20T15:36:00.000000+00:00",
  "region": "us-east-1"
}
```

#### `GET /cart/{user_id}`
Recupera el registro del carrito desde DynamoDB para verificar propagación activa-activa entre regiones.

- **Respuestas:** `200 OK` con `{user_id, item, quantity, updated_at, region}` | `404 Not Found` (`"Carrito no encontrado"`) | `500 Internal Server Error`.

---

### 3.4. Almacenamiento de Objetos (Amazon S3)

#### `POST /invoice`
Genera un comprobante de texto plano (`invoices/{invoice_id}.txt`) y lo carga en el bucket S3 configurado con metadatos personalizados (`customer`, `amount`, `origin_region`, `timestamp`).

- **Esquema `InvoiceCreate`:**
  - `invoice_id` (`string | null`, opcional; si se omite se genera `INV-<8 hex en mayúsculas>`)
  - `customer_name` (`string`, default `"Cliente Corporativo"`)
  - `amount` (`float`, default `150.00`)
- **Respuesta `201 Created`:**
```json
{
  "status": "Comprobante digital subido",
  "invoice_id": "INV-8F3A19C2",
  "s3_bucket": "dr-invoices-utb-a1b2c3d4",
  "s3_key": "invoices/INV-8F3A19C2.txt",
  "version_id": "3L4k5J6h...",
  "timestamp": "2026-10-20T15:37:12.000000+00:00",
  "region": "us-east-1"
}
```

#### `GET /invoice/{invoice_id}`
Consulta mediante `s3.head_object` la existencia, tamaño, `VersionId` y metadatos del comprobante en el bucket regional, permitiendo validar que el objeto fue replicado vía CRR.

- **Respuestas:** `200 OK` con `{invoice_id, s3_bucket, s3_key, version_id, content_length, last_modified, metadata}` | `404 Not Found` (`"Factura no encontrada"`) | `500 Internal Server Error`.

---

## 4. Empaquetado Docker y Ejecución en EC2

El archivo [Dockerfile](file:///c:/Users/soulg/OneDrive/Desktop/Programaci%C3%B3n/aws-dr-architecture/api/Dockerfile) implementa una construcción **multi-stage** sobre `python:3.11-slim`:
1. **Etapa `builder`:** Compila los wheels de `requirements.txt` incluyendo todas las dependencias transitivas (`pip wheel --no-cache-dir --wheel-dir /app/wheels -r requirements.txt`), garantizando la presencia de `cryptography>=42.0.0` para la autenticación MySQL 8.0.
2. **Etapa final (runner):** Instala offline desde `/wheels`, elimina los archivos temporales y expone el puerto `8000`.
3. **Health Check interno del contenedor:** Ejecuta cada `30s` una petición HTTP contra `http://localhost:8000/health` usando `urllib.request` de la librería estándar de Python.
4. **Arranque:** `uvicorn main:app --host 0.0.0.0 --port 8000`.

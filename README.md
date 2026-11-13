# Disaster Recovery Multi-Región en AWS (Warm Standby)

Arquitectura de alta disponibilidad y recuperación ante desastres (**Disaster Recovery - DR**) en **Amazon Web Services (AWS)** basada en el modelo **Warm Standby**, diseñada para garantizar continuidad de negocio con objetivos de resiliencia estrictos:
* **RTO (Recovery Time Objective):** $< 15$ minutos ($900$ s)
* **RPO (Recovery Point Objective):** $< 5$ minutos ($300$ s)

---

## 1. Visión General del Sistema

El sistema implementa una arquitectura web transaccional distribuida geográficamente en dos regiones de AWS:
* **Región Primaria (`us-east-1`):** Opera con capacidad productiva completa atendiendo el 100% del tráfico de los usuarios.
* **Región Secundaria (`us-west-2`):** Opera en modo **Warm Standby**; mantiene las capas de datos replicadas continuamente en tiempo real, mientras que la capa de cómputo (instancias EC2) permanece en reposo (`desired_capacity = 0`) para optimizar costos de infraestructura.

Ante una caída total o sobrecarga crítica en la región primaria, el borde de la red (Route 53 y CloudFront) detecta la falla y un proceso automatizado de SRE promueve la base de datos secundaria y escala el grupo de cómputo, restableciendo el servicio de forma transparente.

---

## 2. Diagrama de Arquitectura

```mermaid
flowchart TD
    subgraph EdgeTier ["Capa de Borde Global (Anycast / DNS)"]
        Users["Clientes / Tráfico Web / Locust"] --> CF["AWS CloudFront (Origin Group Multi-Region)"]
        CF --> R53["Route 53 Failover DNS (Health Check cada 10s)"]
    end

    subgraph RegionPrimary ["Región Primaria: us-east-1 (Activa - Tráfico Productivo)"]
        ALB1["Application Load Balancer (us-east-1)"]
        ASG1["Auto Scaling Group (2-4 Instancias t3.micro)\nAPI FastAPI Contenerizada"]
        RDS1[("RDS MySQL 8.0 Multi-AZ\nEscritor Primario")]
        DDB1[("DynamoDB Table\nuser_sessions (Streams ON)")]
        S31["S3 Source Bucket\nVersionado Habilitado"]

        ALB1 --> ASG1
        ASG1 --> RDS1
        ASG1 --> DDB1
        ASG1 --> S31
    end

    subgraph RegionSecondary ["Región Secundaria: us-west-2 (Warm Standby - desired=0)"]
        ALB2["Application Load Balancer (us-west-2 - Activo)"]
        ASG2["Auto Scaling Group (desired=0 -> escala a 2 en Failover)\nAPI FastAPI"]
        RDS2[("RDS MySQL Read Replica\nReplicación Asíncrona")]
        DDB2[("DynamoDB Replica\nReplicación Activa-Activa")]
        S32["S3 Replica Bucket\nDestino de CRR"]

        ALB2 --> ASG2
        ASG2 --> RDS2
        ASG2 --> DDB2
        ASG2 --> S32
    end

    R53 -- "Enrutamiento Normal (PRIMARY)" --> ALB1
    R53 -. "Conmutación por Error (SECONDARY)" .-> ALB2
    CF -- "Origin Failover (HTTP 500/502/503/504)" -.-> ALB2

    %% Canales de Sincronización de Datos
    RDS1 -- "Replicación Asíncrona Cross-Region (binlogs)" --> RDS2
    DDB1 <== "DynamoDB Global Tables (Bidireccional < 1s)" ==> DDB2
    S31 -- "S3 Cross-Region Replication (CRR con IAM Role)" --> S32
```

---

## 3. Stack Tecnológico

| Capa | Tecnologías / Servicios | Función Principal |
| :--- | :--- | :--- |
| **Infraestructura como Código (IaC)** | Terraform (v1.10.x) | Aprovisionamiento modular, repetible y parametrizado de recursos AWS. |
| **Borde y DNS** | AWS Route 53, AWS CloudFront | Monitoreo por Health Checks (10s), DNS Failover y Origin Group Failover. |
| **Red** | AWS VPC, Subredes, IGW, NAT GW | Aislamiento en 3 Tiers (Público, App Privada, Datos Privados) sin colisión de CIDRs. |
| **Cómputo** | AWS EC2, Auto Scaling Groups, ALB, Docker | Ejecución contenerizada elástica de la API con despliegue vía Launch Templates. |
| **Persistencia Relacional** | Amazon RDS MySQL 8.0 | Transacciones financieras ACID. Multi-AZ primario y Read Replica Cross-Region. |
| **Persistencia NoSQL** | Amazon DynamoDB Global Tables | Gestión de carritos y sesiones con replicación multi-maestro activa-activa. |
| **Almacenamiento de Objetos** | Amazon S3 | Facturas digitales con versionado y Cross-Region Replication (CRR). |
| **Backend / API** | Python 3.11, FastAPI, SQLAlchemy, Pydantic | API REST transaccional con reconexión elástica (`pool_pre_ping`). |
| **Automatización SRE** | Python 3, Boto3 | Script autónomo de Failover (promoción de base de datos y escalado de cómputo). |
| **Pruebas de Carga y Caos** | Locust | Inyección de estrés concurrente, simulación de caída regional y auditoría de SLA. |
| **CI/CD** | GitHub Actions | Validación estática en Pull Requests y despliegue continuo secuencial en `main`. |

---

## 4. Estructura del Repositorio

```text
DisasterRecovery-MultiRegion/
├── .github/
│   └── workflows/
│       └── terraform.yml            # Pipeline CI/CD: formateo, validación y despliegue secuencial
├── api/
│   ├── Dockerfile                   # Imagen multi-stage optimizada sobre python:3.11-slim
│   ├── main.py                      # API REST transaccional con endpoints de observabilidad y negocio
│   └── requirements.txt             # Dependencias del servicio web
├── automation/
│   └── failover_trigger.py          # Automatización SRE: promoción de RDS y escalado de ASG
├── docs/
│   ├── locust_dr_report.html        # Reporte interactivo de pruebas de carga y conmutación
│   └── runbook.md                   # Procedimientos operativos estándar de Failover y Failback
├── terraform/
│   ├── environments/
│   │   ├── global/                  # Entorno global: Route 53 Failover DNS y CloudFront Origin Group
│   │   ├── primary_us_east_1/       # Entorno primario: VPC 10.0.0.0/16, ALB, ASG (desired=2), RDS Multi-AZ
│   │   └── secondary_us_west_2/     # Entorno secundario: VPC 10.1.0.0/16, ASG (desired=0), RDS Replica
│   └── modules/
│       ├── compute_alb_asg/         # Balanceador ALB, Launch Template, ASG e IAM Role para EC2
│       ├── database_rds/            # RDS MySQL (modo Multi-AZ Writer o Read Replica Cross-Region)
│       ├── route53_failover/        # Hosted Zone, Health Checks y registros Alias PRIMARY/SECONDARY
│       ├── storage_s3/              # S3 con versionado, cifrado SSE-S3 y reglas CRR
│       └── vpc/                     # Red 3-Tier (subredes públicas, privadas de app y privadas de datos)
├── tests/
│   ├── locustfile.py                # Definición de pruebas de carga concurrentes con Locust
│   ├── requirements.txt             # Dependencias de testing
│   ├── simulate_dr_end_to_end.py    # Orquestador E2E: Carga Locust + Caos + Failover + Reporte HTML
│   ├── test_api_connection.py       # Pruebas funcionales de conectividad de la API
│   └── test_replication_fase2.py    # Verificación de replicación cross-region en us-west-2
└── docker-compose.yml               # Entorno de emulación local (MySQL 8.0 + LocalStack S3/DynamoDB + API)
```

---

## 5. Funcionamiento Detallado por Componentes

### 5.1 Red y Conectividad (VPC 3-Tier)
Cada región cuenta con una VPC aislada configurada en dos Zonas de Disponibilidad para tolerancia a fallos:
* **VPC Primaria (`us-east-1`):** Bloque `10.0.0.0/16`.
* **VPC Secundaria (`us-west-2`):** Bloque `10.1.0.0/16`.

Ambas implementan tres niveles de subredes:
1. **Tier Público:** Aloja el balanceador ALB e Internet Gateway. Contiene la Elastic IP del NAT Gateway.
2. **Tier Privado de Aplicación:** Aloja las instancias EC2 del Auto Scaling Group. Tiene acceso saliente a internet exclusivamente a través del NAT Gateway.
3. **Tier Privado de Datos:** Aloja la base de datos RDS MySQL. **Carece de rutas a internet (`0.0.0.0/0`)**; solo permite tráfico en el puerto `3306` originado desde el Security Group del cómputo.

### 5.2 Capa de Cómputo y Balanceo
* **Application Load Balancer:** Recibe el tráfico HTTP en el puerto 80 y lo distribuye hacia el puerto 8000 de las instancias EC2 mediante un Target Group con Health Checks cada 10 segundos en `/health`.
* **Launch Template:** Especifica instancias `t3.micro` con Amazon Linux 2023. En el script de `user_data`, instala Docker, clona el código fuente y levanta el contenedor de la API inyectando las variables de base de datos y AWS.
* **Auto Scaling Group y Prevención de Drift:**
  El ASG de `us-west-2` se inicializa con `min_size = 0` y `desired_capacity = 0`. El recurso en Terraform incluye:
  ```hcl
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity, min_size]
  }
  ```
  Esto previene que una ejecución posterior de Terraform revierta el escalado a 0 una vez que la región secundaria haya sido activada por un failover.

### 5.3 Persistencia Políglota y Replicación Cross-Region
El sistema maneja tres tipos de datos con sus respectivos mecanismos de sincronización continua:
1. **Datos Relacionales (Amazon RDS MySQL 8.0):**
   * Primario: Instancia Multi-AZ en `us-east-1` para conmutación síncrona local entre zonas.
   * Secundario: Read Replica asíncrona en `us-west-2` enlazada vía `replicate_source_db`.
   * Incluye `lifecycle { ignore_changes = [replicate_source_db] }` para que al promoverse a Standalone Writer durante el desastre, Terraform no intente recrearla.
2. **Sesiones y Carritos NoSQL (Amazon DynamoDB Global Tables):**
   * Tabla `user_sessions` con Streams habilitados (`NEW_AND_OLD_IMAGES`).
   * Replicación bidireccional Activa-Activa entre ambas regiones con latencia de propagación inferior a 1 segundo.
3. **Comprobantes y Archivos (Amazon S3 CRR):**
   * Buckets con versionado activo y cifrado en reposo `AES-256`.
   * Regla de Cross-Region Replication (CRR) con rol IAM dedicado que transfiere automáticamente objetos y marcadores de borrado entre regiones.

### 5.4 Borde y Enrutamiento Global
* **Route 53 Failover DNS:**
  * Health Checks monitorean `/health` cada **10 segundos** con un umbral de 3 fallos consecutivos (detección en 30 segundos).
  * Registro Alias `PRIMARY` hacia el ALB de `us-east-1` y `SECONDARY` hacia el ALB de `us-west-2`.
* **AWS CloudFront (Origin Group):**
  * Configura un grupo de orígenes que incluye ambos ALBs. Conmuta automáticamente las peticiones hacia el balanceador secundario si el primario responde con códigos de error `500, 502, 503` o `504`.

---

## 6. API Transaccional y Resiliencia (`api/main.py`)

La API FastAPI está construida para manejar caídas y conmutaciones sin interrupciones:
* **Manejo de Desconexiones con `pool_pre_ping=True`:**
  ```python
  engine = create_engine(
      DATABASE_URL,
      pool_pre_ping=True,
      pool_recycle=3600,
      connect_args={"connect_timeout": 5}
  )
  ```
  Cuando la réplica de RDS se promueve a escritora, las conexiones TCP se resetean. El parámetro `pool_pre_ping` ejecuta una comprobación previa (`SELECT 1`) en cada consulta, descartando conexiones muertas y reestableciendo una conexión válida hacia el nuevo Writer de forma transparente.
* **Separación de Monitoreo:**
  * `/health`: Verificación inmediata ($< 1\text{ ms}$) utilizada por Route 53 y ALB para determinar la salud del nodo.
  * `/readiness`: Sondeo profundo que valida la conectividad en vivo hacia RDS (`SELECT 1`), DynamoDB (`describe_table`) y S3 (`head_bucket`).
* **Endpoints de Negocio:**
  * `POST /transaction`: Registra pagos con ID único, monto y región de procesamiento.
  * `GET /transactions/latest`: Consulta el histórico de transacciones para auditar el cumplimiento del RPO.
  * `POST /cart` y `GET /cart/{user_id}`: Operaciones sobre carritos en DynamoDB Global Tables.
  * `POST /invoice` y `GET /invoice/{id}`: Carga y verificación de comprobantes en S3 con metadatos y `VersionId`.

---

## 7. Automatización SRE de Failover (`automation/failover_trigger.py`)

Script en Python utilizando **Boto3** que ejecuta la conmutación sin intervención manual en consolas:
1. **Detección Dinámica:** Descubre el nombre generado del Auto Scaling Group secundario mediante el prefijo `dr-architecture-secondary-asg-`.
2. **Promoción de Base de Datos:** Llama a `promote_read_replica` sobre `dr-architecture-secondary-mysql`. La función es idempotente; si ya fue promovida, continúa sin generar error.
3. **Escalado Horizontal:** Eleva `MinSize = 2` y `DesiredCapacity = 2` en el ASG de `us-west-2`, levantando dos instancias EC2 en minutos.
4. **Sondeo de Convergencia:** Monitorea que RDS esté disponible, que las instancias EC2 alcancen el estado `InService` en el balanceador y que `/health` retorne HTTP 200, registrando el tiempo de recuperación (**RTO**) alcanzado.
5. **Modo Failback:** El argumento `--mode scale-down` reduce el ASG secundario nuevamente a `0` instancias una vez que la región primaria se ha recuperado.

---

## 8. Ciclo de Vida del Desastre (Failover y Failback)

```
[1. Operación Normal]
  - Tráfico dirigido 100% a us-east-1 a través de CloudFront y Route 53 (PRIMARY).
  - us-west-2 en reposo Warm Standby (ASG en desired=0, RDS como Read Replica).
  - Sincronización continua de datos entre regiones.

[2. Evento de Caída en us-east-1]
  - Caída catastrófica o sobrecarga masiva en us-east-1.
  - El endpoint /health de us-east-1 deja de responder o retorna HTTP 503.

[3. Detección y Conmutación en el Borde]
  - Route 53 detecta 3 fallos consecutivos en 30 segundos y cambia el DNS hacia SECONDARY.
  - CloudFront activa Origin Failover al recibir respuestas de error del primario.

[4. Disparo de Automatización SRE (failover_trigger.py)]
  - Promueve la Read Replica de RDS en us-west-2 a Standalone Writer.
  - Escala el Auto Scaling Group de us-west-2 de 0 a 2 instancias EC2.

[5. Restablecimiento del Servicio]
  - Las nuevas instancias entran en estado InService en el balanceador secundario.
  - us-west-2 comienza a procesar lecturas y escrituras productivas.
  - RTO observado: minutos | RPO observado: 0% pérdida de transacciones.

[6. Procedimiento de Retorno (Failback)]
  - La región primaria us-east-1 es restablecida.
  - Se sincronizan los datos generados durante la contingencia.
  - Se ejecuta failover_trigger.py --mode scale-down para regresar el ASG de us-west-2 a 0 instancias.
```

---

## 9. Pruebas de Carga y Caos con Locust (`tests/`)

El sistema incluye una suite de pruebas con **Locust** ([locust.io](https://locust.io/)) para validar el comportamiento bajo estrés concurrente:

* **[tests/locustfile.py](tests/locustfile.py):** Modela usuarios virtuales que generan tráfico ponderado contra la API, auditando en cada respuesta la región que atendió la petición.
* **[tests/simulate_dr_end_to_end.py](tests/simulate_dr_end_to_end.py):**
  1. Inicia un Gateway Global multi-región con `us-east-1` activo y `us-west-2` en Warm Standby.
  2. Lanza Locust con 25 usuarios concurrentes.
  3. En $t = +7\text{s}$, inyecta la caída de `us-east-1` (`HTTP 503`).
  4. Dispara automáticamente `failover_trigger.py`, promueve RDS y escala el ASG secundario a 2 instancias.
  5. Conmuta el tráfico a `us-west-2` y exporta el reporte gráfico interactivo a [`docs/locust_dr_report.html`](docs/locust_dr_report.html).

---

## 10. Guía de Ejecución Rápida

### A. Simulación End-to-End con Locust
```bash
pip install -r tests/requirements.txt
python tests/simulate_dr_end_to_end.py
```
*Genera el reporte HTML interactivo en [`docs/locust_dr_report.html`](docs/locust_dr_report.html).*

### B. Interfaz Gráfica Web de Locust
```bash
locust -f tests/locustfile.py --host http://localhost:8000
```
*Abrir `http://localhost:8089` para lanzar usuarios y ver las gráficas en tiempo real.*

### C. Entorno Local con Docker Compose
```bash
docker compose up --build -d
python tests/test_api_connection.py --url http://localhost:8000
```

### D. Despliegue en AWS con Terraform
```bash
# 1. Región Primaria (us-east-1)
cd terraform/environments/primary_us_east_1 && terraform init && terraform apply -auto-approve

# 2. Región Secundaria Warm Standby (us-west-2)
cd ../secondary_us_west_2 && terraform init && terraform apply -auto-approve

# 3. Capa Global (Route 53 & CloudFront)
cd ../global && terraform init && terraform apply -auto-approve
```

### E. Conmutación Manual (Failover y Failback)
```bash
# Activar región secundaria ante un desastre:
python automation/failover_trigger.py --region us-west-2 --capacity 2

# Retornar a reposo Warm Standby tras normalización:
python automation/failover_trigger.py --region us-west-2 --mode scale-down
```

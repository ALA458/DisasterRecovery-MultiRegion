# Estrategia de Disaster Recovery Multi-Región en AWS (Warm Standby)

Proyecto integral de diseño, implementación y validación de una arquitectura de alta disponibilidad y recuperación ante desastres (**Disaster Recovery - DR**) en **Amazon Web Services (AWS)** bajo el modelo **Warm Standby**, con objetivos de nivel de servicio estrictos:
* **RTO (Recovery Time Objective):** $< 15$ minutos ($900$ segundos)
* **RPO (Recovery Point Objective):** $< 5$ minutos ($300$ segundos)

---

## Equipo de Trabajo

* **Universidad Tecnológica de Bolívar (UTB)** — Arquitectura de Sistemas Distribuidos y Cloud Computing
* **Integrantes y Roles:**
  * **Maykol Stiven Madrid Romero — `T00078588`** | *Compute & Networking Specialist*
  * **Joel David Gonzalez Barros — `T00078571`** | *DevOps Lead & Core IaC*
  * **Álvaro Jesús Ayala Alcala — `T00078312`** | *Database & Persistence Engineer*
  * **Diego Peña Paez — `T00067812`** | *SRE & Automation Engineer*

---

## 1. Fundamentos y Estrategia: ¿Por qué Warm Standby?

En la computación en la nube existen cuatro patrones principales de Disaster Recovery:

```
[Menor Costo / Mayor RTO]                                   [Mayor Costo / Menor RTO]
Backup & Restore (Horas)  -->  Pilot Light (20-45m)  -->  Warm Standby (< 15m)  -->  Active-Active (< 1m)
                                                            ▲
                                                     [NUESTRA ELECCIÓN]
```

* **Descarte de Backup & Restore y Pilot Light:** Presentan tiempos de recuperación inaceptables ($> 30\text{ minutos}$ a varias horas) debido a la necesidad de reconstruir la red, bases de datos o esperar el aprovisionamiento de máquinas virtuales desde cero.
* **Descarte de Active-Active Multi-Región:** Duplica al $200\%$ los costos de cómputo en reposo continuo y genera una latencia de red跨-región inadmisible ($70\text{ a }90\text{ ms}$) en los `COMMIT` sincrónicos de bases de datos relacionales, además de complejos conflictos de concurrencia multi-maestro.
* **Ventajas del Modelo Warm Standby:**
  1. **Persistencia Sincronizada en Tiempo Real:** Las tres capas de datos (RDS Read Replica, DynamoDB Global Tables y S3 Cross-Region Replication) operan de forma continua.
  2. **Ahorro de Costos Óptimo:** La VPC, subredes, firewalls y el Balanceador de Carga (ALB) en la región secundaria (`us-west-2`) están aprovisionados y activos, pero las instancias de cómputo EC2 se mantienen en **`desired_capacity = 0`** (cero costo de cómputo en reposo).
  3. **Conmutación en Minutos:** Ante un desastre, la automatización en Python Boto3 promueve la base de datos a escritora y escala el grupo de instancias a capacidad productiva en minutos, cumpliendo holgadamente el **RTO $< 15\text{ min}$** y **RPO $< 5\text{ min}$**.

---

## 2. Arquitectura Global de la Solución

```mermaid
flowchart TD
    subgraph EdgeTier ["Borde y Distribución Global (Anycast / DNS)"]
        Users["Usuarios / Clientes / Locust"] --> CF["AWS CloudFront (Origin Group Multi-Region)"]
        CF --> R53["Route 53 Failover DNS (Health Check cada 10 seg)"]
    end

    subgraph RegionPrimary ["Región Primaria: us-east-1 (Activa - Productiva)"]
        ALB1["Application Load Balancer (us-east-1)"]
        ASG1["EC2 Auto Scaling Group (2-4 Instancias t3.micro)\nAPI FastAPI Contenerizada"]
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
        ASG2["EC2 Auto Scaling Group (desired=0 -> escala a 2 en Failover)\nAPI FastAPI"]
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

    %% Canales de Replicación
    RDS1 -- "Replicación Asíncrona Cross-Region (RPO < 5s)" --> RDS2
    DDB1 <== "DynamoDB Global Tables (Activo-Activo < 1s)" ==> DDB2
    S31 -- "S3 Cross-Region Replication (CRR con IAM Role)" --> S32
```

---

## 3. Estructura del Repositorio y Explicación de Código

```text
├── .github/
│   └── workflows/
│       └── terraform.yml            # CI/CD: Validación estática en PRs y Despliegue Secuencial en main
├── api/
│   ├── Dockerfile                   # Contenedor multi-stage optimizado (python:3.11-slim)
│   ├── main.py                      # API REST transaccional (FastAPI, SQLAlchemy, Boto3)
│   └── requirements.txt             # Dependencias de la API
├── automation/
│   └── failover_trigger.py          # Script SRE Boto3: promueve RDS Read Replica, escala ASG (0->2) y mide RTO
├── docs/
│   ├── locust_dr_report.html        # Reporte gráfico interactivo de pruebas de carga y Failover con Locust
│   └── runbook.md                   # Procedimientos operativos estándar (SOP de Failover & Failback)
├── terraform/
│   ├── environments/
│   │   ├── global/                  # Fase 3: Route 53 Failover DNS + CloudFront Origin Group
│   │   ├── primary_us_east_1/       # Fase 1: Infraestructura productiva en us-east-1 (desired=2)
│   │   └── secondary_us_west_2/     # Fase 2: Infraestructura Warm Standby en us-west-2 (desired=0)
│   └── modules/
│       ├── compute_alb_asg/         # Balanceador ALB, IAM Roles, Launch Template y Auto Scaling Group
│       ├── database_rds/            # Instancia MySQL 8.0 (soporta Primary Multi-AZ y Read Replica Cross-Region)
│       ├── route53_failover/        # Hosted Zone, Health Checks HTTP (10s) y Registros Alias PRIMARY/SECONDARY
│       ├── storage_s3/              # Buckets S3 con versionado, cifrado AES-256 y reglas CRR
│       └── vpc/                     # Red VPC 3-Tier (subredes públicas, privadas de app y privadas de datos)
├── tests/
│   ├── locustfile.py                # Escenario de pruebas de carga concurrente y auditoría SLA con Locust
│   ├── requirements.txt             # Dependencias de pruebas
│   ├── simulate_dr_end_to_end.py    # Simulador E2E: Carga masiva + Inyección de Caos + Failover + Reporte HTML
│   ├── test_api_connection.py       # Validación E2E Fase 1 (6 pruebas funcionales)
│   └── test_replication_fase2.py    # Validación E2E Fase 2 (auditoría de replicación cross-region)
└── docker-compose.yml               # Entorno local completo (MySQL 8.0 + LocalStack S3/DynamoDB + API)
```

---

## 4. Desglose Técnico por Capas y Componentes

### A. Capa de Red (VPC 3-Tier) — `terraform/modules/vpc/`
* **Aislamiento Geográfico y CIDRs Desacoplados:**
  * Región Primaria (`us-east-1`): Red `10.0.0.0/16`.
  * Región Secundaria (`us-west-2`): Red `10.1.0.0/16`.
  * Esta separación evita solapamientos y permite establecer VPC Peering o Transit Gateway sin conflicto.
* **Segmentación en 3 Tiers (en 2 Zonas de Disponibilidad para alta disponibilidad local):**
  1. *Subredes Públicas:* Acomodan los Application Load Balancers (ALB) y NAT Gateways con salida por Internet Gateway.
  2. *Subredes Privadas de Aplicación:* Acomodan las instancias EC2 del Auto Scaling Group con salida saliente a internet vía NAT Gateway para comunicarse con APIs de AWS.
  3. *Subredes Privadas de Datos:* Aisladas estrictamente sin salida a internet (`0.0.0.0/0`); solo admiten tráfico TCP en el puerto `3306` originado desde el Security Group de las instancias EC2.

### B. Capa de Cómputo Elástico — `terraform/modules/compute_alb_asg/`
* **Application Load Balancer (ALB):** Expone el puerto 80 y distribuye tráfico hacia el puerto 8000 mediante un Target Group con sondeo cada 10 segundos en `/health`.
* **Launch Template:** Instancias `t3.micro` con Amazon Linux 2023. El script de arranque (`user_data`) instala Docker, clona el repositorio desde GitHub y levanta el contenedor de la API inyectando las variables de base de datos y AWS.
* **Auto Scaling Group y Prevención de Drift:**
  ```hcl
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity, min_size]
  }
  ```
  Permite que en `us-west-2` el ASG arranque en `0` instancias y que, cuando el script de failover lo escale a `2`, futuras ejecuciones de Terraform no reviertan el clúster a cero.
* **Gestión Segura con AWS SSM:** Se asocia la política administrada `AmazonSSMManagedInstanceCore` al IAM Role de las EC2, permitiendo gestión por consola mediante Session Manager sin necesidad de abrir el puerto SSH 22.

### C. Capa de Persistencia Políglota — `terraform/modules/`
1. **Relacional (RDS MySQL 8.0) — `database_rds/`:**
   * En `us-east-1`: Configurado como escritor maestro con **Multi-AZ habilitado** (standby síncrono intra-región) y retención de backups de 7 días.
   * En `us-west-2`: Configurado como **Read Replica asíncrona Cross-Region** enlazada mediante `replicate_source_db`.
   * Incluye `lifecycle { ignore_changes = [replicate_source_db] }` para que cuando el failover rompa la réplica y la convierta en Standalone Writer, Terraform no intente destruirla.
2. **NoSQL (DynamoDB Global Tables) — `secondary_us_west_2/`:**
   * La tabla `user_sessions` en `us-east-1` tiene habilitado `DynamoDB Streams` con vista `NEW_AND_OLD_IMAGES`.
   * El recurso `aws_dynamodb_table_replica` extiende la tabla a `us-west-2`, proporcionando replicación activa-activa bidireccional en menos de 1 segundo.
3. **Almacenamiento de Objetos (Amazon S3) — `storage_s3/`:**
   * Versionado obligatorio activo (`aws_s3_bucket_versioning`).
   * Cifrado en reposo `SSE-S3` (`AES-256`) y bloqueo total de acceso público.
   * Regla de **Cross-Region Replication (CRR)** respaldada por un rol IAM que replica objetos y marcadores de borrado de forma automática hacia el bucket réplica en `us-west-2`.

### D. Capa de Borde y Enrutamiento Global — `terraform/environments/global/`
* **Route 53 Failover DNS (`route53_failover/`):**
  * Health Checks HTTP de alta frecuencia cada **10 segundos** (`failure_threshold = 3`, detección en 30 segundos).
  * Registro Alias `PRIMARY` apuntando al ALB de `us-east-1` y `SECONDARY` al ALB de `us-west-2`.
* **AWS CloudFront Multi-Región:**
  * Distribución global con **Origin Group Failover** (`dr-multi-region-origin-group`). Si el ALB primario responde con códigos `500, 502, 503` o `504`, CloudFront conmuta de forma transparente e instantánea al ALB secundario.

---

## 5. API Transaccional y Patrones de Resiliencia (`api/main.py`)

* **FastAPI + SQLAlchemy con `pool_pre_ping=True`:**
  ```python
  engine = create_engine(
      DATABASE_URL,
      pool_pre_ping=True,
      pool_recycle=3600,
      connect_args={"connect_timeout": 5}
  )
  ```
  * *Manejo de Failover:* Cuando la base de datos de `us-west-2` es promovida de réplica de solo lectura a escritora, las conexiones TCP existentes se reinician. `pool_pre_ping=True` valida la conexión antes de despachar cada consulta; si el socket murió, lo reemplaza limpiamente sin arrojar errores al usuario.
* **Endpoints Principales:**
  * `GET /health`: Health Check ultra-ligero para Route 53 y ALB (indica estado y región activa).
  * `GET /readiness`: Chequeo profundo de salud conectando a RDS (`SELECT 1`), DynamoDB (`describe_table`) y S3 (`head_bucket`).
  * `POST /transaction`: Registra pagos con ID único UUID, monto, timestamp UTC y la etiqueta `region`.
  * `GET /transactions/latest`: Consulta el histórico de transacciones para auditar el **RPO** (certifica que lo escrito en `us-east-1` antes del fallo esté íntegro).
  * `POST /cart` y `GET /cart/{user_id}`: Persistencia de sesiones en DynamoDB Global Tables.
  * `POST /invoice` y `GET /invoice/{id}`: Genera comprobantes en S3 y retorna su `VersionId` único.

---

## 6. Automatización SRE de Failover (`automation/failover_trigger.py`)

Script autónomo en Python con el SDK **Boto3** que ejecuta la conmutación en segundos sin intervención manual:
1. **Autodescubrimiento Dinámico:** La función `find_asg_by_prefix` detecta el nombre exacto del Auto Scaling Group secundario a partir del prefijo `dr-architecture-secondary-asg-`.
2. **Promoción Idempotente de RDS:** Llama a `promote_read_replica` sobre `dr-architecture-secondary-mysql`. Si la base de datos ya fue promovida, continúa sin error.
3. **Escalado Horizontal Warm Standby:** Eleva `MinSize = 2` y `DesiredCapacity = 2` en el ASG de `us-west-2`, encendiendo dos instancias EC2 en minutos.
4. **Medición del RTO en Vivo:** La función `wait_for_convergence` sondea el estado de RDS, las instancias `InService` en el balanceador y el código HTTP 200 en `/health`, calculando e imprimiendo el tiempo exacto de recuperación.
5. **Procedimiento de Retorno (Failback):** El parámetro `--mode scale-down` permite reducir nuevamente el ASG de `us-west-2` a `0` instancias cuando la región primaria se ha restablecido.

---

## 7. Pruebas de Estrés y Caos con Locust (`tests/`)

Se implementó una suite con **Locust** ([locust.io](https://locust.io/)) para evaluar la resistencia del sistema bajo carga masiva y simular la caída regional:

* **[tests/locustfile.py](tests/locustfile.py):** Modela usuarios virtuales concurrentes realizando operaciones ponderadas sobre RDS, DynamoDB y S3, auditando el campo `region` de cada respuesta.
* **[tests/simulate_dr_end_to_end.py](tests/simulate_dr_end_to_end.py):**
  1. Levanta el clúster multi-región con `us-east-1` activo y `us-west-2` en Warm Standby (`desired=0`).
  2. Lanza Locust con **25 usuarios simultáneos**.
  3. En $t = +7\text{s}$, **inyecta la caída total de `us-east-1` (`HTTP 503`)**.
  4. Dispara automáticamente `failover_trigger.py`, promueve RDS y escala el ASG secundario a 2 instancias.
  5. Conmuta el tráfico a `us-west-2` y genera el reporte gráfico HTML en [`docs/locust_dr_report.html`](docs/locust_dr_report.html).

### Resultados Cuantitativos Obtenidos:

```text
========================================================================================
                     DICTAMEN DE AUDITORÍA Y CUMPLIMIENTO DE SLAs
========================================================================================
 Métrica / Prueba         | Objetivo SLA       | Resultado Obtenido en Prueba  | Estado
--------------------------|--------------------|-------------------------------|--------
 Peticiones Totales       | Carga sostenida    | 1,222 peticiones (63.7 req/s) | OK
 Latencia Promedio        | < 50 ms            | 5 ms (Mediana: 2 ms)          | OK
 Transacciones us-east-1  | Pre-caída          | 73 registros procesados       | OK
 Transacciones us-west-2  | Post-failover      | 176 registros procesados      | OK
 RPO (Pérdida de datos)   | < 5 minutos (300s) | 0% pérdida (73/73 intactas)   | 100% OK
 RTO (Tiempo recuperación)| < 15 minutos (900s)| 2.01 a 2.04 segundos          | 100% OK
========================================================================================
```

---

## 8. Guía de Ejecución y Validación

### A. Simulación End-to-End con Locust (Para Demostración Rápida)
```bash
pip install -r tests/requirements.txt
python tests/simulate_dr_end_to_end.py
```
*Abre [`docs/locust_dr_report.html`](docs/locust_dr_report.html) en tu navegador para ver las curvas interactivas de tráfico, percentiles y conmutación.*

### B. Ejecución con Interfaz Gráfica de Locust (Dashboard en Vivo)
```bash
locust -f tests/locustfile.py --host http://localhost:8000
```
*Accede a `http://localhost:8089` para lanzar usuarios concurrentes y monitorear las gráficas en tiempo real.*

### C. Ejecución Local con Docker Compose
```bash
docker compose up --build -d
python tests/test_api_connection.py --url http://localhost:8000
```

### D. Despliegue en AWS Real con Terraform
```bash
# 1. Región Primaria (us-east-1)
cd terraform/environments/primary_us_east_1 && terraform init && terraform apply -auto-approve

# 2. Región Secundaria Warm Standby (us-west-2)
cd ../secondary_us_west_2 && terraform init && terraform apply -auto-approve

# 3. Capa Global (Route 53 & CloudFront)
cd ../global && terraform init && terraform apply -auto-approve
```

### E. Disparo Manual de Failover y Failback en AWS
```bash
# Ejecutar Failover (Promover RDS y escalar ASG a 2 en us-west-2):
python automation/failover_trigger.py --region us-west-2 --capacity 2

# Ejecutar Failback (Reducir ASG secundario a 0 tras normalizar us-east-1):
python automation/failover_trigger.py --region us-west-2 --mode scale-down
```

Consulta el procedimiento operativo estándar paso a paso en el [Runbook Operativo](docs/runbook.md).

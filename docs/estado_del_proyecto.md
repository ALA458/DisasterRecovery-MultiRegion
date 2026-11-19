# Informe de Estado del Proyecto: Arquitectura de Disaster Recovery Multi-Región en AWS (Warm Standby)

**Universidad Tecnológica de Bolívar (UTB)**  
**Facultad de Ingeniería — Programa de Ingeniería de Sistemas**  
**Asignatura:** Infraestructura como Código & DevOps  
**Docente:** Rafael Enrique Monterroza Barrios  
**Fecha de corte:** Noviembre de 2026
**Estado general:** IMPLEMENTACIÓN COMPLETA — lista para despliegue y validación final en AWS

---

## 1. Ficha Técnica y Objetivos de Negocio

* **Estrategia DR Adoptada:** Warm Standby Multi-Región (`us-east-1` Primaria Activa / `us-west-2` Secundaria Standby).
* **SLA de Recuperación:**
  * **RTO (Recovery Time Objective):** $< 15$ minutos.
  * **RPO (Recovery Point Objective):** $< 5$ minutos.
* **Modelo de Persistencia Evaluado:**
  * **Relacional:** Amazon RDS MySQL (Multi-AZ en primaria $\rightarrow$ Cross-Region Read Replica en secundaria).
  * **NoSQL:** Amazon DynamoDB (Global Tables v2 con replicación activa-activa inter-regional).
  * **Objetos:** Amazon S3 (Cross-Region Replication - CRR con versionado obligatorio).
* **Cómputo:** Balanceador ALB público + Auto Scaling Group de instancias EC2 ejecutando contenedor Docker con FastAPI.

---

## 2. Equipo de Trabajo y Matriz de Responsabilidad

| Integrante | Código UTB | Rol en el Proyecto | Responsabilidades Principales |
| :--- | :---: | :--- | :--- |
| **Joel David Gonzalez Barros** | `T00078571` | **DevOps Lead & Core IaC** | Gobernanza de Terraform, Pipeline CI/CD en GitHub Actions, Módulo `vpc`, Módulo `storage_s3` (CRR) y gestión del State remoto. |
| **Álvaro Jesús Ayala Alcala** | `T00078312` | **Database & Persistence Engineer** | Módulo `database_rds` (Multi-AZ y Read Replica asíncrona), DynamoDB Global Tables y gestión de secretos en SSM. |
| **Maykol Stiven Madrid Romero** | `T00078588` | **Compute & Networking Specialist** | Módulo `compute_alb_asg` (ALB, Target Groups, Launch Templates, User Data para EC2 y ASG de ambas regiones). |
| **Diego Peña Paez** | `T00067812` | **SRE & Automation Engineer** | Desarrollo de la API REST transaccional, script `failover_trigger.py` (Boto3), módulo `route53_failover`, Chaos Engineering y Runbook. |

---

## 3. Estado Actual de Avance por Fases

```
[FASE 0] Preparación & API:      ████████████████████ 100% (Completada y Probada)
[FASE 1] Región Primaria (IaC):   ████████████████████ 100% (Codificada y Validada)
[FASE 2] Warm Standby & Replica:  ████████████████████ 100% (Implementada como código)
[FASE 3] Failover DNS & Boto3:    ████████████████████ 100% (Implementada como código)
[FASE 4] Chaos, RTO/RPO & Runbook:████████████████████ 100% (Simulación y Runbook listos)
```

---

## 4. Detalle Exhaustivo de lo Realizado

### 4.1. Fase 0: Preparación del Entorno, CI/CD y Backend Transaccional (100% Completada)
1. **Saneamiento del Pipeline CI/CD (`.github/workflows/terraform.yml`):**
   * Se resolvió la incompatibilidad crítica entre la directiva nativa de S3 `use_lockfile = true` y Terraform: se actualizó el runner de GitHub Actions a **Terraform 1.10.5** con `actions/checkout@v4` y `hashicorp/setup-terraform@v3`.
   * Se agregó un *job* automatizado previo (`validate`) que audita el formateo en todo el árbol de directorios con `terraform fmt -check -recursive ./terraform`.
2. **Implementación de la API Transaccional Real (`api/main.py`):**
   * Se sustituyeron las respuestas simuladas por persistencia auténtica mediante **SQLAlchemy ORM** (`TransactionModel`).
   * Se implementaron endpoints de observabilidad:
     * `GET /health`: Chequeo inmediato para el balanceador y Route 53 (200 OK con región y timestamp).
     * `GET /readiness`: Chequeo profundo de salud que valida la conectividad física hacia MySQL, DynamoDB y S3.
     * `POST /transaction`: Inserción transaccional relacional con UUID y commit en MySQL.
     * `GET /transactions/latest`: Consulta de auditoría utilizada como métrica base para el cálculo de RPO.
     * `POST /cart` y `GET /cart/{user_id}`: Persistencia de estado en DynamoDB.
     * `POST /invoice` y `GET /invoice/{invoice_id}`: Carga de comprobantes en S3 con metadatos.
3. **Empaquetado y Optimización de Contenedor (`api/Dockerfile` & `requirements.txt`):**
   * Se corrigió la bandera `--no-deps` del comando `pip wheel`, asegurando la descarga íntegra de las dependencias transitivas.
   * Se incluyó la librería `cryptography>=42.0.0` requerida por el método de autenticación `caching_sha2_password` de MySQL 8.0 en AWS RDS.
   * Se configuró el comando nativo `HEALTHCHECK` dentro de la imagen.
4. **Entorno de Pruebas Local (`docker-compose.yml`):**
   * Se diseñó el entorno local para desacoplar el desarrollo de los costos de AWS.
   * Se reasignó el puerto de la base de datos a `3307:3306` para evitar colisiones con instancias nativas de MySQL en Windows (`mysqld.exe`).
   * **Pruebas locales ejecutadas y aprobadas:** Contenedores `dr-local-mysql` y `dr-api-service` levantados, probados con `Invoke-RestMethod` y con transacciones reales confirmadas en base de datos.
5. **Estandarización de Estados Remotos:**
   * Se generaron los archivos `backend.tf` con bloqueo nativo para los tres entornos (`primary_us_east_1`, `secondary_us_west_2` y `global`), garantizando el aislamiento de estados y previniendo el radio de impacto entre regiones.

---

### 4.2. Fase 1: Infraestructura Base y Región Primaria `us-east-1` (100% Codificada y Validada)
Se desarrollaron módulos reutilizables bajo estándares de producción en `terraform/modules/`:

1. **Módulo de Red (`modules/vpc/`):**
   * Topología multi-nivel en 2 Zonas de Disponibilidad (AZs dinámicas).
   * 2 subredes públicas (para el ALB e Internet Gateway).
   * 2 subredes privadas de aplicación (para el ASG de EC2, con salida controlada mediante NAT Gateway y Elastic IP).
   * 2 subredes privadas de datos (para RDS MySQL, con aislamiento de red estricto sin ruta a Internet).
2. **Módulo de Almacenamiento (`modules/storage_s3/`):**
   * Bucket con versionado obligatorio habilitado (`versioning { status = "Enabled" }`), habilitador técnico indispensable para la replicación inter-regional (CRR).
   * Cifrado en reposo SSE-S3 (`AES256`) y bloqueo total de acceso público.
3. **Módulo de Base de Datos Relacional (`modules/database_rds/`):**
   * Instancia MySQL 8.0 en configuración **Multi-AZ** (`multi_az = true`) como escritor principal.
   * Retención de backups automatizados fijada en **7 días** (`backup_retention_period = 7`), requisito mandatorio de AWS para habilitar réplicas de lectura cross-region en la Fase 2.
   * Security Group restringido al puerto 3306 admitiendo tráfico únicamente desde el Security Group de las instancias EC2.
4. **Módulo de Cómputo y Balanceo (`modules/compute_alb_asg/`):**
   * Application Load Balancer público con Target Group configurado para evaluar `/health` cada **10 segundos** con umbral de 2 fallos consecutivos.
   * Rol de IAM e *Instance Profile* con directiva `AmazonSSMManagedInstanceCore` (acceso por Session Manager sin llaves SSH) y permisos de lectura/escritura en DynamoDB y S3.
   * *Launch Template* con script de *User Data* automatizado: instala Docker, clona el repositorio, inyecta las variables de entorno (`DB_HOST`, `DB_NAME`, `DYNAMO_TABLE`, `S3_BUCKET`, `AWS_REGION`) y corre el contenedor en segundo plano.
   * Auto Scaling Group configurado en `desired_capacity = 2` (mínimo 2, máximo 4) en las subredes privadas.
5. **Capa NoSQL DynamoDB (`environments/primary_us_east_1/`):**
   * Tabla `user_sessions` en modo `PAY_PER_REQUEST` con **DynamoDB Streams activos** (`NEW_AND_OLD_IMAGES`), lista para convertirse en *Global Table* en la Fase 2.
6. **Harness de Pruebas Automatizadas (`tests/test_api_connection.py`):**
   * Script en Python que valida en secuencia los 6 componentes de la infraestructura contra el DNS del balanceador en AWS: salud del ALB, `/readiness`, escritura y lectura en RDS, operaciones en DynamoDB y carga de archivos en S3.
7. **Validación Formal con Terraform:**
   * `terraform init`: Inicialización completa de módulos y proveedores (`hashicorp/aws v5.100.0`, `hashicorp/random v3.9.1`).
   * `terraform validate`: Sintaxis 100% válida (`Success! The configuration is valid.`).
   * `terraform plan`: **40 recursos planificados para creación** (`Plan: 40 to add, 0 to change, 0 to destroy`), coincidiendo con la arquitectura diseñada.

---

## 5. Próximos Pasos Inmediatos (Plan de Acción)

### Paso 1: Ejecución del Despliegue en AWS (Inmediato)
* **Acción:** Ejecutar el despliegue del plan generado en la cuenta de AWS con el usuario IAM de permisos mínimos:
  ```powershell
  terraform "-chdir=terraform/environments/primary_us_east_1" apply tfplan
  ```
* **Tiempo estimado:** 10 a 15 minutos (aprovisionamiento del clúster Multi-AZ y del NAT Gateway).
* **Resultado esperado:** Obtención del `alb_dns_name` y el `rds_endpoint`.

### Paso 2: Validación End-to-End en la Nube
* **Acción:** Ejecutar la suite de pruebas contra el balanceador desplegado:
  ```powershell
  python tests/test_api_connection.py --url http://<ALB_DNS_NAME>
  ```
* **Resultado esperado:** Los 6 chequeos en estado `[OK]`, certificando el cierre formal de la Fase 1.

### Paso 3: Fase 2 completada (Warm Standby y Replicación Cruzada)
* El entorno secundario de `us-west-2` ya contiene VPC, cómputo en `desired_capacity = 0`, RDS Read Replica, réplica S3 y DynamoDB Global Tables.
* Existe la suite `tests/test_replication_fase2.py` para verificar RDS, DynamoDB y S3 después del despliegue.

### Paso 4: Fase 3 completada (Failover DNS y Automatización Boto3)
* Route 53, CloudFront, Health Checks y notificaciones SNS están implementados en Terraform.
* `automation/failover_trigger.py` promueve RDS, escala el ASG secundario y monitorea convergencia y RTO.

### Paso 5: Fase 4 lista para ejecutar (Chaos Engineering, RTO/RPO y Runbook)
* `tests/simulate_dr_end_to_end.py` ejecuta el ciclo completo de carga, degradación, failover y reporte.
* `docs/runbook.md` contiene los procedimientos operativos finales.
* La validación científica real debe registrarse ejecutando el simulacro en la cuenta AWS de la sustentación.

---

## 6. Recomendaciones Operativas y de Costos

1. **Gestión de Créditos Cloud:**
   * Dado que el clúster RDS Multi-AZ y el NAT Gateway facturan por hora de uso, cuando el equipo termine las sesiones de prueba diarias se recomienda destruir los recursos temporales para no agotar el saldo de AWS:
     ```powershell
     terraform "-chdir=terraform/environments/primary_us_east_1" destroy -auto-approve
     ```
   * Al estar toda la infraestructura declarada en código, volver a levantarla para una entrega o clase tomará únicamente una ejecución de `terraform apply`.
2. **Registro de Evidencias para la Sustentación:**
   * Tomar capturas de pantalla de la salida de `terraform plan` (40 recursos), la consola de AWS mostrando el Multi-AZ y la ejecución exitosa de `test_api_connection.py`. Estas evidencias sustentarán el 20% correspondiente a la primera entrega evaluada por el profesor Rafael Monterroza.

# Runbook Operativo: Disaster Recovery Multi-Región (Failover y Failback)

> **Estado del documento:** Runbook operativo listo. Contiene los procedimientos de failover y failback y el script de automatización; las métricas reales de RTO/RPO deben registrarse al ejecutar el simulacro en AWS.

---

## 1. Propósito y Alcance

Este manual define los Procedimientos Operativos Estándar (SOP) para responder ante una caída total o degradación severa de la región primaria `us-east-1`, ejecutando la conmutación hacia la región Warm Standby `us-west-2` y el posterior restablecimiento hacia la región primaria.

- **Objetivo de Tiempo de Recuperación (RTO):** `< 15 minutos`
- **Objetivo de Punto de Recuperación (RPO):** `< 5 minutos`

---

## 2. Matriz de Roles y Escalamiento

| Rol Operativo | Responsable | Código UTB | Responsabilidad Durante Incidente |
| :--- | :--- | :--- | :--- |
| **Incident Commander / DevOps Lead** | Joel David Gonzalez Barros | `T00078571` | Autorización de Failback, validación de estado Terraform (`primary` / `secondary` / `global`) y gobernanza de red/S3. |
| **SRE & Automation Lead** | Diego Peña Paez | `T00067812` | Monitoreo de alertas SNS, ejecución/auditoría de `failover_trigger.py`, validación de Route 53 y medición de RTO/RPO. |
| **Database & Persistence Lead** | Álvaro Jesús Ayala Alcala | `T00078312` | Verificación de promoción de RDS Read Replica, auditoría de integridad en `/transactions/latest` y replicación DynamoDB. |
| **Compute & Networking Lead** | Maykol Stiven Madrid Romero | `T00078588` | Verificación de salud del ALB secundario, escalado del ASG en `us-west-2` y validación de Targets en estado `healthy`. |

---

## 3. Verificaciones Previas (Pre-Flight Checks en Operación Normal)

Antes de validar o simular una contingencia, confirmar:
1. El endpoint público primario responde `200 OK` en `GET /health` y `"connected"` en las tres capas en `GET /readiness`.
2. El Auto Scaling Group en `us-west-2` mantiene el Launch Template actualizado y `desired_capacity = 0`.
3. La RDS Read Replica en `us-west-2` presenta estado `available` y `ReplicaLag` inferior a `5 minutos`.
4. La regla S3 CRR y DynamoDB Global Tables se encuentran activas sin errores de replicación.

---

## 4. SOP-01: Procedimiento de Failover (`us-east-1` -> `us-west-2`)

### Fase A: Detección y Confirmación (0 – 2 min)
1. Recibir notificación de cambio de estado desde **Amazon SNS** (disparada por Route 53 Health Check tras 2 fallos consecutivos de 10s).
2. Confirmar indisponibilidad real de `us-east-1` (evitar falsos positivos antes de promover la base de datos):
   - Verificar consola/CLI de Health Checks en Route 53.
   - Consultar estado del ALB primario y RDS en `us-east-1`.

### Fase B: Conmutación DNS y Activación en `us-west-2` (2 – 10 min)
1. **DNS:** Verificar que Route 53 Failover Routing ya resolvió el tráfico hacia el ALB de `us-west-2`.
2. **Orquestación automatizada (Fase 3):** Ejecutar o verificar la ejecución de `automation/failover_trigger.py`:
   - Promover la RDS Read Replica en `us-west-2` a instancia Writer independiente (`promote-read-replica`).
   - Escalar el ASG de `us-west-2` de `desired_capacity = 0` a `desired_capacity = 2`.
   - Actualizar parámetros de conexión (endpoint RDS promovido / bucket réplica) para las instancias nuevas.

### Fase C: Verificación Post-Failover (< 15 min)
1. Confirmar que las instancias EC2 en `us-west-2` figuran como `InService` y `healthy` en el Target Group del ALB secundario.
2. Ejecutar verificación funcional contra la URL pública:
   ```bash
   python tests/test_api_connection.py --url http://<ENDPOINT_GLOBAL_O_ALB_SECUNDARIO>
   ```
3. Verificar que `region` en las respuestas JSON reporta `"us-west-2"` y auditar `GET /transactions/latest` para registrar el último ID persistido previo al incidente.

---

## 5. SOP-02: Procedimiento de Failback (`us-west-2` -> `us-east-1`)

> **Advertencia crítica:** No redirigir tráfico hacia `us-east-1` sin haber sincronizado las transacciones escritas en `us-west-2` durante la contingencia.

1. **Reconstrucción de `us-east-1`:** Ejecutar `terraform -chdir=terraform/environments/primary_us_east_1 apply` si la infraestructura primaria sufrió destrucción o corrupción.
2. **Conciliación de Datos (Ventana controlada):**
   - Establecer replicación temporal o restauración de snapshot desde la instancia RDS activa en `us-west-2` hacia `us-east-1`.
   - Verificar convergencia de DynamoDB Global Tables y sincronización de objetos nuevos en S3 hacia el bucket de `us-east-1`.
3. **Validación en frío de `us-east-1`:** Probar `/health` y `/readiness` directamente contra el ALB de `us-east-1`.
4. **Retorno de Tráfico:**
   - Restablecer el registro primario saludable en Route 53 hacia `us-east-1`.
   - Confirmar ausencia de tráfico residual en el ALB de `us-west-2`.
   - Recrear la topología de replicación original (`us-east-1` -> `us-west-2`) y reducir el ASG secundario a `desired_capacity = 0`.

---

## 6. Bitácora de Simulacros y Medición RTO / RPO (Plantilla Fase 4)

| Fecha / Simulacro | Escenario Inyectado (AWS FIS) | `T_fallo` (UTC) | `T_recuperacion` (UTC) | RTO Medido | Última Tx Pre-Fallo | RPO Medido | Cumple SLA (`<15m / <5m`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| *Por completar durante el simulacro AWS* | *Ej. Caída ALB / Writer us-east-1* | — | — | — | — | — | — |

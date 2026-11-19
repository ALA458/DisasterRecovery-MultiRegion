# Índice Maestro de Documentación Técnica

Bienvenido al centro de documentación de la **Estrategia de Disaster Recovery Multi-Región en AWS (Warm Standby)**.

---

## 1. Mapa de Documentación

| Documento | Alcance y Contenido Principal | Estado |
| :--- | :--- | :--- |
| [arquitectura.md](arquitectura.md) | Requisitos SLA (`RTO < 15 min`, `RPO < 5 min`), comparativa de modelos DR del AWS Well-Architected Framework, justificación de Warm Standby, topología VPC multi-tier, Security Groups, diagramas de arquitectura/secuencia y ADRs. | Vigente (Fase 1) |
| [regiones-y-replicacion.md](regiones-y-replicacion.md) | Justificación de regiones (`us-east-1` / `us-west-2`), diseño CIDR sin solapamiento (`10.0.0.0/16` vs `10.1.0.0/16`) y especificación técnica de RDS MySQL, DynamoDB Global Tables y S3 CRR. | Vigente (Fase 1 / Diseño Fase 2) |
| [api.md](api.md) | Especificación de la API transaccional FastAPI (`api/main.py`), variables de entorno, modelo SQLAlchemy, contrato detallado de los 8 endpoints y empaquetado Docker multi-stage. | Implementado (Fase 0–1) |
| [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) | Máquina de estados (Normal, Failover, Failback), flujo de detección Route 53 + SNS, orquestación Boto3 (`failover_trigger.py`), presupuesto de RTO y plan de Chaos Engineering (AWS FIS). | Diseño (Ejecución Fase 3–4) |
| [iac-y-cicd.md](iac-y-cicd.md) | Catálogo de módulos Terraform, aislamiento de entornos, backend remoto S3 con `use_lockfile = true`, pipeline de GitHub Actions, hoja de endurecimiento de seguridad y costos. | Vigente (Fase 1) |
| [pruebas-y-validacion.md](pruebas-y-validacion.md) | Guía paso a paso para pruebas locales con Docker Compose (puerto MySQL `3307`), pruebas manuales `curl`/PowerShell y validación end-to-end en AWS con `tests/test_api_connection.py`. | Implementado (Fase 0–1) |
| [runbook.md](runbook.md) | Manual de Procedimientos Operativos Estándar (SOP-01 Failover, SOP-02 Failback), matriz de escalamiento y plantilla de bitácora RTO/RPO. | Borrador Estructural (Completar Fase 3–4) |
| [estado_del_proyecto.md](estado_del_proyecto.md) | Informe de corte de avance por fases (octubre de 2026), resumen de hitos de Fase 0 y Fase 1 y plan de acción inmediato. | Informe de Corte |

---

## 2. Guía de Lectura por Perfil

* **Arquitecto Cloud / Evaluador Técnico:** Comenzar por [arquitectura.md](arquitectura.md) -> [regiones-y-replicacion.md](regiones-y-replicacion.md) -> [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md).
* **Ingeniero DevOps / IaC:** Revisar [iac-y-cicd.md](iac-y-cicd.md) -> [pruebas-y-validacion.md](pruebas-y-validacion.md).
* **Desarrollador Backend / QA:** Consultar [api.md](api.md) -> [pruebas-y-validacion.md](pruebas-y-validacion.md).
* **SRE / Operaciones:** Revisar [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) -> [runbook.md](runbook.md).

---

## 3. Trazabilidad con Criterios de Evaluación (UTB)

| Criterio de Evaluación | Peso | Documentación de Respaldo | Estado en el Repositorio |
| :--- | :---: | :--- | :--- |
| Infraestructura primaria y secundaria desplegadas | 20% | [arquitectura.md](arquitectura.md), [iac-y-cicd.md](iac-y-cicd.md) | Primaria codificada y planificada (40 recursos); secundaria en Fase 2 |
| Replicación S3 CRR y RDS Read Replica funcionando | 20% | [regiones-y-replicacion.md](regiones-y-replicacion.md) | Habilitadores creados en Fase 1; replicación activa en Fase 2 |
| Route 53 Health Checks y failover automático | 20% | [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) | Health Check `/health` en ALB activo; Route 53 en Fase 3 |
| RTO real `< 15 min` y RPO real `< 5 min` demostrado | 20% | [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md), [api.md](api.md) | SLA y endpoints de auditoría listos; medición en Fase 4 |
| Runbook y scripts de failover/failback | 15% | [runbook.md](runbook.md), [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) | Estructura SOP creada; automatización en Fase 3–4 |
| Documentación y chaos engineering | 5% | [docs/README.md](README.md), [estado_del_proyecto.md](estado_del_proyecto.md) | Documentación técnica completa; AWS FIS en Fase 4 |

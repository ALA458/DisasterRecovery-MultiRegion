# Índice Maestro de Documentación Técnica

Bienvenido al centro de documentación de la **Estrategia de Disaster Recovery Multi-Región en AWS (Warm Standby)**.

---

## 1. Mapa de Documentación

| Documento | Alcance y Contenido Principal | Estado |
| :--- | :--- | :--- |
| [arquitectura.md](arquitectura.md) | Requisitos SLA (`RTO < 15 min`, `RPO < 5 min`), comparativa de modelos DR del AWS Well-Architected Framework, justificación de Warm Standby, topología VPC multi-tier, Security Groups, diagramas de arquitectura/secuencia y ADRs. | Vigente — implementación completa |
| [regiones-y-replicacion.md](regiones-y-replicacion.md) | Justificación de regiones (`us-east-1` / `us-west-2`), diseño CIDR sin solapamiento (`10.0.0.0/16` vs `10.1.0.0/16`) y especificación técnica de RDS MySQL, DynamoDB Global Tables y S3 CRR. | Implementado — listo para validar |
| [api.md](api.md) | Especificación de la API transaccional FastAPI (`api/main.py`), variables de entorno, modelo SQLAlchemy, contrato detallado de los 8 endpoints y empaquetado Docker multi-stage. | Implementado (Fase 0–1) |
| [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) | Máquina de estados (Normal, Failover, Failback), flujo de detección Route 53 + SNS, orquestación Boto3 (`failover_trigger.py`), presupuesto de RTO y ejecución de Chaos Engineering. | Implementado — listo para ejecutar |
| [iac-y-cicd.md](iac-y-cicd.md) | Catálogo de módulos Terraform, aislamiento de entornos, backend remoto S3 con `use_lockfile = true`, pipeline de GitHub Actions, hoja de endurecimiento de seguridad y costos. | Implementado — listo para desplegar |
| [pruebas-y-validacion.md](pruebas-y-validacion.md) | Guía paso a paso para pruebas locales con Docker Compose (puerto MySQL `3307`), pruebas manuales `curl`/PowerShell y validación end-to-end en AWS. | Implementado — suite completa |
| [runbook.md](runbook.md) | Manual de Procedimientos Operativos Estándar (SOP-01 Failover, SOP-02 Failback), matriz de escalamiento y plantilla de bitácora RTO/RPO. | Listo para uso operativo |
| [estado_del_proyecto.md](estado_del_proyecto.md) | Informe final de avance por fases (noviembre de 2026), resumen de la implementación y procedimientos de despliegue y validación. | Informe final |

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
| Infraestructura primaria y secundaria desplegadas | 20% | [arquitectura.md](arquitectura.md), [iac-y-cicd.md](iac-y-cicd.md) | Código completo para ambas regiones y configuración global |
| Replicación S3 CRR y RDS Read Replica funcionando | 20% | [regiones-y-replicacion.md](regiones-y-replicacion.md) | Implementación completa; validación con `test_replication_fase2.py` |
| Route 53 Health Checks y failover automático | 20% | [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) | Route 53, CloudFront y script Boto3 implementados |
| RTO real `< 15 min` y RPO real `< 5 min` demostrado | 20% | [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md), [api.md](api.md) | Instrumentación y simulación completas; requiere evidencia del despliegue real |
| Runbook y scripts de failover/failback | 15% | [runbook.md](runbook.md), [sistema-recovery-multiregion.md](sistema-recovery-multiregion.md) | Scripts, procedimientos y validaciones listos |
| Documentación y chaos engineering | 5% | [docs/README.md](README.md), [estado_del_proyecto.md](estado_del_proyecto.md) | Documentación y simulación end-to-end completas |

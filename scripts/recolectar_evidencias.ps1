<#
  recolectar_evidencias.ps1
  Recolecta evidencia verificable del estado real de la infraestructura DR en AWS
  (Fase 1: región primaria activa, Fase 2: replicación activa).
  Cada archivo guarda: fecha/hora, el comando ejecutado y la respuesta de AWS.
  No guarda secretos (la contraseña de RDS nunca se lee).

  Uso (desde la raíz del repo):
    $env:AWS_PROFILE = "dr"
    powershell -ExecutionPolicy Bypass -File .\scripts\recolectar_evidencias.ps1
#>
$ErrorActionPreference = "Continue"
$R1 = "us-east-1"; $R2 = "us-west-2"
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out   = Join-Path $root "evidencias\$stamp"
New-Item -ItemType Directory -Force $out | Out-Null
$tfP = Join-Path $root "terraform\environments\primary_us_east_1"
$tfS = Join-Path $root "terraform\environments\secondary_us_west_2"

function Save([string]$name, [scriptblock]$cmd) {
  $file = Join-Path $out "$name.txt"
  "# $name`r`n# Fecha: $(Get-Date -Format o)`r`n# Comando:`r`n$($cmd.ToString().Trim())`r`n`r`n# Resultado:" | Out-File $file -Encoding utf8
  try { & $cmd 2>&1 | Out-String -Width 400 | Out-File $file -Append -Encoding utf8 }
  catch { "ERROR: $_" | Out-File $file -Append -Encoding utf8 }
  Write-Host "  [ok] $name"
}
function J($obj) { $obj | ConvertTo-Json -Depth 6 }

Write-Host "Leyendo outputs de Terraform..."
$P      = terraform "-chdir=$tfP" output -raw alb_dns_name
$S      = terraform "-chdir=$tfS" output -raw alb_dns_name
$B1     = terraform "-chdir=$tfP" output -raw s3_bucket_name
$B2     = terraform "-chdir=$tfS" output -raw s3_replica_bucket_name
$ASG2   = terraform "-chdir=$tfS" output -raw asg_name
$TG1    = aws elbv2 describe-target-groups --names dr-architecture-primary-tg --region $R1 --query "TargetGroups[0].TargetGroupArn" --output text
Write-Host "Guardando evidencia en $out"

# ---------------- General ----------------
Save "00_identidad_cuenta"      { aws sts get-caller-identity }
Save "01_outputs_primaria"      { terraform "-chdir=$tfP" output }
Save "02_outputs_secundaria"    { terraform "-chdir=$tfS" output }
Save "03_recursos_terraform"    { "PRIMARIA:"; terraform "-chdir=$tfP" state list; ""; "SECUNDARIA:"; terraform "-chdir=$tfS" state list }

# ---------------- Fase 1: región primaria activa ----------------
Save "10_targets_alb_primario"  { aws elbv2 describe-target-health --target-group-arn $TG1 --region $R1 --query "TargetHealthDescriptions[].{Instancia:Target.Id,Estado:TargetHealth.State}" --output table }
Save "11_api_health"            { J (Invoke-RestMethod "http://$P/health") }
Save "12_api_readiness"         { J (Invoke-RestMethod "http://$P/readiness") }
Save "13_api_escritura_rds"     { J (Invoke-RestMethod -Method Post "http://$P/transaction" -ContentType "application/json" -Body '{"user_id":"evidencia","description":"prueba evidencias"}') }
Save "14_api_lectura_rds"       { J (Invoke-RestMethod "http://$P/transactions/latest?limit=3") }
Save "15_rds_primaria"          { aws rds describe-db-instances --db-instance-identifier dr-architecture-primary-mysql --region $R1 --query "DBInstances[0].{Estado:DBInstanceStatus,MultiAZ:MultiAZ,Motor:Engine,Version:EngineVersion,Replicas:ReadReplicaDBInstanceIdentifiers,Backups:BackupRetentionPeriod}" }
Save "16_s3_versionado"         { aws s3api get-bucket-versioning --bucket $B1 }
Save "17_dynamodb_tabla"        { aws dynamodb describe-table --table-name user_sessions --region $R1 --query "Table.{Estado:TableStatus,Stream:StreamSpecification,Replicas:Replicas[].{Region:RegionName,Estado:ReplicaStatus}}" }
Save "18_ssm_secreto_existe"    { aws ssm describe-parameters --region $R1 --query "Parameters[].{Nombre:Name,Tipo:Type}" --output table }
Save "19_ecr_imagenes"          { "us-east-1:"; aws ecr describe-images --repository-name dr-api --region $R1 --query "imageDetails[].{Tags:imageTags,Subida:imagePushedAt}" --output table; "us-west-2 (replica):"; aws ecr describe-images --repository-name dr-api --region $R2 --query "imageDetails[].{Tags:imageTags,Subida:imagePushedAt}" --output table }

# ---------------- Fase 2: replicación activa ----------------
Save "20_rds_read_replica"      { aws rds describe-db-instances --db-instance-identifier dr-architecture-secondary-mysql --region $R2 --query "DBInstances[0].{Estado:DBInstanceStatus,Origen:ReadReplicaSourceDBInstanceIdentifier,AZ:AvailabilityZone}" }
Save "21_rds_replica_lag"       {
  $end = (Get-Date).ToUniversalTime(); $start = $end.AddMinutes(-30)
  aws cloudwatch get-metric-statistics --region $R2 --namespace AWS/RDS --metric-name ReplicaLag --dimensions Name=DBInstanceIdentifier,Value=dr-architecture-secondary-mysql --start-time $start.ToString("s") --end-time $end.ToString("s") --period 300 --statistics Maximum --query "sort_by(Datapoints,&Timestamp)[].{Hora:Timestamp,LagMaxSegundos:Maximum}" --output table }
Save "22_s3_regla_crr"          { aws s3api get-bucket-replication --bucket $B1 }
Save "23_s3_crr_objeto_nuevo"   {
  $inv = Invoke-RestMethod -Method Post "http://$P/invoice" -ContentType "application/json" -Body '{"customer_name":"Evidencia CRR"}'
  "Objeto subido a us-east-1: $($inv.s3_key)"
  Start-Sleep 30
  "Estado de replicacion en el bucket origen ($B1):"
  aws s3api head-object --bucket $B1 --key $inv.s3_key --query ReplicationStatus
  "Objeto presente en el bucket replica ($B2, us-west-2):"
  aws s3api head-object --bucket $B2 --key $inv.s3_key --region $R2 --query "{Tamano:ContentLength,Estado:ReplicationStatus,Modificado:LastModified}" }
Save "24_dynamodb_item_replicado" {
  $uid = "evidencia-$stamp"
  J (Invoke-RestMethod -Method Post "http://$P/cart" -ContentType "application/json" -Body ("{""user_id"":""$uid"",""item"":""SKU-EVID"",""quantity"":2}"))
  Start-Sleep 5
  $keyFile = Join-Path $env:TEMP "dr_key.json"
  [IO.File]::WriteAllText($keyFile, "{""user_id"":{""S"":""$uid""}}")
  "Lectura del mismo item en us-west-2:"
  aws dynamodb get-item --table-name user_sessions --region $R2 --key "file://$keyFile" }
Save "25_asg_secundario_standby" { aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG2 --region $R2 --query "AutoScalingGroups[0].{Min:MinSize,Deseado:DesiredCapacity,Max:MaxSize,InstanciasCorriendo:length(Instances)}" }
Save "26_alb_secundario_listo"  { aws elbv2 describe-load-balancers --names dr-architecture-secondary-alb --region $R2 --query "LoadBalancers[0].{DNS:DNSName,Estado:State.Code}" }

# ---------------- Código ----------------
Save "30_git_historial"         { git -C $root log --oneline -20 }

Write-Host ""
Write-Host "Listo. Evidencia en: $out"
Write-Host "Revisa especialmente 12, 20, 23 y 24 (deben mostrar connected / available / COMPLETED / el item en us-west-2)."

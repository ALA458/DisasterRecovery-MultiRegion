<#
  simular_failover.ps1
  Prueba de failover REAL en AWS con medición de RTO y RPO.

  Flujo:
    0. Verifica precondiciones (Warm Standby intacto: réplica sin promover, ASG secundario en 0).
    1. Carga continua: 1 escritura/seg en us-east-1 con número de secuencia (para el RPO).
    2. INYECCIÓN: aísla us-east-1 de internet quitando la regla HTTP:80 del Security Group del ALB primario.
    3. Detección: sondea /health de us-east-1 hasta que falla (equivale al Health Check de Route 53).
    4. Failover: ejecuta automation/failover_trigger.py (promueve RDS y escala el ASG de us-west-2).
    5. RTO: sonda que intenta escribir en us-west-2; RTO = primera escritura aceptada - momento de la inyección.
    6. RPO: compara las escrituras confirmadas en us-east-1 con las presentes en us-west-2.
    7. Reporte en evidencias\failover-<fecha>\.

  ATENCIÓN: el paso 4 promueve la réplica de RDS (IRREVERSIBLE). Para repetir la prueba hay que recrear la réplica.

  Uso (desde la raíz del repo):
    $env:AWS_PROFILE = "dr"
    powershell -ExecutionPolicy Bypass -File .\scripts\simular_failover.ps1
    # -Inyeccion red      : (default) aísla el ALB primario quitando la regla HTTP:80 de su Security Group
    # -Inyeccion computo  : apaga el cómputo primario (ASG de us-east-1 a 0 instancias)
    # -SegundosCarga 120  : segundos de carga antes de inyectar (default 120, da datos de ReplicaLag)
    # -RestaurarPrimaria  : al final, vuelve a abrir el puerto 80 del ALB primario (crea split-brain; solo si sabe lo que hace)
#>
param(
  [ValidateSet("red","computo")][string]$Inyeccion = "red",
  [int]$SegundosCarga = 120,
  [switch]$RestaurarPrimaria
)
$ErrorActionPreference = "Stop"
$R1 = "us-east-1"; $R2 = "us-west-2"
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out   = Join-Path $root "evidencias\failover-$stamp"
New-Item -ItemType Directory -Force $out | Out-Null
$log      = Join-Path $out "escrituras_us-east-1.log"
$rtoFile  = Join-Path $out "sonda_rto.log"
$trigLog  = Join-Path $out "failover_trigger.log"
$reporte  = Join-Path $out "REPORTE.txt"
$tfP = Join-Path $root "terraform\environments\primary_us_east_1"
$tfS = Join-Path $root "terraform\environments\secondary_us_west_2"
function T { (Get-Date).ToUniversalTime() }
function Paso($m) { Write-Host ""; Write-Host "=== $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 0. Precondiciones
Paso "0. Verificando precondiciones"
function Out-TF($dir, $name) {
  # Reintenta (fallos de red/DNS transitorios) y aborta si el valor viene vacío
  for ($k = 1; $k -le 3; $k++) {
    $v = terraform "-chdir=$dir" output -raw $name 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($v)) { return "$v".Trim() }
    Start-Sleep 3
  }
  throw "No se pudo leer el output '$name' de $dir (3 intentos). NO se inyectó ninguna falla."
}
$P    = Out-TF $tfP "alb_dns_name"
$S    = Out-TF $tfS "alb_dns_name"
$ASG2 = Out-TF $tfS "asg_name"
$ASG1 = Out-TF $tfP "asg_name"
if ($ASG1 -notlike "dr-architecture-primary-asg-*" -or $ASG2 -notlike "dr-architecture-secondary-asg-*") { throw "Nombres de ASG inesperados: '$ASG1' / '$ASG2'. NO se inyectó ninguna falla." }
$SG   = aws ec2 describe-security-groups --region $R1 --filters Name=group-name,Values=dr-architecture-primary-alb-sg --query "SecurityGroups[0].GroupId" --output text
$src  = aws rds describe-db-instances --region $R2 --db-instance-identifier dr-architecture-secondary-mysql --query "DBInstances[0].ReadReplicaSourceDBInstanceIdentifier" --output text
$des  = aws autoscaling describe-auto-scaling-groups --region $R2 --auto-scaling-group-names $ASG2 --query "AutoScalingGroups[0].DesiredCapacity" --output text
$rule = aws ec2 describe-security-groups --region $R1 --group-ids $SG --query "SecurityGroups[0].IpPermissions[?FromPort==``80``] | length(@)" --output text

if ($src -eq "None" -or [string]::IsNullOrWhiteSpace($src)) { throw "La RDS de us-west-2 NO es réplica (ya fue promovida). Recree la réplica antes de probar." }
if ($des -ne "0") { throw "El ASG secundario tiene DesiredCapacity=$des. Ejecute: python automation\failover_trigger.py --mode scale-down" }
if ($Inyeccion -eq "red" -and $rule -eq "0") { throw "El ALB primario ya no tiene la regla HTTP:80 (¿prueba anterior sin restaurar?)." }
try { Invoke-RestMethod "http://$P/health" -TimeoutSec 5 -DisableKeepAlive | Out-Null } catch { throw "La API primaria no responde en http://$P/health" }
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$pyArn = & python -c "import boto3; print(boto3.client('sts').get_caller_identity()['Arn'])" 2>&1
$pyOk = $LASTEXITCODE -eq 0
$ErrorActionPreference = $prevEAP
if (-not $pyOk) { throw "Python/boto3 no encuentra credenciales de AWS ($pyArn). Defina `$env:AWS_PROFILE = 'dr' en esta ventana. NO se inyectó ninguna falla." }
Write-Host "  OK: Python/boto3 autenticado como $pyArn"
Write-Host "  OK: réplica sin promover, ASG secundario en 0, primaria sana."
Write-Host "  Primaria : http://$P"
Write-Host "  DR       : http://$S"
$resp = Read-Host "  Esto PROMOVERÁ la réplica de RDS (irreversible). Escriba SI para continuar"
if ($resp -ne "SI") { Write-Host "Cancelado."; exit 0 }

# ---------------------------------------------------------------- 1. Carga continua
Paso "1. Carga continua sobre us-east-1 (1 escritura/s, ${SegundosCarga}s antes de inyectar)"
$uid = "rpo-$stamp"
$tCargaIni = T
$writer = Start-Job -ArgumentList $P, $uid, $log -ScriptBlock {
  param($P, $uid, $log)
  $i = 0
  while ($true) {
    $i++
    $body = @{ user_id = $uid; amount = $i; description = "seq-$i" } | ConvertTo-Json
    $ts = (Get-Date).ToUniversalTime().ToString("o")
    try {
      $r = Invoke-RestMethod -Method Post "http://$P/transaction" -ContentType "application/json" -Body $body -TimeoutSec 3 -DisableKeepAlive
      "$ts|OK|$i|$($r.transaction_id)" | Out-File $log -Append -Encoding utf8
    } catch {
      "$ts|FALLA|$i|" | Out-File $log -Append -Encoding utf8
    }
    Start-Sleep -Milliseconds 1000
  }
}
Start-Sleep $SegundosCarga
$okAntes = @(Get-Content $log | Where-Object { $_ -match "\|OK\|" }).Count
Write-Host "  Escrituras confirmadas antes de la falla: $okAntes"

# ---------------------------------------------------------------- 2. Inyección
$t0 = T
if ($Inyeccion -eq "red") {
  Paso "2. INYECCIÓN DE FALLA (red): aislando us-east-1 (revoke HTTP:80 en $SG)"
  aws ec2 revoke-security-group-ingress --region $R1 --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0 | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-Job $writer; throw "La inyección (revoke) FALLÓ. No se lanzó el failover." }
  $metodo = "Aislamiento de red del ALB primario (revoke tcp/80 en $SG)"
} else {
  Paso "2. INYECCIÓN DE FALLA (cómputo): ASG primario $ASG1 a 0 instancias"
  aws autoscaling update-auto-scaling-group --region $R1 --auto-scaling-group-name $ASG1 --min-size 0 --desired-capacity 0 | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-Job $writer; throw "La inyección (ASG a 0) FALLÓ. No se lanzó el failover." }
  $metodo = "Apagado del cómputo primario (ASG $ASG1 a 0)"
}
Write-Host "  t0 (falla) = $($t0.ToString('o'))"

# Sonda RTO en segundo plano: primer POST aceptado en us-west-2
$probe = Start-Job -ArgumentList $S, $rtoFile -ScriptBlock {
  param($S, $rtoFile)
  $deadline = (Get-Date).AddMinutes(25)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-RestMethod -Method Post "http://$S/transaction" -ContentType "application/json" -Body '{"user_id":"rto-probe","description":"primera escritura DR"}' -TimeoutSec 5 -DisableKeepAlive
      "$((Get-Date).ToUniversalTime().ToString('o'))|OK|$($r.region)|$($r.transaction_id)" | Out-File $rtoFile -Encoding utf8
      return
    } catch { Start-Sleep 3 }
  }
  "TIMEOUT" | Out-File $rtoFile -Encoding utf8
}

# ---------------------------------------------------------------- 3. Detección
Paso "3. Detección (sondeo de /health en us-east-1 cada 2 s; caída = 3 fallas SEGUIDAS)"
$tDetect = $null; $seguidas = 0; $tPrimeraFalla = $null
while (-not $tDetect) {
  try {
    Invoke-RestMethod "http://$P/health" -TimeoutSec 3 -DisableKeepAlive | Out-Null
    $seguidas = 0; $tPrimeraFalla = $null
  } catch {
    if ($seguidas -eq 0) { $tPrimeraFalla = T }
    $seguidas++
    if ($seguidas -ge 3) { $tDetect = T }
  }
  if (-not $tDetect) { Start-Sleep 2 }
  if (((T) - $t0).TotalMinutes -gt 10) { Stop-Job $writer; throw "La primaria no cayó en 10 min: la inyección no surtió efecto. NO se lanzó el failover." }
}
# Verificación cruzada: la caída debe verse también desde AWS (no solo desde esta red)
if ($Inyeccion -eq "computo") {
  $vivas = aws autoscaling describe-auto-scaling-groups --region $R1 --auto-scaling-group-names $ASG1 --query "AutoScalingGroups[0].DesiredCapacity" --output text
  if ($vivas -ne "0") { Stop-Job $writer; throw "El ASG primario no está en 0 (Desired=$vivas): la 'caída' es de su red local. NO se lanzó el failover." }
}
Write-Host "  Caída detectada a los $([int]($tDetect - $t0).TotalSeconds) s"

# ---------------------------------------------------------------- 4. Failover
Paso "4. Failover: automation\failover_trigger.py"
$tTrig = T
$env:PYTHONUNBUFFERED = "1"
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& python (Join-Path $root "automation\failover_trigger.py") --secondary-alb-url "http://$S" 2>&1 | Tee-Object -FilePath $trigLog
$ErrorActionPreference = $prevEAP
$tTrigEnd = T
$trigTxt = Get-Content $trigLog -Raw
function Seg($patron) { if ($trigTxt -match $patron) { [int]$Matches[1] } else { $null } }
$sAsg = Seg '\[\+(\d+)s\] \[OK\] ASG'
$sApi = Seg '\[\+(\d+)s\] \[OK\] ALB Secundario'
$sRds = Seg '\[\+(\d+)s\] \[OK\] RDS' 

# ---------------------------------------------------------------- 5. RTO
Paso "5. Esperando la primera escritura aceptada en us-west-2"
Wait-Job $probe -Timeout 1500 | Out-Null
$probeLine = (Get-Content $rtoFile -ErrorAction SilentlyContinue | Select-Object -First 1)
Stop-Job $writer; Remove-Job $writer -Force
if (-not $probeLine -or $probeLine -eq "TIMEOUT") { throw "No hubo escritura aceptada en us-west-2 en 25 min. Revise $trigLog" }
$tRec = [DateTime]::Parse($probeLine.Split("|")[0]).ToUniversalTime()
$rto = $tRec - $t0

# ---------------------------------------------------------------- 6. RPO
Paso "6. Calculando RPO"
$confirmadas = @(Get-Content $log | Where-Object { $_ -match "\|OK\|" } | ForEach-Object {
  $f = $_.Split("|"); [pscustomobject]@{ Hora = [DateTime]::Parse($f[0]).ToUniversalTime(); Seq = [int]$f[2] } })
# Paréntesis: en PowerShell 5.1 un arreglo JSON viaja como UN objeto por el pipeline si no se fuerza la enumeración
$enDR = @((Invoke-RestMethod "http://$S/transactions/latest?limit=500" -TimeoutSec 10) | Where-Object { $_.user_id -eq $uid } |
  ForEach-Object { [int]($_.description -replace "seq-","") })
$faltantes = @($confirmadas | Where-Object { $enDR -notcontains $_.Seq })
$ultConf = $confirmadas | Sort-Object Seq | Select-Object -Last 1
if ($faltantes.Count -eq 0) {
  $rpoSeg = 0
} else {
  $ultEnDR = $confirmadas | Where-Object { $enDR -contains $_.Seq } | Sort-Object Seq | Select-Object -Last 1
  $rpoSeg = if ($ultEnDR) { [int]($ultConf.Hora - $ultEnDR.Hora).TotalSeconds } else { [int]($ultConf.Hora - $confirmadas[0].Hora).TotalSeconds }
}

# ReplicaLag durante la carga (CloudWatch, granularidad 1 min)
$lagTxt = "sin datos"
try {
  $json = (aws cloudwatch get-metric-statistics --region $R2 --namespace AWS/RDS --metric-name ReplicaLag --dimensions Name=DBInstanceIdentifier,Value=dr-architecture-secondary-mysql --start-time $tCargaIni.ToString("yyyy-MM-ddTHH:mm:ssZ") --end-time $t0.ToString("yyyy-MM-ddTHH:mm:ssZ") --period 60 --statistics Average Maximum --output json) -join ""
  $dp = @(($json | ConvertFrom-Json).Datapoints)
  if ($dp.Count) { $lagTxt = "{0:N2} s promedio / {1:N2} s máximo ({2} puntos)" -f ($dp | Measure-Object -Property Average -Average).Average, ($dp | Measure-Object -Property Maximum -Maximum).Maximum, $dp.Count }
} catch { }

# ---------------------------------------------------------------- 7. Reporte
$cumpleRTO = $rto.TotalMinutes -lt 15
$cumpleRPO = $rpoSeg -lt 300
$txt = @"
REPORTE DE PRUEBA DE FAILOVER - Warm Standby us-east-1 -> us-west-2
Fecha (UTC)                     : $($t0.ToString('o'))
Método de inyección             : $metodo
Detección                       : Sondeo HTTP /health cada 2 s (Route 53 aún no desplegado)

LÍNEA DE TIEMPO (desde la falla)
  t0  Falla inyectada            : 0 s
  t1  Caída detectada            : $([int]($tDetect - $t0).TotalSeconds) s
  t2  failover_trigger.py inicia : $([int]($tTrig - $t0).TotalSeconds) s
  t3  failover_trigger.py termina: $([int]($tTrigEnd - $t0).TotalSeconds) s
  t4  1ra escritura en us-west-2 : $([int]$rto.TotalSeconds) s   ($probeLine)

RTO medido  : $($rto.ToString('mm\:ss')) (min:seg)   Objetivo < 15 min  -> $(if($cumpleRTO){'CUMPLE'}else{'NO CUMPLE'})
RPO medido  : $rpoSeg s                Objetivo < 5 min   -> $(if($cumpleRPO){'CUMPLE'}else{'NO CUMPLE'})
  Escrituras confirmadas en us-east-1 : $($confirmadas.Count) (última seq-$($ultConf.Seq))
  Presentes en us-west-2 tras failover: $($enDR.Count)
  Perdidas                            : $($faltantes.Count) $(if($faltantes.Count){'-> seq ' + (($faltantes | ForEach-Object Seq) -join ',')})

DESGLOSE (segundos desde que arranca failover_trigger.py)
  ASG secundario InService        : $sAsg s
  API secundaria healthy (ALB)    : $sApi s
  Promoción de la Read Replica    : $sRds s
  ReplicaLag bajo carga (antes de la falla): $lagTxt

Archivos: escrituras_us-east-1.log, sonda_rto.log, failover_trigger.log
"@
$txt | Out-File $reporte -Encoding utf8
Write-Host ""; Write-Host $txt -ForegroundColor Green

if ($RestaurarPrimaria) {
  if ($Inyeccion -eq "red") { aws ec2 authorize-security-group-ingress --region $R1 --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0 | Out-Null }
  else { aws autoscaling update-auto-scaling-group --region $R1 --auto-scaling-group-name $ASG1 --min-size 2 --desired-capacity 2 | Out-Null }
  Write-Host "Primaria reabierta. OJO: ahora hay DOS bases escribibles (split-brain)." -ForegroundColor Yellow
} else {
  Write-Host "us-east-1 sigue CAÍDA (correcto tras un failover). Para restaurarla:" -ForegroundColor Yellow
  if ($Inyeccion -eq "red") { Write-Host "  aws ec2 authorize-security-group-ingress --region $R1 --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0" }
  else { Write-Host "  aws autoscaling update-auto-scaling-group --region $R1 --auto-scaling-group-name $ASG1 --min-size 2 --desired-capacity 2" }
}
Write-Host "Reporte: $reporte"

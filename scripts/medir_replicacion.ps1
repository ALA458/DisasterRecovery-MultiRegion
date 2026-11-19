<#
  medir_replicacion.ps1  (NO destructivo: se puede correr las veces que quiera)
  Mide, en estado Warm Standby normal y bajo carga:
    - Latencia de replicación S3 CRR (us-east-1 -> us-west-2), N muestras
    - Latencia de propagación DynamoDB Global Tables, N muestras (+ métrica ReplicationLatency de CloudWatch)
    - ReplicaLag de RDS (promedio y máximo) durante la ventana de carga (CloudWatch)
  Reporte: evidencias\metricas-<fecha>\REPORTE_replicacion.txt

  Uso:  $env:AWS_PROFILE = "dr"
        powershell -ExecutionPolicy Bypass -File .\scripts\medir_replicacion.ps1 [-Muestras 5] [-SegundosCarga 120]
#>
param([int]$Muestras = 5, [int]$SegundosCarga = 120)
$ErrorActionPreference = "Continue"
$R1 = "us-east-1"; $R2 = "us-west-2"
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out   = Join-Path $root "evidencias\metricas-$stamp"
New-Item -ItemType Directory -Force $out | Out-Null
$tfP = Join-Path $root "terraform\environments\primary_us_east_1"
$tfS = Join-Path $root "terraform\environments\secondary_us_west_2"
function T { (Get-Date).ToUniversalTime() }
function Iso($d) { $d.ToString("yyyy-MM-ddTHH:mm:ssZ") }
function Stats($arr) {
  if (-not $arr -or $arr.Count -eq 0) { return "sin datos" }
  $m = $arr | Measure-Object -Average -Minimum -Maximum
  "{0:N2} s promedio (min {1:N2} s, max {2:N2} s, n={3})" -f $m.Average, $m.Minimum, $m.Maximum, $m.Count
}
function CW($region, $ns, $metric, $dims, $ini, $fin) {
  # $dims puede ser un arreglo: PowerShell pasa cada elemento como argumento separado
  $json = (aws cloudwatch get-metric-statistics --region $region --namespace $ns --metric-name $metric --dimensions $dims --start-time (Iso $ini) --end-time (Iso $fin) --period 60 --statistics Average Maximum --output json) -join ""
  ($json | ConvertFrom-Json).Datapoints | Sort-Object Timestamp
}

$P  = terraform "-chdir=$tfP" output -raw alb_dns_name
$B2 = terraform "-chdir=$tfS" output -raw s3_replica_bucket_name
$src = aws rds describe-db-instances --region $R2 --db-instance-identifier dr-architecture-secondary-mysql --query "DBInstances[0].ReadReplicaSourceDBInstanceIdentifier" --output text
$hayReplica = -not ([string]::IsNullOrWhiteSpace($src) -or $src -eq "None")
if (-not $hayReplica) { Write-Warning "La RDS de us-west-2 no es Read Replica: no habrá ReplicaLag." }

Write-Host "=== Carga de fondo: 1 escritura/s en us-east-1 durante $SegundosCarga s"
$tCargaIni = T
$cargaLog = Join-Path $out "carga.log"
$writer = Start-Job -ArgumentList $P, $cargaLog -ScriptBlock {
  param($P, $log)
  $i = 0
  while ($true) {
    $i++
    try {
      Invoke-RestMethod -Method Post "http://$P/transaction" -ContentType "application/json" -Body (@{user_id="carga-metricas"; amount=$i; description="carga-$i"} | ConvertTo-Json) -TimeoutSec 3 -DisableKeepAlive | Out-Null
      "OK" | Out-File $log -Append -Encoding ascii
    } catch { "FALLA" | Out-File $log -Append -Encoding ascii }
    Start-Sleep -Milliseconds 1000
  }
}

Write-Host "=== S3 CRR: $Muestras muestras (sondeo del bucket réplica cada 0.5 s)"
$s3 = @()
for ($k = 1; $k -le $Muestras; $k++) {
  $ini = T
  $inv = Invoke-RestMethod -Method Post "http://$P/invoice" -ContentType "application/json" -Body '{"customer_name":"Metrica CRR"}' -TimeoutSec 10 -DisableKeepAlive
  $found = $null
  while (-not $found -and ((T) - $ini).TotalSeconds -lt 300) {
    aws s3api head-object --bucket $B2 --key $inv.s3_key --region $R2 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $found = T } else { Start-Sleep -Milliseconds 500 }
  }
  if ($found) { $s = ($found - $ini).TotalSeconds; $s3 += $s; Write-Host ("  muestra {0}: {1:N2} s  ({2})" -f $k, $s, $inv.s3_key) }
  else { Write-Host "  muestra $k : NO replicó en 300 s ($($inv.s3_key))" }
}

Write-Host "=== DynamoDB Global Tables: $Muestras muestras (lectura en us-west-2)"
$ddb = @()
for ($k = 1; $k -le $Muestras; $k++) {
  $uid = "metrica-$stamp-$k"
  $keyFile = Join-Path $env:TEMP "dr_key_$k.json"
  [IO.File]::WriteAllText($keyFile, "{""user_id"":{""S"":""$uid""}}")
  $ini = T
  Invoke-RestMethod -Method Post "http://$P/cart" -ContentType "application/json" -Body (@{user_id=$uid; item="SKU-MET"; quantity=1} | ConvertTo-Json) -TimeoutSec 10 -DisableKeepAlive | Out-Null
  $found = $null
  while (-not $found -and ((T) - $ini).TotalSeconds -lt 120) {
    $r = aws dynamodb get-item --table-name user_sessions --region $R2 --key "file://$keyFile" --query "Item.user_id.S" --output text 2>$null
    if ($r -eq $uid) { $found = T } else { Start-Sleep -Milliseconds 300 }
  }
  if ($found) { $s = ($found - $ini).TotalSeconds; $ddb += $s; Write-Host ("  muestra {0}: {1:N2} s" -f $k, $s) }
  else { Write-Host "  muestra $k : no apareció en 120 s" }
}

$restante = $SegundosCarga - ((T) - $tCargaIni).TotalSeconds
if ($restante -gt 0) { Write-Host "=== Completando ventana de carga ($([int]$restante) s)"; Start-Sleep ([int]$restante) }
$tCargaFin = T
Stop-Job $writer; Remove-Job $writer -Force
$ok = @(Get-Content $cargaLog | Where-Object { $_ -eq "OK" }).Count
$fa = @(Get-Content $cargaLog | Where-Object { $_ -eq "FALLA" }).Count

Write-Host "=== Esperando 120 s a que CloudWatch publique las métricas"
Start-Sleep 120
$lag = @(); $lagMax = @()
if ($hayReplica) {
  $dp = CW $R2 "AWS/RDS" "ReplicaLag" "Name=DBInstanceIdentifier,Value=dr-architecture-secondary-mysql" $tCargaIni.AddMinutes(-1) $tCargaFin.AddMinutes(2)
  $lag = @($dp | ForEach-Object { [double]$_.Average }); $lagMax = @($dp | ForEach-Object { [double]$_.Maximum })
}
$dpD = CW $R1 "AWS/DynamoDB" "ReplicationLatency" @("Name=TableName,Value=user_sessions", "Name=ReceivingRegion,Value=$R2") $tCargaIni.AddMinutes(-1) $tCargaFin.AddMinutes(2)
$repLatMs = @($dpD | ForEach-Object { [double]$_.Average })

$lagTxt = if ($lag.Count) { "{0:N2} s promedio / {1:N2} s máximo ({2} puntos de 1 min)" -f ($lag | Measure-Object -Average).Average, ($lagMax | Measure-Object -Maximum).Maximum, $lag.Count } else { "sin datos (¿réplica promovida o métrica aún no publicada?)" }
$cwDdb  = if ($repLatMs.Count) { "{0:N0} ms promedio ({1} puntos)" -f ($repLatMs | Measure-Object -Average).Average, $repLatMs.Count } else { "sin datos" }

$txt = @"
REPORTE DE MÉTRICAS DE REPLICACIÓN (estado Warm Standby, bajo carga)
Ventana de carga (UTC): $(Iso $tCargaIni) -> $(Iso $tCargaFin)
Carga aplicada        : 1 escritura/s en /transaction ($ok OK, $fa fallas)

RDS ReplicaLag bajo carga (CloudWatch)        : $lagTxt
S3 CRR - latencia hasta verse en us-west-2     : $(Stats $s3)
S3 CRR replicado                               : $(if ($s3.Count -eq $Muestras) {'Sí, todas las muestras'} else {"$($s3.Count)/$Muestras muestras"})
DynamoDB Global Tables - visible en us-west-2  : $(Stats $ddb)
DynamoDB ReplicationLatency (CloudWatch)       : $cwDdb

Nota de método: las latencias S3/DynamoDB son COTA SUPERIOR: incluyen la llamada a la API y el
tiempo de cada consulta de la AWS CLI (~0.5-1.5 s en Windows). La métrica ReplicationLatency de
CloudWatch es la medida interna de AWS y es más precisa para DynamoDB.
"@
$file = Join-Path $out "REPORTE_replicacion.txt"
$txt | Out-File $file -Encoding utf8
Write-Host ""; Write-Host $txt -ForegroundColor Green
Write-Host "Reporte: $file"

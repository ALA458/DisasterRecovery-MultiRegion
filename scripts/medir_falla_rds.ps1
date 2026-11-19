<#
  medir_falla_rds.ps1  (Escenario B: falla de la base de datos primaria)
  Fuerza un failover Multi-AZ de la RDS primaria (reboot --force-failover) y mide cuánto tiempo
  la API de us-east-1 no puede escribir. No es destructivo: la réplica cross-region sigue activa.
  Reporte: evidencias\falla-rds-<fecha>\REPORTE_falla_rds.txt

  Uso:  $env:AWS_PROFILE = "dr"
        powershell -ExecutionPolicy Bypass -File .\scripts\medir_falla_rds.ps1
#>
$ErrorActionPreference = "Continue"
$R1 = "us-east-1"; $DB = "dr-architecture-primary-mysql"
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out   = Join-Path $root "evidencias\falla-rds-$stamp"
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out "escrituras.log"
$P = terraform "-chdir=$(Join-Path $root 'terraform\environments\primary_us_east_1')" output -raw alb_dns_name
function T { (Get-Date).ToUniversalTime() }

$azAntes = aws rds describe-db-instances --region $R1 --db-instance-identifier $DB --query "DBInstances[0].AvailabilityZone" --output text
$multi   = aws rds describe-db-instances --region $R1 --db-instance-identifier $DB --query "DBInstances[0].MultiAZ" --output text
if ($multi -ne "True") { Write-Error "La RDS primaria no es Multi-AZ; no aplica."; exit 1 }
Write-Host "RDS primaria en $azAntes (Multi-AZ). Se forzará el failover a la zona standby."
if ((Read-Host "Escriba SI para continuar") -ne "SI") { exit 0 }

$writer = Start-Job -ArgumentList $P, $log -ScriptBlock {
  param($P, $log)
  $i = 0
  while ($true) {
    $i++; $ts = (Get-Date).ToUniversalTime().ToString("o")
    try {
      Invoke-RestMethod -Method Post "http://$P/transaction" -ContentType "application/json" -Body (@{user_id="falla-rds"; amount=$i; description="rds-$i"} | ConvertTo-Json) -TimeoutSec 3 -DisableKeepAlive | Out-Null
      "$ts|OK" | Out-File $log -Append -Encoding ascii
    } catch { "$ts|FALLA" | Out-File $log -Append -Encoding ascii }
    Start-Sleep -Milliseconds 1000
  }
}
Write-Host "Línea base de 20 s..."; Start-Sleep 20
$t0 = T
aws rds reboot-db-instance --region $R1 --db-instance-identifier $DB --force-failover | Out-Null
Write-Host "Failover Multi-AZ forzado en $($t0.ToString('o')). Esperando a que RDS vuelva a 'available'..."
Start-Sleep 20
aws rds wait db-instance-available --region $R1 --db-instance-identifier $DB
Start-Sleep 30
Stop-Job $writer; Remove-Job $writer -Force
$azDespues = aws rds describe-db-instances --region $R1 --db-instance-identifier $DB --query "DBInstances[0].AvailabilityZone" --output text

$ev = @(Get-Content $log | ForEach-Object { $f = $_.Split("|"); [pscustomobject]@{ Hora = [DateTime]::Parse($f[0]).ToUniversalTime(); Ok = ($f[1] -eq "OK") } } | Where-Object { $_.Hora -ge $t0 })
$fallas = @($ev | Where-Object { -not $_.Ok })
if ($fallas.Count -eq 0) {
  $rto = "0 s (ninguna escritura falló)"
} else {
  $ultimaFalla = ($fallas | Sort-Object Hora | Select-Object -Last 1).Hora
  $recup = ($ev | Where-Object { $_.Ok -and $_.Hora -gt $ultimaFalla } | Sort-Object Hora | Select-Object -First 1).Hora
  $rto = if ($recup) { "{0:N0} s (de la falla a la primera escritura OK posterior)" -f ($recup - $t0).TotalSeconds } else { "no se recuperó en la ventana medida" }
}
$txt = @"
REPORTE ESCENARIO B: FALLA DE LA BASE DE DATOS PRIMARIA (failover Multi-AZ)
Falla inyectada (UTC) : $($t0.ToString('o'))  [aws rds reboot-db-instance --force-failover]
Zona antes / después  : $azAntes -> $azDespues
RTO de escritura      : $rto
Escrituras fallidas   : $($fallas.Count) de $($ev.Count) intentos desde la falla
Nota: la recuperación es dentro de la región (Multi-AZ); no requiere failover regional.
"@
$file = Join-Path $out "REPORTE_falla_rds.txt"
$txt | Out-File $file -Encoding utf8
Write-Host ""; Write-Host $txt -ForegroundColor Green
Write-Host "Reporte: $file"

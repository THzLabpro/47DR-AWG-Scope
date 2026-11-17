param([Parameter(Mandatory=$true)][string]$DeploymentDirectory,
      [string]$ConfigName='lab_config_v5.json')
$ErrorActionPreference='Stop'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Run in administrator PowerShell. No changes made.'
}
$directory=(Resolve-Path -LiteralPath $DeploymentDirectory).Path
$exe=Join-Path $directory 'FPGA_Shared_Service\FPGA_Shared_Service.exe'
$config=Join-Path $directory $ConfigName
& $exe --config $config --check
if($LASTEXITCODE -ne 0){throw 'Configuration validation failed; no task installed.'}
$settings=Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$listener=Get-NetTCPConnection -State Listen -LocalPort $settings.port -ErrorAction SilentlyContinue
if($listener){throw 'Stop the existing shared-service instance after confirming no active hardware operation, then rerun.'}
$name='FPGA_BoardShare_v2'
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'Task already exists; inspect it before replacing.'}
$action=New-ScheduledTaskAction -Execute $exe -Argument ('--config "'+$config+'"') -WorkingDirectory $directory
$trigger=New-ScheduledTaskTrigger -AtStartup
$options=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $options -User 'SYSTEM' -RunLevel Highest -Description 'FPGA shared coordinator; startup requires explicit hardware recovery.' | Out-Null
Start-ScheduledTask -TaskName $name
Get-ScheduledTask -TaskName $name | Select-Object TaskName,State
Write-Output 'Task installed. Verify API connectivity; hardware remains unverified until explicit recovery.'

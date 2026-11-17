param([Parameter(Mandatory=$true)][string]$DeploymentDirectory)
$ErrorActionPreference='Stop'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Administrator PowerShell required; no firewall changes made.'
}
$exe=(Resolve-Path -LiteralPath (Join-Path $DeploymentDirectory 'FPGA_Shared_Service\FPGA_Shared_Service.exe')).Path
$name='FPGA-BoardShare-V2-Telemetry-9001'
if(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue){throw 'Rule exists; inspect before replacing.'}
New-NetFirewallRule -Name $name -DisplayName 'FPGA shared service telemetry from board' -Direction Inbound -Action Allow -Profile Any -Protocol UDP -LocalAddress '192.168.42.20' -LocalPort 9001 -RemoteAddress '192.168.42.2' -Program $exe | Out-Null
Get-NetFirewallRule -Name $name | Select-Object Name,Enabled,Action
Get-NetFirewallRule -Name $name | Get-NetFirewallAddressFilter | Select-Object LocalAddress,RemoteAddress
Write-Output 'Limited telemetry rule installed. UDP reception still needs a live check.'

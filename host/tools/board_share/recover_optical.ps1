param(
    [Parameter(Mandatory=$true)][ValidateSet('Verify','Restart')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$HostIP,
    [Parameter(Mandatory=$true)][string]$BoardIP,
    [Parameter(Mandatory=$true)][string]$AllowedInterfaceGuids,
    [string]$Vivado,
    [string]$ProbeScript,
    [string]$CableSerial
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# Select the actual route; GUID allowlist is provisioned only on the lab host.
# Never restart WLAN, Tailscale or all adapters; never change IP/MAC/MTU.
$allowed=@($AllowedInterfaceGuids.Split(',') | ForEach-Object {([guid]$_).ToString()})
$route=@(Find-NetRoute -RemoteIPAddress $BoardIP -LocalIPAddress $HostIP)
$indices=@($route | Select-Object -ExpandProperty InterfaceIndex -Unique)
if($indices.Count -ne 1){throw 'Ambiguous board route'}
$nic=@(Get-NetAdapter -Physical | Where-Object {
    $_.ifIndex -eq $indices[0] -and ([guid]$_.InterfaceGuid).ToString() -in $allowed
})
if($nic.Count -ne 1 -or $nic[0].Status -ne 'Up'){throw 'Board route is not an allowed active optical adapter'}
$nic=$nic[0]
if(-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 | Where-Object IPAddress -eq $HostIP)){
    throw 'Board source IP does not belong to selected adapter'
}
Write-Output ('OPTICAL_ADAPTER '+$nic.Name+' '+$nic.InterfaceGuid)
if($Mode -eq 'Verify') {
    if(Get-NetTCPConnection -LocalPort 3121 -State Established -ErrorAction SilentlyContinue){
        throw 'Another JTAG client is connected'
    }
    if(-not (Test-Path -LiteralPath $Vivado -PathType Leaf) -or -not (Test-Path -LiteralPath $ProbeScript -PathType Leaf)){
        throw 'Missing Vivado or identity probe'
    }
    & $Vivado -mode batch -nolog -nojournal -source $ProbeScript -tclargs $CableSerial
    if($LASTEXITCODE -ne 0){throw 'F3 JTAG identity probe failed'}
} else {
    Restart-NetAdapter -InputObject $nic -Confirm:$false
    $deadline=(Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $current=Get-NetAdapter -Physical | Where-Object InterfaceGuid -eq $nic.InterfaceGuid
        if($current.Status -eq 'Up'){break}
    } while((Get-Date) -lt $deadline)
    if($current.Status -ne 'Up'){throw 'Optical link did not return after adapter restart'}
    Write-Output 'OPTICAL_ADAPTER_RESTARTED'
}

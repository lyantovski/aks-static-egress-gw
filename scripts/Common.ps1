Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $File,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $output = & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
    return ($output -join "`n")
}

function Test-IPv4InCidr {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Cidr
    )
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { throw "Invalid IPv4 CIDR: $Cidr" }
    $ip = [System.Net.IPAddress]::Parse($Address)
    $network = [System.Net.IPAddress]::Parse($parts[0])
    $length = 0
    if (-not [int]::TryParse($parts[1], [ref]$length) -or $length -lt 0 -or $length -gt 32) {
        throw "Invalid IPv4 prefix length: $Cidr"
    }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $network.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Only IPv4 addresses are supported.'
    }
    $ipBytes = $ip.GetAddressBytes()
    $networkBytes = $network.GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $length - 8 * $i))
        $mask = (0xff -shl (8 - $bits)) -band 0xff
        if (($ipBytes[$i] -band $mask) -ne ($networkBytes[$i] -band $mask)) { return $false }
    }
    return $true
}

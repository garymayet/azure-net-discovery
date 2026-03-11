<#
.SYNOPSIS
    Discover-HubSpoke.ps1 — Descubrimiento profundo de arquitectura Hub & Spoke en Azure.

.DESCRIPTION
    Itera sobre suscripciones Azure para recolectar VNets, Subnets, Peerings,
    Gateways (ExpressRoute/VPN), Azure Firewall, DNS Private Resolver, y genera:
      • Objetivo A — Reporte de evaluación de mejores prácticas (consola + CSV).
      • Objetivo B — Diagrama Mermaid.js de la topología descubierta.

.NOTES
    Autor  : Arquitecto de Soluciones Cloud Senior
    Fecha  : 2026-03-11
    Requiere: Módulos Az.Network, Az.Accounts (Az PowerShell >= 12.x)

.PARAMETER SubscriptionIds
    (Opcional) Array de IDs de suscripción a analizar. Si no se indica, usa todas
    las suscripciones accesibles por la identidad autenticada.

.PARAMETER OutputPath
    (Opcional) Directorio de salida para CSV y .mmd. Por defecto: ./hub-spoke-output

.EXAMPLE
    # Analizar todas las suscripciones accesibles
    .\Discover-HubSpoke.ps1

    # Analizar suscripciones específicas
    .\Discover-HubSpoke.ps1 -SubscriptionIds @("aaaa-bbbb-cccc", "dddd-eeee-ffff")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./hub-spoke-output"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 0 — FUNCIONES AUXILIARES
# ─────────────────────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO"    { "Cyan"    }
        "OK"      { "Green"   }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        default   { "White"   }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Get-ShortId {
    <# Extrae un ID legible desde un ResourceId de Azure #>
    param([string]$ResourceId)
    if ([string]::IsNullOrEmpty($ResourceId)) { return "N/A" }
    return ($ResourceId -split "/")[-1]
}

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 1 — INICIALIZACIÓN Y PREPARACIÓN
# ─────────────────────────────────────────────────────────────────────────────

Write-Status "═══════════════════════════════════════════════════════════════"
Write-Status "  Azure Hub & Spoke — Deep Discovery & Best Practices Audit   "
Write-Status "═══════════════════════════════════════════════════════════════"

# Crear directorio de salida si no existe
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Status "Directorio de salida creado: $OutputPath"
}

# Verificar autenticación Azure
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Status "No hay sesión Azure activa. Ejecutando Connect-AzAccount..." "WARN"
        Connect-AzAccount
    }
    Write-Status "Autenticado como: $($context.Account.Id)" "OK"
}
catch {
    Write-Status "Error de autenticación: $_" "ERROR"
    exit 1
}

# Resolver suscripciones objetivo
# @() fuerza array incluso con un solo resultado (evita error .Count en objeto único)
if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $subscriptions = @($SubscriptionIds | ForEach-Object {
        Get-AzSubscription -SubscriptionId $_ -WarningAction SilentlyContinue
    })
}
else {
    $subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue |
        Where-Object { $_.State -eq "Enabled" })
}

Write-Status "Suscripciones a analizar: $($subscriptions.Count)"

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 2 — ESTRUCTURAS DE ALMACENAMIENTO (Data Mining)
# ─────────────────────────────────────────────────────────────────────────────

# Colecciones globales para todos los objetos descubiertos
$allVNets          = [System.Collections.Generic.List[PSCustomObject]]::new()
$allSubnets        = [System.Collections.Generic.List[PSCustomObject]]::new()
$allPeerings       = [System.Collections.Generic.List[PSCustomObject]]::new()
$allErGateways     = [System.Collections.Generic.List[PSCustomObject]]::new()
$allVpnGateways    = [System.Collections.Generic.List[PSCustomObject]]::new()
$allFirewalls       = [System.Collections.Generic.List[PSCustomObject]]::new()
$allDnsResolvers   = [System.Collections.Generic.List[PSCustomObject]]::new()
$allPublicIPs      = [System.Collections.Generic.List[PSCustomObject]]::new()
$bestPractices     = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 3 — RECOLECCIÓN POR SUSCRIPCIÓN
# ─────────────────────────────────────────────────────────────────────────────

foreach ($sub in $subscriptions) {
    # Normalizar propiedades (Az antiguo usa .SubscriptionId/.Name, nuevo usa .Id/.Name)
    $subId   = if ($sub.PSObject.Properties['SubscriptionId']) { $sub.SubscriptionId } else { $sub.Id }
    $subName = if ($sub.PSObject.Properties['Name']) { $sub.Name } else { $sub.SubscriptionName }

    Write-Status "────────────────────────────────────────────────────────────"
    Write-Status "Procesando suscripción: $subName [$subId]"
    Set-AzContext -SubscriptionId $subId -Force -WarningAction SilentlyContinue | Out-Null

    # ── 3.1 VNets y Subnets ──────────────────────────────────────────────
    Write-Status "  Descubriendo VNets..."
    $vnets = @(Get-AzVirtualNetwork)

    foreach ($vnet in $vnets) {
        $vnetRecord = [PSCustomObject]@{
            SubscriptionId   = $subId
            SubscriptionName = $subName
            ResourceGroup    = $vnet.ResourceGroupName
            VNetName         = $vnet.Name
            Location         = $vnet.Location
            AddressSpace     = ($vnet.AddressSpace.AddressPrefixes -join ", ")
            ResourceId       = $vnet.Id
            # Flags de clasificación (se determinan luego)
            IsHub            = $false
            IsSpoke          = $false
        }
        $allVNets.Add($vnetRecord)

        # Subnets con clasificación especial
        foreach ($subnet in $vnet.Subnets) {
            $subnetType = "Standard"
            if ($subnet.Name -eq "GatewaySubnet")        { $subnetType = "GatewaySubnet" }
            if ($subnet.Name -eq "AzureFirewallSubnet")   { $subnetType = "AzureFirewallSubnet" }
            if ($subnet.Name -eq "AzureFirewallManagementSubnet") { $subnetType = "AzureFirewallMgmtSubnet" }

            $allSubnets.Add([PSCustomObject]@{
                VNetName      = $vnet.Name
                SubnetName    = $subnet.Name
                SubnetType    = $subnetType
                AddressPrefix = ($subnet.AddressPrefix -join ", ")
                NSG           = (Get-ShortId $subnet.NetworkSecurityGroup.Id)
                RouteTable    = (Get-ShortId $subnet.RouteTable.Id)
            })
        }

        # ── 3.2 VNet Peerings ────────────────────────────────────────────
        foreach ($peering in $vnet.VirtualNetworkPeerings) {
            $allPeerings.Add([PSCustomObject]@{
                SubscriptionId      = $subId
                SourceVNet          = $vnet.Name
                SourceVNetId        = $vnet.Id
                PeeringName         = $peering.Name
                RemoteVNetId        = $peering.RemoteVirtualNetwork.Id
                RemoteVNetName      = (Get-ShortId $peering.RemoteVirtualNetwork.Id)
                PeeringState        = $peering.PeeringState
                AllowGatewayTransit = $peering.AllowGatewayTransit
                UseRemoteGateways   = $peering.UseRemoteGateways
                AllowForwardedTraffic = $peering.AllowForwardedTraffic
                AllowVNetAccess     = $peering.AllowVirtualNetworkAccess
            })
        }
    }

    # ── 3.3 Virtual Network Gateways (ExpressRoute + VPN) ────────────────
    Write-Status "  Descubriendo Gateways..."
    $gateways = @()
    $rgs = @(Get-AzResourceGroup)
    foreach ($rg in $rgs) {
        try {
            $gws = @(Get-AzVirtualNetworkGateway -ResourceGroupName $rg.ResourceGroupName -WarningAction SilentlyContinue)
            if ($gws.Count -gt 0 -and $gws[0]) { $gateways += $gws }
        }
        catch { <# silenciar RGs sin gateways #> }
    }

    foreach ($gw in $gateways) {
        $gwRecord = [PSCustomObject]@{
            SubscriptionId   = $subId
            ResourceGroup    = $gw.ResourceGroupName
            GatewayName      = $gw.Name
            GatewayType      = $gw.GatewayType        # ExpressRoute | Vpn
            VpnType          = $gw.VpnType             # RouteBased | PolicyBased
            Sku              = $gw.Sku.Name
            SkuTier          = $gw.Sku.Tier
            Active           = $gw.ActiveActive
            EnableBgp        = $gw.EnableBgp
            Location         = $gw.Location
            VNetName         = ""
            PublicIPs        = @()
            IsZoneRedundant  = $false
        }

        # Determinar VNet asociada (desde IpConfigurations → SubnetId)
        if ($gw.IpConfigurations.Count -gt 0) {
            $subnetId = $gw.IpConfigurations[0].Subnet.Id
            if ($subnetId) {
                # Formato: .../virtualNetworks/{vnetName}/subnets/GatewaySubnet
                $parts = $subnetId -split "/"
                $vnetIdx = [Array]::IndexOf($parts, "virtualNetworks")
                if ($vnetIdx -ge 0) { $gwRecord.VNetName = $parts[$vnetIdx + 1] }
            }
        }

        # Recoger IPs Públicas del Gateway
        foreach ($ipConfig in $gw.IpConfigurations) {
            if ($ipConfig.PublicIpAddress.Id) {
                $pipName = Get-ShortId $ipConfig.PublicIpAddress.Id
                $gwRecord.PublicIPs += $pipName
                try {
                    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $gw.ResourceGroupName
                    $allPublicIPs.Add([PSCustomObject]@{
                        Name          = $pip.Name
                        IpAddress     = $pip.IpAddress
                        SKU           = $pip.Sku.Name
                        Allocation    = $pip.PublicIpAllocationMethod
                        AssociatedTo  = $gw.Name
                        Zones         = ($pip.Zones -join ", ")
                    })
                }
                catch { <# IP en otro RG, continuar #> }
            }
        }

        # Verificar Zone Redundancy (SKUs que terminan en AZ)
        $azSkus = @(
            "ErGw1AZ", "ErGw2AZ", "ErGw3AZ", "ErGwScale",
            "VpnGw1AZ", "VpnGw2AZ", "VpnGw3AZ", "VpnGw4AZ", "VpnGw5AZ"
        )
        $gwRecord.IsZoneRedundant = $azSkus -contains $gw.Sku.Name

        if ($gw.GatewayType -eq "ExpressRoute") {
            $allErGateways.Add($gwRecord)
        }
        else {
            $allVpnGateways.Add($gwRecord)
        }
    }

    # ── 3.4 Azure Firewalls ──────────────────────────────────────────────
    Write-Status "  Descubriendo Azure Firewalls..."
    try {
        $firewalls = Get-AzFirewall
        foreach ($fw in $firewalls) {
            $fwVNet = ""
            if ($fw.IpConfigurations.Count -gt 0 -and $fw.IpConfigurations[0].Subnet.Id) {
                $parts = $fw.IpConfigurations[0].Subnet.Id -split "/"
                $vnetIdx = [Array]::IndexOf($parts, "virtualNetworks")
                if ($vnetIdx -ge 0) { $fwVNet = $parts[$vnetIdx + 1] }
            }

            $allFirewalls.Add([PSCustomObject]@{
                SubscriptionId  = $subId
                ResourceGroup   = $fw.ResourceGroupName
                FirewallName    = $fw.Name
                Location        = $fw.Location
                SkuName         = $fw.Sku.Name          # AZFW_VNet | AZFW_Hub
                SkuTier         = $fw.Sku.Tier           # Standard | Premium
                ThreatIntelMode = $fw.ThreatIntelMode
                VNetName        = $fwVNet
                PrivateIP       = ($fw.IpConfigurations | Where-Object { $_.PrivateIpAddress } |
                                   Select-Object -First 1).PrivateIpAddress
                Zones           = ($fw.Zones -join ", ")
                PolicyId        = $fw.FirewallPolicy.Id
            })
        }
    }
    catch { Write-Status "  No se encontraron Azure Firewalls en esta suscripción" "WARN" }

    # ── 3.5 Azure DNS Private Resolver ───────────────────────────────────
    Write-Status "  Descubriendo DNS Private Resolvers..."
    try {
        # DNS Private Resolver usa el módulo Az.DnsResolver
        $resolvers = Get-AzDnsResolver 2>$null
        foreach ($resolver in $resolvers) {
            $resolverVNet = ""
            if ($resolver.VirtualNetworkId) {
                $resolverVNet = Get-ShortId $resolver.VirtualNetworkId
            }

            $allDnsResolvers.Add([PSCustomObject]@{
                SubscriptionId = $subId
                ResourceGroup  = $resolver.ResourceGroupName
                ResolverName   = $resolver.Name
                Location       = $resolver.Location
                VNetName       = $resolverVNet
                State          = $resolver.ProvisioningState
            })
        }
    }
    catch { Write-Status "  DNS Resolver no disponible o módulo Az.DnsResolver no instalado" "WARN" }
}

Write-Status "════════════════════════════════════════════════════════════"
Write-Status "Recolección completa. Procesando resultados..." "OK"
Write-Status "  VNets: $($allVNets.Count) | Peerings: $($allPeerings.Count)"
Write-Status "  ER GWs: $($allErGateways.Count) | VPN GWs: $($allVpnGateways.Count)"
Write-Status "  Firewalls: $($allFirewalls.Count) | DNS Resolvers: $($allDnsResolvers.Count)"

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 4 — CLASIFICACIÓN HUB vs SPOKE
# ─────────────────────────────────────────────────────────────────────────────

Write-Status "Clasificando topología Hub vs Spoke..."

<#
    Heurística de clasificación:
    1. Una VNet es HUB si contiene:
       - GatewaySubnet con un Gateway (ER o VPN) desplegado, O
       - AzureFirewallSubnet con un Azure Firewall, O
       - Tiene AllowGatewayTransit=True en al menos un peering
    2. Una VNet es SPOKE si:
       - Tiene peering con UseRemoteGateways=True, O
       - No cumple criterios de Hub y está conectada a un Hub vía peering
#>

# Identificar VNets Hub por infraestructura desplegada
$hubVNetNames = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)

# Criterio 1: VNet con Gateways
foreach ($gw in ($allErGateways + $allVpnGateways)) {
    if ($gw.VNetName) { [void]$hubVNetNames.Add($gw.VNetName) }
}

# Criterio 2: VNet con Firewalls
foreach ($fw in $allFirewalls) {
    if ($fw.VNetName) { [void]$hubVNetNames.Add($fw.VNetName) }
}

# Criterio 3: Peerings con AllowGatewayTransit = True
foreach ($p in $allPeerings) {
    if ($p.AllowGatewayTransit -eq $true) {
        [void]$hubVNetNames.Add($p.SourceVNet)
    }
}

# Marcar registros
foreach ($vnet in $allVNets) {
    if ($hubVNetNames.Contains($vnet.VNetName)) {
        $vnet.IsHub = $true
    }
    else {
        $vnet.IsSpoke = $true
    }
}

$hubCount   = @($allVNets | Where-Object { $_.IsHub }).Count
$spokeCount = @($allVNets | Where-Object { $_.IsSpoke }).Count
Write-Status "  Hubs identificados: $hubCount | Spokes identificados: $spokeCount" "OK"

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 5 — OBJETIVO A: EVALUACIÓN DE MEJORES PRÁCTICAS
# ─────────────────────────────────────────────────────────────────────────────

Write-Status "═══════════════════════════════════════════════════════════"
Write-Status "  OBJETIVO A — Evaluación de Mejores Prácticas (Best Practices)"
Write-Status "═══════════════════════════════════════════════════════════"

# ── Check 1: ¿Los Spokes están conectados SOLO al Hub? ────────────────────
Write-Status "`n[CHECK 1] Validando que Spokes solo conecten al Hub..."

foreach ($vnet in ($allVNets | Where-Object { $_.IsSpoke })) {
    $spokePeerings = @($allPeerings | Where-Object { $_.SourceVNet -eq $vnet.VNetName })

    if ($spokePeerings.Count -eq 0) {
        $bestPractices.Add([PSCustomObject]@{
            Check       = "Spoke-Connectivity"
            Resource    = $vnet.VNetName
            Status      = "WARNING"
            Detail      = "Spoke VNet no tiene peerings configurados (aislada)"
            Recommendation = "Crear peering hacia la VNet Hub"
        })
        Write-Status "  ⚠ $($vnet.VNetName): Sin peerings (VNet aislada)" "WARN"
        continue
    }

    foreach ($peer in $spokePeerings) {
        $remoteIsHub = $hubVNetNames.Contains($peer.RemoteVNetName)
        if (-not $remoteIsHub) {
            # Spoke tiene peering a otra VNet que no es Hub → Posible Spoke-to-Spoke
            $bestPractices.Add([PSCustomObject]@{
                Check       = "Spoke-Connectivity"
                Resource    = "$($vnet.VNetName) → $($peer.RemoteVNetName)"
                Status      = "FAIL"
                Detail      = "Spoke tiene peering directo a otra VNet no-Hub (Spoke-to-Spoke)"
                Recommendation = "Enrutar tráfico Spoke-to-Spoke a través del Hub (NVA/Firewall)"
            })
            Write-Status "  ✗ $($vnet.VNetName) → $($peer.RemoteVNetName): Peering Spoke-to-Spoke" "ERROR"
        }
        else {
            $bestPractices.Add([PSCustomObject]@{
                Check       = "Spoke-Connectivity"
                Resource    = "$($vnet.VNetName) → $($peer.RemoteVNetName)"
                Status      = "PASS"
                Detail      = "Spoke conectado correctamente al Hub"
                Recommendation = "N/A"
            })
            Write-Status "  ✓ $($vnet.VNetName) → $($peer.RemoteVNetName): OK (Hub)" "OK"
        }
    }
}

# ── Check 2: ¿Tienen los Gateways SKU con Zone Redundancy? ──────────────
Write-Status "`n[CHECK 2] Validando Zone Redundancy en Gateways..."

foreach ($gw in ($allErGateways + $allVpnGateways)) {
    if ($gw.IsZoneRedundant) {
        $bestPractices.Add([PSCustomObject]@{
            Check       = "Gateway-ZoneRedundancy"
            Resource    = "$($gw.GatewayName) ($($gw.GatewayType))"
            Status      = "PASS"
            Detail      = "SKU $($gw.Sku) soporta Zone Redundancy"
            Recommendation = "N/A"
        })
        Write-Status "  ✓ $($gw.GatewayName): SKU $($gw.Sku) — Zone Redundant" "OK"
    }
    else {
        $bestPractices.Add([PSCustomObject]@{
            Check       = "Gateway-ZoneRedundancy"
            Resource    = "$($gw.GatewayName) ($($gw.GatewayType))"
            Status      = "FAIL"
            Detail      = "SKU $($gw.Sku) NO soporta Zone Redundancy"
            Recommendation = "Migrar a SKU con sufijo 'AZ' (ej: ErGw2AZ, VpnGw2AZ)"
        })
        Write-Status "  ✗ $($gw.GatewayName): SKU $($gw.Sku) — SIN Zone Redundancy" "ERROR"
    }
}

# ── Check 3: ¿Está habilitado Gateway Transit correctamente? ─────────────
Write-Status "`n[CHECK 3] Validando configuración de Gateway Transit..."

foreach ($vnet in ($allVNets | Where-Object { $_.IsHub })) {
    $hubPeerings = $allPeerings | Where-Object { $_.SourceVNet -eq $vnet.VNetName }

    foreach ($peer in $hubPeerings) {
        # Lado Hub: debe tener AllowGatewayTransit = True
        if (-not $peer.AllowGatewayTransit) {
            $bestPractices.Add([PSCustomObject]@{
                Check       = "GatewayTransit-Hub"
                Resource    = "$($peer.SourceVNet) → $($peer.RemoteVNetName)"
                Status      = "FAIL"
                Detail      = "AllowGatewayTransit deshabilitado en el lado Hub"
                Recommendation = "Habilitar AllowGatewayTransit en el peering del Hub"
            })
            Write-Status "  ✗ Hub $($peer.SourceVNet) → $($peer.RemoteVNetName): AllowGatewayTransit=False" "ERROR"
        }
        else {
            $bestPractices.Add([PSCustomObject]@{
                Check       = "GatewayTransit-Hub"
                Resource    = "$($peer.SourceVNet) → $($peer.RemoteVNetName)"
                Status      = "PASS"
                Detail      = "AllowGatewayTransit habilitado correctamente"
                Recommendation = "N/A"
            })
            Write-Status "  ✓ Hub $($peer.SourceVNet) → $($peer.RemoteVNetName): AllowGatewayTransit=True" "OK"
        }
    }
}

# Verificar lado Spoke: UseRemoteGateways debe ser True
foreach ($vnet in ($allVNets | Where-Object { $_.IsSpoke })) {
    $spokePeerings = $allPeerings | Where-Object {
        $_.SourceVNet -eq $vnet.VNetName -and $hubVNetNames.Contains($_.RemoteVNetName)
    }

    foreach ($peer in $spokePeerings) {
        if (-not $peer.UseRemoteGateways) {
            $bestPractices.Add([PSCustomObject]@{
                Check       = "GatewayTransit-Spoke"
                Resource    = "$($peer.SourceVNet) → $($peer.RemoteVNetName)"
                Status      = "FAIL"
                Detail      = "UseRemoteGateways deshabilitado en el lado Spoke"
                Recommendation = "Habilitar UseRemoteGateways en el peering del Spoke hacia el Hub"
            })
            Write-Status "  ✗ Spoke $($peer.SourceVNet): UseRemoteGateways=False" "ERROR"
        }
        else {
            $bestPractices.Add([PSCustomObject]@{
                Check       = "GatewayTransit-Spoke"
                Resource    = "$($peer.SourceVNet) → $($peer.RemoteVNetName)"
                Status      = "PASS"
                Detail      = "UseRemoteGateways habilitado correctamente"
                Recommendation = "N/A"
            })
            Write-Status "  ✓ Spoke $($peer.SourceVNet): UseRemoteGateways=True" "OK"
        }
    }
}

# ── Check 4: ¿AllowForwardedTraffic habilitado? ─────────────────────────
Write-Status "`n[CHECK 4] Validando AllowForwardedTraffic para enrutamiento a través del Hub..."

foreach ($peer in $allPeerings) {
    if (-not $peer.AllowForwardedTraffic) {
        $bestPractices.Add([PSCustomObject]@{
            Check       = "ForwardedTraffic"
            Resource    = "$($peer.SourceVNet) → $($peer.RemoteVNetName)"
            Status      = "WARN"
            Detail      = "AllowForwardedTraffic deshabilitado"
            Recommendation = "Habilitar si se requiere enrutamiento transitive vía NVA/Firewall"
        })
        Write-Status "  ⚠ $($peer.SourceVNet) → $($peer.RemoteVNetName): AllowForwardedTraffic=False" "WARN"
    }
}

# ── Check 5: Azure Firewall Zone Redundancy ──────────────────────────────
Write-Status "`n[CHECK 5] Validando Zone Redundancy en Azure Firewalls..."

foreach ($fw in $allFirewalls) {
    $zones = @($fw.Zones -split ", " | Where-Object { $_ })
    if ($zones.Count -ge 2) {
        $bestPractices.Add([PSCustomObject]@{
            Check       = "Firewall-ZoneRedundancy"
            Resource    = $fw.FirewallName
            Status      = "PASS"
            Detail      = "Desplegado en zonas: $($fw.Zones)"
            Recommendation = "N/A"
        })
        Write-Status "  ✓ $($fw.FirewallName): Zonas [$($fw.Zones)]" "OK"
    }
    else {
        $bestPractices.Add([PSCustomObject]@{
            Check       = "Firewall-ZoneRedundancy"
            Resource    = $fw.FirewallName
            Status      = "FAIL"
            Detail      = "Firewall NO desplegado en múltiples zonas"
            Recommendation = "Redesplegar en al menos 2 Availability Zones"
        })
        Write-Status "  ✗ $($fw.FirewallName): Sin redundancia de zona" "ERROR"
    }
}

# ── Resumen de la Evaluación ─────────────────────────────────────────────
$passCount = @($bestPractices | Where-Object { $_.Status -eq "PASS" }).Count
$failCount = @($bestPractices | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = @($bestPractices | Where-Object { $_.Status -match "WARN" }).Count

Write-Status "`n═══════════════════════════════════════════════════════════"
Write-Status "  RESUMEN: $passCount PASS | $failCount FAIL | $warnCount WARNINGS"
Write-Status "═══════════════════════════════════════════════════════════"

# Exportar CSV
$csvPath = Join-Path $OutputPath "best-practices-report.csv"
$bestPractices | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Reporte CSV exportado: $csvPath" "OK"

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 6 — OBJETIVO B: GENERACIÓN DE DIAGRAMA MERMAID
# ─────────────────────────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════════════════"
Write-Status "  OBJETIVO B — Generación de Diagrama Mermaid.js"
Write-Status "═══════════════════════════════════════════════════════════"

# Función para sanitizar nombres (Mermaid no acepta ciertos caracteres)
function ConvertTo-MermaidId {
    param([string]$Name)
    return ($Name -replace "[^a-zA-Z0-9]", "_")
}

$mermaid = [System.Text.StringBuilder]::new()
[void]$mermaid.AppendLine("graph TD")
[void]$mermaid.AppendLine("")
[void]$mermaid.AppendLine("    %% ═══════════════════════════════════════════════")
[void]$mermaid.AppendLine("    %% Azure Hub & Spoke — Diagrama Auto-Generado")
[void]$mermaid.AppendLine("    %% Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$mermaid.AppendLine("    %% ═══════════════════════════════════════════════")
[void]$mermaid.AppendLine("")

# ── Estilos ──
[void]$mermaid.AppendLine("    %% Estilos")
[void]$mermaid.AppendLine("    classDef hubStyle fill:#1a73e8,stroke:#0d47a1,stroke-width:3px,color:#fff")
[void]$mermaid.AppendLine("    classDef spokeStyle fill:#34a853,stroke:#1b5e20,stroke-width:2px,color:#fff")
[void]$mermaid.AppendLine("    classDef fwStyle fill:#ea4335,stroke:#b71c1c,stroke-width:2px,color:#fff")
[void]$mermaid.AppendLine("    classDef gwStyle fill:#fbbc04,stroke:#f57f17,stroke-width:2px,color:#000")
[void]$mermaid.AppendLine("    classDef dnsStyle fill:#9c27b0,stroke:#4a148c,stroke-width:2px,color:#fff")
[void]$mermaid.AppendLine("    classDef onpremStyle fill:#607d8b,stroke:#263238,stroke-width:2px,color:#fff")
[void]$mermaid.AppendLine("")

# ── Nodo On-Premises (si hay ER/VPN Gateways) ──
if (($allErGateways.Count + $allVpnGateways.Count) -gt 0) {
    [void]$mermaid.AppendLine("    %% On-Premises / Conectividad Externa")
    [void]$mermaid.AppendLine("    ONPREM[/""🏢 On-Premises<br/>Datacenter""/]:::onpremStyle")
    [void]$mermaid.AppendLine("")
}

# ── Subgrafos Hub ──
foreach ($hub in ($allVNets | Where-Object { $_.IsHub })) {
    $hubId = ConvertTo-MermaidId $hub.VNetName
    [void]$mermaid.AppendLine("    %% ── Hub: $($hub.VNetName) ──")
    [void]$mermaid.AppendLine("    subgraph ${hubId}_sub[""🔷 HUB: $($hub.VNetName)""]")
    [void]$mermaid.AppendLine("        direction TB")
    [void]$mermaid.AppendLine("        ${hubId}[""📡 $($hub.VNetName)<br/>$($hub.AddressSpace)<br/>$($hub.Location)""]:::hubStyle")

    # Firewalls dentro del Hub
    $hubFirewalls = $allFirewalls | Where-Object { $_.VNetName -eq $hub.VNetName }
    foreach ($fw in $hubFirewalls) {
        $fwId = ConvertTo-MermaidId $fw.FirewallName
        $fwLabel = "🔥 $($fw.FirewallName)<br/>Tier: $($fw.SkuTier)"
        if ($fw.PrivateIP) { $fwLabel += "<br/>IP: $($fw.PrivateIP)" }
        if ($fw.Zones) { $fwLabel += "<br/>Zonas: $($fw.Zones)" }
        [void]$mermaid.AppendLine("        ${fwId}[""$fwLabel""]:::fwStyle")
        [void]$mermaid.AppendLine("        ${hubId} --- ${fwId}")
    }

    # Gateways ExpressRoute dentro del Hub
    $hubErGws = $allErGateways | Where-Object { $_.VNetName -eq $hub.VNetName }
    foreach ($gw in $hubErGws) {
        $gwId = ConvertTo-MermaidId $gw.GatewayName
        $azTag = if ($gw.IsZoneRedundant) { "✅ AZ" } else { "⚠️ No-AZ" }
        [void]$mermaid.AppendLine("        ${gwId}[""⚡ $($gw.GatewayName)<br/>ExpressRoute<br/>SKU: $($gw.Sku)<br/>$azTag""]:::gwStyle")
        [void]$mermaid.AppendLine("        ${hubId} --- ${gwId}")
    }

    # Gateways VPN dentro del Hub
    $hubVpnGws = $allVpnGateways | Where-Object { $_.VNetName -eq $hub.VNetName }
    foreach ($gw in $hubVpnGws) {
        $gwId = ConvertTo-MermaidId $gw.GatewayName
        $azTag = if ($gw.IsZoneRedundant) { "✅ AZ" } else { "⚠️ No-AZ" }
        [void]$mermaid.AppendLine("        ${gwId}[""🔒 $($gw.GatewayName)<br/>VPN Gateway<br/>SKU: $($gw.Sku)<br/>$azTag""]:::gwStyle")
        [void]$mermaid.AppendLine("        ${hubId} --- ${gwId}")
    }

    # DNS Private Resolvers dentro del Hub
    $hubDns = $allDnsResolvers | Where-Object { $_.VNetName -eq $hub.VNetName }
    foreach ($dns in $hubDns) {
        $dnsId = ConvertTo-MermaidId $dns.ResolverName
        [void]$mermaid.AppendLine("        ${dnsId}[""🌐 $($dns.ResolverName)<br/>DNS Private Resolver""]:::dnsStyle")
        [void]$mermaid.AppendLine("        ${hubId} --- ${dnsId}")
    }

    [void]$mermaid.AppendLine("    end")
    [void]$mermaid.AppendLine("")

    # Conexión On-Prem → Gateway (si existe)
    foreach ($gw in $hubErGws) {
        $gwId = ConvertTo-MermaidId $gw.GatewayName
        [void]$mermaid.AppendLine("    ONPREM ==>|ExpressRoute| ${gwId}")
    }
    foreach ($gw in $hubVpnGws) {
        $gwId = ConvertTo-MermaidId $gw.GatewayName
        [void]$mermaid.AppendLine("    ONPREM -.->|VPN IPSec| ${gwId}")
    }
    [void]$mermaid.AppendLine("")
}

# ── Subgrafos Spoke ──
foreach ($spoke in ($allVNets | Where-Object { $_.IsSpoke })) {
    $spokeId = ConvertTo-MermaidId $spoke.VNetName

    [void]$mermaid.AppendLine("    %% ── Spoke: $($spoke.VNetName) ──")
    [void]$mermaid.AppendLine("    subgraph ${spokeId}_sub[""🟢 SPOKE: $($spoke.VNetName)""]")
    [void]$mermaid.AppendLine("        ${spokeId}[""🖥️ $($spoke.VNetName)<br/>$($spoke.AddressSpace)<br/>$($spoke.Location)""]:::spokeStyle")

    # Listar subnets del Spoke (solo las estándar, las especiales ya están cubitas)
    $spokeSubnets = @($allSubnets | Where-Object {
        $_.VNetName -eq $spoke.VNetName -and $_.SubnetType -eq "Standard"
    })
    if ($spokeSubnets.Count -gt 0 -and $spokeSubnets.Count -le 5) {
        foreach ($sn in $spokeSubnets) {
            $snId = ConvertTo-MermaidId "$($spoke.VNetName)_$($sn.SubnetName)"
            [void]$mermaid.AppendLine("        ${snId}[""📂 $($sn.SubnetName)<br/>$($sn.AddressPrefix)""]")
            [void]$mermaid.AppendLine("        ${spokeId} --- ${snId}")
        }
    }
    elseif ($spokeSubnets.Count -gt 5) {
        [void]$mermaid.AppendLine("        ${spokeId}_sn[""📂 $($spokeSubnets.Count) subnets""]")
        [void]$mermaid.AppendLine("        ${spokeId} --- ${spokeId}_sn")
    }

    # Firewalls en Spoke (raro pero posible)
    $spokeFws = $allFirewalls | Where-Object { $_.VNetName -eq $spoke.VNetName }
    foreach ($fw in $spokeFws) {
        $fwId = ConvertTo-MermaidId $fw.FirewallName
        [void]$mermaid.AppendLine("        ${fwId}[""🔥 $($fw.FirewallName)""]:::fwStyle")
        [void]$mermaid.AppendLine("        ${spokeId} --- ${fwId}")
    }

    [void]$mermaid.AppendLine("    end")
    [void]$mermaid.AppendLine("")
}

# ── Conexiones de Peering (Hub ↔ Spoke) ──
[void]$mermaid.AppendLine("    %% ═══ Peering Connections ═══")
$processedPeerings = [System.Collections.Generic.HashSet[string]]::new()

foreach ($peer in $allPeerings) {
    # Crear clave única para evitar duplicar A→B y B→A
    $sortedPair = @($peer.SourceVNet, $peer.RemoteVNetName) | Sort-Object
    $pairKey = "$($sortedPair[0])|$($sortedPair[1])"

    if ($processedPeerings.Contains($pairKey)) { continue }
    [void]$processedPeerings.Add($pairKey)

    $sourceId = ConvertTo-MermaidId $peer.SourceVNet
    $remoteId = ConvertTo-MermaidId $peer.RemoteVNetName

    # Construir etiqueta del peering con estado de configuración
    $peerLabel = "Peering"
    $annotations = @()
    if ($peer.AllowGatewayTransit) { $annotations += "GW Transit" }
    if ($peer.UseRemoteGateways)   { $annotations += "Use Remote GW" }
    if ($peer.PeeringState -ne "Connected") { $annotations += "WARN: $($peer.PeeringState)" }
    if ($annotations.Count -gt 0) { $peerLabel = $annotations -join ", " }

    $sourceIsHub = $hubVNetNames.Contains($peer.SourceVNet)
    $remoteIsHub = $hubVNetNames.Contains($peer.RemoteVNetName)

    if ($sourceIsHub -or $remoteIsHub) {
        # Hub ↔ Spoke: línea sólida gruesa
        [void]$mermaid.AppendLine("    ${sourceId} <-->|$peerLabel| ${remoteId}")
    }
    else {
        # Spoke ↔ Spoke: línea punteada (anti-pattern)
        [void]$mermaid.AppendLine("    ${sourceId} -.->|S2S: $peerLabel| ${remoteId}")
    }
}

[void]$mermaid.AppendLine("")

# ── Output del Mermaid ──
$mermaidContent = $mermaid.ToString()

# Guardar archivo .mmd
$mermaidPath = Join-Path $OutputPath "hub-spoke-topology.mmd"
$mermaidContent | Out-File -FilePath $mermaidPath -Encoding UTF8
Write-Status "Diagrama Mermaid exportado: $mermaidPath" "OK"

# Mostrar en consola
Write-Status "`n┌─────────────────────────────────────────────────────────┐"
Write-Status "│              MERMAID OUTPUT (copiar abajo)              │"
Write-Status "└─────────────────────────────────────────────────────────┘"
Write-Host ""
Write-Host '```mermaid'
Write-Host $mermaidContent
Write-Host '```'

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 7 — EXPORTACIÓN DETALLADA DE INVENTARIO
# ─────────────────────────────────────────────────────────────────────────────

Write-Status "`nExportando inventarios detallados..."

$allVNets    | Export-Csv (Join-Path $OutputPath "inventory-vnets.csv")    -NoTypeInformation -Encoding UTF8
$allSubnets  | Export-Csv (Join-Path $OutputPath "inventory-subnets.csv")  -NoTypeInformation -Encoding UTF8
$allPeerings | Export-Csv (Join-Path $OutputPath "inventory-peerings.csv") -NoTypeInformation -Encoding UTF8

$gatewayExport = ($allErGateways + $allVpnGateways) | Select-Object `
    SubscriptionId, ResourceGroup, GatewayName, GatewayType, Sku, IsZoneRedundant, VNetName, Active, EnableBgp
$gatewayExport | Export-Csv (Join-Path $OutputPath "inventory-gateways.csv") -NoTypeInformation -Encoding UTF8

if ($allFirewalls.Count -gt 0) {
    $allFirewalls | Export-Csv (Join-Path $OutputPath "inventory-firewalls.csv") -NoTypeInformation -Encoding UTF8
}

Write-Status "Inventarios exportados en: $OutputPath" "OK"

# ─────────────────────────────────────────────────────────────────────────────
# REGIÓN 8 — RESUMEN FINAL
# ─────────────────────────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════════════════"
Write-Status "                   EJECUCIÓN COMPLETA                      "
Write-Status "═══════════════════════════════════════════════════════════"
Write-Status "Archivos generados:" "OK"
Write-Status "  📊 $csvPath"
Write-Status "  🗺️  $mermaidPath"
Write-Status "  📋 $OutputPath/inventory-*.csv"
Write-Status ""
Write-Status "Próximos pasos:"
Write-Status "  1. Revisar el CSV de best practices y remediar los FAIL"
Write-Status "  2. Pegar el contenido .mmd en https://mermaid.live para visualizar"
Write-Status "  3. Integrar en pipeline de gobernanza (Azure Policy / DevOps)"
Write-Status "═══════════════════════════════════════════════════════════"

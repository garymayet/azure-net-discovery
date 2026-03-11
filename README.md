# Azure Hub & Spoke — Discovery & Audit Tool

## Requisitos Previos

```powershell
# Instalar módulos necesarios
Install-Module -Name Az.Accounts -Force -Scope CurrentUser
Install-Module -Name Az.Network  -Force -Scope CurrentUser
Install-Module -Name Az.DnsResolver -Force -Scope CurrentUser   # Opcional

# Autenticarse
Connect-AzAccount
```

## Ejecución

```powershell
# Opción 1: Todas las suscripciones accesibles
.\Discover-HubSpoke.ps1

# Opción 2: Suscripciones específicas
.\Discover-HubSpoke.ps1 -SubscriptionIds @(
    "a1b2c3d4-0000-1111-2222-333344445555",
    "e5f6g7h8-9999-8888-7777-666655554444"
)

# Opción 3: Directorio de salida personalizado
.\Discover-HubSpoke.ps1 -OutputPath "C:\Audits\NetworkReview"
```

## Archivos de Salida

| Archivo | Descripción |
|---|---|
| `best-practices-report.csv` | Resultado de los 5 checks de mejores prácticas |
| `hub-spoke-topology.mmd` | Diagrama Mermaid listo para renderizar |
| `inventory-vnets.csv` | Inventario completo de VNets con clasificación Hub/Spoke |
| `inventory-subnets.csv` | Todas las subnets con tipo (Gateway, Firewall, Standard) |
| `inventory-peerings.csv` | Todos los peerings con flags de GatewayTransit |
| `inventory-gateways.csv` | Gateways ER/VPN con SKU y estado AZ |
| `inventory-firewalls.csv` | Azure Firewalls con tier, zonas e IP privada |

---

## Checks de Mejores Prácticas

| # | Check | Qué Valida |
|---|---|---|
| 1 | **Spoke-Connectivity** | Que cada Spoke solo tenga peering hacia el Hub (sin Spoke-to-Spoke) |
| 2 | **Gateway-ZoneRedundancy** | Que los Gateways usen SKUs con sufijo `AZ` |
| 3 | **GatewayTransit-Hub** | Que `AllowGatewayTransit=True` en el lado Hub del peering |
| 3b | **GatewayTransit-Spoke** | Que `UseRemoteGateways=True` en el lado Spoke del peering |
| 4 | **ForwardedTraffic** | Que `AllowForwardedTraffic=True` para enrutamiento transitivo |
| 5 | **Firewall-ZoneRedundancy** | Que Azure Firewall esté desplegado en 2+ zonas |

### Ejemplo de Output en Consola

```
[14:32:01] [INFO] ═══════════════════════════════════════════════════════════
[14:32:01] [INFO]   OBJETIVO A — Evaluación de Mejores Prácticas
[14:32:01] [INFO] ═══════════════════════════════════════════════════════════

[14:32:01] [INFO] [CHECK 1] Validando que Spokes solo conecten al Hub...
[14:32:01] [OK]     ✓ spoke-app1-vnet → hub-core-vnet: OK (Hub)
[14:32:01] [OK]     ✓ spoke-data-vnet → hub-core-vnet: OK (Hub)
[14:32:01] [ERROR]  ✗ spoke-dev-vnet → spoke-test-vnet: Peering Spoke-to-Spoke

[14:32:02] [INFO] [CHECK 2] Validando Zone Redundancy en Gateways...
[14:32:02] [OK]     ✓ hub-er-gateway: SKU ErGw2AZ — Zone Redundant
[14:32:02] [ERROR]  ✗ hub-vpn-gateway: SKU VpnGw1 — SIN Zone Redundancy

[14:32:02] [INFO] [CHECK 3] Validando configuración de Gateway Transit...
[14:32:02] [OK]     ✓ Hub hub-core-vnet → spoke-app1-vnet: AllowGatewayTransit=True
[14:32:02] [ERROR]  ✗ Hub hub-core-vnet → spoke-data-vnet: AllowGatewayTransit=False
[14:32:02] [OK]     ✓ Spoke spoke-app1-vnet: UseRemoteGateways=True
[14:32:02] [ERROR]  ✗ Spoke spoke-data-vnet: UseRemoteGateways=False

[14:32:03] [INFO] ═══════════════════════════════════════════════════════════
[14:32:03] [INFO]   RESUMEN: 4 PASS | 4 FAIL | 1 WARNINGS
[14:32:03] [INFO] ═══════════════════════════════════════════════════════════
```

---

## Ejemplo de Diagrama Mermaid Generado

El siguiente es un ejemplo representativo del output que genera el script para una
arquitectura Hub & Spoke típica con 3 Spokes, ExpressRoute, VPN, Firewall y DNS Resolver.

Pegar este bloque en [mermaid.live](https://mermaid.live) para visualizar.

```mermaid
graph TD

    %% Azure Hub and Spoke - Diagrama Auto-Generado

    classDef hubStyle fill:#1a73e8,stroke:#0d47a1,stroke-width:3px,color:#fff
    classDef spokeStyle fill:#34a853,stroke:#1b5e20,stroke-width:2px,color:#fff
    classDef fwStyle fill:#ea4335,stroke:#b71c1c,stroke-width:2px,color:#fff
    classDef gwStyle fill:#fbbc04,stroke:#f57f17,stroke-width:2px,color:#000
    classDef dnsStyle fill:#9c27b0,stroke:#4a148c,stroke-width:2px,color:#fff
    classDef onpremStyle fill:#607d8b,stroke:#263238,stroke-width:2px,color:#fff

    ONPREM[/"On-Premises Datacenter"/]:::onpremStyle

    subgraph hub_core_vnet_sub["HUB: hub-core-vnet"]
        direction TB
        hub_core_vnet["hub-core-vnet<br/>10.0.0.0/16<br/>eastus2"]:::hubStyle

        hub_azfw["hub-azfw-premium<br/>Tier: Premium<br/>IP: 10.0.1.4<br/>Zonas: 1, 2, 3"]:::fwStyle
        hub_core_vnet --- hub_azfw

        hub_er_gw["hub-er-gateway<br/>ExpressRoute<br/>SKU: ErGw2AZ<br/>AZ: Yes"]:::gwStyle
        hub_core_vnet --- hub_er_gw

        hub_vpn_gw["hub-vpn-gateway<br/>VPN Gateway<br/>SKU: VpnGw1<br/>AZ: No"]:::gwStyle
        hub_core_vnet --- hub_vpn_gw

        hub_dns["hub-dns-resolver<br/>DNS Private Resolver"]:::dnsStyle
        hub_core_vnet --- hub_dns
    end

    ONPREM ==>|ExpressRoute| hub_er_gw
    ONPREM -.->|VPN IPSec| hub_vpn_gw

    subgraph spoke_app1_vnet_sub["SPOKE: spoke-app1-vnet"]
        spoke_app1_vnet["spoke-app1-vnet<br/>10.1.0.0/16<br/>eastus2"]:::spokeStyle
        spoke_app1_vnet_frontend["snet-frontend<br/>10.1.1.0/24"]
        spoke_app1_vnet --- spoke_app1_vnet_frontend
        spoke_app1_vnet_backend["snet-backend<br/>10.1.2.0/24"]
        spoke_app1_vnet --- spoke_app1_vnet_backend
        spoke_app1_vnet_pe["snet-privateendpoints<br/>10.1.3.0/24"]
        spoke_app1_vnet --- spoke_app1_vnet_pe
    end

    subgraph spoke_data_vnet_sub["SPOKE: spoke-data-vnet"]
        spoke_data_vnet["spoke-data-vnet<br/>10.2.0.0/16<br/>eastus2"]:::spokeStyle
        spoke_data_vnet_sql["snet-sql-mi<br/>10.2.1.0/24"]
        spoke_data_vnet --- spoke_data_vnet_sql
        spoke_data_vnet_databricks["snet-databricks<br/>10.2.2.0/24"]
        spoke_data_vnet --- spoke_data_vnet_databricks
    end

    subgraph spoke_dev_vnet_sub["SPOKE: spoke-dev-vnet"]
        spoke_dev_vnet["spoke-dev-vnet<br/>10.3.0.0/16<br/>eastus2"]:::spokeStyle
        spoke_dev_vnet_aks["snet-aks<br/>10.3.0.0/22"]
        spoke_dev_vnet --- spoke_dev_vnet_aks
    end

    hub_core_vnet <-->|GW Transit, Use Remote GW| spoke_app1_vnet
    hub_core_vnet <-->|GW Transit| spoke_data_vnet
    hub_core_vnet <-->|GW Transit, Use Remote GW| spoke_dev_vnet
    spoke_dev_vnet -.->|S2S: Spoke-to-Spoke| spoke_app1_vnet
```

---

## Lógica de Clasificación Hub vs Spoke

El script clasifica automáticamente las VNets usando esta heurística:

**Una VNet es HUB si cumple al menos uno de estos criterios:**
1. Contiene un `GatewaySubnet` con un Gateway desplegado (ExpressRoute o VPN)
2. Contiene un `AzureFirewallSubnet` con un Azure Firewall
3. Tiene `AllowGatewayTransit = True` en al menos un peering

**Una VNet es SPOKE si:**
- No cumple ningún criterio de Hub
- Está conectada vía peering a una VNet clasificada como Hub

---

## Integración en Pipelines

### Azure DevOps (YAML)

```yaml
trigger:
  schedules:
    - cron: "0 6 * * 1"           # Cada lunes a las 6:00 AM
      branches:
        include: [main]

pool:
  vmImage: 'ubuntu-latest'

steps:
  - task: AzurePowerShell@5
    displayName: 'Hub & Spoke Audit'
    inputs:
      azureSubscription: 'my-service-connection'
      ScriptPath: '$(Build.SourcesDirectory)/Discover-HubSpoke.ps1'
      azurePowerShellVersion: 'LatestVersion'

  - publish: $(System.DefaultWorkingDirectory)/hub-spoke-output
    artifact: NetworkAuditReport
```

### GitHub Actions

```yaml
on:
  schedule:
    - cron: '0 6 * * 1'

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Run Audit
        shell: pwsh
        run: ./Discover-HubSpoke.ps1
      - uses: actions/upload-artifact@v4
        with:
          name: network-audit
          path: hub-spoke-output/
```

# Seguridad del Repositorio — Guía de Referencia

## Estructura de Archivos de Protección

```
repo/
├── .gitignore                  ← Qué archivos nunca entran a git
├── .gitleaks.toml              ← Qué patrones de texto son secretos
├── .pre-commit-config.yaml     ← Hooks que bloquean antes del commit
├── .env.example                ← Plantilla segura (sin valores reales)
└── .github/
    └── workflows/
        └── security-scan.yml   ← Escaneo en cada PR (ver abajo)
```

## Qué Datos Sensibles Genera el Script

| Dato | Dónde aparece | Riesgo si se filtra |
|---|---|---|
| Subscription IDs | CSVs, .mmd, logs | Permite enumerar recursos con herramientas como `az resource list` |
| Tenant ID | Contexto Az, logs | Facilita ataques de phishing dirigido y enumeración de usuarios |
| Resource Group names | Todos los CSVs | Revela convención de nombres y estructura organizacional |
| VNet names + CIDRs | inventory-vnets.csv, .mmd | Mapa completo de la red interna para reconocimiento |
| IPs privadas de Firewall | inventory-firewalls.csv, .mmd | Objetivo directo para movimiento lateral |
| IPs públicas de Gateways | inventory-gateways.csv | Superficie de ataque externa directa |
| SKUs de Gateways | CSVs, .mmd | Revela capacidades y posibles limitaciones de throughput |
| Peering state + config | inventory-peerings.csv | Muestra rutas transitivas y posibles bypasses |
| Nombres de subnets | inventory-subnets.csv | Revela propósito de cada segmento (SQL, AKS, etc.) |

## Capas de Defensa

### Capa 1 — `.gitignore` (preventiva)

Bloquea que los archivos completos entren al staging area de git.

```bash
# Verificar que funciona antes de hacer commit
git status          # No debería mostrar archivos de hub-spoke-output/
git check-ignore -v hub-spoke-output/best-practices-report.csv   # Debería confirmar la regla
```

### Capa 2 — `pre-commit` hooks (detectiva)

Escanea el contenido de los archivos que sí están en staging. Atrapa secretos que terminen en archivos no ignorados, como un Subscription ID que alguien haya pegado en el README.

```bash
# Instalación única
pip install pre-commit
pre-commit install

# Prueba manual
pre-commit run --all-files
```

### Capa 3 — `.gitleaks.toml` (detectiva, patrones Azure)

Reglas personalizadas que entienden patrones específicos del output de este script, como Resource IDs completos o IPs privadas en contexto de configuración.

```bash
# Ejecutar manualmente
gitleaks detect --config .gitleaks.toml --source .
```

### Capa 4 — GitHub Actions (CI/CD)

Escaneo automático en cada Pull Request como última línea de defensa.

```yaml
# .github/workflows/security-scan.yml
name: Secret Scanning
on: [pull_request]

jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Qué Archivos SÍ Son Seguros Para el Repo

| Archivo | Por qué es seguro |
|---|---|
| `Discover-HubSpoke.ps1` | Es código, no contiene datos reales |
| `README-HubSpoke.md` | Ejemplo con datos ficticios |
| `example-topology.mermaid` | Diagrama con datos ficticios |
| `.env.example` | Plantilla vacía sin valores |
| `.gitignore`, `.gitleaks.toml`, etc. | Configuración de seguridad |

## Verificación Post-Setup

```bash
# 1. Ejecutar el script para generar output real
./Discover-HubSpoke.ps1

# 2. Verificar que git ignora todo el output
git status
# No debería aparecer ningún archivo de hub-spoke-output/

# 3. Forzar intento de agregar un CSV (debe fallar)
git add hub-spoke-output/best-practices-report.csv
# fatal: pathspec matches ignored file

# 4. Escaneo completo de secretos
pre-commit run --all-files
gitleaks detect --config .gitleaks.toml --source .
```

## Si Ya Se Subió Información Sensible

Si accidentalmente ya hiciste push de datos sensibles, eliminarlos del HEAD no es suficiente porque quedan en el historial de git.

```bash
# Opción 1: BFG Repo-Cleaner (más rápido)
bfg --delete-files '*.csv' --no-blob-protection
git reflog expire --expire=now --all
git gc --prune=now --aggressive
git push --force

# Opción 2: git-filter-repo
git filter-repo --path hub-spoke-output/ --invert-paths

# Después de limpiar: ROTAR CREDENCIALES
# - Regenerar Service Principal secrets
# - Rotar claves de Storage Account si se expusieron
# - Revisar Azure Activity Log por accesos no autorizados
```

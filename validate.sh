#!/bin/bash

# -----------------------------------------------------------------------------
# Script: validate.sh
# Propósito: Validar Pull Request (Linting, Análisis Estático, Validación de Despliegue)
# -----------------------------------------------------------------------------

set -o pipefail

# --- Colores e Iconos ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
ICON_OK="✅"
ICON_ERR="❌"
ICON_WARN="⚠️ "
ICON_INFO="ℹ️ "
ICON_RUN="🚀"

# --- Código de salida global para rastrear fallos no fatales ---
EXIT_CODE=0

# --- Cargar Variables de Entorno ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Asignar defaults seguros si las variables no fueron definidas (ni por .env ni por entorno)
ALIAS_DEFAULT="${ALIAS_DEFAULT:-""}"
TARGET_DEFAULT="${TARGET_DEFAULT:-"develop"}"

PATH_DIFF="${PATH_DIFF:-"diff.txt"}"
PATH_PMD_LIST="${PATH_PMD_LIST:-"pmd.txt"}"
PATH_JS_LIST="${PATH_JS_LIST:-"js.txt"}"
PATH_RESULTS="${PATH_RESULTS:-"results.txt"}"

PATH_PMD_RULES="${PATH_PMD_RULES:-"pmd-rules.xml"}"
TEST_CLASS_FILE="${TEST_CLASS_FILE:-"unitTest.txt"}"

CMD_ESLINT="${CMD_ESLINT:-"npx eslint"}"

# --- Variables Globales ---
VERBOSE=false
DISCARD=false
DRY_RUN=false
TARGET_BRANCH="$TARGET_DEFAULT"
SF_ALIAS="$ALIAS_DEFAULT"
PROJECT_ROOT="$(pwd)"
CURRENT_STEP=0
TOTAL_STEPS=7

# --- Funciones de Utilidad ---

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${BLUE}=============================================================${NC}"
    echo -e "${BLUE}${ICON_RUN} Paso $CURRENT_STEP: $1${NC}"
    echo -e "${BLUE}=============================================================${NC}"
}

log_info() {
    echo -e "${CYAN}${ICON_INFO} $1${NC}"
}

log_success() {
    echo -e "${GREEN}${ICON_OK} $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}${ICON_WARN} $1${NC}"
}

log_error() {
    echo -e "${RED}${ICON_ERR} $1${NC}"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}[VERBOSE] $1${NC}"
    fi
}

show_help() {
    echo -e "${GREEN}Uso: validate.sh [opciones]${NC}"
    echo ""
    echo "Opciones:"
    echo "  --target=<rama>   Rama destino (Ej: fullcopy_branch). Por defecto: $TARGET_DEFAULT"
    echo "  --alias=<alias>   Alias de Salesforce Org (Ej: fullcopy). Por defecto: $ALIAS_DEFAULT"
    echo "  --discard         Elimina los archivos temporales generados al finalizar (pmd-list, diff, etc)."
    echo "  --dry-run         Ejecuta análisis estático pero omite el despliegue a Salesforce."
    echo "  --verbose         Muestra salida detallada de los comandos."
    echo "  -h, --help        Muestra esta ayuda."
    echo ""
    echo "Ejemplo:"
    echo "  ./validate.sh --target=uat --alias=uat_sandbox --discard --verbose"
    echo "  ./validate.sh --target=uat --dry-run    # Solo linting, sin deploy"
    exit 0
}

# --- Procesamiento de Parámetros ---

while [ $# -gt 0 ]; do
    case "$1" in
        --target=*)
            TARGET_BRANCH="${1#*=}"
            ;;
        --alias=*)
            SF_ALIAS="${1#*=}"
            ;;
        --discard)
            DISCARD=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --verbose)
            VERBOSE=true
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Parámetro desconocido: $1"
            show_help
            ;;
    esac
    shift
done



# --- Trap para limpieza en caso de error o interrupción ---
cleanup() {
    local exit_status=$?
    if [ "$DISCARD" = true ]; then
        rm -f "$PATH_DIFF" "$PATH_PMD_LIST" "$PATH_JS_LIST"
        rm -rf package destructiveChanges
    fi
    if [ "$exit_status" -ne 0 ] && [ "$exit_status" -ne "$EXIT_CODE" ]; then
        log_error "Script interrumpido con código de salida: $exit_status"
    fi
}
trap cleanup EXIT

# Limpiar archivo de resultados previo
echo "Resumen de Validación de Código" > "$PATH_RESULTS"
echo "Generado el: $(date)" >> "$PATH_RESULTS"
echo "-----------------------------" >> "$PATH_RESULTS"

# --- INICIO DEL SCRIPT ---

# 1. Validación de Dependencias y Git
log_step "Validando entorno y dependencias..."

# Git Project check
if [ ! -d ".git" ]; then
    log_error "Este directorio no es un proyecto git."
    exit 1
fi

# Verificar existencia de un comando. Segundo argumento indica si es obligatorio.
check_cmd() {
    local cmd="$1"
    local required="${2:-false}"
    if ! command -v "$cmd" &> /dev/null; then
        if [ "$required" = true ]; then
            log_error "$cmd no está instalado. Por favor instálalo."
            exit 1
        else
            log_warn "Herramienta $cmd no encontrada en PATH. Pasos que la requieran podrían fallar."
        fi
    else
        log_verbose "$cmd detectado."
    fi
}

check_cmd git true
check_cmd npm true
check_cmd sf true
check_cmd jq false
check_cmd pmd false

# Instalar sfdx-git-delta si no existe (Check plugin list)
if ! sf plugins inspect sfdx-git-delta &> /dev/null; then
    log_info "Instalando plugin sfdx-git-delta..."
    echo y | sf plugins install sfdx-git-delta
else
    log_verbose "Plugin sfdx-git-delta ya instalado."
fi


# 2. Git Operations
log_step "Operaciones de Git: Analizando diferencias..."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log_info "Rama Actual: $CURRENT_BRANCH"
log_info "Rama Destino: origin/$TARGET_BRANCH"

# Fetch para tener últimas referencias (solo origin, no todos los remotos)
log_info "Actualizando referencias (git fetch origin)..."
if [ "$VERBOSE" = true ]; then
    git fetch origin
else
    git fetch origin &> /dev/null
fi

# Validar si la rama remota existe
if ! git show-ref --verify --quiet refs/remotes/origin/"$TARGET_BRANCH"; then
    log_error "La rama destino origin/$TARGET_BRANCH no existe."
    exit 1
fi

# Obtener diferencias (Archivos modificados entre el HEAD actual y el destino remoto)
# Usamos git diff con ... para encontrar el ancestro común
# Se usa --name-status para detectar eliminados (D) y renombrados (R)
git diff --name-status "origin/$TARGET_BRANCH...HEAD" > "$PATH_DIFF"

NUM_DIFF=$(wc -l < "$PATH_DIFF")

if [ "$NUM_DIFF" -eq 0 ]; then
    log_info "No se encontraron archivos modificados. Finalizando proceso."
    exit 0
fi

log_success "Se encontraron $NUM_DIFF archivos modificados."
log_verbose "Archivos guardados en $PATH_DIFF"


# 3. Filtrado de Archivos y Análisis PMD
log_step "Análisis estático de Apex (PMD)..."

# Filtrar Clases
# Lógica:
# 1. Ignorar si el status (columna 1) empieza con 'D' (Deleted)
# 2. Si empieza con 'R' (Renamed), tomar la columna 3 (nuevo path)
# 3. En otros casos (M, A), tomar la columna 2
# 4. Filtrar que termine en .cls
awk '$1 !~ /^D/ { if ($1 ~ /^R/) print $3; else print $2 }' "$PATH_DIFF" | grep -E ".*\.cls$" > "$PATH_PMD_LIST" || true
COUNT_CLS=$(wc -l < "$PATH_PMD_LIST")

if [ "$COUNT_CLS" -gt 0 ]; then
    log_info "Analizando $COUNT_CLS clases de Apex..."
    
    echo -e "\n\n### REPORTES PMD (APEX) ###\n" >> "$PATH_RESULTS"

    # Verificar que el archivo de reglas PMD exista
    if [ ! -f "$PATH_PMD_RULES" ]; then
        log_error "Archivo de reglas PMD no encontrado: $PATH_PMD_RULES"
        echo "ERROR: Archivo de reglas PMD no encontrado: $PATH_PMD_RULES" >> "$PATH_RESULTS"
        EXIT_CODE=1
    else
        # Ejecutar PMD sin eval — usando argumentos directos
        PMD_EXIT=0
        if [ "$VERBOSE" = true ]; then
            pmd check "-R=$PATH_PMD_RULES" "--file-list=$PATH_PMD_LIST" --no-cache --no-progress --show-suppressed \
                | tee -a "$PATH_RESULTS" || PMD_EXIT=$?
        else
            pmd check "-R=$PATH_PMD_RULES" "--file-list=$PATH_PMD_LIST" --no-cache --no-progress --show-suppressed \
                >> "$PATH_RESULTS" 2>&1 || PMD_EXIT=$?
        fi

        if [ "$PMD_EXIT" -ne 0 ]; then
            log_warn "PMD reportó violaciones (exit code: $PMD_EXIT). Revisa $PATH_RESULTS para detalles."
            EXIT_CODE=1
        else
            log_success "Análisis PMD completado sin violaciones."
        fi
    fi
else
    log_info "No se encontraron archivos .cls modificados."
    echo -e "\n\n### REPORTES PMD ###\nSin cambios en Apex." >> "$PATH_RESULTS"
fi


# 4. Linting JS (ESLint)
log_step "Linting de Javascript (ESLint)..."

# Filtrar JS (Ignorar standard objects u otros si es necesario, aquí agarramos todo .js)
# Misma lógica que para Apex
awk '$1 !~ /^D/ { if ($1 ~ /^R/) print $3; else print $2 }' "$PATH_DIFF" | grep -E ".*\.js$" > "$PATH_JS_LIST" || true
COUNT_JS=$(wc -l < "$PATH_JS_LIST")

if [ "$COUNT_JS" -gt 0 ]; then
    log_info "Analizando $COUNT_JS archivos JS..."
    echo -e "\n\n### REPORTES ESLINT (JS) ###\n" >> "$PATH_RESULTS"
    
    # Usar xargs para manejar correctamente archivos con espacios u otros caracteres especiales
    ESLINT_EXIT=0
    if [ "$VERBOSE" = true ]; then
        xargs $CMD_ESLINT < "$PATH_JS_LIST" | tee -a "$PATH_RESULTS" || ESLINT_EXIT=$?
    else
        xargs $CMD_ESLINT < "$PATH_JS_LIST" >> "$PATH_RESULTS" 2>&1 || ESLINT_EXIT=$?
    fi

    if [ "$ESLINT_EXIT" -ne 0 ]; then
        log_warn "ESLint reportó problemas (exit code: $ESLINT_EXIT). Revisa $PATH_RESULTS para detalles."
        EXIT_CODE=1
    else
        log_success "Análisis ESLint completado sin errores."
    fi
else
    log_info "No se encontraron archivos .js modificados."
    echo -e "\n\n### REPORTES ESLINT ###\nSin cambios en JS." >> "$PATH_RESULTS"
fi


# 5. Formatear archivos con Prettier
log_step "Formateando archivos con Prettier..."

PRETTIER_FILES=()
if [ -f "$PATH_JS_LIST" ] && [ "$(wc -l < "$PATH_JS_LIST")" -gt 0 ]; then
    while IFS= read -r line; do
        PRETTIER_FILES+=("$line")
    done < "$PATH_JS_LIST"
fi
if [ -f "$PATH_PMD_LIST" ] && [ "$(wc -l < "$PATH_PMD_LIST")" -gt 0 ]; then
    while IFS= read -r line; do
        PRETTIER_FILES+=("$line")
    done < "$PATH_PMD_LIST"
fi

if [ "${#PRETTIER_FILES[@]}" -gt 0 ]; then
    log_info "Formateando ${#PRETTIER_FILES[@]} archivos con Prettier..."
    PRETTIER_EXIT=0
    if [ "$VERBOSE" = true ]; then
        npx prettier --write "${PRETTIER_FILES[@]}" || PRETTIER_EXIT=$?
    else
        npx prettier --write "${PRETTIER_FILES[@]}" >> "$PATH_RESULTS" 2>&1 || PRETTIER_EXIT=$?
    fi

    if [ "$PRETTIER_EXIT" -ne 0 ]; then
        log_warn "Prettier reportó problemas (exit code: $PRETTIER_EXIT). Revisa $PATH_RESULTS para detalles."
        EXIT_CODE=1
    else
        log_success "Formateo con Prettier completado exitosamente."
    fi
else
    log_info "No se encontraron archivos .js o .cls para formatear con Prettier."
fi


# 6. Validación de Despliegue (Git Delta + SF)
log_step "Generando Delta y Validando Despliegue en Salesforce..."

if [ "$DRY_RUN" = true ]; then
    log_info "Modo --dry-run activo. Omitiendo generación de delta y despliegue a Salesforce."
else
    # Calcular merge-base de forma segura
    MERGE_BASE=""
    MERGE_BASE=$(git merge-base HEAD "origin/$TARGET_BRANCH" 2>/dev/null) || true

    if [ -z "$MERGE_BASE" ]; then
        log_error "No se pudo calcular el ancestro común (merge-base) entre HEAD y origin/$TARGET_BRANCH."
        log_error "Verifica que ambas ramas compartan historial."
        EXIT_CODE=1
    else
        log_verbose "Merge-base calculado: $MERGE_BASE"

        # Usar plugin sgd para generar package.xml incremental
        log_info "Generando package.xml incremental..."

        if [ "$VERBOSE" = true ]; then
            sf sgd source delta --to HEAD --from "$MERGE_BASE" --output-dir=.
        else
            sf sgd source delta --to HEAD --from "$MERGE_BASE" --output-dir=. &> /dev/null
        fi

        # Verificar que el manifiesto se haya generado correctamente
        if [ ! -f "package/package.xml" ]; then
            log_error "No se generó package/package.xml. El plugin sgd pudo haber fallado."
            EXIT_CODE=1
        fi

        if [ -f "package/package.xml" ] && [ -n "$SF_ALIAS" ]; then
            log_info "Iniciando Validación contra la Org: $SF_ALIAS"
            log_verbose "Usando manifiesto: package/package.xml"

            # Leer archivo de tests si está configurado
            TESTS=""
            if [ -n "$TEST_CLASS_FILE" ]; then
                if [ -f "$TEST_CLASS_FILE" ]; then
                    log_info "Leyendo clases de test desde $TEST_CLASS_FILE..."
                    # Extraer nombres de clases entre Apex::[ y ]::Apex
                    TESTS=$(grep -o "Apex::\[[^]]*\]::Apex" "$TEST_CLASS_FILE" | sed 's/Apex::\[//; s/\]::Apex//' | tr '\n' ' ' | xargs)
                    
                    if [ -n "$TESTS" ]; then
                        log_success "Tests identificados: $TESTS"
                    else
                        log_warn "No se encontraron tests con el formato Apex::[Nombre]::Apex en $TEST_CLASS_FILE"
                    fi
                else
                    log_warn "El archivo de tests configurado ($TEST_CLASS_FILE) no fue encontrado."
                fi
            fi

            # Construir comando de deploy según si hay tests o no
            if [ -z "$TESTS" ]; then
                log_warn "No se especificaron tests. Usando --test-level=NoTestRun en lugar de RunSpecifiedTests."
                SF_DEPLOY_CMD=(sf project deploy validate "--target-org=$SF_ALIAS" "--manifest=package/package.xml" "--test-level=NoTestRun")
            else
                SF_DEPLOY_CMD=(sf project deploy validate "--target-org=$SF_ALIAS" "--manifest=package/package.xml" "--test-level=RunSpecifiedTests" "--tests=$TESTS")
            fi

            log_verbose "Comando: ${SF_DEPLOY_CMD[*]}"

            DEPLOY_EXIT=0
            "${SF_DEPLOY_CMD[@]}" || DEPLOY_EXIT=$?

            if [ "$DEPLOY_EXIT" -eq 0 ]; then
                log_success "Validación de despliegue EXITOSA."
            else
                log_error "La validación de despliegue falló (exit code: $DEPLOY_EXIT)."
                log_error "Comando ejecutado: ${SF_DEPLOY_CMD[*]}"
                EXIT_CODE=1
            fi
        elif [ -f "package/package.xml" ]; then
            log_info "No se proporcionó alias de Salesforce (--alias). Omitiendo validación de despliegue."
        fi
    fi
fi


# --- Finalización ---
echo ""
echo -e "${BLUE}=============================================================${NC}"
if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}${ICON_OK} Proceso completado exitosamente.${NC}"
else
    echo -e "${YELLOW}${ICON_WARN} Proceso completado con advertencias o errores (código: $EXIT_CODE).${NC}"
fi
echo -e "Resultados de análisis estático guardados en: ${YELLOW}$PATH_RESULTS${NC}"
if [ "$DISCARD" = true ]; then
    log_info "Los archivos temporales serán limpiados automáticamente al salir (--discard)."
fi
echo -e "${BLUE}=============================================================${NC}"

# La limpieza se ejecuta automáticamente vía trap EXIT
exit "$EXIT_CODE"
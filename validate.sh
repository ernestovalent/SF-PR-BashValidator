#!/bin/bash

# -----------------------------------------------------------------------------
# Script: pr-validate
# Propósito: Validar Pull Request (Linting, Análisis Estático, Validación de Despliegue)
# -----------------------------------------------------------------------------

# --- Colores e Iconos ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
ICON_OK="✅"
ICON_ERR="❌"
ICON_WARN="⚠️"
ICON_INFO="ℹ️ "
ICON_RUN="🚀"

# --- Cargar Variables de Entorno ---
if [ -f .env ]; then
    source .env
else
    echo -e "${YELLOW}${ICON_WARN} Archivo .env no encontrado. Usando valores internos por defecto.${NC}"
    # Configuración por defecto para pr-validate
    ALIAS_DEFAULT="sandbox"
    TARGET_DEFAULT="develop"
    # Rutas de archivos temporales
    PATH_PMD_LIST="pmd-clases.txt"
    PATH_JS_LIST="js-scripts.txt"
    PATH_DIFF="diff.txt"
    PATH_RESULTS="results.txt"
    # Configuración por defecto de PMD
    PATH_PMD_RULES="apex-rules.xml"
    # Rutas o Comandos base
    CMD_PMD="pmd"
    CMD_ESLINT="npx eslint"
fi

# --- Variables Globales ---
VERBOSE=false
DISCARD=false
TARGET_BRANCH="$TARGET_DEFAULT"
SF_ALIAS="$ALIAS_DEFAULT"
PROJECT_ROOT=$(pwd)
CURRENT_STEP=0
TOTAL_STEPS=5

# --- Funciones de Utilidad ---

function log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${BLUE}=============================================================${NC}"
    echo -e "${BLUE}${ICON_RUN} Paso $CURRENT_STEP: $1${NC}"
    echo -e "${BLUE}=============================================================${NC}"
}

function log_info() {
    echo -e "${CYAN}${ICON_INFO} $1${NC}"
}

function log_success() {
    echo -e "${GREEN}${ICON_OK} $1${NC}"
}

function log_error() {
    echo -e "${RED}${ICON_ERR} $1${NC}"
}

function log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}[VERBOSE] $1${NC}"
    fi
}

function show_help() {
    echo -e "${GREEN}Uso: pr-validate [opciones]${NC}"
    echo ""
    echo "Opciones:"
    echo "  --target=<rama>   Rama destino (Ej: fullcopy_branch). Por defecto: $TARGET_DEFAULT"
    echo "  --alias=<alias>   Alias de Salesforce Org (Ej: fullcopy). Por defecto: $ALIAS_DEFAULT"
    echo "  --discard         Elimina los archivos temporales generados al finalizar (pmd-list, diff, etc)."
    echo "  --verbose         Muestra salida detallada de los comandos."
    echo "  -h, --help        Muestra esta ayuda."
    echo ""
    echo "Ejemplo:"
    echo "  ./pr-validate.sh --target=uat --alias=uat_sandbox --discard --verbose"
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

if [ -z "$SF_ALIAS" ]; then
    log_error "El Alias de la Org es obligatorio. Define ALIAS_DEFAULT en .env o usa --alias"
    exit 1
fi

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

# Function to check command existence
check_cmd() {
    if ! command -v "$1" &> /dev/null; then
        if [ "$1" == "npm" ] || [ "$1" == "git" ]; then
             log_error "$1 no está instalado. Por favor instálalo."
             exit 1
        else 
            log_info "Herramienta $1 no encontrada en PATH, se intentará ejecución local o reportar error."
        fi
    else
        log_verbose "$1 detectado."
    fi
}

check_cmd git
check_cmd npm
check_cmd sf
check_cmd $CMD_PMD

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

# Fetch para tener últimas referencias
log_info "Actualizando referencias (git fetch)..."
if [ "$VERBOSE" = true ]; then
    git fetch --all
else
    git fetch --all &> /dev/null
fi

# Validar si la rama remota existe
if ! git show-ref --verify --quiet refs/remotes/origin/"$TARGET_BRANCH"; then
    log_error "La rama destino origin/$TARGET_BRANCH no existe."
    exit 1
fi

# Obtener diferencias (Archivos modificados entre el HEAD actual y el destino remoto)
# Usamos git diff con ... para encontrar el ancestro común
git diff --name-only "origin/$TARGET_BRANCH...HEAD" > "$PATH_DIFF"

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
grep -E ".*\.cls$" "$PATH_DIFF" > "$PATH_PMD_LIST" || true
COUNT_CLS=$(wc -l < "$PATH_PMD_LIST")

if [ "$COUNT_CLS" -gt 0 ]; then
    log_info "Analizando $COUNT_CLS clases de Apex..."
    
    echo -e "\n\n### REPORTES PMD (APEX) ###\n" >> "$PATH_RESULTS"

    PMD_CMD="$CMD_PMD check -d . -R \"$PATH_PMD_RULES\" --file-list \"$PATH_PMD_LIST\" --no-cache --no-progress"
    
    if [ "$VERBOSE" = true ]; then
        # Ejecutar y mostrar en pantalla, además de guardar en results
        # Nota: PMD retorna exit code != 0 si hay violaciones, permitimos que continúe
        eval "$PMD_CMD" | tee -a "$PATH_RESULTS" || true
    else
        eval "$PMD_CMD" >> "$PATH_RESULTS" 2>&1 || true
    fi
    log_success "Análisis PMD completado."
else
    log_info "No se encontraron archivos .cls modificados."
    echo -e "\n\n### REPORTES PMD ###\nSin cambios en Apex." >> "$PATH_RESULTS"
fi


# 4. Linting JS (ESLint)
log_step "Linting de Javascript (ESLint)..."

# Filtrar JS (Ignorar standard objects u otros si es necesario, aquí agarramos todo .js)
grep -E ".*\.js$" "$PATH_DIFF" > "$PATH_JS_LIST" || true
COUNT_JS=$(wc -l < "$PATH_JS_LIST")

if [ "$COUNT_JS" -gt 0 ]; then
    log_info "Analizando $COUNT_JS archivos JS..."
    echo -e "\n\n### REPORTES ESLINT (JS) ###\n" >> "$PATH_RESULTS"
    
    # Leer lista y ejecutar eslint por archivo o por lista
    # ESLint generalmente acepta archivos como argumentos.
    # Usamos tr para convertir nuevas lineas en espacios para pasarlo como args
    JS_FILES=$(tr '\n' ' ' < "$PATH_JS_LIST")
    
    ESLINT_RUN="$CMD_ESLINT $JS_FILES"

    if [ "$VERBOSE" = true ]; then
        $ESLINT_RUN | tee -a "$PATH_RESULTS" || true
    else
        $ESLINT_RUN >> "$PATH_RESULTS" 2>&1 || true
    fi
    log_success "Análisis ESLint completado."
else
    log_info "No se encontraron archivos .js modificados."
    echo -e "\n\n### REPORTES ESLINT ###\nSin cambios en JS." >> "$PATH_RESULTS"
fi


# 5. Validación de Despliegue (Git Delta + SF)
log_step "Generando Delta y Validando Despliegue en Salesforce..."

# Generar carpeta de salida para delta
DELTA_OUTPUT="deploy_delta"
mkdir -p "$DELTA_OUTPUT"

# Usar plugin sgd
# "origin/$TARGET_BRANCH" es el "from" (estado estable) y "HEAD" es el "to" (estado propuesto)
log_info "Generando package.xml incremental..."

SGD_CMD="sf sgd source delta --to HEAD --from origin/$TARGET_BRANCH --output $DELTA_OUTPUT --generate-delta"

if [ "$VERBOSE" = true ]; then
    $SGD_CMD
else
    $SGD_CMD &> /dev/null
fi

MANIFEST_PATH="$DELTA_OUTPUT/package/package.xml"

if [ -f "$MANIFEST_PATH" ]; then
    # Chequear si package.xml tiene contenido real (a veces SGD genera xml vacio si solo hay cambios en archivos ignorados)
    # Una forma simple es intentar deploy validate, si está vacio SF avisará.
    
    log_info "Iniciando Validación contra la Org: $SF_ALIAS"
    log_verbose "Usando manifiesto: $MANIFEST_PATH"

    # Validate only
    SF_DEPLOY_CMD="sf project deploy validate --manifest \"$MANIFEST_PATH\" --target-org \"$SF_ALIAS\" --wait 30"

    if [ "$VERBOSE" = true ]; then
         $SF_DEPLOY_CMD
    else
         # Mostramos salida en vivo pero filtrada o solo resultado final. 
         # Si no es verbose, dejamos que sf muestre su output standard de progreso
         $SF_DEPLOY_CMD
    fi
    
    if [ $? -eq 0 ]; then
        log_success "Validación de despliegue EXITOSA."
    else
        log_error "La validación de despliegue falló."
    fi

else
    log_info "No se generó un package.xml válido o no hubo diferencias desplegables detectadas por SGD."
fi


# --- Finalización y Limpieza ---
echo ""
if [ "$DISCARD" = true ]; then
    log_info "Limpiando archivos temporales (--discard)..."
    rm -f "$PATH_DIFF" "$PATH_PMD_LIST" "$PATH_JS_LIST"
    rm -rf "$DELTA_OUTPUT"
fi

echo -e "${BLUE}=============================================================${NC}"
echo -e "${GREEN}${ICON_OK} Proceso completado.${NC}"
echo -e "Resultados de análisis estático guardados en: ${YELLOW}$PATH_RESULTS${NC}"
echo -e "${BLUE}=============================================================${NC}"

exit 0
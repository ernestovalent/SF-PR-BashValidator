#!/bin/bash

# -----------------------------------------------------------------------------
# Script: mergeXml.sh
# Propósito: Fusionar N archivos package.xml de Salesforce en uno solo
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

# --- Funciones de Utilidad ---

log_info() {
    echo -e "${CYAN}${ICON_INFO} $1${NC}" >&2
}

log_success() {
    echo -e "${GREEN}${ICON_OK} $1${NC}" >&2
}

log_warn() {
    echo -e "${YELLOW}${ICON_WARN} $1${NC}" >&2
}

log_error() {
    echo -e "${RED}${ICON_ERR} $1${NC}" >&2
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}[VERBOSE] $1${NC}" >&2
    fi
}

show_help() {
    echo -e "${GREEN}Uso: mergeXml.sh [opciones] <archivo1.xml> <archivo2.xml> [...]${NC}"
    echo ""
    echo "Fusiona N archivos package.xml de Salesforce en uno solo, deduplicando"
    echo "miembros y agrupando tipos. Soporta 1 archivo como normalizador."
    echo ""
    echo "Opciones:"
    echo "  --output=<path>   Ruta del archivo de salida. Por defecto: merged-package.xml"
    echo "  --version=<num>   Fuerza la versión de API en la salida. Por defecto: max detectada"
    echo "  --stdout          Imprime en stdout en lugar de escribir a archivo."
    echo "  --overwrite       Permite sobrescribir si --output ya existe."
    echo "  --verbose         Muestra salida detallada."
    echo "  -h, --help        Muestra esta ayuda."
    echo ""
    echo "Ejemplos:"
    echo "  ./mergeXml.sh package/package.xml destructiveChanges/package.xml"
    echo "  ./mergeXml.sh a.xml b.xml c.xml --output=final.xml --overwrite"
    echo "  ./mergeXml.sh *.xml --stdout > result.xml"
    exit 0
}

# --- Defaults ---
OUTPUT="merged-package.xml"
FORCE_VERSION=""
USE_STDOUT=false
OVERWRITE=false
VERBOSE=false
FILES=()

# --- Procesamiento de Parámetros ---

while [ $# -gt 0 ]; do
    case "$1" in
        --output=*)
            OUTPUT="${1#*=}"
            ;;
        --version=*)
            FORCE_VERSION="${1#*=}"
            ;;
        --stdout)
            USE_STDOUT=true
            ;;
        --overwrite)
            OVERWRITE=true
            ;;
        --verbose)
            VERBOSE=true
            ;;
        -h|--help)
            show_help
            ;;
        -*)
            log_error "Flag desconocido: $1"
            show_help
            ;;
        *)
            FILES+=("$1")
            ;;
    esac
    shift
done

# --- Validaciones ---

if [ "${#FILES[@]}" -lt 1 ]; then
    log_error "Se requiere al menos un archivo."
    exit 1
fi

if [ "${#FILES[@]}" -eq 1 ]; then
    log_warn "Solo se proporcionó 1 archivo. Se producirá una versión ordenada/normalizada del mismo."
fi

for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        log_error "No existe o no es un archivo regular: $f"
        exit 1
    fi
    if [ ! -r "$f" ]; then
        log_error "No se puede leer el archivo: $f"
        exit 1
    fi
    if ! grep -q "<Package" "$f"; then
        log_error "No parece un package.xml válido (sin <Package>): $f"
        exit 1
    fi
done

if [ "$USE_STDOUT" = false ] && [ -f "$OUTPUT" ] && [ "$OVERWRITE" = false ]; then
    log_error "$OUTPUT ya existe. Usa --overwrite para sobreescribir."
    exit 1
fi

log_info "Procesando ${#FILES[@]} archivo(s): ${FILES[*]}"

# --- Archivos temporales ---
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# --- Parseo con AWK ---
# Emite pares TYPE<TAB>MEMBER y líneas __VERSION__<TAB>X para cada archivo.
# Usa gsub para extraer contenido de etiquetas (compatible con mawk/gawk/nawk).
awk '
    BEGIN { in_types=0; mb_count=0; name=""; }
    /<types[^>]*>/ {
        in_types=1;
        for (k in members_buf) delete members_buf[k];
        mb_count=0;
        name="";
        next
    }
    /<\/types>/ {
        if (name != "") {
            for (i=1; i<=mb_count; i++) print name "\t" members_buf[i]
        }
        in_types=0;
        next
    }
    in_types && /<members>/ && /<\/members>/ {
        val = $0;
        gsub(/.*<members>[[:space:]]*/, "", val);
        gsub(/[[:space:]]*<\/members>.*/, "", val);
        mb_count++;
        members_buf[mb_count] = val
    }
    in_types && /<name>/ && /<\/name>/ {
        val = $0;
        gsub(/.*<name>[[:space:]]*/, "", val);
        gsub(/[[:space:]]*<\/name>.*/, "", val);
        name = val
    }
    !in_types && /<version>/ && /<\/version>/ {
        val = $0;
        gsub(/.*<version>[[:space:]]*/, "", val);
        gsub(/[[:space:]]*<\/version>.*/, "", val);
        print "__VERSION__\t" val
    }
' "${FILES[@]}" > "$TMP"

# --- Extraer versión ---
if [ -n "$FORCE_VERSION" ]; then
    VERSION="$FORCE_VERSION"
    log_verbose "Versión forzada: $VERSION"
else
    VERSION=$(awk -F'\t' '$1=="__VERSION__"{print $2}' "$TMP" | sort -V | tail -1)
    if [ -z "$VERSION" ]; then
        log_warn "No se detectó <version> en ningún archivo. Usando 60.0 por defecto."
        VERSION="60.0"
    else
        log_verbose "Versión máxima detectada: $VERSION"
    fi
fi

log_info "Versión de API: $VERSION"

# --- Obtener tipos únicos ---
TYPES=$(awk -F'\t' '$1!="__VERSION__"{print $1}' "$TMP" | sort -u)

if [ -z "$TYPES" ]; then
    log_error "No se encontró ningún <types> en los archivos de entrada."
    exit 2
fi

TYPE_COUNT=$(echo "$TYPES" | wc -l)
log_info "Tipos detectados: $TYPE_COUNT"

# --- Construir salida ---
build_output() {
    echo '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    echo '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
    while IFS= read -r type; do
        [ -z "$type" ] && continue
        echo "    <types>"

        # Todos los miembros antes de dedup (para contar duplicados)
        ALL_MEMBERS=$(awk -F'\t' -v t="$type" '$1==t{print $2}' "$TMP")
        TOTAL_RAW=$(echo "$ALL_MEMBERS" | grep -c .)
        MEMBERS_UNIQUE=$(echo "$ALL_MEMBERS" | sort -u)
        TOTAL_UNIQUE=$(echo "$MEMBERS_UNIQUE" | grep -c .)
        DUPES=$(( TOTAL_RAW - TOTAL_UNIQUE ))

        if [ "$DUPES" -gt 0 ]; then
            log_info "Tipo $type: $TOTAL_RAW miembros, $DUPES duplicado(s) eliminado(s)."
        fi
        log_verbose "Tipo $type: $TOTAL_UNIQUE miembro(s) único(s)."

        # Regla del wildcard: si '*' está presente, colapsar
        if echo "$MEMBERS_UNIQUE" | grep -qxF '*'; then
            SPECIFIC_COUNT=$(( TOTAL_UNIQUE - 1 ))
            log_verbose "Tipo $type: colapsado a '*' ($SPECIFIC_COUNT miembro(s) específico(s) descartado(s))."
            echo "        <members>*</members>"
        else
            while IFS= read -r m; do
                [ -n "$m" ] && echo "        <members>${m}</members>"
            done <<< "$MEMBERS_UNIQUE"
        fi

        echo "        <name>${type}</name>"
        echo "    </types>"
    done <<< "$TYPES"
    echo "    <version>${VERSION}</version>"
    echo "</Package>"
}

# --- Salida ---
if [ "$USE_STDOUT" = true ]; then
    build_output
else
    build_output > "$OUTPUT"
    log_success "Merge generado en: $OUTPUT"
fi

exit 0

#!/bin/bash

# --- Función de Ayuda ---
# Muestra cómo usar el script.
show_help() {
    echo "¿Cómo se usa este script?: $(basename "$0") --target=RAMA_DESTINO"
    echo ""
    echo "¿Qué hace?:"
    echo " Valida posibles errores de un PR, entre la rama actual y la RAMA_DESTINO"
    echo "  1) Valida mediante PMD"
    echo "  2) Valida mediante EsLint"
    echo "  3) Busca System.Debug o código comentado"
    echo ""
    echo "Parámetros:"
    echo "* --target=RAMA   Especifica la rama de destino del Pull Request. *Obligatorio"
    echo "  -h, --help      Muestra este mensaje de ayuda."
    echo ""
    echo "Ejemplo:"
    echo "  $(basename "$0") --target=Main"
}

# --- Configuración y Valores por Defecto ---
TARGET_BRANCH=""

# --- Procesamiento de Parámetros de Línea de Comandos ---
for arg in "$@"
do
    case $arg in
        -h|--help)
        show_help
        exit 0
        ;;
        --target=*)
        # Extrae el valor después de '--target='
        TARGET_BRANCH="${arg#*=}"
        # Si el valor está vacío (ej. --target=), es un error
        if [ -z "$TARGET_BRANCH" ]; then
            echo "Error: La opción --target no puede estar vacía." >&2
            echo ""
            show_help
            exit 1
        fi
        shift # Mueve al siguiente argumento
        ;;
        *)
        # Argumento desconocido
        echo "Error: Opción desconocida '$arg'" >&2
        echo ""
        show_help
        exit 1
        ;;
    esac
done

# --- Validaciones Previas ---
# 1: Asegurarse de que el parámetro --target fue proporcionado
if [ -z "$TARGET_BRANCH" ]; then
    echo "🔴Error: El parámetro --target es obligatorio." >&2
    echo ""
    show_help
    exit 1
fi
# 2: Asegurarse de que estamos dentro de un repositorio de Git
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "🔴Error: Este script debe ejecutarse dentro de un repositorio de Git." >&2
    exit 1
fi

PROJECT_ROOT=$(git rev-parse --show-toplevel)
SOURCE_BRANCH=$(git rev-parse --abbrev-ref HEAD)



# --- Lógica Principal del Script ---

# Asegurarse de que la rama de destino remota esté actualizada localmente
echo "Buscando cambios entre ramas $SOURCE_BRANCH -> $TARGET_BRANCH..."
git fetch origin "$TARGET_BRANCH":"$TARGET_BRANCH" --update-head-ok
if [ $? -ne 0 ]; then
    echo "⚠Advertencia: No se pudo actualizar la rama de destino '$TARGET_BRANCH'. Puede que la comparación no sea la más reciente." >&2
fi

# Generar la lista de archivos modificados (Change Entries)
# Usamos 'name-status' para ver el tipo de cambio (A, M, D, R)
# Comparamos el punto común de ambas ramas (merge-base) con la rama actual
echo "Guardando temporalmente los cambios en $PROJECT_ROOT/git-diff.txt..."
git diff --name-status "origin/$TARGET_BRANCH...HEAD" > "$PROJECT_ROOT/git-diff.txt"

# usa awk para enviar las clases al archivo PMD
# Si la primera columna es D (Eliminado), salta a la siguiente
# Si la primera columna es R (Renombrado), usa el tercer campo, de lo contrario, usa el segundo
# Si el archivo es un archivo Apex (.cls), lo imprime (En la ruta especifica de PMD)
echo "Obteniendo clases Apex para analizar PMD..."
awk '
$1 == "D" { next }
{
    path = ($1 ~ /^R/) ? $3 : $2;
    if (path ~ /\.cls$/) {
        print path;
    }
}
' "$PROJECT_ROOT/git-diff.txt" > "$PROJECT_ROOT/pmd/apex-clases"
echo "Analizando problemas de PMD..."
# Se analizan las clases con PMD (Se debe contar con la herramienta)
echo "PMD: " > "$PROJECT_ROOT/validate-results.txt"
pmd check -R "$PROJECT_ROOT/pmd/apex-rules.xml" --file-list "$PROJECT_ROOT/pmd/apex-clases" --no-cache --no-progress --show-suppressed &>> "$PROJECT_ROOT/validate-results.txt"

# usa awk otra vez, para enviar los archivos de Javascript a un archivo temporal
echo "Obteniendo archivos Javascript para analizar con EsLint..."
awk '
# Si la primera columna es D (Eliminado), salta a la siguiente
$1 == "D" { next }
{
    # Si la primera columna es R (Renombrado), usa el tercer campo, de lo contrario, usa el segundo
    path = ($1 ~ /^R/) ? $3 : $2;
    # Si el archivo es un archivo Javascript (.js), lo imprime
    if (path ~ /\.js$/) {
        print path;
    }
}
' "$PROJECT_ROOT/git-diff.txt" > "$PROJECT_ROOT/pmd/js-archivos"

# Se crea un array con la lista de archivos Javascript
mapfile -t JS_FILES < "$PROJECT_ROOT/pmd/js-archivos"
# Si hay archivos Javascript, se ejecuta EsLint con esos archivos y se guardan los resultados
if [ ${#JS_FILES[@]} -gt 0 ]; then
    echo "Analizando problemas con EsLint en archivos Javascript..."
    echo "" >> "$PROJECT_ROOT/validate-results.txt"
    echo "EsLint:" >> "$PROJECT_ROOT/validate-results.txt"
    # El comando &>> permite adicionar la salida de EsLint incluido los errores.
    npx eslint "${JS_FILES[@]}" | grep -E -v "problems|fixable" | sed "s|$PROJECT_ROOT/||" &>> "$PROJECT_ROOT/validate-results.txt"
fi

# Busca System.Debug o código comentado en los archivos Apex
echo "Buscando System.Debug o código comentado en archivos Apex..."
mapfile -t APEX_FILES < "$PROJECT_ROOT/pmd/apex-clases"
# Si hay archivos Apex se ejecuta la búsqueda
if [ ${#APEX_FILES[@]} -gt 0 ]; then
    echo "Comentarios y Debugs:" >> "$PROJECT_ROOT/validate-results.txt"
    while IFS= read -r file; do
        echo "$file" >> "$PROJECT_ROOT/validate-results.txt"
        grep -E -i -n 'system\.debug\(|//|/\*|^\s*\*' "$file" &>> "$PROJECT_ROOT/validate-results.txt"
        echo "" >> "$PROJECT_ROOT/validate-results.txt"
    done < <(printf "%s\n" "${APEX_FILES[@]}")
fi

# Discard git changes on some files
echo "Descartando cambios en archivos temporales..."
git checkout --force -- "$PROJECT_ROOT/pmd/apex-clases"
rm "$PROJECT_ROOT/git-diff.txt"
rm "$PROJECT_ROOT/pmd/js-archivos"

# Imprimir ruta de resultados:
echo "Resultados:"
echo "  '$PROJECT_ROOT/validate-results.txt'"
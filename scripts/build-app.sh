#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Островок удобства.app"
contents_dir="$app_dir/Contents"
resources_dir="$contents_dir/Resources"
python_source="/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9"
python_source="${CONVENIENCE_ISLAND_PYTHON_RUNTIME:-$python_source}"
transcriber_python="${CONVENIENCE_ISLAND_TRANSCRIBER_PYTHON:-$project_dir/.venv-transcribe/bin/python3}"
huggingface_home="${HF_HOME:-$HOME/.cache/huggingface}"
model_cache="${CONVENIENCE_ISLAND_MODEL_CACHE:-$huggingface_home/hub/models--mlx-community--whisper-large-v3-turbo}"

cd "$project_dir"
if [[ ! -x "$python_source/bin/python3" ]]; then
    echo "Не найден Python runtime: $python_source" >&2
    exit 1
fi
if [[ ! -x "$transcriber_python" ]]; then
    echo "Не найден Python с mlx-whisper: $transcriber_python" >&2
    echo "Укажите CONVENIENCE_ISLAND_TRANSCRIBER_PYTHON или создайте .venv-transcribe." >&2
    exit 1
fi
transcriber_site_packages="$($transcriber_python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
if [[ ! -d "$transcriber_site_packages/mlx_whisper" ]]; then
    echo "В $transcriber_python не установлен mlx-whisper." >&2
    exit 1
fi
if [[ ! -f "$model_cache/refs/main" ]]; then
    echo "Не найдена локальная модель whisper-large-v3-turbo" >&2
    exit 1
fi

model_snapshot="$(<"$model_cache/refs/main")"
if [[ ! "$model_snapshot" =~ '^[0-9a-f]{40,64}$' ]]; then
    echo "Некорректный идентификатор snapshot модели." >&2
    exit 1
fi
model_cache_root="${model_cache:A}"
snapshots_root="$model_cache_root/snapshots"
model_source="${snapshots_root}/${model_snapshot}"
model_source="${model_source:A}"
if [[ "$model_source" != "$snapshots_root"/* || ! -d "$model_source" ]]; then
    echo "Snapshot модели находится вне разрешённого каталога." >&2
    exit 1
fi
if [[ ! -f "$model_source/config.json" || ! -f "$model_source/weights.safetensors" ]]; then
    echo "Snapshot модели неполный: нужны config.json и weights.safetensors." >&2
    exit 1
fi
while IFS= read -r model_link; do
    resolved_link="${model_link:A}"
    if [[ "$resolved_link" != "$model_cache_root"/* ]]; then
        echo "Модель содержит ссылку за пределы локального кэша: $model_link" >&2
        exit 1
    fi
done < <(find "$model_source" -type l -print)

swift_build_arguments=(-c release)
if [[ "${CONVENIENCE_ISLAND_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    swift_build_arguments+=(--disable-sandbox)
fi
swift build "${swift_build_arguments[@]}"

if [[ "${app_dir:h}" != "$project_dir/build" || "${app_dir:t}" != "Островок удобства.app" ]]; then
    echo "Отказ очищать неожиданный путь сборки: $app_dir" >&2
    exit 1
fi
rm -rf -- "$app_dir"
mkdir -p "$contents_dir/MacOS" "$resources_dir"
cp "$project_dir/.build/release/ConvenienceIsland" "$contents_dir/MacOS/ConvenienceIsland"
cp "$project_dir/AppBundle/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/AppBundle/Resources/transcribe_mlx.py" "$resources_dir/transcribe_mlx.py"
chmod 755 "$contents_dir/MacOS/ConvenienceIsland"

runtime_dir="$resources_dir/PythonRuntime"
mkdir -p "$runtime_dir"
cp -RX "$python_source/." "$runtime_dir/"
mkdir -p "$runtime_dir/lib/python3.9/site-packages"
cp -RX "$transcriber_site_packages/." "$runtime_dir/lib/python3.9/site-packages/"

model_dir="$resources_dir/Models/whisper-large-v3-turbo"
mkdir -p "$model_dir"
cp -RL "$model_source/." "$model_dir/"

signing_identity="$(zsh "$project_dir/scripts/ensure-local-signing-identity.sh")"
codesign --force --deep --options runtime --timestamp=none --sign "$signing_identity" "$app_dir"
echo "$app_dir"

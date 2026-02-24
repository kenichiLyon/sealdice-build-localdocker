#!/usr/bin/env bash
set -euo pipefail

TARGETS="${ARTIFACT_TARGETS:-linux/amd64 linux/arm64 windows/amd64 osx/amd64 osx/arm64 android/arm64}"
VERSION="${ARTIFACT_VERSION:-local}"
OUT_DIR="${OUT_DIR:-/out}"
VERSION_PRERELEASE="${ARTIFACT_VERSION_PRERELEASE:--docker-artifact}"
APP_CHANNEL="${ARTIFACT_APP_CHANNEL:-dev}"
NT_SIGN_URL="${ARTIFACT_NT_SIGN_URL:-}"
SEAL_TRUSTED_PRIVATE_KEY="${ARTIFACT_SEAL_TRUSTED_PRIVATE_KEY:-}"
CGO_FLAGS="${ARTIFACT_CGO_FLAGS:--Werror=unused-variable -Werror=implicit-function-declaration -O2}"
ENABLE_UPX="${ARTIFACT_ENABLE_UPX:-0}"
GO_WIN_PATCH="${ARTIFACT_GO_WIN_PATCH:-/src/sealdice-build/.github/patch_go/unified-1-25-patch.diff}"
ANDROID_NDK_PATH="${ANDROID_NDK:-/opt/android-ndk-r25c}"
GITHUB_PROXY="${ARTIFACT_GITHUB_PROXY:-}"
GITHUB_PROXY_FALLBACKS="${ARTIFACT_GITHUB_PROXY_FALLBACKS:-https://mirror.ghproxy.com/ https://ghproxy.net/}"
BUILTINS_ENABLE="${ARTIFACT_BUILTINS_ENABLE:-1}"
BUILTINS_REPO="${ARTIFACT_BUILTINS_REPO:-https://github.com/sealdice/sealdice-builtins}"
BUILTINS_REF="${ARTIFACT_BUILTINS_REF:-master}"
LAGRANGE_ENABLE="${ARTIFACT_LAGRANGE_ENABLE:-1}"
LAGRANGE_BASE_URL="${ARTIFACT_LAGRANGE_BASE_URL:-https://d1.sealdice.com/lagrange}"
LAGRANGE_VERSION="${ARTIFACT_LAGRANGE_VERSION:-0.0.6}"
LAGRANGE_TAG="${ARTIFACT_LAGRANGE_TAG:-8.0}"
LAGRANGE_QUERY="${ARTIFACT_LAGRANGE_QUERY:-v=3}"
ANDROID_APK_ENABLE="${ARTIFACT_ANDROID_APK_ENABLE:-0}"
ANDROID_REPO="${ARTIFACT_ANDROID_REPO:-https://github.com/sealdice/sealdice-android}"
ANDROID_REF="${ARTIFACT_ANDROID_REF:-master}"
ANDROID_APP_RUNNER_URL="${ARTIFACT_ANDROID_APP_RUNNER_URL:-https://d1.sealdice.com/lagrange/app-runner-std-arm64.tar.gz}"
CLEANUP_MODE="${ARTIFACT_CLEANUP_MODE:-pkg}"

RAW_DIR="${OUT_DIR}/raw"
PKG_DIR="${OUT_DIR}/pkg"
SUMMARY_FILE="${OUT_DIR}/summary.txt"
SHARED_DIR="${OUT_DIR}/shared"
BUILTINS_DATA_DIR="${SHARED_DIR}/data"
LAGRANGE_DIR="${SHARED_DIR}/lagrange"

mkdir -p "${RAW_DIR}" "${PKG_DIR}" "${SHARED_DIR}" "${LAGRANGE_DIR}"
: > "${SUMMARY_FILE}"

echo "Build version: ${VERSION}" | tee -a "${SUMMARY_FILE}"
echo "Targets: ${TARGETS}" | tee -a "${SUMMARY_FILE}"
echo "" | tee -a "${SUMMARY_FILE}"

success_count=0
failed_targets=()
go_win_patch_applied=0
darwin_nocgo_prepared=0
android_core_bin=""

is_optional_target() {
  case "$1" in
    darwin/amd64|darwin/arm64|osx/amd64|osx/arm64|android/arm64)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_ldflags() {
  local flags="-s -w -X sealdice-core/dice.VERSION_PRERELEASE=${VERSION_PRERELEASE} -X sealdice-core/dice.VERSION_BUILD_METADATA=+${VERSION} -X sealdice-core/dice.APP_CHANNEL=${APP_CHANNEL}"
  if [[ -n "${NT_SIGN_URL}" ]]; then
    flags="${flags} -X sealdice-core/dice.DefaultSignUrl=${NT_SIGN_URL}"
  fi
  if [[ -n "${SEAL_TRUSTED_PRIVATE_KEY}" ]]; then
    flags="${flags} -X sealdice-core/dice.SealTrustedClientPrivateKey=${SEAL_TRUSTED_PRIVATE_KEY}"
  fi
  echo "${flags}"
}

maybe_apply_go_win_patch() {
  if [[ ${go_win_patch_applied} -eq 1 ]]; then
    return 0
  fi
  if [[ ! -f "${GO_WIN_PATCH}" ]]; then
    echo "WARN windows patch not found, skip: ${GO_WIN_PATCH}" | tee -a "${SUMMARY_FILE}"
    go_win_patch_applied=1
    return 0
  fi
  echo "Applying go patch for windows7/8 compatibility: ${GO_WIN_PATCH}" | tee -a "${SUMMARY_FILE}"
  (cd "$(go env GOROOT)" && patch --verbose -p1 < "${GO_WIN_PATCH}")
  go_win_patch_applied=1
}

maybe_upx() {
  local file="$1"
  if [[ "${ENABLE_UPX}" != "1" ]]; then
    return 0
  fi
  if ! command -v upx >/dev/null 2>&1; then
    echo "WARN upx not found, skip compress: ${file}" | tee -a "${SUMMARY_FILE}"
    return 0
  fi
  upx -9 -fq "${file}" || true
}

build_proxy_url() {
  local proxy="$1"
  local base_url="$2"
  case "${proxy}" in
    *"{url}"*)
      echo "${proxy}" | sed "s|{url}|${base_url}|g"
      ;;
    *"%URL%"*)
      echo "${proxy}" | sed "s|%URL%|${base_url}|g"
      ;;
    *)
      echo "${proxy}${base_url}"
      ;;
  esac
}

github_candidate_urls() {
  local url="$1"
  if [[ "${url}" != https://github.com/* ]]; then
    echo "${url}"
    return 0
  fi

  local candidates=()
  local seen=" "
  local candidate
  add_unique() {
    local item="$1"
    if [[ -z "${item}" ]]; then
      return 0
    fi
    if [[ "${seen}" == *" ${item} "* ]]; then
      return 0
    fi
    seen="${seen}${item} "
    candidates+=("${item}")
  }

  if [[ -n "${GITHUB_PROXY}" ]]; then
    candidate="$(build_proxy_url "${GITHUB_PROXY}" "${url}")"
    add_unique "${candidate}"
  fi
  local proxy
  for proxy in ${GITHUB_PROXY_FALLBACKS}; do
    candidate="$(build_proxy_url "${proxy}" "${url}")"
    add_unique "${candidate}"
  done
  add_unique "${url}"

  printf '%s\n' "${candidates[@]}"
}

lagrange_id_for_target() {
  case "$1" in
    linux/amd64) echo "linux-amd64" ;;
    linux/arm64) echo "linux-arm64" ;;
    windows/amd64) echo "windows-amd64" ;;
    windows/386) echo "windows-386" ;;
    darwin/amd64|osx/amd64) echo "darwin-amd64" ;;
    darwin/arm64|osx/arm64) echo "darwin-arm64" ;;
    android/arm64) echo "android-arm64" ;;
    *) echo "" ;;
  esac
}

lagrange_remote_name() {
  case "$1" in
    linux-amd64) echo "linux-x64" ;;
    linux-arm64) echo "linux-arm64" ;;
    windows-amd64) echo "win-x64" ;;
    windows-386) echo "win-x86" ;;
    darwin-amd64) echo "osx-x64" ;;
    darwin-arm64) echo "osx-arm64" ;;
    android-arm64) echo "linux-musl-arm64" ;;
    *) echo "" ;;
  esac
}

prepare_builtins_data() {
  if [[ "${BUILTINS_ENABLE}" != "1" ]]; then
    echo "skip builtins data preparation" | tee -a "${SUMMARY_FILE}"
    return 0
  fi
  rm -rf "${BUILTINS_DATA_DIR}"
  mkdir -p "${BUILTINS_DATA_DIR}"

  local repo_url="${BUILTINS_REPO}"
  local source_repo_dir archive_url archive_file repo_path
  source_repo_dir="$(mktemp -d /tmp/sealdice-builtins.XXXXXX)"
  echo "Preparing builtins from ${repo_url}@${BUILTINS_REF}" | tee -a "${SUMMARY_FILE}"

  if [[ "${repo_url}" == https://github.com/* ]]; then
    repo_path="${repo_url#https://github.com/}"
    repo_path="${repo_path%.git}"
    archive_file="/tmp/sealdice-builtins-${BUILTINS_REF}.tar.gz"
    local archive_urls=()
    mapfile -t archive_urls < <(github_candidate_urls "https://github.com/${repo_path}/archive/refs/heads/${BUILTINS_REF}.tar.gz")
    local try_url
    for try_url in "${archive_urls[@]}"; do
      if [[ -z "${try_url}" ]]; then
        continue
      fi
      if wget -q "${try_url}" -O "${archive_file}"; then
        if tar -xzf "${archive_file}" -C "${source_repo_dir}" --strip-components=1 >/dev/null 2>&1; then
          rm -f "${archive_file}"
          break
        fi
      fi
      rm -f "${archive_file}"
    done

    if [[ ! -d "${source_repo_dir}/data" ]]; then
      git clone --depth 1 --branch "${BUILTINS_REF}" "${repo_url}" "${source_repo_dir}" >/dev/null 2>&1 || true
    fi
  else
    git clone --depth 1 --branch "${BUILTINS_REF}" "${repo_url}" "${source_repo_dir}" >/dev/null 2>&1 || true
  fi

  if [[ ! -d "${source_repo_dir}/data" ]]; then
    if [[ -d "/src/sealdice-core/sealdice-builtins/data" ]]; then
      echo "WARN builtins fetch failed, fallback to local /src/sealdice-core/sealdice-builtins/data" | tee -a "${SUMMARY_FILE}"
      cp -r /src/sealdice-core/sealdice-builtins/data/. "${BUILTINS_DATA_DIR}/" || true
      rm -rf "${source_repo_dir}"
      if [[ -z "$(ls -A "${BUILTINS_DATA_DIR}" 2>/dev/null || true)" ]]; then
        echo "FAIL builtins data not found." | tee -a "${SUMMARY_FILE}"
        return 1
      fi
      return 0
    fi
    rm -rf "${source_repo_dir}"
    echo "FAIL builtins fetch failed and no local fallback." | tee -a "${SUMMARY_FILE}"
    return 1
  fi

  if [[ ! -d "${source_repo_dir}/data" ]]; then
    rm -rf "${source_repo_dir}"
    echo "FAIL builtins repo has no data directory." | tee -a "${SUMMARY_FILE}"
    return 1
  fi
  cp -r "${source_repo_dir}/data/." "${BUILTINS_DATA_DIR}/"
  rm -rf "${source_repo_dir}"
  echo "Builtins data prepared." | tee -a "${SUMMARY_FILE}"
}

prepare_lagrange_files() {
  if [[ "${LAGRANGE_ENABLE}" != "1" ]]; then
    echo "skip lagrange download" | tee -a "${SUMMARY_FILE}"
    return 0
  fi
  rm -rf "${LAGRANGE_DIR}"
  mkdir -p "${LAGRANGE_DIR}"

  local processed_ids=" "
  local target lag_id remote_name zip_name url extract_dir
  for target in ${TARGETS}; do
    lag_id="$(lagrange_id_for_target "${target}")"
    if [[ -z "${lag_id}" ]]; then
      continue
    fi
    if [[ "${processed_ids}" == *" ${lag_id} "* ]]; then
      continue
    fi
    processed_ids="${processed_ids}${lag_id} "
    remote_name="$(lagrange_remote_name "${lag_id}")"
    if [[ -z "${remote_name}" ]]; then
      continue
    fi

    zip_name="Lagrange.OneBot.${lag_id}.zip"
    url="${LAGRANGE_BASE_URL}/${LAGRANGE_VERSION}/Lagrange.OneBot_${remote_name}_${LAGRANGE_TAG}.zip"
    if [[ -n "${LAGRANGE_QUERY}" ]]; then
      url="${url}?${LAGRANGE_QUERY}"
    fi
    echo "Downloading lagrange ${lag_id}" | tee -a "${SUMMARY_FILE}"
    wget -q "${url}" -O "/tmp/${zip_name}"
    extract_dir="${LAGRANGE_DIR}/${lag_id}"
    mkdir -p "${extract_dir}"
    unzip -q "/tmp/${zip_name}" -d "${extract_dir}"
    rm -f "/tmp/${zip_name}"
  done
  echo "Lagrange files prepared." | tee -a "${SUMMARY_FILE}"
}

prepare_repo_from_github() {
  local repo_url="$1"
  local repo_ref="$2"
  local dest_dir="$3"
  local repo_path archive_url archive_file
  repo_path="${repo_url#https://github.com/}"
  repo_path="${repo_path%.git}"
  archive_file="/tmp/repo-${repo_ref}-$$.tar.gz"
  local archive_urls=()
  mapfile -t archive_urls < <(github_candidate_urls "https://github.com/${repo_path}/archive/refs/heads/${repo_ref}.tar.gz")
  local archive_url
  for archive_url in "${archive_urls[@]}"; do
    if wget -q "${archive_url}" -O "${archive_file}"; then
      if tar -xzf "${archive_file}" -C "${dest_dir}" --strip-components=1 >/dev/null 2>&1; then
        rm -f "${archive_file}"
        return 0
      fi
    fi
    rm -f "${archive_file}"
  done
  return 1
}

build_android_apk() {
  if [[ "${ANDROID_APK_ENABLE}" != "1" ]]; then
    return 0
  fi
  if [[ " ${TARGETS} " != *" android/arm64 "* ]]; then
    echo "skip android apk build: android/arm64 target not selected" | tee -a "${SUMMARY_FILE}"
    return 0
  fi
  if [[ -z "${android_core_bin}" || ! -f "${android_core_bin}" ]]; then
    echo "FAIL android core binary missing for apk build." | tee -a "${SUMMARY_FILE}"
    return 1
  fi

  local repo_dir
  repo_dir="$(mktemp -d /tmp/sealdice-android.XXXXXX)"
  echo "Preparing android repo from ${ANDROID_REPO}@${ANDROID_REF}" | tee -a "${SUMMARY_FILE}"
  if [[ "${ANDROID_REPO}" == https://github.com/* ]]; then
    prepare_repo_from_github "${ANDROID_REPO}" "${ANDROID_REF}" "${repo_dir}" || git clone --depth 1 --branch "${ANDROID_REF}" "${ANDROID_REPO}" "${repo_dir}" >/dev/null 2>&1 || true
  else
    git clone --depth 1 --branch "${ANDROID_REF}" "${ANDROID_REPO}" "${repo_dir}" >/dev/null 2>&1 || true
  fi
  if [[ ! -f "${repo_dir}/gradlew" ]]; then
    rm -rf "${repo_dir}"
    echo "FAIL android repo invalid or unavailable." | tee -a "${SUMMARY_FILE}"
    return 1
  fi

  local assets_dir
  assets_dir="${repo_dir}/app/src/main/assets"
  mkdir -p "${assets_dir}/sealdice"
  cp "${android_core_bin}" "${assets_dir}/sealdice/sealdice-core"
  if [[ -d "${BUILTINS_DATA_DIR}" ]]; then
    mkdir -p "${assets_dir}/sealdice/data"
    cp -r "${BUILTINS_DATA_DIR}/." "${assets_dir}/sealdice/data/"
  fi
  if [[ -d "${LAGRANGE_DIR}/android-arm64" ]]; then
    mkdir -p "${assets_dir}/sealdice/lagrange"
    cp -r "${LAGRANGE_DIR}/android-arm64/." "${assets_dir}/sealdice/lagrange/"
  fi
  if [[ -n "${ANDROID_APP_RUNNER_URL}" ]]; then
    wget -q "${ANDROID_APP_RUNNER_URL}" -O "${assets_dir}/app-runner-arm64.tar.gz" || true
  fi

  if [[ -f "${repo_dir}/app/src/main/java/com/sealdice/dice/MyApplication.kt" ]]; then
    sed -i '/secrets.Auth.*/d' "${repo_dir}/app/src/main/java/com/sealdice/dice/MyApplication.kt" || true
    sed -i '/httpSender {/,/}/d' "${repo_dir}/app/src/main/java/com/sealdice/dice/MyApplication.kt" || true
  fi
  if [[ -f "${repo_dir}/app/build.gradle" ]]; then
    sed -i "s/versionName \".*\"/versionName \"${VERSION}\"/g" "${repo_dir}/app/build.gradle" || true
  fi

  chmod +x "${repo_dir}/gradlew"
  (cd "${repo_dir}" && LANG=C.UTF-8 LC_ALL=C.UTF-8 JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8" ./gradlew assembleDebug --stacktrace)

  local apk_file
  apk_file="$(find "${repo_dir}/app/build/outputs/apk" -type f -name "*.apk" | head -n 1)"
  if [[ -z "${apk_file}" ]]; then
    rm -rf "${repo_dir}"
    echo "FAIL android apk not generated." | tee -a "${SUMMARY_FILE}"
    return 1
  fi
  cp "${apk_file}" "${PKG_DIR}/sealdice-android_${VERSION}_arm64.apk"
  rm -rf "${repo_dir}"
  echo "Android APK generated: sealdice-android_${VERSION}_arm64.apk" | tee -a "${SUMMARY_FILE}"
  return 0
}

cleanup_intermediate_outputs() {
  case "${CLEANUP_MODE}" in
    none)
      echo "Cleanup mode: none (keep raw/shared)." | tee -a "${SUMMARY_FILE}"
      ;;
    pkg)
      rm -rf "${RAW_DIR}" "${SHARED_DIR}"
      echo "Cleanup mode: pkg (removed raw/shared)." | tee -a "${SUMMARY_FILE}"
      ;;
    all)
      rm -rf "${RAW_DIR}" "${SHARED_DIR}"
      rm -f "${SUMMARY_FILE}"
      echo "Cleanup mode: all (removed raw/shared/summary)."
      ;;
    *)
      rm -rf "${RAW_DIR}" "${SHARED_DIR}"
      echo "Cleanup mode: invalid '${CLEANUP_MODE}', fallback to pkg." | tee -a "${SUMMARY_FILE}"
      ;;
  esac
}

prepare_darwin_nocgo_fallback() {
  if [[ ${darwin_nocgo_prepared} -eq 1 ]]; then
    return 0
  fi

  if [[ -f tray_darwin.go ]]; then
    if grep -q "^//go:build darwin$" tray_darwin.go; then
      sed -i "1s|^//go:build darwin$|//go:build darwin \&\& cgo|" tray_darwin.go
      cat > tray_darwin_nocgo.go <<'EOF'
//go:build darwin && !cgo

package main

import (
	"net"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"syscall"

	"github.com/labstack/echo/v4"

	"sealdice-core/dice"
	"sealdice-core/logger"
)

func trayInit(dm *dice.DiceManager) {
	select {}
}

func hideWindow() {
}

func showWindow() {
}

func TestRunning() bool {
	return false
}

func tempDirWarn() {
	logger.M().Warn("当前工作路径为临时目录，因此拒绝继续执行。")
}

func showMsgBox(title string, message string) {
	logger.M().Info(title, message)
}

func httpServe(e *echo.Echo, dm *dice.DiceManager, hideUI bool) {
	log := logger.M()
	portStr := "3211"
	rePort := regexp.MustCompile(`:(\d+)$`)
	m := rePort.FindStringSubmatch(dm.ServeAddress)
	if len(m) > 0 {
		portStr = m[1]
	}

	ln, err := net.Listen("tcp", ":"+portStr)
	if err != nil {
		log.Errorf("端口已被占用，即将自动退出: %s", dm.ServeAddress)
		runtime.Goexit()
	}
	_ = ln.Close()

	log.Infof("如果浏览器没有自动打开，请手动访问:\nhttp://localhost:%s", portStr)
	err = e.Start(dm.ServeAddress)
	if err != nil {
		log.Errorf("端口已被占用，即将自动退出: %s", dm.ServeAddress)
		return
	}
}

func executeWin(name string, arg ...string) *exec.Cmd {
	cmd := exec.Command(name, arg...)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid: true,
		Pgid:    os.Getppid(),
	}
	cmd.Stderr = os.Stderr
	cmd.Stdout = os.Stdout
	cmd.Stdin = os.Stdin
	return cmd
}
EOF
      echo "Prepared darwin !cgo tray fallback for cross build." | tee -a "${SUMMARY_FILE}"
    fi
  fi

  darwin_nocgo_prepared=1
}

build_one() {
  local target="$1"
  local target_os="${target%/*}"
  local goarch="${target#*/}"
  local goos="${target_os}"
  local bin_os="${target_os}"
  local bin_name
  local output_path
  local stage_dir
  local runtime_bin_name
  local lag_id
  local ldflags
  ldflags="$(build_ldflags)"
  local status=0

  if [[ "${target_os}" == "osx" ]]; then
    goos="darwin"
  fi

  bin_name="sealdice-core_${bin_os}_${goarch}"
  output_path="${RAW_DIR}/${bin_name}"

  if [[ "${goos}" == "windows" ]]; then
    output_path="${output_path}.exe"
  fi

  echo "==> building ${target}" | tee -a "${SUMMARY_FILE}"

  case "${target}" in
    linux/amd64)
      GOOS=linux GOARCH=amd64 CGO_ENABLED=1 CC=musl-gcc CGO_CFLAGS="${CGO_FLAGS}" \
        go build -tags musl -trimpath -ldflags "${ldflags} -linkmode external -extldflags '-static'" -o "${output_path}" . || status=$?
      ;;
    linux/arm64)
      GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=/opt/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc CGO_CFLAGS="${CGO_FLAGS}" \
        go build -tags musl -trimpath -ldflags "${ldflags} -linkmode external -extldflags '-static'" -o "${output_path}" . || status=$?
      ;;
    windows/amd64)
      maybe_apply_go_win_patch || status=$?
      GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc CGO_CFLAGS="${CGO_FLAGS}" \
        go build -trimpath -ldflags "${ldflags} -H=windowsgui" -o "${output_path}" . || status=$?
      ;;
    darwin/amd64|darwin/arm64|osx/amd64|osx/arm64)
      prepare_darwin_nocgo_fallback
      GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
        go build -trimpath -ldflags "${ldflags}" -o "${output_path}" . || status=$?
      ;;
    android/arm64)
      if [[ -x "${ANDROID_NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang" ]]; then
        GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="${ANDROID_NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang" CGO_CFLAGS="${CGO_FLAGS}" \
          go build -trimpath -ldflags "${ldflags}" -o "${output_path}" . || status=$?
      else
        GOOS=android GOARCH=arm64 CGO_ENABLED=0 \
          go build -trimpath -ldflags "${ldflags}" -o "${output_path}" . || status=$?
      fi
      ;;
    *)
      echo "skip unsupported target: ${target}" | tee -a "${SUMMARY_FILE}"
      return 0
      ;;
  esac

  if [[ ${status} -ne 0 ]]; then
    echo "FAIL ${target}" | tee -a "${SUMMARY_FILE}"
    failed_targets+=("${target}")
    return ${status}
  fi

  maybe_upx "${output_path}"

  stage_dir="${RAW_DIR}/stage/${bin_name}"
  rm -rf "${stage_dir}"
  mkdir -p "${stage_dir}"
  if [[ "${goos}" == "windows" ]]; then
    runtime_bin_name="sealdice-core.exe"
  else
    runtime_bin_name="sealdice-core"
  fi
  cp "${output_path}" "${stage_dir}/${runtime_bin_name}"

  if [[ "${BUILTINS_ENABLE}" == "1" && -d "${BUILTINS_DATA_DIR}" ]]; then
    mkdir -p "${stage_dir}/data"
    cp -r "${BUILTINS_DATA_DIR}/." "${stage_dir}/data/"
  fi

  lag_id="$(lagrange_id_for_target "${target}")"
  if [[ "${LAGRANGE_ENABLE}" == "1" && -n "${lag_id}" && -d "${LAGRANGE_DIR}/${lag_id}" ]]; then
    mkdir -p "${stage_dir}/lagrange"
    cp -r "${LAGRANGE_DIR}/${lag_id}/." "${stage_dir}/lagrange/"
  fi

  if [[ "${goos}" == "windows" ]]; then
    (cd "${stage_dir}" && zip -qr "${PKG_DIR}/${bin_name}.zip" .)
  else
    (cd "${stage_dir}" && tar -czf "${PKG_DIR}/${bin_name}.tar.gz" .)
  fi

  if [[ "${target}" == "android/arm64" ]]; then
    android_core_bin="${output_path}"
  fi

  echo "OK   ${target}" | tee -a "${SUMMARY_FILE}"
  echo "" | tee -a "${SUMMARY_FILE}"
  success_count=$((success_count + 1))
  return 0
}

strict_fail=0

if ! prepare_builtins_data; then
  echo "Builtins preparation failed." | tee -a "${SUMMARY_FILE}"
  exit 1
fi

if ! prepare_lagrange_files; then
  echo "Lagrange preparation failed." | tee -a "${SUMMARY_FILE}"
  exit 1
fi

for target in ${TARGETS}; do
  if ! build_one "${target}"; then
    if ! is_optional_target "${target}"; then
      strict_fail=1
    fi
  fi
done

if ! build_android_apk; then
  echo "Android APK build failed." | tee -a "${SUMMARY_FILE}"
  exit 1
fi

echo "Success count: ${success_count}" | tee -a "${SUMMARY_FILE}"
if [[ ${#failed_targets[@]} -gt 0 ]]; then
  echo "Failed targets: ${failed_targets[*]}" | tee -a "${SUMMARY_FILE}"
fi

if [[ ${success_count} -eq 0 ]]; then
  echo "No artifacts generated." | tee -a "${SUMMARY_FILE}"
  exit 1
fi

if [[ ${strict_fail} -ne 0 ]]; then
  echo "Required targets failed." | tee -a "${SUMMARY_FILE}"
  exit 1
fi

cleanup_intermediate_outputs

if [[ "${CLEANUP_MODE}" == "all" ]]; then
  echo "Artifacts are in ${OUT_DIR}"
else
  echo "Artifacts are in ${OUT_DIR}" | tee -a "${SUMMARY_FILE}"
fi

#!/usr/bin/env bash
set -euo pipefail

: "${TARGET:?TARGET environment variable is required}"
: "${GITHUB_ENV:?GITHUB_ENV environment variable is required}"

apt_update_args=()
if [[ -n "${APT_UPDATE_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  apt_update_args=(${APT_UPDATE_ARGS})
fi

apt_install_args=()
if [[ -n "${APT_INSTALL_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  apt_install_args=(${APT_INSTALL_ARGS})
fi

sudo apt-get update "${apt_update_args[@]}"
sudo apt-get install -y "${apt_install_args[@]}"   ca-certificates curl make perl binutils musl-tools pkg-config   g++ clang libc++-dev libc++abi-dev lld xz-utils

case "${TARGET}" in
  x86_64-unknown-linux-musl)
    arch="x86_64"
    ;;
  aarch64-unknown-linux-musl)
    arch="aarch64"
    ;;
  *)
    echo "Unexpected musl target: ${TARGET}" >&2
    exit 1
    ;;
esac

libcap_version="2.75"
libcap_sha256="de4e7e064c9ba451d5234dd46e897d7c71c96a9ebf9a0c445bc04f4742d83632"
libcap_tarball_name="libcap-${libcap_version}.tar.xz"
libcap_download_url="https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/${libcap_tarball_name}"

runner_temp="${RUNNER_TEMP:-/tmp}"
tool_root="${runner_temp}/codex-musl-tools-${TARGET}"
mkdir -p "${tool_root}"

# ---------------------------------------------------------------------------
# TOOLCHAIN CONTRACT
# ---------------------------------------------------------------------------
# HOST tools build and/or execute programs on the x86_64 GitHub runner.
# TARGET tools produce ARM64 Linux-musl objects and executables.
#
# Never put a target compiler in global CC/CXX: Cargo build scripts and native
# dependencies also compile host-side helper programs.
# ---------------------------------------------------------------------------

zig_target="${TARGET/-unknown-linux-musl/-linux-musl}"

if [[ "${TARGET}" == "aarch64-unknown-linux-musl" ]]; then
  command -v zig >/dev/null || {
    echo "Zig is required for AArch64 musl cross-compilation" >&2
    exit 1
  }

  zig_bin="$(command -v zig)"
  musl_linker="${zig_bin} cc -target ${zig_target}"

  # Compile a real target executable and prove its ELF machine type.
  probe_dir="${tool_root}/toolchain-probe"
  rm -rf "${probe_dir}"
  mkdir -p "${probe_dir}"
  printf 'int main(void){return 0;}\n' > "${probe_dir}/probe.c"
  "${zig_bin}" cc -target "${zig_target}" "${probe_dir}/probe.c" -o "${probe_dir}/probe"

  file "${probe_dir}/probe" | tee "${probe_dir}/probe.file"
  grep -Eq 'ARM aarch64|AArch64' "${probe_dir}/probe.file"
  ! grep -Eq 'x86-64|x86_64' "${probe_dir}/probe.file"
  readelf -h "${probe_dir}/probe" | grep -Eq 'Machine:.*AArch64'

  # Also prove the target compiler can create a relocatable ARM64 object.
  "${zig_bin}" cc -target "${zig_target}" -c "${probe_dir}/probe.c" -o "${probe_dir}/probe.o"
  file "${probe_dir}/probe.o" | tee "${probe_dir}/probe.o.file"
  grep -Eq 'ARM aarch64|AArch64' "${probe_dir}/probe.o.file"

  echo "AArch64 musl compiler probe: PASS"
else
  if command -v "${arch}-linux-musl-gcc" >/dev/null; then
    musl_linker="$(command -v "${arch}-linux-musl-gcc")"
  elif command -v musl-gcc >/dev/null; then
    musl_linker="$(command -v musl-gcc)"
  else
    echo "musl gcc not found after install; arch=${arch}" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# libcap: build ONLY the static archive needed by Codex.
# ---------------------------------------------------------------------------
# libcap 2.75's normal/shared build creates an ARM64 'empty' executable and
# then invokes objcopy to extract .interp. That shared-library path is not
# required by Codex and is a common source of host/target objcopy mismatches.
#
# SHARED=no is intentional and is part of the cross-compilation contract.
# BUILD_CC=gcc is required for libcap's _makenames host-side generator.
# ---------------------------------------------------------------------------

libcap_root="${tool_root}/libcap-${libcap_version}"
libcap_src_root="${libcap_root}/src"
libcap_prefix="${libcap_root}/prefix"
libcap_pkgconfig_dir="${libcap_prefix}/lib/pkgconfig"

if [[ ! -f "${libcap_prefix}/lib/libcap.a" ]]; then
  rm -rf "${libcap_src_root}" "${libcap_prefix}"
  mkdir -p "${libcap_src_root}" "${libcap_prefix}/lib"     "${libcap_prefix}/include/sys" "${libcap_prefix}/include/linux"     "${libcap_pkgconfig_dir}"

  libcap_tarball="${libcap_root}/${libcap_tarball_name}"
  curl -fsSL "${libcap_download_url}" -o "${libcap_tarball}"
  echo "${libcap_sha256}  ${libcap_tarball}" | sha256sum -c -

  tar -xJf "${libcap_tarball}" -C "${libcap_src_root}"
  libcap_source_dir="${libcap_src_root}/libcap-${libcap_version}"

  make -C "${libcap_source_dir}/libcap" -j"$(nproc)" libcap.a     SHARED=no     CC="${musl_linker}"     BUILD_CC=gcc     AR=ar     RANLIB=ranlib

  test -s "${libcap_source_dir}/libcap/libcap.a"
  ar t "${libcap_source_dir}/libcap/libcap.a" | grep -q '^cap_alloc.o$'

  # GNU objdump on Ubuntu supports reading foreign ELF objects; this is a
  # host-side inspection only and never participates in the target build.
  objdump -f "${libcap_source_dir}/libcap/cap_alloc.o" |     grep -Eq 'aarch64|AArch64|ARM aarch64' || {
      echo "libcap archive object is not AArch64" >&2
      exit 1
    }

  cp "${libcap_source_dir}/libcap/libcap.a" "${libcap_prefix}/lib/libcap.a"
  cp "${libcap_source_dir}/libcap/include/uapi/linux/capability.h"     "${libcap_prefix}/include/linux/capability.h"
  cp "${libcap_source_dir}/libcap/../libcap/include/sys/capability.h"     "${libcap_prefix}/include/sys/capability.h"

  cat > "${libcap_pkgconfig_dir}/libcap.pc" <<EOF
prefix=${libcap_prefix}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libcap
Description: Linux capabilities
Version: ${libcap_version}
Libs: -L\${libdir} -lcap
Cflags: -I\${includedir}
EOF
fi

# ---------------------------------------------------------------------------
# Cargo/native build environment
# ---------------------------------------------------------------------------

sysroot=""
if command -v zig >/dev/null; then
  zig_bin="$(command -v zig)"
  cc="${tool_root}/zigcc"
  cxx="${tool_root}/zigcxx"

  # Quoted heredoc: wrapper arguments MUST be evaluated when the wrapper runs,
  # not while this setup script is generating it.
  cat > "${cc}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

: "${ZIG_BIN:?ZIG_BIN is required}"
: "${ZIG_TARGET:?ZIG_TARGET is required}"

args=()
skip_next=0
pending_include=0

for arg in "$@"; do
  if [[ "${pending_include}" -eq 1 ]]; then
    pending_include=0
    if [[ "${arg}" == /usr/include || "${arg}" == /usr/include/* ]]; then
      args+=("-idirafter" "${arg}")
    else
      args+=("-I" "${arg}")
    fi
    continue
  fi

  if [[ "${skip_next}" -eq 1 ]]; then
    skip_next=0
    continue
  fi

  case "${arg}" in
    --target)
      skip_next=1
      continue
      ;;
    --target=*|-target=*)
      continue
      ;;
    -target)
      skip_next=1
      continue
      ;;
    -I)
      pending_include=1
      continue
      ;;
    -I/usr/include|-I/usr/include/*)
      args+=("-idirafter" "${arg#-I}")
      continue
      ;;
    -Wp,-U_FORTIFY_SOURCE)
      args+=("-U_FORTIFY_SOURCE")
      continue
      ;;
  esac

  args+=("${arg}")
done

exec "${ZIG_BIN}" cc -target "${ZIG_TARGET}" "${args[@]}" -fno-sanitize=undefined
WRAPPER

  cat > "${cxx}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

: "${ZIG_BIN:?ZIG_BIN is required}"
: "${ZIG_TARGET:?ZIG_TARGET is required}"

args=()
skip_next=0
pending_include=0

for arg in "$@"; do
  if [[ "${pending_include}" -eq 1 ]]; then
    pending_include=0
    if [[ "${arg}" == /usr/include || "${arg}" == /usr/include/* ]]; then
      args+=("-idirafter" "${arg}")
    else
      args+=("-I" "${arg}")
    fi
    continue
  fi

  if [[ "${skip_next}" -eq 1 ]]; then
    skip_next=0
    continue
  fi

  case "${arg}" in
    --target)
      skip_next=1
      continue
      ;;
    --target=*|-target=*)
      continue
      ;;
    -target)
      skip_next=1
      continue
      ;;
    -I)
      pending_include=1
      continue
      ;;
    -I/usr/include|-I/usr/include/*)
      args+=("-idirafter" "${arg#-I}")
      continue
      ;;
    -Wp,-U_FORTIFY_SOURCE)
      args+=("-U_FORTIFY_SOURCE")
      continue
      ;;
  esac

  args+=("${arg}")
done

exec "${ZIG_BIN}" c++ -target "${ZIG_TARGET}" "${args[@]}" -fno-sanitize=undefined
WRAPPER

  chmod +x "${cc}" "${cxx}"

  # These are consumed by the wrappers at execution time.
  echo "ZIG_BIN=${zig_bin}" >> "$GITHUB_ENV"
  echo "ZIG_TARGET=${zig_target}" >> "$GITHUB_ENV"

  sysroot="$( "${zig_bin}" cc -target "${zig_target}" -print-sysroot 2>/dev/null || true)"
else
  cc="${musl_linker}"

  if command -v "${arch}-linux-musl-g++" >/dev/null; then
    cxx="$(command -v "${arch}-linux-musl-g++")"
  elif command -v musl-g++ >/dev/null; then
    cxx="$(command -v musl-g++)"
  else
    cxx="${cc}"
  fi
fi

# ---------------------------------------------------------------------------
# Export only target-specific compiler variables for cross builds.
# Keep global CC/CXX as native host compilers.
# ---------------------------------------------------------------------------

if [[ -n "${sysroot}" && "${sysroot}" != "/" ]]; then
  echo "BORING_BSSL_SYSROOT=${sysroot}" >> "$GITHUB_ENV"
  boring_sysroot_var="BORING_BSSL_SYSROOT_${TARGET}"
  boring_sysroot_var="${boring_sysroot_var//-/_}"
  echo "${boring_sysroot_var}=${sysroot}" >> "$GITHUB_ENV"
fi

cflags="-pthread"
cxxflags="-pthread"
target_cflags="-pthread"
target_cxxflags="-pthread"
if [[ "${TARGET}" == "aarch64-unknown-linux-musl" ]]; then
  target_cflags="${target_cflags} -Wno-error=frame-larger-than"
  target_cxxflags="${target_cxxflags} -Wno-error=frame-larger-than"
fi

echo "CFLAGS=${cflags}" >> "$GITHUB_ENV"
echo "CXXFLAGS=${cxxflags}" >> "$GITHUB_ENV"

# Host compilers: used for host build scripts/generators.
echo "CC=gcc" >> "$GITHUB_ENV"
echo "CXX=g++" >> "$GITHUB_ENV"

# aws-lc-sys has explicit target compiler/flag variables. Keep host builds on
# native gcc/g++, while AWS-LC target objects use the AArch64 musl compiler.
echo "AWS_LC_SYS_CC=gcc" >> "$GITHUB_ENV"
echo "AWS_LC_SYS_CXX=g++" >> "$GITHUB_ENV"
echo "AWS_LC_SYS_TARGET_CC=${cc}" >> "$GITHUB_ENV"
echo "AWS_LC_SYS_TARGET_CXX=${cxx}" >> "$GITHUB_ENV"
echo "AWS_LC_SYS_TARGET_CFLAGS=${target_cflags}" >> "$GITHUB_ENV"
echo "AWS_LC_SYS_TARGET_CXXFLAGS=${target_cxxflags}" >> "$GITHUB_ENV"

# Target compilers: used only for the target triple.
target_cc_var="CC_${TARGET^^}"
target_cc_var="${target_cc_var//-/_}"
echo "${target_cc_var}=${cc}" >> "$GITHUB_ENV"

target_cxx_var="CXX_${TARGET^^}"
target_cxx_var="${target_cxx_var//-/_}"
echo "${target_cxx_var}=${cxx}" >> "$GITHUB_ENV"

cargo_linker_var="CARGO_TARGET_${TARGET^^}_LINKER"
cargo_linker_var="${cargo_linker_var//-/_}"
echo "${cargo_linker_var}=${cc}" >> "$GITHUB_ENV"

echo "CMAKE_C_COMPILER=gcc" >> "$GITHUB_ENV"
echo "CMAKE_CXX_COMPILER=g++" >> "$GITHUB_ENV"
echo "CMAKE_ARGS=-DCMAKE_HAVE_THREADS_LIBRARY=1 -DCMAKE_USE_PTHREADS_INIT=1 -DCMAKE_THREAD_LIBS_INIT=-pthread -DTHREADS_PREFER_PTHREAD_FLAG=ON" >> "$GITHUB_ENV"

echo "PKG_CONFIG_ALLOW_CROSS=1" >> "$GITHUB_ENV"
pkg_config_path="${libcap_pkgconfig_dir}"
if [[ -n "${PKG_CONFIG_PATH:-}" ]]; then
  pkg_config_path="${pkg_config_path}:${PKG_CONFIG_PATH}"
fi
echo "PKG_CONFIG_PATH=${pkg_config_path}" >> "$GITHUB_ENV"

pkg_config_path_var="PKG_CONFIG_PATH_${TARGET^^}"
pkg_config_path_var="${pkg_config_path_var//-/_}"
echo "${pkg_config_path_var}=${libcap_pkgconfig_dir}" >> "$GITHUB_ENV"

pkg_config_libdir_var="PKG_CONFIG_LIBDIR_${TARGET^^}"
pkg_config_libdir_var="${pkg_config_libdir_var//-/_}"
echo "${pkg_config_libdir_var}=${libcap_pkgconfig_dir}" >> "$GITHUB_ENV"

if [[ -n "${sysroot}" && "${sysroot}" != "/" ]]; then
  echo "PKG_CONFIG_SYSROOT_DIR=${sysroot}" >> "$GITHUB_ENV"
  pkg_config_sysroot_var="PKG_CONFIG_SYSROOT_DIR_${TARGET^^}"
  pkg_config_sysroot_var="${pkg_config_sysroot_var//-/_}"
  echo "${pkg_config_sysroot_var}=${sysroot}" >> "$GITHUB_ENV"
fi

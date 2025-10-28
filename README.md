# python-wheel-convert-to-s390x

A containerized toolchain to validate a seed set of Python wheels and build the full transitive dependency closure as native s390x wheels from source. It is designed for environments where prebuilt manylinux wheels are unavailable for IBM Z (s390x), and you need a reproducible way to assemble a complete, architecture-correct wheelhouse.

This project does not “convert” wheels between architectures. Instead, it verifies your seed wheel(s), inspects declared dependencies, and builds those dependencies from source as s390x wheels. It handles complex packages (notably PyArrow) by compiling required native libraries inside the container.


**What You Get**
- **Validated wheelhouse:** Every input wheel is installed in a throwaway target to check basic import/install viability without dependencies.
- **Full dependency closure:** The script reads `Requires-Dist` metadata and breadth‑first builds all direct and transitive dependencies as s390x wheels.
- **Native builds:** Uses `pip wheel --no-binary :all:` to force source builds for correct s390x artifacts.
- **PyArrow support:** Compiles Apache Arrow C++ once, then builds PyArrow against it.
- **Detailed logs:** Per‑package build and validation logs for traceability.


## How It Works

The workflow runs inside a purpose-built Ubuntu container and is orchestrated by `build-wheels.sh`. At a high level:

1) The `Dockerfile.s390x` provisions a minimal s390x build image:
   - Tooling: `build-essential`, `gcc/g++/gfortran`, `cmake`, `ninja`, `autoconf/automake/libtool`, `pkg-config`.
   - Common native deps: `libopenblas-dev`, `liblapack-dev`, `libssl-dev`, `liblz4-dev`, `libsnappy-dev`, `libzstd-dev`, `zlib1g-dev`, `libbz2-dev`.
   - Python toolchain: `python3`, `python3-dev`, `python3-venv`, then upgrades `pip`, `setuptools`, `wheel`, `Cython` in a venv at `/venv`.
   - Installs `build-wheels.sh` at `/usr/local/bin/build-wheels.sh` and sets the entrypoint to `/bin/bash`.

2) The `build-wheels.sh` script runs in four main phases:
   - **ENV CHECK:** Prints Python/pip versions and ensures Python build tooling (`pip`, `setuptools`, `wheel`, `packaging`) are present.
   - **DISCOVERY:** Finds `*.whl` in the working directory (`/work` by default) — these are the “seed” wheels you care about.
   - **STRUCTURAL VALIDATION:** For each seed wheel, installs it with `--no-deps` into a temporary directory to catch obvious packaging/import issues. If the install succeeds, the wheel is copied into the validated wheelhouse.
   - **DEPENDENCY RESOLUTION:** Reads `Requires-Dist` from the wheel’s `METADATA` (evaluating environment markers) and executes a BFS walk to build all direct and transitive dependencies from source as s390x wheels.

3) Artifact detection and idempotency:
   - Produced wheels are detected by diffing the wheelhouse directory before/after each build step, with a fallback that parses `pip wheel` logs (`Saved ... .whl`).
   - The script canonicalizes project names using `packaging` and recognizes both `-` and `_` in filenames, so it won’t rebuild packages already present.

4) Special‑case for PyArrow:
   - PyArrow requires Arrow C++ libraries. The script compiles Arrow C++ once (using CMake with `-DARROW_*` feature flags) and sets `CMAKE_PREFIX_PATH`/`Arrow_DIR` so PyArrow links against the local install.
   - It exports `PYARROW_BUNDLE_ARROW_CPP=0` to avoid bundling Arrow C++ and keeps build logs under `/work/build_logs`.


## What It Actually Does (Scope)

- Validates given wheels and builds all dependencies from source into a single wheelhouse directory.
- Targets s390x by building natively within an s390x container base image.
- Focuses on correctness and reproducibility rather than speed. Heavy packages (e.g., Arrow C++) will take significant time and RAM/CPU.
- Does not modify, retag, or “convert” foreign‑arch wheels. If a wheel is for another architecture, it is not repackaged; instead, dependencies are compiled natively.


## Image Contents

- Base image: `mirror.gcr.io/library/ubuntu:24.04`
- Build tools: `build-essential`, compilers, CMake, Ninja, autotools, `pkg-config`
- Common numeric/compression libs: OpenBLAS/LAPACK, SSL, Snappy, LZ4, Zstandard, zlib, bzip2
- Python: system `python3`, plus venv at `/venv` with up‑to‑date `pip`, `setuptools`, `wheel`, `Cython`
- Entrypoint: `/bin/bash`
- Script: `/usr/local/bin/build-wheels.sh`


## Script Internals (Deep Dive)

`build-wheels.sh` is organized into reusable helpers and phases:

- **Environment and tooling**
  - Activates the venv and ensures `pip`, `setuptools`, `wheel`, and `packaging` are installed.
  - Configurable via env vars `PY_BIN` and `PIP_BIN` (default: `/venv/bin/python3`, `/venv/bin/pip`).

- **Name handling**
  - Uses `packaging.requirements.Requirement` and `packaging.utils.canonicalize_name` to derive a project’s canonical base name from a PEP 508 spec. This prevents unnecessary rebuilds (e.g., it recognizes that `numpy>=1.20` and `NumPy` are the same project).
  - Detects already‑built wheels with both hyphen and underscore forms in filenames.

- **Validation**
  - `validate_wheel_no_deps`: Installs a wheel into a temporary directory with `--no-deps`. On success, the wheel is copied to the output wheelhouse.

- **Metadata parsing**
  - `requires_from_wheel`: Reads the wheel’s `METADATA` from the `.dist-info/` directory and prints normalized `Requires-Dist` lines, respecting environment markers for the current interpreter/platform.

- **Building**
  - `build_spec_with_deps`: Runs `pip wheel --no-binary :all:` to force a source build of a PEP 508 spec into the wheelhouse. For PyArrow it precompiles Arrow C++ and sets the required environment variables so PyArrow links against it.
  - Tracks produced artifacts by diffing the wheelhouse state before/after; falls back to parsing `pip`’s “Saved … .whl” lines when needed.

- **Dependency closure (BFS)**
  - `build_dependency_closure`: Seeds the queue with all direct dependencies of the validated wheel. Each produced wheel’s dependencies are enqueued, skipping anything already present or previously processed, until the closure is exhausted.

- **Logging**
  - Pretty, timestamped logging with `ENV CHECK`, `PHASE 1–4` headers.
  - Writes detailed logs per build under `/work/build_logs`, including `arrow_cmake.out`, `arrow_make.out`, and `arrow_install.out` for the Arrow build.


## Quick Start

1) Build the s390x image:

```bash
docker build -f Dockerfile.s390x -t s390x-wheelhouse:latest .
```

2) Prepare your seed wheels directory on the host (these are the primary wheels you want to validate and for which you want dependencies built). For example, place `my_package-1.0.0-py3-none-any.whl` into `./wheels`.

3) Run the container, mounting:
   - Your seed wheels directory → `/work`
   - An output directory → `/validated_wheels`
   - A logs directory → `/work/build_logs`

```bash
mkdir -p wheelhouse build_logs
docker run --rm \
  -v "$PWD/wheels:/work" \
  -v "$PWD/wheelhouse:/validated_wheels" \
  -v "$PWD/build_logs:/work/build_logs" \
  s390x-wheelhouse:latest \
  /usr/local/bin/build-wheels.sh
```

4) Results:
   - Validated seed wheels and all s390x dependency wheels land in `./wheelhouse`.
   - Build/validation logs appear in `./build_logs`.


## Advanced Usage

- Positional arguments:
  - `build-wheels.sh [VALIDATED_DIR] [LOG_DIR]`
  - Defaults: `VALIDATED_DIR=/validated_wheels`, `LOG_DIR=/work/build_logs`

- Environment variables:
  - `PY_BIN`: Python interpreter (default `/venv/bin/python3`)
  - `PIP_BIN`: pip (default `/venv/bin/pip`)
  - Standard build variables like `CFLAGS`, `LDFLAGS`, `CMAKE_PREFIX_PATH` may help for custom/advanced native builds.

- Building PyArrow explicitly:
  - PyArrow is handled automatically when it appears in the dependency graph. If you want to seed with PyArrow directly, place a PyArrow wheel (or seed a dependent wheel) in `/work`. The script compiles Arrow C++ if not already present and then builds PyArrow.


## Tips and Expectations

- Heavy native builds: Arrow C++, NumPy/SciPy (with OpenBLAS/LAPACK), and similar packages can take significant time and resources. Ensure the host has sufficient CPU/RAM and consider constraining container resources appropriately.
- Extra system deps: Some packages may need additional `apt` libraries not preinstalled here. Extend `Dockerfile.s390x` to add those if you encounter missing headers/libraries.
- Idempotent runs: Re-running with the same wheelhouse will skip already-present base packages (thanks to canonical name matching and filename normalization).
- Environment markers: Dependencies are evaluated against the running environment (e.g., Python version). Changing the base Python may change resolved dependencies.


## Outputs and Logs

- Output wheelhouse: `/validated_wheels` (mount a host directory here to persist results).
- Logs directory: `/work/build_logs`
  - Per-package logs such as `build_<project>.log` and validation logs `validate_<wheel>.log`.
  - Arrow C++ build logs: `arrow_cmake.out`, `arrow_make.out`, `arrow_install.out`.
- Summary: At the end, the script prints a summary with total wheels present and points to the logs directory.


## Troubleshooting

- Build fails for a dependency
  - Check `build_<project>.log` in `/work/build_logs`.
  - Look for missing system headers/libs; extend `Dockerfile.s390x` to `apt install` what’s needed.

- No wheels produced for a package you expected
  - The script logs `[have]` when it detects that the wheelhouse already contains that base package.
  - If still unclear, examine the `Saved ... .whl` lines parsed from the pip log and verify the wheelhouse diff logic.

- PyArrow build errors
  - Inspect `arrow_*` logs. Some Arrow features may require additional system libraries. Adjust CMake flags in `build-wheels.sh` or add libs in the Dockerfile.


## Repository Layout

- `Dockerfile.s390x` — s390x Ubuntu 24.04 base with toolchains and Python venv; installs the build script.
- `build-wheels.sh` — orchestrates validation, dependency parsing, native builds, logging, and artifact detection.
- `LICENSE` — project license.


## License

See `LICENSE` for details.

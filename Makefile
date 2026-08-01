.PHONY: package-macos package-windows clean-dist

## Build + package macOS .app into dist/ (.zip + .dmg)
package-macos:
	bash scripts/package_macos.sh

## Build + package Windows release zip (must run on Windows)
package-windows:
	powershell -ExecutionPolicy Bypass -File scripts/package_windows.ps1

clean-dist:
	rm -rf dist

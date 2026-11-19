{
  lib,
  fetchPypi,
  python3Packages,
  rustPlatform,
}:
python3Packages.buildPythonApplication (finalAttrs: {
  pname = "complexipy";
  version = "7.0.1";
  pyproject = true;

  src = fetchPypi {
    inherit (finalAttrs) pname version;
    hash = "sha256-6a6vtm2fbgTpj+sc4UzTGxFK5WdXjtLOrw5rusf6Kfo=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) src;
    hash = "sha256-Rwgz56HP9eKRJ0wR5Z3LcAeRtM3lpCck4T9uIOgMznY=";
  };

  nativeBuildInputs = with rustPlatform; [
    cargoSetupHook
    maturinBuildHook
  ];

  dependencies = with python3Packages; [
    tomli
    typer
  ];

  pythonImportsCheck = [ "complexipy" ];

  meta = {
    description = "Fast cognitive complexity analysis for Python";
    homepage = "https://github.com/rohaquinlop/complexipy";
    changelog = "https://github.com/rohaquinlop/complexipy/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.mit;
    maintainers = [ ];
    mainProgram = "complexipy";
  };
})

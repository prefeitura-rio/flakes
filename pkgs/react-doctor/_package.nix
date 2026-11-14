{
  lib,
  buildNpmPackage,
  fetchurl,
  makeWrapper,
  nodejs,
}:
buildNpmPackage (finalAttrs: {
  pname = "react-doctor";
  version = "0.9.12";

  src = fetchurl {
    url = "https://registry.npmjs.org/react-doctor/-/react-doctor-${finalAttrs.version}.tgz";
    hash = "sha256-8rhyM0ct1QlTHr8wpw6crpouO+N7y1VWGTQL9fe2qpc=";
  };

  npmDepsHash = "sha256-4EeSyBqkbCHFuaWGYgndAl7lL3CS92t42VlZAMVWcpw=";
  dontNpmBuild = true;

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
    ${nodejs}/bin/node -e '
      const fs = require("node:fs");
      const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));
      delete packageJson.devDependencies;
      fs.writeFileSync("package.json", JSON.stringify(packageJson, null, 2) + String.fromCharCode(10));
    '
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/node_modules/react-doctor $out/bin
    cp -r . $out/lib/node_modules/react-doctor
    makeWrapper ${nodejs}/bin/node $out/bin/react-doctor \
      --add-flags "$out/lib/node_modules/react-doctor/bin/react-doctor.js"
    runHook postInstall
  '';

  meta = {
    description = "React-specific code quality diagnostics";
    homepage = "https://github.com/millionco/react-doctor";
    license = lib.licenses.mit;
    maintainers = [ ];
    mainProgram = "react-doctor";
  };
})

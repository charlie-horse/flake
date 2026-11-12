{
  buildDotnetModule,
  dotnetCorePackages,
  fetchFromGitHub,
  fetchNuGet,
  writeShellScript,
  icu,
  lib,
  patchelf,
  stdenv,
  runCommand,
  expect,
}:
let
  inherit (dotnetCorePackages) sdk_6_0 runtime_6_0;
in
let
  finalPackage = buildDotnetModule rec {
    pname = "omnisharp-roslyn";
    version = "1.39.4";

    src = fetchFromGitHub {
      owner = "OmniSharp";
      repo = pname;
      rev = "v${version}";
      sha256 = "sha256-rX0FeURw6WMbcJOomqHFcZ9tpKO1td60/HbbVClV324=";
    };

    projectFile = "src/OmniSharp.Stdio.Driver/OmniSharp.Stdio.Driver.csproj";
    nugetDeps = ./deps.nix;

    nativeBuildInputs = [
      patchelf
    ];

    dotnetInstallFlags = [ "--framework net472" ];
    dotnetBuildFlags = [ "--framework net472" ];
    dotnetFlags = [
      # These flags are set by the cake build.
      "-property:PackageVersion=${version}"
      "-property:AssemblyVersion=${version}.0"
      "-property:FileVersion=${version}.0"
      "-property:InformationalVersion=${version}"
      "-property:RuntimeFrameworkVersion=${runtime_6_0.version}"
      "-property:RollForward=LatestMajor"
    ];

    postPatch = ''
      # Relax the version requirement
      substituteInPlace global.json \
        --replace '7.0.100-rc.1.22431.12' '${sdk_6_0.version}'
      # Patch the project files so we can compile them properly
      for project in src/OmniSharp.Http.Driver/OmniSharp.Http.Driver.csproj src/OmniSharp.LanguageServerProtocol/OmniSharp.LanguageServerProtocol.csproj src/OmniSharp.Stdio.Driver/OmniSharp.Stdio.Driver.csproj; do
        substituteInPlace $project \
          --replace '<RuntimeIdentifiers>win7-x64;win7-x86;win10-arm64</RuntimeIdentifiers>' '<RuntimeIdentifiers>linux-x64;linux-arm64;osx-x64;osx-arm64</RuntimeIdentifiers>'
      done
    '';

    bundle = fetchNuGet {
      pname = "SQLitePCLRaw.bundle_green";
      version = "2.1.0";
      sha256 = "sha256-W14WMqNZndRmnySqLdFqmvfbH14kJxMV6+/4dIS0CwE=";
      outputFiles = [ "lib/netstandard2.0/*" ];
    };
    core = fetchNuGet {
      pname = "SQLitePCLRaw.core";
      version = "2.1.0";
      sha256 = "sha256-l1lfw114VmMprNFNn1fM/wzKEbDywXDlgdTQWWbqBU8=";
      outputFiles = [ "lib/netstandard2.0/*" ];
    };
    provider = fetchNuGet {
      pname = "SQLitePCLRaw.provider.e_sqlite3";
      version = "2.1.0";
      sha256 = "sha256-VkGdCCECj+0oaha/QsyfF9CQoaurC/KO2RHR2GaI77w=";
      outputFiles = [ "lib/netstandard2.0/*" ];
    };

    dontDotnetFixup = true; # we'll fix it ourselves
    postFixup = lib.optionalString stdenv.isLinux ''
      cp ${bundle}/lib/dotnet/SQLitePCLRaw.bundle_green/*.dll $out/lib/omnisharp-roslyn/
      cp ${core}/lib/dotnet/SQLitePCLRaw.core/*.dll $out/lib/omnisharp-roslyn/
      cp ${provider}/lib/dotnet/SQLitePCLRaw.provider.e_sqlite3/*.dll $out/lib/omnisharp-roslyn/

      mkdir -p $out/bin
      echo "${''
        #!/usr/bin/env bash

        base_dir=$out
        omnisharp_dir=''\\''\${base_dir}/lib/omnisharp-roslyn
        omnisharp_cmd=''\\''\${omnisharp_dir}/OmniSharp.exe
        mono_cmd=mono

        \"''\\''\${mono_cmd}\" \"''\\''\${omnisharp_cmd}\" \"\$@\"
      ''}" > $out/bin/OmniSharp
      chmod 755 $out/bin/OmniSharp
    '';

    meta = with lib; {
      description = "OmniSharp based on roslyn workspaces";
      homepage = "https://github.com/OmniSharp/omnisharp-roslyn";
      sourceProvenance = with sourceTypes; [
        fromSource
        binaryNativeCode # dependencies
      ];
      license = licenses.mit;
    };
  };
in
finalPackage

{
  description = "Profile manipulation functions";
  nixConfig.substituters = ["https://github.com/tomberek/floxmeta/releases/latest/download/"];
  nixConfig.trustedKeys = "floxdev.com-1:Qp9ctlVGzK7IASHGy3d9HlcsaPg8m4rKEqay8VcVrOQ=";
  inputs.capacitor.url = "git+ssh://git@github.com/flox/capacitor";

  outputs = inputs @ {self, ...}: let
    manifestAttr = with builtins; fromJSON (readFile manifestPath);
    manifestPath = "${self.outPath}/manifest.json";
  in {

    # an app to upload results to a GitHub Release-hosted store
    # $1 = location of key file
    # $2 = tag to use in GitHub
    # $3 = attribute path to build
    # note: .store remains on disk
    apps = with inputs.capacitor.inputs; nixpkgs.lib.genAttrs ["x86_64-linux"] (system: with nixpkgs.legacyPackages.${system}; {
      copy-to-gh = {
        type = "app";
        program = (writeShellApplication {
          name = "upload-cache";
          runtimeInputs = [ gnused github-cli findutils ];
          text = ''
            nix build "$3"
            nix store sign --key-file "$1" --recursive ./result
            mkdir -p "$PWD/.store"
            nix copy --to "file://$PWD/.store?parallel-compression=1&write-nar-listing=1&parallel-compression=1" ./result
            find .store -iname "*.narinfo" -exec sed -i 's#URL: nar/#URL: #' {} +
            git tag "$2" || true
            gh release create --target ${system}.default --generate-notes "$2" || true
            gh release upload --clobber "$2" .store/*.narinfo .store/nar/* .store/nix-cache-info
            gh release list
          '';
        })+"/bin/upload-cache";
      };
    });

    __pins.vscode-extensions = [
      {
        name = "python";
        publisher = "ms-python";
        sha256 = "0607sfplkin97zrrv00vypfgbpfcljzfd6sb4jn07w7ng2rvwv65";
        version = "2022.9.11741005";
      }
      {
        name = "pylint";
        publisher = "ms-python";
        sha256 = "1vhy3jh2wx4bx48sn1k584bgnwjq0m4ckp7wkkh0frc6acpilp2k";
        version = "2022.3.11671003";
      }
    ];
    pinnedPackages =
      builtins.mapAttrs (system: _: {
        vscodeCustom =
          inputs.capacitor.lib.vscode.configuredVscode
          inputs.capacitor.inputs.nixpkgs.legacyPackages.${system}
          {extensions = map (x: "${x.publisher}.${x.name}") self.__pins.vscode-extensions;}
          self.__pins.vscode-extensions;
      })
      self.lib.systems;

    legacyPackages =
      builtins.mapAttrs (
        system: _:
          ((self.lib.packageSet system manifestAttr).legacyPackages.${system} or {})
          // {default = self.legacyPackages.${system}.catalog.flox.stable.flox;}
      )
      self.lib.systems;
    packages =
      builtins.mapAttrs (
        system: _:
          self.lib.makeProfile.${system} manifestPath manifestAttr
      )
      self.lib.systems;

    generations = with builtins; let
      nameValuePair = name: value: {inherit name value;};
      filterAttrs = pred: set:
        listToAttrs (concatMap (name: let
          v = set.${name};
        in
          if pred name v
          then [(nameValuePair name v)]
          else []) (attrNames set));
      gensJSON =
        filterAttrs
        (n: v: builtins.match "[0-9]*\\.json$" n != null && v == "regular")
        (builtins.readDir ./.);
      gens = map (x: builtins.substring 0 (stringLength x - 5) x) (builtins.attrNames gensJSON);

      genAttrs = names: f: listToAttrs (map (n: nameValuePair n (f n)) names);
    in
      genAttrs gens (gen: let
        manifestAttr = with builtins; fromJSON (readFile manifestPath);
        manifestPath = "${self.outPath}/${gen}.json";
      in {
        legacyPackages =
          builtins.mapAttrs (
            system: _:
              (self.lib.packageSet system manifestAttr).legacyPackages.${system} or {}
          )
          self.lib.systems;
      });

    lib = rec {
      systems = {
        "aarch64-darwin" = {};
        "aarch64-linux" = {};
        # "armv6l-linux" = {};
        # "armv7l-linux" = {};
        # "i686-linux" = {};
        # "mipsel-linux" = {};
        "x86_64-darwin" = {};
        "x86_64-linux" = {};
      };

      # Copied from nixpkgs
      attrByPath = with builtins;
        attrPath: default: e: let
          attr = head attrPath;
        in
          if attrPath == []
          then e
          else if e ? ${attr}
          then attrByPath (tail attrPath) default e.${attr}
          else default;

      # fetch an element from the manifest. Rewrite the attrpath with the provided system.
      fetchFromElement = system: element:
        if element ? attrPath
        then let
          attr =
            self.lib.attrByPath
            (
              map (s:
                if systems ? ${s}
                then system
                else s)
              (self.lib.parsePath element.attrPath)
            ) (throw "unable to find ${element.attrPath} in ${element.url}")
            (builtins.getFlake element.url);
        in
          builtins.map (x: attr.${x}) (attr.meta.outputsToInstall or attr.outputs)
        else
          # TODO: requires --impure. eventually upgrade to fetchClosure
          map (y: {
            type = "derivation";
            outPath = builtins.storePath y;
          })
          element.storePaths;

      # Create a profile using a system and packages
      makeEnv = system: packages:
        derivation {
          name = "profile";
          builder = "builtin:buildenv";
          system = system;
          # manifest = "this-symlink-intentionally-left-dangling";
          # using this symlink ensures we keep the originating source around. Good? Bad?
          manifest = manifestPath;
          # TODO: get priority from new format
          derivations = map (x: ["true" 5 1 x]) packages;
        };

      # make a manifest using a system
      makeManifest = system: env: manifest:
        derivation {
          name = "profile";
          system = system;
          builder = "/bin/sh";
          args = [
            "-c"
            ''
              # Force this build to potentially contain all possible runtime references
              # Copy text file, with only POSIX shell builtins
              while IFS= read -r line; do
                printf '%s\n' "$line"
              done < ${manifest} >> $out
              [ -n "$line" ] && printf "%s" "$line" >> $out
              echo done writing manifest
            ''
          ];
        };

      # Create a derivation representing the profile
      makeProfile =
        # {{{
        builtins.mapAttrs (
          system: _: manifestPath: manifestAttr: let
            packages = builtins.concatMap (fetchFromElement system) manifestAttr.elements;
            env = makeEnv system packages;
          in {
            default = env;
            manifest = makeManifest system env manifestPath;
          }
        )
        systems; # }}}

      # Copied from nixpkgs
      last = list: builtins.elemAt list (builtins.length list - 1);

      # Parse an attribute string into a list of strings
      parsePath = with builtins; # {{{
      
        attrPath: let
          raw = filter isString (split "\\." attrPath);
          stripQuotes = replaceStrings [''"''] [""];
          result =
            foldl' (
              acc: i:
                if length acc > 0 && isList (self.lib.last acc)
                then
                  if !isNull (match ''.*("+)$'' i)
                  then init acc ++ [(concatStringsSep "." (last acc ++ [(stripQuotes i)]))]
                  else init acc ++ [(last acc ++ [(stripQuotes i)])]
                else if !isNull (match ''^("+).*'' i)
                then acc ++ [[(stripQuotes i)]]
                else acc ++ [i]
            ) []
            raw;
        in
          result; # }}}
      # Generate a packageset given a manifest attribute structure
      packageSet = system: manifestAttr: let
        # Copied from nixpkgs {{{
        recursiveUpdateUntil = pred: lhs: rhs: let
          f = attrPath:
            builtins.zipAttrsWith (
              n: values: let
                here = attrPath ++ [n];
              in
                if
                  builtins.length values
                  == 1
                  || pred here (builtins.elemAt values 1) (builtins.head values)
                then builtins.head values
                else f here values
            );
        in
          f [] [rhs lhs];
        recursiveUpdate = recursiveUpdateUntil (path: lhs: rhs: !(builtins.isAttrs lhs && builtins.isAttrs rhs));
        setAttrByPath = attrPath: value: let
          len = builtins.length attrPath;
          atDepth = n:
            if n == len
            then value
            else {${builtins.elemAt attrPath n} = atDepth (n + 1);};
        in
          atDepth 0;

        getAttrFromPath = attrPath: let
          errorMsg = "cannot find attribute `" + builtins.concatStringsSep "." attrPath + "'";
        in
          attrByPath attrPath (abort errorMsg);

        attrByPath = attrPath: default: e: let
          attr = builtins.head attrPath;
        in
          if attrPath == []
          then e
          else if e ? ${attr}
          then attrByPath (builtins.tail attrPath) default e.${attr}
          else default;
        # }}}
      in (builtins.foldl' (acc: x: recursiveUpdate acc x) {}
        (
          map (
            x: let
              a = builtins.getFlake x.url;
              path = self.lib.parsePath x.attrPath;
            in
              if x ? url
              then setAttrByPath path (getAttrFromPath path a)
              else let
                packages = map builtins.storePath x.storePaths;
              in {
                env = derivation {
                  name = "profile";
                  builder = "builtin:buildenv";
                  system = system;
                  manifest = "/thing";
                  packages = packages;
                  derivations = map (x: ["true" 5 1 x]) packages;
                };
              }
          )
          manifestAttr.elements
        ));
    };
  };
}

{ python }:
python.pkgs.buildPythonPackage
rec { pname = "txxonion";
      version = "0.1";
      src = python.pkgs.fetchPypi
      { inherit pname version;
        extension = "tar.gz";
        sha256 = "0ahfkmrh6mwvxz0jah0m8la5dzf2ns8xj6xv1zgb9mnprqpwvrk4";
      };
      propagatedBuildInputs = [ python.pkgs.zope_interface python.pkgs.twisted python.pkgs.txtorcon ];
}
